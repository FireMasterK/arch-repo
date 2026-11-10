#!/usr/bin/env bash
# Resolve the latest CodSpeed runner release and update this package's PKGBUILD.
#
# Upstream publishes prebuilt runner tarballs on GitHub. The `releases/latest`
# redirect resolves to the newest non-prerelease tag without needing the API.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../scripts/lib.sh
source "$here/../../scripts/lib.sh"

pkgbuild=$here/PKGBUILD
ua='arch-repo-updater/1.0 (+https://github.com/FireMasterK/arch-repo)'

curl_opts=(--fail --silent --show-error --location --retry 5 --retry-delay 2 --retry-all-errors --max-time 60)

release_url=$(curl "${curl_opts[@]}" --head -o /dev/null -w '%{url_effective}' -A "$ua" \
  'https://github.com/CodSpeedHQ/codspeed/releases/latest') ||
  die 'codspeed: failed to resolve the latest GitHub release'

[[ $release_url =~ /releases/tag/v([0-9]+(\.[0-9]+)+)$ ]] ||
  die "codspeed: unexpected latest release URL: $release_url"
version=${BASH_REMATCH[1]}

asset_url="https://github.com/CodSpeedHQ/codspeed/releases/download/v${version}/codspeed-runner-x86_64-unknown-linux-musl.tar.gz"
curl "${curl_opts[@]}" --head -o /dev/null -A "$ua" "$asset_url" ||
  die "codspeed: codspeed-runner asset is missing from release v$version"

current=$(pkgvar "$pkgbuild" pkgver)

if [[ $current == "$version" ]]; then
  log "codspeed: up to date ($version)"
  exit 0
fi

set_pkgvar "$pkgbuild" pkgver "$version"
set_pkgvar "$pkgbuild" pkgrel 1
log "codspeed: $current -> $version"
