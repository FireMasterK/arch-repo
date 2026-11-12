#!/usr/bin/env bash
# Run every package's update.sh and report which packages need a rebuild.
#
# Outputs (to $GITHUB_OUTPUT when running in Actions):
#   matrix          - JSON array of package names to build
#   has_updates     - "true" when matrix is non-empty
#   test_candidates - JSON array of published source packages whose dependency
#                     drift should be checked (see scripts/plan-smoke-tests.sh)
#   failed          - comma separated list of packages whose updater failed
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd -- "$here/.." && pwd)
# shellcheck source=lib.sh
source "$here/lib.sh"

force=${FORCE:-false}
read -r -a filter <<<"${PACKAGES:-}"
event=${GITHUB_EVENT_NAME:-local}

contains() {
  local needle=$1 candidate
  shift
  for candidate in "$@"; do
    [[ $candidate == "$needle" ]] && return 0
  done
  return 1
}

changed=()
failed=()
# pkgver per package, used by the workflow to key the source-download cache.
declare -A versions=()

while IFS= read -r dir; do
  pkg=$(basename "$dir")

  if ((${#filter[@]})) && ! contains "$pkg" "${filter[@]}"; then
    continue
  fi

  # Packages without an updater are only built when something was pushed
  # (or forced), so they can be maintained by hand.
  if [[ ! -f $dir/update.sh ]]; then
    versions[$pkg]=$(pkgvar "$dir/PKGBUILD" pkgver)
    if [[ $event == push || $force == true ]]; then
      log "$pkg: no updater, scheduling rebuild (event: $event, force: $force)"
      changed+=("$pkg")
    fi
    continue
  fi

  before=$(pkgvar "$dir/PKGBUILD" pkgver)

  if ! (cd "$dir" && bash update.sh); then
    printf '::warning title=Updater failed::%s\n' "$pkg" >&2
    failed+=("$pkg")
    continue
  fi

  after=$(pkgvar "$dir/PKGBUILD" pkgver)
  versions[$pkg]=$after

  if [[ $after != "$before" ]]; then
    changed+=("$pkg")
  elif [[ $force == true ]]; then
    bump_pkgrel "$dir/PKGBUILD"
    changed+=("$pkg")
  fi
done < <(package_dirs "$root")

# Source packages whose published build may no longer match the Arch packages
# it runs against. Packages built in this run are always tested; the rest are
# filtered by scripts/plan-smoke-tests.sh, which compares dependency versions
# once for the whole set so a quiet scheduled run starts no smoke jobs at all.
candidates=()
while IFS= read -r dir; do
  pkg=$(basename "$dir")

  if ((${#filter[@]})) && ! contains "$pkg" "${filter[@]}"; then
    continue
  fi
  contains "$pkg" "${changed[@]}" && continue
  builds_from_source "$root" "$pkg" || continue
  [[ -f $dir/build-env.txt ]] || continue
  candidates+=("$pkg")
done < <(package_dirs "$root")

# Packages that compile from source. The build job uses this to decide which
# matrix entries have anything to put in the compiler cache.
sources=()
while IFS= read -r dir; do
  pkg=$(basename "$dir")
  builds_from_source "$root" "$pkg" && sources+=("$pkg")
done < <(package_dirs "$root")

matrix='[]'
if ((${#changed[@]})); then
  matrix=$(printf '%s\n' "${changed[@]}" | jq -R . | jq -sc .)
fi

test_candidates='[]'
if ((${#candidates[@]})); then
  test_candidates=$(printf '%s\n' "${candidates[@]}" | jq -R . | jq -sc .)
fi

source_matrix='[]'
if ((${#sources[@]})); then
  source_matrix=$(printf '%s\n' "${sources[@]}" | jq -R . | jq -sc .)
fi

# package -> pkgver, so the build job can key its download cache by version: a
# new upstream release must not restore (and then throw away) the old sources.
versions_json=$(
  for pkg in "${!versions[@]}"; do
    printf '%s\t%s\n' "$pkg" "${versions[$pkg]}"
  done | jq -R 'split("\t") | {(.[0]): .[1]}' | jq -sc 'add // {}'
)

failed_csv=$(IFS=,; echo "${failed[*]-}")

emit() {
  if [[ -n ${GITHUB_OUTPUT:-} ]]; then
    printf '%s\n' "$1" >>"$GITHUB_OUTPUT"
  else
    printf '%s\n' "$1"
  fi
}

emit "matrix=$matrix"
emit "has_updates=$([[ ${#changed[@]} -gt 0 ]] && echo true || echo false)"
emit "test_candidates=$test_candidates"
emit "source_matrix=$source_matrix"
emit "versions=$versions_json"
emit "failed=$failed_csv"

if ((${#changed[@]})); then
  log "to build: ${changed[*]}"
else
  log 'all packages are up to date'
fi
