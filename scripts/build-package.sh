#!/usr/bin/env bash
# Build one package and stage the build products plus the refreshed metadata.
#
# Environment:
#   PACKAGE  - package directory name (required)
#   FORCE    - "true" to bump pkgrel and rebuild an unchanged version
#   SKIP_UPDATE - "true" to rebuild without running update.sh
#   GITHUB_WORKSPACE - repo root (defaults to this script's parent)
#   SRCDEST  - makepkg download cache (defaults to <repo>/.srcdest)
set -euo pipefail

: "${PACKAGE:?PACKAGE is required}"

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=${GITHUB_WORKSPACE:-$(cd -- "$here/.." && pwd)}
# shellcheck source=lib.sh
source "$here/lib.sh"

dir=$root/packages/$PACKAGE
[[ -f $dir/PKGBUILD ]] || die "no PKGBUILD for package '$PACKAGE'"

cd "$dir"

# An updater can be skipped to rebuild the version already in the tree (used by
# the smoke-test retry, which must not pick up a new upstream release).
if [[ -f update.sh && ${SKIP_UPDATE:-false} != true ]]; then
  before=$(pkgvar PKGBUILD pkgver)
  bash update.sh
  after=$(pkgvar PKGBUILD pkgver)
else
  before='' after=''
fi

# Only bump pkgrel when the version itself did not change; a fresh version
# always starts at pkgrel=1 (handled by update.sh).
if [[ ${FORCE:-false} == true && $before == "$after" ]]; then
  bump_pkgrel PKGBUILD
fi

# makepkg runs with --nodeps/--nocheck, so install the build dependencies here.
# Deps that are not in the configured repos (e.g. a sibling package from this
# repo) are skipped; makepkg does not need them to run.
install_makedepends() {
  local dep
  local -a deps=() available=()

  mapfile -t deps < <(
    makepkg --printsrcinfo |
      sed -n 's/^[[:space:]]*makedepends = //p' |
      sed 's/[<>=].*//' |
      sort -u
  )

  for dep in "${deps[@]}"; do
    [[ -n $dep ]] || continue
    if pacman -Si "$dep" >/dev/null 2>&1; then
      available+=("$dep")
    else
      log "skipping makedepend '$dep' (not in the sync repos)"
    fi
  done

  ((${#available[@]})) || return 0
  log "installing makedepends: ${available[*]}"
  sudo pacman -S --needed --noconfirm --asdeps "${available[@]}"
}

install_makedepends

export SRCDEST=${SRCDEST:-$root/.srcdest}
mkdir -p "$SRCDEST"

log "updating checksums ($PACKAGE)"
updpkgsums

log "generating .SRCINFO ($PACKAGE)"
makepkg --printsrcinfo >.SRCINFO

log "building $PACKAGE $(pkgvar PKGBUILD pkgver)-$(pkgvar PKGBUILD pkgrel)"

# Remove packages from earlier builds first; makepkg names its output, so a
# leftover file would otherwise be copied to out/ as if it were just built.
rm -f ./*.pkg.tar.zst

makepkg --nodeps --nocheck --noconfirm --force

shopt -s nullglob
built=(./*.pkg.tar.zst)
((${#built[@]})) || die "makepkg produced no package for '$PACKAGE'"

out=$root/out
mkdir -p "$out"
# Drop stale packages for this package so out/ only holds the new build; the
# smoke retry selects the newest file there.
rm -f "$out/$PACKAGE"-[0-9]*.pkg.tar.zst "$out/$PACKAGE"-debug-*.pkg.tar.zst
cp -f "${built[@]}" "$out/"
cp -f PKGBUILD "$out/PKGBUILD.$PACKAGE"
cp -f .SRCINFO "$out/SRCINFO.$PACKAGE"

log "staged $(basename "${built[0]}")"
