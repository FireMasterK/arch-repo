#!/usr/bin/env bash
# Run a package's startup smoke test in a disposable Arch container.
#
# Usage: scripts/smoke-test.sh <package>
#
# Exit codes:
#   0 - the package started successfully
#   1 - the startup check failed (logs are in $LOG_DIR/<package>)
#   2 - skipped (nothing to test, or an unbuildable dependency is missing)
#
# Environment:
#   PKG_DIR      directory containing the built packages (default: out)
#   SMOKE_IMAGE  container image (default: archlinux:latest)
#   LOG_DIR      where logs are written (default: smoke-logs)
#   LOG_SUBDIR   directory under LOG_DIR (default: the package name)
#   S3_PUBLIC_BASE_URL, S3_BUCKET, S3_ENDPOINT - how to read the published
#                        repository for siblings that were not built here
#                        (see scripts/fetch-published.sh)
#
# The container uses a headless Weston compositor (Wayland virtual buffer), so
# GUI packages can be verified on a machine/CI runner without a display.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd -- "$here/.." && pwd)
# shellcheck source=lib.sh
source "$here/lib.sh"

[[ $# -eq 1 ]] || die "usage: $0 <package>"
pkg=$1

image=${SMOKE_IMAGE:-archlinux:latest}
pkg_dir=$(cd -- "${PKG_DIR:-$root/out}" && pwd)
# LOG_SUBDIR defaults to the package name; the retry runner nests a second
# attempt under "<package>/retry" so the first attempt's logs are preserved.
log_dir=${LOG_DIR:-$root/smoke-logs}/${LOG_SUBDIR:-$pkg}

[[ -d $root/packages/$pkg ]] || die "unknown package: $pkg"

shopt -s nullglob
packages=("$pkg_dir/$pkg"-[0-9]*.pkg.tar.zst)
if ((${#packages[@]} == 0)); then
  log "$pkg: no built package in $pkg_dir, skipping startup check"
  exit 2
fi

command -v docker >/dev/null || die 'docker is required'

rm -rf "$log_dir"
mkdir -p "$log_dir"

# Stage the package plus the sibling packages it depends on. Siblings are not in
# the Arch repositories; prefer this run's artifacts, then the already published
# repo so a package whose sibling was not rebuilt is still testable.
stage=$(mktemp -d "${TMPDIR:-/tmp}/smoke-pkgs-$pkg.XXXXXX")
trap 'rm -rf "$stage"' EXIT
cp -f "$pkg_dir/$pkg"-[0-9]*.pkg.tar.zst "$stage"/

sibling_deps() {
  # depends entries that name a package directory in this repo.
  local dep
  sed -n 's/^[[:space:]]*depends = //p' "$root/packages/$pkg/.SRCINFO" 2>/dev/null |
    while read -r dep; do
      dep=${dep%%[<>=]*}
      [[ -d $root/packages/$dep ]] && printf '%s\n' "$dep"
    done | sort -u
}

for dep in $(sibling_deps); do
  if cp -f "$pkg_dir/$dep"-[0-9]*.pkg.tar.zst "$stage"/ 2>/dev/null; then
    continue
  fi
  rc=0
  newest=$(bash "$here/fetch-published.sh" "$dep" "$stage") || rc=$?
  if ((rc != 0)); then
    log "warning: '$dep' was not built in this run and is not in the published repo"
    continue
  fi
  log "$pkg: staging sibling '$newest' from the published repo"
done

log "smoke testing $pkg $(basename "${packages[0]}")"

rc=0
docker run --rm \
  --shm-size=512m \
  -e PACKAGE="$pkg" \
  -e SMOKE_IMAGE="$image" \
  -v "$stage:/pkgs:ro" \
  -v "$root/scripts:/smoke-scripts:ro" \
  -v "$root/packages:/smoke-packages:ro" \
  -v "$root/packages/$pkg:/smoke-package:ro" \
  -v "$log_dir:/logs" \
  "$image" \
  bash /smoke-scripts/smoke-runner.sh || rc=$?

# The container runs as root; hand the logs back to the invoking user.
if ((rc != 125 && EUID != 0)); then
  docker run --rm -v "$log_dir:/logs" "$image" \
    chown -R "$(id -u):$(id -g)" /logs >/dev/null 2>&1 || true
fi

case $rc in
0) log "$pkg passed startup check (logs: $log_dir)" ;;
1) log "$pkg FAILED startup check (logs: $log_dir)" ;;
2) log "$pkg startup check skipped" ;;
*) die "smoke test for $pkg could not run (docker exit $rc)" ;;
esac

exit "$rc"
