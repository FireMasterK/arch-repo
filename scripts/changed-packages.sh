#!/usr/bin/env bash
# Work out what a push to main touched, so the plan job can force a rebuild of
# exactly those packages instead of the whole repository.
#
# A push is the only event that carries hand-edited intent (a new or edited
# PKGBUILD), and a hand-edited file has no version change to detect, so those
# packages are force-rebuilt with a pkgrel bump. Narrowing that to the packages
# the commit actually touched keeps "add one package" from rebuilding and
# republishing every other package.
#
# Source packages (those with a build() function) are always rebuilt from a
# push: their output depends on the Arch libraries present on build day, so
# republishing one picks up a fix.
#
# A binary repack is rebuilt only when the push changes what it downloads -
# pkgver, pkgrel or a `_`-prefixed helper such as cursor's `_commit` - or when
# the package is new. A comment or metadata edit is skipped, because rebuilding
# it would re-pack the same upstream artifact: a large download and a duplicate
# package. Its versions otherwise come from its updater alone.
#
# Outputs (to $GITHUB_OUTPUT when running in Actions):
#   packages - space separated names of the source packages the push touched
#   tooling  - "true" when the push changed scripts/build-package.sh, which
#              shapes every package's output, so all of them are forced
#   skip     - "true" when the pushed commit carried SKIP_MARKER, which empties
#              both outputs above
#
# The two are mutually exclusive: when tooling is "true", `packages` is empty
# and the workflow forces every package. An empty `packages` with tooling
# "false" means the push has nothing to force.
#
# A push can opt out of forcing entirely: when the pushed commit's message
# contains the skip marker (SKIP_MARKER, see below), both outputs are emitted
# empty and the run behaves like a scheduled upstream check. That is for
# commits that land under packages/ or scripts/ without changing what gets
# built - refreshed metadata, a comment, a README - which would otherwise
# rebuild (and republish) packages nobody touched.
#
# Environment:
#   BEFORE, AFTER - commits to compare (defaults to HEAD^ and HEAD locally)
#   SKIP_MARKER   - commit message substring that opts the push out of forcing
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd -- "$here/.." && pwd)
# shellcheck source=lib.sh
source "$here/lib.sh"

before=${BEFORE:-}
after=${AFTER:-}

if [[ -z $before || -z $after ]]; then
  before=$(git -C "$root" rev-parse --verify --quiet 'HEAD^') || before=''
  after=$(git -C "$root" rev-parse HEAD)
fi

packages=()
tooling=false
skip=false

# pkg_identity <rev> <package>
# Prints the PKGBUILD lines that decide which upstream artifact the package
# pulls in: pkgver, pkgrel and the updater-maintained `_`-prefixed helpers
# (cursor's `_commit`, termius' `_deb`, ...). Comparing them across two
# revisions separates a "ship this version" push from a comment-only edit
# without evaluating the PKGBUILD.
pkg_identity() {
  git -C "$root" show "$1:packages/$2/PKGBUILD" 2>/dev/null |
    sed -n -E '/^(pkgver|pkgrel|_[A-Za-z0-9_]+)=/p' | sort || true
}

# binary_repack_changed <before> <after> <package>
# True when the push added the binary repack or changed what it downloads. An
# unknown `before` (a new package, or a history the checkout does not have)
# counts as changed so the package is built rather than silently skipped.
binary_repack_changed() {
  local old new
  old=$(pkg_identity "$1" "$3")
  new=$(pkg_identity "$2" "$3")
  [[ -z $old || $old != "$new" ]]
}

# The pushed head commit is the one whose intent this run is acting on, so only
# its message is consulted. Checking the whole range instead would let a marker
# anywhere in a multi-commit push silence commits that meant to rebuild.
marker=${SKIP_MARKER:-'[skip build]'}
if message=$(git -C "$root" log -1 --format=%B "$after" 2>/dev/null); then
  if grep -qiF -- "$marker" <<<"$message"; then
    skip=true
  fi
else
  # Not knowing whether the commit asked to skip means assuming it did not:
  # building something that did not need it is cheaper than a silent no-op.
  log "could not read the message of $after; not honouring $marker"
fi

if [[ $skip == true ]]; then
  # Leave both outputs empty so every consumer of them sees "nothing to force".
  log "commit ${after:0:12} carries $marker; forcing no package"
elif [[ -z $before || $before =~ ^0+$ ]]; then
  # A new branch or a forced push leaves no commit to compare against. Assume the
  # worst instead of silently leaving a changed package unbuilt.
  log 'push has no usable base commit; forcing every package'
  tooling=true
elif ! files=$(git -C "$root" diff --name-only --diff-filter=ACMR "$before" "$after"); then
  log "could not diff $before..$after; forcing every package"
  tooling=true
elif grep -qxF -- 'scripts/build-package.sh' <<<"$files"; then
  # build-package.sh decides how every package is compiled, so a change there
  # affects all of them the way a PKGBUILD edit affects its own package. The
  # other scripts (publishing, smoke tests) do not change what a package
  # contains, so they force nothing.
  log 'push changed the build driver (scripts/build-package.sh); forcing every package'
  tooling=true
else
  # Deleted package directories are left out: there is nothing to build, and
  # removing a package from the published database is a manual step.
  while IFS= read -r pkg; do
    [[ -n $pkg ]] || continue
    [[ -f $root/packages/$pkg/PKGBUILD ]] || continue
    if ! builds_from_source "$root" "$pkg"; then
      # A binary repack only needs a rebuild when the push changed what it
      # downloads. Anything else (a comment, a dependency, a README) would
      # re-pack the artifact its updater already published.
      if binary_repack_changed "$before" "$after" "$pkg"; then
        log "$pkg: binary repack whose version or source changed"
        packages+=("$pkg")
      else
        log "$pkg: binary repack unchanged, so a push does not rebuild it"
      fi
      continue
    fi
    packages+=("$pkg")
  done < <(sed -n 's#^packages/\([^/]*\)/.*#\1#p' <<<"$files" | sort -u)
fi

emit() {
  if [[ -n ${GITHUB_OUTPUT:-} ]]; then
    printf '%s\n' "$1" >>"$GITHUB_OUTPUT"
  else
    printf '%s\n' "$1"
  fi
}

emit "packages=${packages[*]-}"
emit "tooling=$tooling"
emit "skip=$skip"

if [[ $skip == true ]]; then
  log 'nothing will be force-rebuilt; upstream version checks still run'
elif [[ $tooling == true ]]; then
  log 'every package will be force-rebuilt'
elif ((${#packages[@]})); then
  log "to force-rebuild: ${packages[*]}"
else
  log 'push forced no source package; nothing to force-rebuild'
fi
