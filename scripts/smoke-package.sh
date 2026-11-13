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
#   S3_BUCKET, S3_ENDPOINT, S3_REGION, S3_PREFIX, S3_ADDRESSING_STYLE
#                        signed access to that repository when it is private
#                        (see scripts/fetch-published.sh for the full list)
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

stage=$(mktemp -d "${TMPDIR:-/tmp}/published-$pkg.XXXXXX")
trap 'rm -rf "$stage"' EXIT

# A repository this run cannot read (no public URL, no credentials) must not
# fail the job: the re-check is an extra safety net, not a required step.
rc=0
newest=$(bash "$here/fetch-published.sh" "$pkg" "$stage") || rc=$?
if ((rc != 0)); then
  log "warning: $pkg: could not fetch the published build, skipping this run"
  exit 2
fi

log "$pkg: re-checking the published build $newest"

# The retry runner reports `rebuilt` through GITHUB_OUTPUT. Read it through a
# private file so this script can tell a plain pass from a pass that needed a
# rebuild, then forward the outputs unchanged to the workflow.
outputs=$(mktemp "${TMPDIR:-/tmp}/smoke-outputs-$pkg.XXXXXX")
rc=0
GITHUB_OUTPUT=$outputs PKG_DIR=$stage bash "$here/smoke-with-retry.sh" "$pkg" || rc=$?
rebuilt=$(sed -n 's/^rebuilt=//p' "$outputs" | tail -n 1)
if [[ -n ${GITHUB_OUTPUT:-} && -s $outputs ]]; then
  cat "$outputs" >>"$GITHUB_OUTPUT"
fi
rm -f "$outputs"

# The published build still works against this dependency set, and the next
# plan run can skip re-checking it until something moves again. The record only
# covers the build that was just checked, so a retry rebuild (which publishes a
# fresh baseline) does not write one.
if ((rc == 0)) && [[ $rebuilt != true ]]; then
  verified=$root/.smoke-verified
  mkdir -p "$verified"
  printf '%s\n' "$drift" >"$verified/$pkg.txt"
  log "$pkg: recorded the verified dependency set in .smoke-verified/$pkg.txt"
fi

exit "$rc"
