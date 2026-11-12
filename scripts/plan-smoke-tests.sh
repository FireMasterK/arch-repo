#!/usr/bin/env bash
# Decide which packages need a smoke test this run.
#
# A package built in this run is always tested. A source package that was not
# built is only re-checked when one of its runtime dependencies has a different
# version than the one its published build recorded. Reading the Arch databases
# once here (rather than per smoke job) keeps a run with no upstream changes
# from starting a job for every package just to skip it again.
#
# Inputs (JSON arrays):
#   BUILT       - packages built in this run
#   CANDIDATES  - published source packages that might need a re-check
#
# Outputs (to $GITHUB_OUTPUT when running in Actions):
#   test_matrix - JSON array of packages to smoke test
#   has_tests   - "true" when test_matrix is non-empty
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd -- "$here/.." && pwd)
# shellcheck source=lib.sh
source "$here/lib.sh"

mapfile -t tests < <(jq -r '.[]' <<<"${BUILT:-[]}")
mapfile -t candidates < <(jq -r '.[]' <<<"${CANDIDATES:-[]}")

if ((${#candidates[@]})); then
  dump=$(mktemp "${TMPDIR:-/tmp}/pacman-si.XXXXXX")
  trap 'rm -f "$dump"' EXIT

  # One database read and one comparison for the whole set: a per-package loop
  # would re-parse the 300k-line dump for every package in the repository.
  if bash "$here/dep-drift.sh" --dump >"$dump" &&
    batch=$(python3 "$here/dep-drift.py" --batch "$root" "$dump" "${candidates[@]}"); then
    declare -A codes=()
    while IFS= read -r line; do
      case $line in
      '@@ '*)
        read -r _ pkg code <<<"$line"
        codes[$pkg]=$code
        ;;
      *) log "    $line" ;;
      esac
    done <<<"$batch"

    for pkg in "${candidates[@]}"; do
      case ${codes[$pkg]-} in
      0)
        log "$pkg: runtime dependencies changed, scheduling a re-check"
        tests+=("$pkg")
        ;;
      1) log "$pkg: runtime dependencies are unchanged, skipping" ;;
      2) log "$pkg: no build baseline recorded, skipping" ;;
      *)
        # A failed comparison must not silently drop a check.
        log "warning: $pkg: could not compare dependency versions, scheduling a re-check"
        tests+=("$pkg")
        ;;
      esac
    done
  else
    # Without a database read every candidate would be skipped, so re-check
    # them all (smoke-package.sh skips again if it still cannot tell).
    log 'warning: could not read the Arch databases; re-checking every candidate'
    tests+=("${candidates[@]}")
  fi
fi

# A package can only appear once in the matrix, even if the inputs overlap.
if ((${#tests[@]})); then
  mapfile -t tests < <(printf '%s\n' "${tests[@]}" | awk '!seen[$0]++')
fi

test_matrix='[]'
if ((${#tests[@]})); then
  test_matrix=$(printf '%s\n' "${tests[@]}" | jq -R . | jq -sc .)
fi

emit() {
  if [[ -n ${GITHUB_OUTPUT:-} ]]; then
    printf '%s\n' "$1" >>"$GITHUB_OUTPUT"
  else
    printf '%s\n' "$1"
  fi
}

emit "test_matrix=$test_matrix"
emit "has_tests=$([[ ${#tests[@]} -gt 0 ]] && echo true || echo false)"

if ((${#tests[@]})); then
  log "to smoke test: ${tests[*]}"
else
  log 'no packages need a smoke test'
fi
