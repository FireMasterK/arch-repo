#!/usr/bin/env bash
# Report runtime dependencies whose Arch version changed since <package> was built.
#
# A source package compiled months ago can stop starting after Arch moves a
# library (or the debuginfo it is coupled to). Re-checking it is only worth it
# when something it runs against has actually changed, so the versions recorded
# when the published build was made are compared with the current repositories.
#
# Usage: scripts/dep-drift.sh <package>
#
# Exit codes:
#   0 - a runtime dependency changed: its "<name> <built> <now>" lines on stdout
#   1 - every runtime dependency is unchanged
#   2 - no baseline recorded yet (nothing to compare against)
#   3 - the check could not run (docker/image/network problem)
#
# Environment:
#   SMOKE_IMAGE  container image used to read the current repositories
#
# `--dump` prints the current `pacman -Si` output and exits, so callers that
# check many packages (scripts/plan-smoke-tests.sh) read the databases once.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd -- "$here/.." && pwd)
# shellcheck source=lib.sh
source "$here/lib.sh"

# A transient failure here must not look like "no drift", so it gets its own
# exit code and the caller can skip the package instead of reporting it.
unavailable() {
  printf 'error: %s\n' "$*" >&2
  exit 3
}

image=${SMOKE_IMAGE:-archlinux:latest}

# Refresh the sync databases so the dump describes the repositories as they are
# right now. A full upgrade is not needed: only the versions in the repos matter.
read_database() {
  docker run --rm "$image" bash -c '
    set -e
    pacman-key --init >/dev/null 2>&1
    pacman-key --populate archlinux >/dev/null 2>&1
    pacman -Sy --noconfirm >/dev/null 2>&1
    pacman -Si
  '
}

if [[ ${1:-} == --dump ]]; then
  command -v docker >/dev/null || unavailable 'docker is required'
  read_database || unavailable "could not read the package databases from $image"
  exit 0
fi

[[ $# -eq 1 ]] || die "usage: $0 <package>"
pkg=$1

dir=$root/packages/$pkg
baseline=$dir/build-env.txt
[[ -d $dir ]] || die "unknown package: $pkg"
if [[ ! -f $baseline ]]; then
  log "$pkg: no build baseline recorded yet, nothing to compare"
  exit 2
fi

command -v docker >/dev/null || unavailable 'docker is required'

dump=$(mktemp "${TMPDIR:-/tmp}/pacman-si.XXXXXX")
trap 'rm -f "$dump"' EXIT

read_database >"$dump" || unavailable "could not read the package databases from $image"

rc=0
python3 "$here/dep-drift.py" "$root" "$pkg" "$baseline" "$dump" || rc=$?
case $rc in
0 | 1 | 2) exit "$rc" ;;
*) unavailable "could not compare the dependency versions (exit $rc)" ;;
esac
