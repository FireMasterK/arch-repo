#!/usr/bin/env bash
# Resolve the latest stable Cursor release and update this package's PKGBUILD.
#
# Upstream metadata: https://cursor.com/api/download?platform=linux-x64&releaseTrack=stable
# The API returns the version, the commit sha and the .deb URL. The PKGBUILD
# derives its source URL from the commit + pkgver, so both must stay in sync.
#
# Upstream bundles its own Electron, while the PKGBUILD replaces it with Arch's
# electronNN package. The bundled Electron major is read from the release's .deb
# so a Cursor update that moves to a new Electron major does not need a manual
# `_electron` edit.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../scripts/lib.sh
source "$here/../../scripts/lib.sh"

pkgbuild=$here/PKGBUILD
api='https://cursor.com/api/download?platform=linux-x64&releaseTrack=stable'
ua='arch-repo-updater/1.0 (+https://github.com/FireMasterK/arch-repo)'

json=$(fetch "$ua" -fsSL --retry 5 --retry-delay 2 --retry-all-errors --max-time 60 "$api") ||
  die 'cursor: failed to fetch the download API'

version=$(jq -er '.version | select(type == "string")' <<<"$json") ||
  die 'cursor: API response has no version'
commit=$(jq -er '.commitSha | select(type == "string")' <<<"$json") ||
  die 'cursor: API response has no commitSha'
deburl=$(jq -er '.debUrl | select(type == "string")' <<<"$json") ||
  die 'cursor: API response has no debUrl'

[[ $version =~ ^[0-9]+(\.[0-9]+)+$ ]] || die "cursor: unexpected version '$version'"
[[ $commit =~ ^[0-9a-f]{40}$ ]] || die "cursor: unexpected commitSha '$commit'"

expected="https://downloads.cursor.com/production/${commit}/linux/x64/deb/amd64/deb/cursor_${version}_amd64.deb"
if [[ $deburl != "$expected" ]]; then
  die "cursor: deb URL layout changed
  expected: $expected
  actual:   $deburl"
fi

current=$(pkgvar "$pkgbuild" pkgver)
current_commit=$(pkgvar "$pkgbuild" _commit)

if [[ $current == "$version" && $current_commit == "$commit" ]]; then
  log "cursor: up to date ($version, $commit)"
  exit 0
fi

# deb_electron_version <deb>
# Prints the Electron version embedded in the deb's launcher binary, e.g. 43.8.4.
deb_electron_version() {
  local deb=$1
  if command -v bsdtar >/dev/null 2>&1; then
    bsdtar -xOf "$deb" data.tar.xz
  elif command -v ar >/dev/null 2>&1; then
    ar p "$deb" data.tar.xz
  else
    return 1
  fi | tar -xJO './usr/share/cursor/cursor' 2>/dev/null |
    grep -aoE 'Electron/[0-9]+(\.[0-9]+)+' |
    sed 's|Electron/||' | sort -uV | tail -n 1
}

log "cursor: $current ($current_commit) -> $version ($commit)"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
deb=$tmp/${deburl##*/}

fetch "$ua" -fsSL --retry 5 --retry-delay 2 --retry-all-errors --max-time 600 \
  -o "$deb" "$deburl" || die 'cursor: failed to download the deb for Electron detection'

electron_version=$(deb_electron_version "$deb" || true)
[[ $electron_version =~ ^([0-9]+)\. ]] ||
  die "cursor: could not read the bundled Electron version from $deb"
electron="electron${BASH_REMATCH[1]}"

# depends= must resolve at install time, and the build container only uses the
# stable repositories. Publishing a package that depends on an Electron Arch has
# not packaged yet would leave clients unable to install it.
fetch "$ua" -fsSL --retry 2 --retry-delay 2 --max-time 30 \
  "https://archlinux.org/packages/extra/x86_64/${electron}/json/" >/dev/null 2>&1 ||
  die "cursor: $electron is not in Arch's extra repository yet (needed by Cursor $version)"

current_electron=$(pkgvar "$pkgbuild" _electron)
set_pkgvar "$pkgbuild" pkgver "$version"
set_pkgvar "$pkgbuild" _commit "$commit"
set_pkgvar "$pkgbuild" _electron "$electron"
set_pkgvar "$pkgbuild" pkgrel 1

if [[ $current_electron != "$electron" ]]; then
  log "cursor: bundled Electron $electron_version: $current_electron -> $electron"
else
  log "cursor: bundled Electron $electron_version, using $electron"
fi
