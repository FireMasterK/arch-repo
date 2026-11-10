#!/usr/bin/env bash
# Run startup smoke tests locally against packages already built in out/.
#
# Source packages that fail are rebuilt once and retested (see
# smoke-with-retry.sh); binary repacks fail straight away.
#
# Usage: scripts/local-smoke.sh [package ...]   (default: all packages)
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd -- "$here/.." && pwd)

if (($#)); then
  packages=("$@")
else
  mapfile -t packages < <(
    for dir in "$root"/packages/*/; do
      [[ -f $dir/PKGBUILD ]] && basename "$dir"
    done
  )
fi

((${#packages[@]})) || {
  echo 'no packages found' >&2
  exit 1
}

status=0
for pkg in "${packages[@]}"; do
  rc=0
  "$here/smoke-with-retry.sh" "$pkg" || rc=$?
  # 2 means the package was not built; that is not a test failure.
  ((rc == 0 || rc == 2)) || status=1
done

exit "$status"
