#!/usr/bin/env bash
# Run a package's startup check, rebuilding it once if it fails.
#
# Source-built packages (those with a build() function) are compiled against the
# Arch packages that exist on the day they are built. When Arch later bumps a
# dependency, an old binary can stop starting even though our packaging is fine,
# so a failure is retried once against a freshly updated container before it is
# reported. Binary repacks cannot be rebuilt at all, so they fail immediately.
#
# Usage: scripts/smoke-with-retry.sh <package>
#
# Exit codes: 0 pass, 1 fail, 2 skipped (same as scripts/smoke-test.sh).
#
# Environment (in addition to smoke-test.sh's):
#   PKG_DIR      packages to test (default: out; the retry uses out/ too)
#   LOG_DIR      smoke log root (default: smoke-logs)
#   GITHUB_OUTPUT - receives log_subdir=<dir> and rebuilt=<true|false>
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=${GITHUB_WORKSPACE:-$(cd -- "$here/.." && pwd)}
# shellcheck source=lib.sh
source "$here/lib.sh"

[[ $# -eq 1 ]] || die "usage: $0 <package>"
pkg=$1

log_root=${LOG_DIR:-$root/smoke-logs}
pkg_dir=${PKG_DIR:-$root/out}
subdir=$pkg
rebuilt=false

outputs() {
  [[ -n ${GITHUB_OUTPUT:-} ]] || return 0
  printf 'log_subdir=%s\n' "$subdir" >>"$GITHUB_OUTPUT"
  printf 'rebuilt=%s\n' "$rebuilt" >>"$GITHUB_OUTPUT"
}

# A PKGBUILD with a build() function compiles from source; repacks only have
# package(). smoke.conf may override the decision with SMOKE_REBUILD_ON_FAILURE.
rebuild_on_failure() {
  local conf=$root/packages/$pkg/smoke.conf override=''
  if [[ -f $conf ]]; then
    override=$(sed -n 's/^[[:space:]]*SMOKE_REBUILD_ON_FAILURE=//p' "$conf" |
      tail -n 1 | tr -d "\"' ")
  fi
  case $override in
  true) return 0 ;;
  false) return 1 ;;
  esac
  grep -qE '^[[:space:]]*build[[:space:]]*\(\)' "$root/packages/$pkg/PKGBUILD"
}

run_attempt() {
  local sub=$1 rc=0
  LOG_SUBDIR=$sub PKG_DIR=$pkg_dir bash "$here/smoke-test.sh" "$pkg" || rc=$?
  return "$rc"
}

rc=0
run_attempt "$subdir" || rc=$?
if ((rc == 0 || rc == 2)); then
  # 0 = passed, 2 = skipped (nothing was built for this package).
  outputs
  exit "$rc"
fi
((rc == 1)) || die "$pkg: unexpected smoke-test exit code $rc"

if ! rebuild_on_failure; then
  log "$pkg: binary repack cannot be rebuilt, reporting the failure as-is"
  outputs
  exit 1
fi

log "$pkg: startup check failed, rebuilding against the current Arch packages"
if ! FORCE=true SKIP_UPDATE=true bash "$here/local-build.sh" "$pkg"; then
  log "$pkg: rebuild failed; reporting the original startup failure"
  printf 'REBUILD=failed\n' >>"$log_root/$subdir/summary.txt" 2>/dev/null
  outputs
  exit 1
fi

rebuilt=true
# local-build.sh writes the rebuilt package to <repo>/out.
pkg_dir=$root/out
log "$pkg: retesting the rebuilt package"
subdir=$pkg/retry
rc=0
run_attempt "$subdir" || rc=$?
outputs

if ((rc == 0)); then
  log "$pkg: rebuilt package passes startup check"
  printf 'REBUILD=fixed\n' >>"$log_root/$subdir/summary.txt" 2>/dev/null
  exit 0
fi

# The rebuild supersedes the original build even though it still fails: it is at
# least compiled against the current Arch packages.
log "$pkg: rebuilt package still fails startup check"
printf 'REBUILD=ineffective\n' >>"$log_root/$subdir/summary.txt" 2>/dev/null
exit "$rc"
