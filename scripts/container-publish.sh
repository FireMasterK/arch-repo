#!/usr/bin/env bash
# Used by both GitHub Actions and local dry runs. Bootstraps an Arch container
# and invokes publish.sh.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd -- "$here/.." && pwd)

pacman-key --init >/dev/null
pacman-key --populate archlinux >/dev/null
pacman -Syu --noconfirm --needed git python >/dev/null
# The aws CLI is only needed for a real upload.
if [[ ${DRY_RUN:-0} != 1 ]]; then
  pacman -S --noconfirm --needed aws-cli >/dev/null
fi

export GITHUB_WORKSPACE=$root
exec bash "$root/scripts/publish.sh"
