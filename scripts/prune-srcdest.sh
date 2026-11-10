#!/usr/bin/env bash
# Drop downloaded sources that the current version of a package does not use.
#
# CI restores SRCDEST from the previous run, so without this the download cache
# keeps one copy of every upstream release forever and eventually costs more to
# restore than downloading the one file the build needs.
#
# Usage: scripts/prune-srcdest.sh <package>
#
# Environment:
#   SRCDEST - makepkg download cache (default: <repo>/.srcdest)
#   GITHUB_WORKSPACE - repo root (defaults to this script's parent)
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=${GITHUB_WORKSPACE:-$(cd -- "$here/.." && pwd)}
# shellcheck source=lib.sh
source "$here/lib.sh"

[[ $# -eq 1 ]] || die "usage: $0 <package>"
pkg=$1

srcdest=${SRCDEST:-$root/.srcdest}
srcinfo=$root/packages/$pkg/.SRCINFO
[[ -d $srcdest ]] || exit 0
if [[ ! -f $srcinfo ]]; then
  log "$pkg: no .SRCINFO, leaving $srcdest alone"
  exit 0
fi

# `source` entries are either `filename::url` or a bare URL/path; in both cases
# the file makepkg stores in SRCDEST is the part before `::`, or the basename.
declare -A keep=()
while IFS= read -r entry; do
  entry=${entry%%::*}
  keep[${entry##*/}]=1
done < <(sed -n 's/^[[:space:]]*source = //p' "$srcinfo")

removed=0
shopt -s nullglob
for file in "$srcdest"/*; do
  [[ -f $file ]] || continue
  [[ -n ${keep[${file##*/}]:-} ]] && continue
  rm -f "$file"
  removed=$((removed + 1))
done

log "$pkg: pruned $removed stale download(s) from $srcdest"
