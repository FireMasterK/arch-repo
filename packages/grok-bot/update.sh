#!/usr/bin/env bash
# Resolve the latest Grok Bot release and update this package's PKGBUILD.
#
# x.ai/bot is a Next.js site. The per-platform download links are hard-coded in
# a JS chunk as hashed URLs:
#   https://api2.cursor.sh/updates/download/stable/linux-x64/grok-bot-<hash>
# That URL 302-redirects to the versioned .deb:
#   https://downloads.cursor.com/grokbot/stable/<commit>/linux/x64/grok-bot_<ver>_amd64.deb
# The hash changes on every build, so we scrape the current chunk, resolve the
# redirect and read the version + commit from the final URL.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../scripts/lib.sh
source "$here/../../scripts/lib.sh"

pkgbuild=$here/PKGBUILD
page_url='https://x.ai/bot'
ua='Mozilla/5.0 (X11; Linux x86_64) arch-repo-updater/1.0'

curl_opts=(--fail --silent --show-error --location --retry 5 --retry-delay 2 --retry-all-errors --max-time 60)

page=$(fetch "$ua" "${curl_opts[@]}" "$page_url") || die 'grok-bot: failed to fetch x.ai/bot'

mapfile -t chunks < <(
  grep -oE '/_next/static/chunks/[A-Za-z0-9_.~-]+\.js' <<<"$page" | sort -u
)
((${#chunks[@]} > 0)) || die 'grok-bot: no JS chunks found on x.ai/bot (site layout changed?)'

download_url=''
for chunk in "${chunks[@]}"; do
  body=$(fetch "$ua" "${curl_opts[@]}" "https://x.ai$chunk") || continue
  if [[ $body =~ linux-x64/grok-bot-([0-9a-f]{8,}) ]]; then
    download_url="https://api2.cursor.sh/updates/download/stable/linux-x64/grok-bot-${BASH_REMATCH[1]}"
    break
  fi
done

[[ -n $download_url ]] || die 'grok-bot: no linux-x64 download link found in x.ai JS chunks'

final_url=$(fetch "$ua" "${curl_opts[@]}" --head -o /dev/null -w '%{url_effective}' "$download_url") ||
  die "grok-bot: failed to resolve $download_url"

if [[ $final_url =~ /grokbot/stable/([0-9a-f]{40})/linux/x64/grok-bot_([0-9][0-9.]*)_amd64\.deb$ ]]; then
  commit=${BASH_REMATCH[1]}
  version=${BASH_REMATCH[2]}
else
  die "grok-bot: unexpected download URL: $final_url"
fi

current=$(pkgvar "$pkgbuild" pkgver)
current_commit=$(pkgvar "$pkgbuild" _commit)

if [[ $current == "$version" && $current_commit == "$commit" ]]; then
  log "grok-bot: up to date ($version, $commit)"
  exit 0
fi

set_pkgvar "$pkgbuild" pkgver "$version"
set_pkgvar "$pkgbuild" _commit "$commit"
set_pkgvar "$pkgbuild" pkgrel 1
log "grok-bot: $current ($current_commit) -> $version ($commit)"
