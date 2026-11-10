#!/usr/bin/env bash
# Used by both GitHub Actions and scripts/local-build.sh. Bootstraps an Arch
# container and builds every package listed in $PACKAGES.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd -- "$here/.." && pwd)

pacman-key --init >/dev/null
pacman-key --populate archlinux >/dev/null
pacman -Syu --noconfirm --needed git sudo jq python pacman-contrib ccache >/dev/null

# makepkg's `ccache` BUILDENV puts /usr/lib/ccache/bin first on PATH, so every
# compiler call in build() goes through ccache without touching a PKGBUILD. The
# cache lives in the workspace so CI can restore/save it between runs.
mkdir -p /etc/makepkg.conf.d
printf 'BUILDENV=(!distcc color ccache check !sign)\n' >/etc/makepkg.conf.d/10-ccache.conf
export CCACHE_DIR=${CCACHE_DIR:-$root/.ccache}
export CCACHE_COMPILERCHECK=${CCACHE_COMPILERCHECK:-content}
export CCACHE_MAXSIZE=${CCACHE_MAXSIZE:-1G}

uid=${LOCAL_UID:-1000}
gid=${LOCAL_GID:-1000}
if ! id builder >/dev/null 2>&1; then
  group=$(getent group "$gid" | cut -d: -f1 || true)
  if [[ -z $group ]]; then
    groupadd -g "$gid" builder
    group=builder
  fi
  useradd -m -u "$uid" -g "$group" builder || useradd -m builder
fi
printf 'builder ALL=(ALL) NOPASSWD: ALL\n' >/etc/sudoers.d/builder
chmod 0440 /etc/sudoers.d/builder
mkdir -p "$CCACHE_DIR"
chown -R "$uid:$gid" "$root"
chown "$uid:$gid" "$CCACHE_DIR"
runuser -u builder -- env HOME=/home/builder CCACHE_DIR="$CCACHE_DIR" \
  ccache --max-size="$CCACHE_MAXSIZE" >/dev/null

export GITHUB_WORKSPACE=$root
export PACKAGER='Kavin <20838718+FireMasterK@users.noreply.github.com>'
for pkg in ${PACKAGES:-}; do
  echo "==> building $pkg"
  runuser -u builder -- env \
    HOME=/home/builder \
    GITHUB_WORKSPACE="$root" \
    PACKAGE="$pkg" \
    FORCE="${FORCE:-false}" \
    SKIP_UPDATE="${SKIP_UPDATE:-false}" \
    CCACHE_DIR="$CCACHE_DIR" \
    CCACHE_COMPILERCHECK="$CCACHE_COMPILERCHECK" \
    CCACHE_MAXSIZE="$CCACHE_MAXSIZE" \
    bash "$root/scripts/build-package.sh"
done
