#!/usr/bin/env bash
# Report the shared libraries a built package links to, and which Arch package
# owns each one.
#
# The dependency closure that dep-drift.sh walks comes from `depends=` in the
# PKGBUILD. This reads the binaries instead: every ELF file in the built
# package is scanned for its DT_NEEDED entries, so a library the app links but
# never declared shows up as `undeclared` rather than being invisible.
#
# Usage: scripts/link-audit.sh [--verbose] [--file-db] [package ...]
#        (default: every package with a built artifact)
#
# Exit codes:
#   0 - every linked library is declared or reached through a dependency
#   1 - at least one linked library is not reachable from `depends=`
#   2 - nothing to audit (no built package for the requested name)
#   3 - the check could not run (docker/image/network problem)
#
# Environment:
#   PKG_DIR       built packages (default: out)
#   SMOKE_IMAGE   container image used to read the current repositories
#   PACMAN_DUMP   reuse an existing `pacman -Si` dump instead of starting docker
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd -- "$here/.." && pwd)
# shellcheck source=lib.sh
source "$here/lib.sh"

# A transient failure here must not look like "no undeclared links", so it gets
# its own exit code and the caller can tell the two apart.
unavailable() {
  printf 'error: %s\n' "$*" >&2
  exit 3
}

image=${SMOKE_IMAGE:-archlinux:latest}
pkg_dir=${PKG_DIR:-$root/out}

# Refresh the sync databases so the dump describes the repositories as they are
# right now. Only the versions and provides matter, so no upgrade is needed.
read_database() {
  docker run --rm "$image" bash -c '
    set -e
    pacman-key --init >/dev/null 2>&1
    pacman-key --populate archlinux >/dev/null 2>&1
    pacman -Sy --noconfirm >/dev/null 2>&1
    pacman -Si
  '
}

# Map sonames to the package that ships the file. `provides` is incomplete (Qt
# and GStreamer declare no sonames), so this reads the file database instead.
# Only the canonical `usr/lib/<soname>` path is kept: other packages bundle
# private copies of the same library under their own directory.
read_file_db() {
  docker run --rm -i "$image" bash -s -- "$@" <<'CONTAINER'
set -e
pacman-key --init >/dev/null 2>&1
pacman-key --populate archlinux >/dev/null 2>&1
pacman -Sy --noconfirm >/dev/null 2>&1
pacman -Fy >/dev/null 2>&1
pacman -F "$@" 2>/dev/null | awk '
  /^[^ \t]/ { pkg = $1; sub(/^[^\/]*\//, "", pkg); next }
  /^[ \t]/  { path = $1; n = split(path, a, "/"); base = a[n];
              if (path == "usr/lib/" base) print base "\t" pkg }
' || true
CONTAINER
}

if [[ ${1:-} == --dump ]]; then
  command -v docker >/dev/null || unavailable 'docker is required'
  read_database || unavailable "could not read the package databases from $image"
  exit 0
fi

verbose=()
file_db=false
while [[ ${1:-} == -* ]]; do
  case $1 in
  --verbose | -v) verbose=(--verbose) ;;
  --file-db) file_db=true ;;
  *) die "unknown option: $1" ;;
  esac
  shift
done

if (($#)); then
  packages=("$@")
else
  mapfile -t packages < <(
    for dir in "$root"/packages/*/; do
      [[ -f $dir/PKGBUILD ]] || continue
      name=$(basename "$dir")
      # Artifacts are staged flat in PKG_DIR, or kept next to the PKGBUILD once
      # the package has been published.
      if compgen -G "$pkg_dir/$name-[0-9]*.pkg.tar.zst" >/dev/null ||
        compgen -G "$dir$name-[0-9]*.pkg.tar.zst" >/dev/null; then
        printf '%s\n' "$name"
      fi
    done
  )
fi

((${#packages[@]})) || {
  log "no built packages in $pkg_dir; build one first or set PKG_DIR"
  exit 2
}

command -v readelf >/dev/null || unavailable 'readelf is required (binutils)'

cleanup=()
trap 'rm -f "${cleanup[@]}"' EXIT

dump=${PACMAN_DUMP:-}
if [[ -z $dump ]]; then
  command -v docker >/dev/null || unavailable 'docker is required (or set PACMAN_DUMP)'
  dump=$(mktemp "${TMPDIR:-/tmp}/pacman-si.XXXXXX")
  cleanup+=("$dump")
  read_database >"$dump" || unavailable "could not read the package databases from $image"
fi

map_args=()
if $file_db; then
  command -v docker >/dev/null || unavailable 'docker is required for --file-db'
  mapfile -t sonames < <(
    python3 "$here/link-audit.py" --sonames "$root" "$pkg_dir" "${packages[@]}"
  )
  if ((${#sonames[@]})); then
    map=$(mktemp "${TMPDIR:-/tmp}/soname-owners.XXXXXX")
    cleanup+=("$map")
    log "resolving ${#sonames[@]} sonames against the file database"
    read_file_db "${sonames[@]}" >"$map" ||
      unavailable "could not read the file database from $image"
    map_args=(--file-db-map "$map")
  fi
fi

rc=0
python3 "$here/link-audit.py" "$root" "$pkg_dir" "$dump" \
  "${verbose[@]}" "${map_args[@]}" "${packages[@]}" || rc=$?
case $rc in
0 | 1 | 2) exit "$rc" ;;
*) unavailable "could not audit the linked libraries (exit $rc)" ;;
esac
