#!/usr/bin/env bash
# Runs inside a disposable Arch container. Installs the freshly built package,
# starts it under a headless Wayland compositor (Weston) and verifies that it
# opens a toplevel window. CLI packages instead run a configurable command.
#
# This script is invoked by scripts/smoke-test.sh; it is not meant to run on
# the host. Package-specific settings live in packages/<pkg>/smoke.conf.
set -uo pipefail

: "${PACKAGE:?PACKAGE is required}"

SMOKE_LOG_DIR=/logs
SMOKE_WAYLAND=true
SMOKE_TIMEOUT=90
SMOKE_SETTLE=5
SMOKE_DEVTOOLS_PORT=''
SMOKE_WINDOW_PATTERN=''
SMOKE_PROCESS_PATTERN=''
SMOKE_EXPECT_OUTPUT=''
SMOKE_CMD=()

summary=$SMOKE_LOG_DIR/summary.txt
result=FAIL
reason='test did not run to completion'
version=unknown
app_pid=''
weston_pid=''

mkdir -p "$SMOKE_LOG_DIR"
: >"$summary"

# Mirror everything to the log file that gets uploaded / attached to issues.
exec > >(tee -a "$SMOKE_LOG_DIR/runner.log") 2>&1

log() { printf '==> %s\n' "$*"; }

# shellcheck source=/dev/null
[[ -f /smoke-package/smoke.conf ]] && source /smoke-package/smoke.conf

if ((${#SMOKE_CMD[@]} == 0)); then
  SMOKE_CMD=("$PACKAGE" --version)
fi

if [[ $SMOKE_WAYLAND == true && -z $SMOKE_WINDOW_PATTERN ]]; then
  printf 'error: SMOKE_WINDOW_PATTERN is required for Wayland smoke tests\n' >&2
  exit 1
fi

write_summary() {
  {
    printf 'PACKAGE=%s\n' "$PACKAGE"
    printf 'VERSION=%s\n' "$version"
    printf 'RESULT=%s\n' "$result"
    printf 'REASON=%s\n' "$reason"
    printf 'IMAGE=%s\n' "${SMOKE_IMAGE:-unknown}"
    printf 'WAYLAND=%s\n' "$SMOKE_WAYLAND"
    printf 'LOGS=%s\n' "$(find "$SMOKE_LOG_DIR" -maxdepth 1 -type f -printf '%f ' 2>/dev/null)"
  } >"$summary"
}

cleanup() {
  if [[ -n $SMOKE_PROCESS_PATTERN ]]; then
    pkill -f -- "$SMOKE_PROCESS_PATTERN" 2>/dev/null || true
  fi
  [[ -n $app_pid ]] && kill "$app_pid" 2>/dev/null
  [[ -n ${DBUS_SESSION_BUS_PID:-} ]] && kill "$DBUS_SESSION_BUS_PID" 2>/dev/null
  [[ -n $weston_pid ]] && kill "$weston_pid" 2>/dev/null
  return 0
}
trap cleanup EXIT

fail() {
  reason=$1
  result=FAIL
  write_summary
  printf 'SMOKE FAIL: %s\n' "$reason"
  exit 1
}

skip() {
  reason=$1
  result=SKIP
  write_summary
  printf 'SMOKE SKIP: %s\n' "$reason"
  exit 2
}

pass() {
  reason=''
  result=PASS
  write_summary
  printf 'SMOKE PASS: %s %s\n' "$PACKAGE" "$version"
  exit 0
}

# Find a sibling package staged in /pkgs (scripts/smoke-test.sh fills it from
# this run's artifacts and, when needed, from the published release).
find_package_file() {
  local name=$1
  # Newest first: a rebuild of the same upstream version bumps pkgrel, and the
  # retest must exercise that package rather than the one that just failed.
  find /pkgs -maxdepth 1 -type f -name "${name}-[0-9]*.pkg.tar.zst" 2>/dev/null |
    sort -V | tail -n 1
}

install_package() {
  local file=$1 dep dep_file
  while read -r dep; do
    dep=${dep%%[<>=]*}
    [[ -n $dep && $dep != None ]] || continue
    if ! pacman -T "$dep" >/dev/null 2>&1; then
      dep_file=$(find_package_file "$dep")
      if [[ -n $dep_file ]]; then
        log "installing sibling dependency $(basename "$dep_file")"
        install_package "$dep_file" || return 1
      elif [[ -d /smoke-packages/$dep ]]; then
        # A package from this repo that is neither built here nor published.
        skip "dependency '$dep' is not available for this run"
      fi
    fi
  done < <(pacman -Qip "$file" | sed -n 's/^Depends On *: //p' | tr ' ' '\n')

  pacman -U --noconfirm --needed "$file"
}

app_alive() {
  if [[ -n $SMOKE_PROCESS_PATTERN ]]; then
    pgrep -f -- "$SMOKE_PROCESS_PATTERN" >/dev/null 2>&1
  else
    kill -0 "$app_pid" 2>/dev/null
  fi
}

fetch_devtools() {
  curl -fsS --max-time 3 "http://127.0.0.1:${SMOKE_DEVTOOLS_PORT}/json/list" \
    >"$SMOKE_LOG_DIR/devtools.json" 2>/dev/null
}

start_weston() {
  export XDG_RUNTIME_DIR=/tmp/smoke-xdg
  export HOME=/tmp/smoke-home
  mkdir -p "$XDG_RUNTIME_DIR" "$HOME"
  chmod 700 "$XDG_RUNTIME_DIR"

  if command -v dbus-launch >/dev/null; then
    eval "$(dbus-launch --sh-syntax)"
  fi

  weston --debug --backend=headless-backend.so --socket=wl-smoke \
    --width=1280 --height=800 --idle-time=0 \
    --log="$SMOKE_LOG_DIR/weston.log" \
    >"$SMOKE_LOG_DIR/weston.out" 2>&1 &
  weston_pid=$!

  local _
  for _ in $(seq 1 100); do
    [[ -S $XDG_RUNTIME_DIR/wl-smoke ]] && return 0
    kill -0 "$weston_pid" 2>/dev/null || return 1
    sleep 0.1
  done
  return 1
}

run_wayland_smoke() {
  local deadline started window_seen=false _
  export WAYLAND_DISPLAY=wl-smoke
  export LIBGL_ALWAYS_SOFTWARE=1
  export ELECTRON_ENABLE_LOGGING=1
  export FONTCONFIG_NO_CHECK_CACHE_VERSION=1

  log "launching: ${SMOKE_CMD[*]}"
  "${SMOKE_CMD[@]}" >"$SMOKE_LOG_DIR/app.log" 2>&1 &
  app_pid=$!
  started=$SECONDS
  deadline=$((SECONDS + SMOKE_TIMEOUT))

  while ((SECONDS < deadline)); do
    timeout 5 weston-debug scene-graph >"$SMOKE_LOG_DIR/scene-graph.txt" 2>/dev/null || true

    if grep -Eq -- "$SMOKE_WINDOW_PATTERN" "$SMOKE_LOG_DIR/scene-graph.txt" 2>/dev/null; then
      window_seen=true
      break
    fi

    # The launcher may fork (Cursor's CLI does), so allow a short grace period
    # before treating a missing process as a crash.
    if ((SECONDS - started > 10)) && ! app_alive; then
      reason='process exited before opening a window; see app.log'
      return 1
    fi
    sleep 2
  done

  if [[ $window_seen != true ]]; then
    reason="no Wayland window appeared within ${SMOKE_TIMEOUT}s; see scene-graph.txt"
    return 1
  fi
  log 'window detected'

  if [[ -n $SMOKE_DEVTOOLS_PORT ]]; then
    for _ in $(seq 1 10); do
      fetch_devtools || true
      if jq -e 'any(.[]; .type == "page")' "$SMOKE_LOG_DIR/devtools.json" >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done
    if ! jq -e 'any(.[]; .type == "page")' "$SMOKE_LOG_DIR/devtools.json" >/dev/null 2>&1; then
      reason="window opened but no renderer page appeared on port ${SMOKE_DEVTOOLS_PORT}"
      return 1
    fi
    log 'renderer page detected'
  fi

  sleep "$SMOKE_SETTLE"
  if ! app_alive; then
    reason='application exited after opening its window'
    return 1
  fi
  return 0
}

run_cli_smoke() {
  local rc=0
  log "running: ${SMOKE_CMD[*]}"
  timeout "$SMOKE_TIMEOUT" "${SMOKE_CMD[@]}" >"$SMOKE_LOG_DIR/app.log" 2>&1 || rc=$?

  if ((rc == 124)); then
    reason="command timed out after ${SMOKE_TIMEOUT}s"
    return 1
  fi
  if ((rc != 0)); then
    reason="command exited with status $rc"
    return 1
  fi
  if [[ -n $SMOKE_EXPECT_OUTPUT ]] && ! grep -q -- "$SMOKE_EXPECT_OUTPUT" "$SMOKE_LOG_DIR/app.log"; then
    reason="output did not contain '$SMOKE_EXPECT_OUTPUT'"
    return 1
  fi
  return 0
}

log "preparing ${SMOKE_IMAGE:-unknown} container"

pkgfile=$(find_package_file "$PACKAGE")
# The build job may have failed for this package; there is nothing to test then.
[[ -n $pkgfile ]] || skip "no built package file found for '$PACKAGE' in /pkgs"
[[ -r $pkgfile ]] || skip "package file '$pkgfile' is not readable"

pacman-key --init >/dev/null 2>&1
pacman-key --populate archlinux >/dev/null 2>&1
pacman -Syu --noconfirm --needed >/dev/null || fail 'failed to update the Arch container'

if [[ $SMOKE_WAYLAND == true ]]; then
  log 'installing headless Wayland test tools'
  pacman -S --noconfirm --needed weston mesa procps-ng dbus jq curl >/dev/null ||
    fail 'failed to install headless Wayland test tools'
fi

log "installing $(basename "$pkgfile")"
install_package "$pkgfile" >"$SMOKE_LOG_DIR/pacman-install.log" 2>&1 ||
  fail "failed to install $(basename "$pkgfile"); see pacman-install.log"

version=$(pacman -Q "$PACKAGE" 2>/dev/null | awk '{print $2}')
[[ -n $version ]] || version=$(basename "$pkgfile" | sed -E "s/^${PACKAGE}-//; s/-[^-]+-[^-]+\\.pkg\\.tar\\.zst$//")
[[ -n $version ]] || version=unknown

if [[ $SMOKE_WAYLAND == true ]]; then
  log 'starting headless Weston'
  start_weston || fail 'headless Weston failed to start; see weston.log'
  run_wayland_smoke || fail "$reason"
else
  run_cli_smoke || fail "$reason"
fi

ps -ef >"$SMOKE_LOG_DIR/processes.txt" 2>/dev/null || true
pass
