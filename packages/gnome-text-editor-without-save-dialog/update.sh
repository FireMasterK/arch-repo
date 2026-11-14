#!/usr/bin/env bash
# Resolve the latest gnome-text-editor release and update this PKGBUILD.
#
# Upstream publishes stable releases on GNOME's GitLab with plain numeric tags
# (for example 51.0). Pre-releases use suffixes such as 51.beta and 51.rc, so
# only purely numeric tags are considered.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../scripts/lib.sh
source "$here/../../scripts/lib.sh"

pkgbuild=$here/PKGBUILD
ua='arch-repo-updater/1.0 (+https://github.com/FireMasterK/arch-repo)'

curl_opts=(--fail --silent --show-error --location --retry 5 --retry-delay 2 --retry-all-errors --max-time 60)

json=$(curl "${curl_opts[@]}" -A "$ua" \
  'https://gitlab.gnome.org/api/v4/projects/GNOME%2Fgnome-text-editor/releases?per_page=20') ||
  die 'gnome-text-editor: failed to read the release list'

version=$(jq -er '
  [.[].tag_name | select(test("^[0-9]+(\\.[0-9]+)+$"))] | first // empty
' <<<"$json") ||
  die 'gnome-text-editor: no stable release found'

current=$(pkgvar "$pkgbuild" pkgver)

if [[ $current == "$version" ]]; then
  log "gnome-text-editor: up to date ($version)"
  exit 0
fi

set_pkgvar "$pkgbuild" pkgver "$version"
set_pkgvar "$pkgbuild" pkgrel 1
log "gnome-text-editor: $current -> $version"
