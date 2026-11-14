#!/usr/bin/env bash
# Resolve the latest Termius release and update this package's PKGBUILD.
#
# https://download.termius.com/linux/Termius.deb is a stable URL and the
# electron-updater feed beside it (latest-linux.yml) lags behind releases, so
# the version comes from Termius' own apt repository. Its Packages index lists
# the current termius-app package together with the versioned pool path the
# PKGBUILD downloads, so the version and the source can never disagree.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../scripts/lib.sh
source "$here/../../scripts/lib.sh"

pkgbuild=$here/PKGBUILD
index='https://deb.termius.com/dists/squeeze/main/binary-amd64/Packages.gz'
pool='https://deb.termius.com'
ua='arch-repo-updater/1.0 (+https://github.com/FireMasterK/arch-repo)'
curl_opts=(--fail --silent --show-error --location --retry 5 --retry-delay 2
  --retry-all-errors --max-time 60)

packages=$(fetch "$ua" "${curl_opts[@]}" "$index" | gunzip -c) ||
  die 'termius: failed to fetch the apt Packages index'

# One stanza per package, separated by a blank line.
stanza=$(awk 'BEGIN { RS = "" } $0 ~ /^Package: termius-app\n/ { print; exit }' <<<"$packages")
[[ -n $stanza ]] || die 'termius: termius-app is not in the apt Packages index'

field() { awk -v key="$1:" '$1 == key { print $2; exit }' <<<"$stanza"; }
version=$(field Version)
filename=$(field Filename)
sha256=$(field SHA256)

[[ $version =~ ^[0-9]+(\.[0-9]+)+$ ]] || die "termius: unexpected version '$version'"
[[ $sha256 =~ ^[0-9a-f]{64}$ ]] || die "termius: unexpected SHA256 '$sha256'"

expected="pool/main/t/termius-app/termius-app_${version}_amd64.deb"
if [[ $filename != "$expected" ]]; then
  die "termius: deb path layout changed
  expected: $expected
  actual:   $filename"
fi

current=$(pkgvar "$pkgbuild" pkgver)

if [[ $current == "$version" ]]; then
  log "termius: up to date ($version)"
  exit 0
fi

# Publishing a version whose deb cannot be downloaded would only break the
# build later, so check the pool file before rewriting the PKGBUILD.
fetch "$ua" "${curl_opts[@]}" --range 0-0 --output /dev/null "$pool/$filename" ||
  die "termius: $pool/$filename is not downloadable"

set_pkgvar "$pkgbuild" pkgver "$version"
set_pkgvar "$pkgbuild" pkgrel 1
log "termius: $current -> $version"
