#!/usr/bin/env bash
# Smoke test a package, deciding what to test.
#
# A package built in this run is tested as-is (and rebuilt once if it fails).
# Otherwise the build already in the repository is re-checked against the
# current Arch packages - but only when one of its runtime dependencies has a
# different version than the one it was compiled against, because re-checking
# on every run would cost a container start for nothing.
#
# Usage: scripts/smoke-package.sh <package>
#
# Exit codes: 0 pass, 1 fail, 2 skipped.
#
# Environment:
#   PKG_DIR              built packages (default: out)
#   LOG_DIR              smoke log root (default: smoke-logs)
#   S3_PUBLIC_BASE_URL   published repository, used to fetch the built package
#   REPO_DB              pacman db name (default: arch-repo)
#   SMOKE_IMAGE          image used to read the current package versions
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=${GITHUB_WORKSPACE:-$(cd -- "$here/.." && pwd)}
# shellcheck source=lib.sh
source "$here/lib.sh"

[[ $# -eq 1 ]] || die "usage: $0 <package>"
pkg=$1
pkg_dir=${PKG_DIR:-$root/out}

# Built here: test that artifact (smoke-with-retry rebuilds it on failure).
if compgen -G "$pkg_dir/$pkg-[0-9]*.pkg.tar.zst" >/dev/null; then
  exec bash "$here/smoke-with-retry.sh" "$pkg"
fi

# Nothing was built: re-check the published build when its dependencies moved.
rc=0
drift=$(bash "$here/dep-drift.sh" "$pkg") || rc=$?
case $rc in
0)
  log "$pkg: runtime dependencies changed since the published build:"
  while read -r name was now; do
    log "  $name $was -> $now"
  done <<<"$drift"
  ;;
1)
  log "$pkg: runtime dependencies are unchanged, skipping"
  exit 2
  ;;
2)
  log "$pkg: no published build to re-check, skipping"
  exit 2
  ;;
3)
  # Docker registry or mirror trouble: try again on the next run rather than
  # opening an issue that has no diagnostics behind it.
  log "warning: $pkg: could not compare dependency versions, skipping this run"
  exit 2
  ;;
*)
  die "$pkg: unexpected dependency check exit code $rc"
  ;;
esac

repo_url=${S3_PUBLIC_BASE_URL:-}
[[ -n $repo_url ]] || die 'S3_PUBLIC_BASE_URL is required to re-check a published build'

newest=$(published_filename "$repo_url" "${REPO_DB:-arch-repo}" "$pkg" || true)
if [[ -z $newest ]]; then
  log "$pkg: no published package found, skipping"
  exit 2
fi

stage=$(mktemp -d "${TMPDIR:-/tmp}/published-$pkg.XXXXXX")
trap 'rm -rf "$stage"' EXIT

log "$pkg: re-checking the published build $newest"
if ! curl -fsSL --retry 2 --max-time 300 "${repo_url%/}/$newest" -o "$stage/$newest"; then
  log "warning: $pkg: could not download $newest, skipping this run"
  exit 2
fi

PKG_DIR=$stage bash "$here/smoke-with-retry.sh" "$pkg"
