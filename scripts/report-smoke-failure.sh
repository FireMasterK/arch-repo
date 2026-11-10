#!/usr/bin/env bash
# Open (or update) a GitHub issue after a package startup smoke test fails.
#
# Usage: scripts/report-smoke-failure.sh <package>
#
# Environment:
#   GH_TOKEN           - token with issues:write (set automatically in Actions)
#   GITHUB_REPOSITORY  - owner/repo (set automatically in Actions)
#   GITHUB_RUN_ID      - workflow run id used in the issue body
#   GITHUB_SERVER_URL  - defaults to https://github.com
#   LOG_DIR            - smoke log root (default: smoke-logs)
#   LOG_SUBDIR         - directory under LOG_DIR (default: the package name)
#   REPORT_DRY_RUN=1   - print the issue body instead of calling gh
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd -- "$here/.." && pwd)
# shellcheck source=lib.sh
source "$here/lib.sh"

[[ $# -eq 1 ]] || die "usage: $0 <package>"
pkg=$1

log_dir=${LOG_DIR:-$root/smoke-logs}/${LOG_SUBDIR:-$pkg}
summary=$log_dir/summary.txt
[[ -f $summary ]] || die "missing smoke summary: $summary"

summary_value() {
  sed -n "s/^$1=//p" "$summary" | head -n 1
}

version=$(summary_value VERSION)
reason=$(summary_value REASON)
[[ -n $version ]] || version=unknown
[[ -n $reason ]] || reason='unknown failure'

where=''
[[ $(summary_value WAYLAND) == true ]] && where=' on Wayland'
title="[smoke] $pkg $version failed startup check$where"
run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"

body=$(mktemp)
trap 'rm -f "$body"' EXIT

{
  printf 'The automated startup check for `%s` failed.\n\n' "$pkg"
  printf -- '- **Package:** `%s`\n' "$pkg"
  printf -- '- **Version:** `%s`\n' "$version"
  printf -- '- **Image:** `%s`\n' "$(summary_value IMAGE)"
  printf -- '- **Wayland test:** `%s`\n' "$(summary_value WAYLAND)"
  printf -- '- **Reason:** %s\n' "$reason"
  if [[ -n ${GITHUB_RUN_ID:-} ]]; then
    printf -- '- **Workflow run:** %s\n' "$run_url"
    printf -- '- **Logs artifact:** `smoke-logs-%s-%s`\n' "$pkg" "${GITHUB_RUN_ATTEMPT:-1}"
  fi
  printf '\nThe package was still built and published; this issue only reports the\n'
  printf 'startup regression so it can be fixed or reported upstream.\n'

  printf '\n### Summary\n\n```\n'
  cat "$summary"
  printf '```\n'

  printf '\n### Diagnostics\n\n'
  for file in app.log chrome.log scene-graph.txt devtools.json weston.log \
    runner.log pacman-install.log processes.txt; do
    [[ -s $log_dir/$file ]] || continue
    printf '<details><summary>%s</summary>\n\n```\n' "$file"
    # Keep the issue body under GitHub's 64 KiB limit.
    tail -c 8000 "$log_dir/$file"
    printf '\n```\n\n</details>\n\n'
  done
} >"$body"

if [[ ${REPORT_DRY_RUN:-0} == 1 ]]; then
  cat "$body"
  exit 0
fi

[[ -n ${GITHUB_REPOSITORY:-} ]] || die 'GITHUB_REPOSITORY is required'
command -v gh >/dev/null || die 'the gh CLI is required'

gh label create smoke-test \
  --repo "$GITHUB_REPOSITORY" \
  --color FBCA04 \
  --description 'Automated package startup smoke test' >/dev/null 2>&1 || true

existing=$(gh issue list \
  --repo "$GITHUB_REPOSITORY" \
  --state open \
  --limit 200 \
  --json number,title |
  jq -r --arg title "$title" '.[] | select(.title == $title) | .number' |
  head -n 1 || true)

if [[ -n $existing ]]; then
  log "updating existing issue #$existing"
  gh issue comment "$existing" --repo "$GITHUB_REPOSITORY" --body-file "$body"
else
  log "opening a new issue"
  gh issue create \
    --repo "$GITHUB_REPOSITORY" \
    --title "$title" \
    --body-file "$body" \
    --label smoke-test ||
    gh issue create --repo "$GITHUB_REPOSITORY" --title "$title" --body-file "$body"
fi
