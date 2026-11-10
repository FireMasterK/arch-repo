#!/usr/bin/env bash
# Rebuild the pacman database from the last local build without uploading.
#
# Usage: scripts/local-publish.sh
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd -- "$here/.." && pwd)

[[ -d $root/out ]] || {
  echo 'nothing to publish; run scripts/local-build.sh first' >&2
  exit 1
}

mkdir -p "$root/_artifacts"
cp -f "$root"/out/* "$root/_artifacts/"

docker run --rm \
  -e DRY_RUN=1 \
  -e REPO_DB="${REPO_DB:-arch-repo}" \
  -v "$root:/repo" \
  -w /repo \
  "${IMAGE:-archlinux:base-devel}" \
  bash /repo/scripts/container-publish.sh

# The container runs as root; hand the generated repo back to the caller.
docker run --rm -v "$root:/repo" "${IMAGE:-archlinux:base-devel}" \
  chown -R "$(id -u):$(id -g)" /repo/_repo
