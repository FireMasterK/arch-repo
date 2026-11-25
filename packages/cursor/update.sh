#!/usr/bin/env bash
# Resolve the latest stable Cursor release and update this package's PKGBUILD.
#
# Two upstream endpoints are involved:
#
#  1. Cursor's own update feed, the one its in-app updater calls
#     (out/main.js: createUpdateURL):
#       https://api2.cursor.sh/updates/api/update/linux-x64/cursor/<ver>/anon/stable
#     204 means <ver> is the newest; 200 returns
#     {version, productVersion, url} where the zsync URL carries the build
#     commit as production/<commit>/linux/x64/... It ships ahead of the public
#     download API, so it is the earliest stable signal, but it can advertise a
#     build whose .deb is not on the CDN yet. The machine-id segment is ignored
#     upstream, so a constant placeholder is sent instead of a real id.
#
#  2. The public download API, source of truth for version + commit + .deb:
#       https://cursor.com/api/download?platform=linux-x64&releaseTrack=stable
#     Used when (1) is unavailable, has nothing newer, or points at an
#     unpublished .deb. It also catches a same-version rebuild (new commit).
#
# The PKGBUILD derives its source URL from the commit + pkgver, so both must
# stay in sync.
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
api2='https://api2.cursor.sh/updates/api/update/linux-x64/cursor'
ua='arch-repo-updater/1.0 (+https://github.com/FireMasterK/arch-repo)'

current=$(pkgvar "$pkgbuild" pkgver)
current_commit=$(pkgvar "$pkgbuild" _commit)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# deburl_for <commit> <version>
deburl_for() {
  printf 'https://downloads.cursor.com/production/%s/linux/x64/deb/amd64/deb/cursor_%s_amd64.deb\n' "$1" "$2"
}

# version_gt <a> <b>
# True when <a> is strictly newer than <b>.
version_gt() {
  [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1) == "$1" ]]
}

# deb_available <url>
deb_available() {
  fetch "$ua" -fsSI --retry 2 --retry-delay 2 --max-time 30 "$1" >/dev/null 2>&1
}

version=''
commit=''
deburl=''
resolved=false

# 1. Cursor's own update feed. A candidate is only used once its .deb is
# actually published, which guards against rollout ordering.
http_code=$(fetch "$ua" -sS -o "$tmp/update.json" -w '%{http_code}' \
  --max-time 30 "$api2/$current/anon/stable") || http_code=''

if [[ $http_code == 200 ]]; then
  if candidate_version=$(jq -er '.productVersion | select(type == "string")' "$tmp/update.json") &&
    candidate_commit=$(jq -er '.url | capture("production/(?<commit>[0-9a-f]{40})/").commit' "$tmp/update.json"); then
    if [[ ! $candidate_version =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
      log "cursor: update feed returned an unexpected version '$candidate_version'"
    elif ! version_gt "$candidate_version" "$current"; then
      log "cursor: update feed has no version newer than $current"
    else
      candidate_deburl=$(deburl_for "$candidate_commit" "$candidate_version")
      if deb_available "$candidate_deburl"; then
        version=$candidate_version
        commit=$candidate_commit
        deburl=$candidate_deburl
        resolved=true
        log "cursor: update feed advertises $version ($commit)"
      else
        log "cursor: update feed advertises $candidate_version but its deb is not published yet"
      fi
    fi
  else
    log 'cursor: update feed response is missing productVersion/url'
  fi
elif [[ $http_code == 204 ]]; then
  log "cursor: update feed reports $current is the newest published version"
else
  log "cursor: update feed unavailable (${http_code:-network error})"
fi

# 2. Public download API, including the same-version/new-commit case.
if [[ $resolved == false ]]; then
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

  expected=$(deburl_for "$commit" "$version")
  if [[ $deburl != "$expected" ]]; then
    die "cursor: deb URL layout changed
  expected: $expected
  actual:   $deburl"
  fi

  if [[ $version == "$current" ]]; then
    if [[ $commit == "$current_commit" ]]; then
      log "cursor: up to date ($version, $commit)"
      exit 0
    fi
  elif ! version_gt "$version" "$current"; then
    # The update feed can be ahead of the public API (rollout order), so never
    # let this fallback move the package backwards.
    log "cursor: download API only has $version, older than $current"
    exit 0
  fi
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
