#!/usr/bin/env bash
# Resolve the latest CodSpeed Valgrind fork release and update this PKGBUILD.
#
# The fork tags its releases as <valgrind-version>-0codspeed<N> and vendors
# Capstone as a git submodule, so the PKGBUILD pins both the release and the
# exact Capstone commit the release was built against.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../scripts/lib.sh
source "$here/../../scripts/lib.sh"

pkgbuild=$here/PKGBUILD
ua='arch-repo-updater/1.0 (+https://github.com/FireMasterK/arch-repo)'

curl_opts=(--fail --silent --show-error --location --retry 5 --retry-delay 2 --retry-all-errors --max-time 60)

release_url=$(curl "${curl_opts[@]}" --head -o /dev/null -w '%{url_effective}' -A "$ua" \
  'https://github.com/CodSpeedHQ/valgrind-codspeed/releases/latest') ||
  die 'valgrind-codspeed: failed to resolve the latest GitHub release'

[[ $release_url =~ /releases/tag/([0-9]+(\.[0-9]+)+-0codspeed[0-9]+)$ ]] ||
  die "valgrind-codspeed: unexpected latest release URL: $release_url"
tag=${BASH_REMATCH[1]}
version=${tag/-/_}

current=$(pkgvar "$pkgbuild" pkgver)

if [[ $current == "$version" ]]; then
  log "valgrind-codspeed: up to date ($version)"
  exit 0
fi

# Resolve the Capstone commit the new release pins. Only done when the fork
# version changes, to keep anonymous GitHub API usage negligible.
auth=()
[[ -n ${GITHUB_TOKEN:-} ]] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
api="https://api.github.com/repos/CodSpeedHQ/valgrind-codspeed/contents/third_party/capstone?ref=$tag"

json=$(curl "${curl_opts[@]}" "${auth[@]}" -H 'Accept: application/vnd.github+json' "$api") ||
  die 'valgrind-codspeed: failed to read the Capstone submodule pin'
capstone=$(jq -er 'select(.type == "submodule") | .sha' <<<"$json") ||
  die 'valgrind-codspeed: GitHub response has no submodule sha'
[[ $capstone =~ ^[0-9a-f]{40}$ ]] || die "valgrind-codspeed: unexpected Capstone sha '$capstone'"

set_pkgvar "$pkgbuild" pkgver "$version"
set_pkgvar "$pkgbuild" _capstone "$capstone"
set_pkgvar "$pkgbuild" pkgrel 1
log "valgrind-codspeed: $current -> $version (Capstone $capstone)"
