#!/usr/bin/env bash
# Build packages locally inside the same Arch container used by CI.
#
# Usage: scripts/local-build.sh [package ...]   (default: all packages)
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

command -v docker >/dev/null || {
  echo 'docker is required' >&2
  exit 1
}

echo "==> building: ${packages[*]}"
docker run --rm \
  -e PACKAGES="${packages[*]}" \
  -e FORCE="${FORCE:-false}" \
  -e SKIP_UPDATE="${SKIP_UPDATE:-false}" \
  -e LOCAL_UID="$(id -u)" \
  -e LOCAL_GID="$(id -g)" \
  -v "$root:/repo" \
  -w /repo \
  "${IMAGE:-archlinux:base-devel}" \
  bash /repo/scripts/container-build.sh
