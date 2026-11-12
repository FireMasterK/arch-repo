#!/usr/bin/env bash
# Resolve the latest Lightning release and update this PKGBUILD.
#
# Upstream tags its releases as v<version> and ships the source tree (including
# rust/Cargo.lock and the vendored DeepFilterNet) as the GitHub archive, so the
# source URL needs only the tag.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../scripts/lib.sh
source "$here/../../scripts/lib.sh"

pkgbuild=$here/PKGBUILD
ua='arch-repo-updater/1.0 (+https://github.com/FireMasterK/arch-repo)'

curl_opts=(--fail --silent --show-error --location --retry 5 --retry-delay 2 --retry-all-errors --max-time 60)

release_url=$(curl "${curl_opts[@]}" --head -o /dev/null -w '%{url_effective}' -A "$ua" \
  'https://github.com/Mizerd/lightning/releases/latest') ||
  die 'lightning-matrix: failed to resolve the latest GitHub release'

[[ $release_url =~ /releases/tag/v([0-9]+(\.[0-9]+)+)$ ]] ||
  die "lightning-matrix: unexpected latest release URL: $release_url"
version=${BASH_REMATCH[1]}

current=$(pkgvar "$pkgbuild" pkgver)

if [[ $current == "$version" ]]; then
  log "lightning-matrix: up to date ($version)"
  exit 0
fi

set_pkgvar "$pkgbuild" pkgver "$version"
set_pkgvar "$pkgbuild" pkgrel 1
log "lightning-matrix: $current -> $version"
