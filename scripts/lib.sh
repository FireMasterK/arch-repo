#!/usr/bin/env bash
# Shared helpers for the package update/build scripts.
# This file is meant to be sourced, not executed.

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '==> %s\n' "$*" >&2
}

# fetch helpers
fetch_bin() {
  if [[ -n ${CURL_IMPERSONATE:-} ]]; then
    printf '%s\n' "$CURL_IMPERSONATE"
    return 0
  fi
  # curl-impersonate ships one wrapper per browser profile and each release
  # adds newer ones, so look for the newest chrome wrapper instead of keeping a
  # list here that goes stale. Platform variants (_macos, _android) are
  # skipped: their fingerprint does not match this machine.
  local newest
  newest=$(
    compgen -c curl_chrome 2>/dev/null |
      grep -E '^curl_chrome[0-9]+$' |
      sort -uV |
      tail -n 1
  )
  if [[ -n $newest && -x $(command -v "$newest") ]]; then
    printf '%s\n' "$newest"
    return 0
  fi
  printf 'curl\n'
}

# fetch <user-agent> <curl args...>
fetch() {
  local ua=$1 bin
  shift
  bin=$(fetch_bin)
  if [ "$bin" = curl ]; then
    curl -A "$ua" "$@"
  else
    "$bin" "$@"
  fi
}

# pkgvar <PKGBUILD> <variable>
# Prints the value of a simple `name=value` assignment from a PKGBUILD.
pkgvar() {
  [[ -f $1 ]] || die "missing file: $1"
  sed -n "s/^$2=//p" "$1" | head -n 1
}

# _replace_pkgvar <PKGBUILD> <variable> <value>
# Rewrites a variable without interpolating the value in sed.
_replace_pkgvar() {
  local file=$1 key=$2 value=$3 tmp
  tmp=$(mktemp)
  awk -v key="$key" -v val="$value" '
    index($0, key "=") == 1 { print key "=" val; next }
    { print }
  ' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

# set_pkgvar <PKGBUILD> <variable> <value>
set_pkgvar() {
  local file=$1 key=$2 value=$3
  if grep -qE "^${key}=" "$file"; then
    _replace_pkgvar "$file" "$key" "$value"
  else
    printf '\n%s=%s\n' "$key" "$value" >> "$file"
  fi
}

# bump_pkgrel <PKGBUILD>
bump_pkgrel() {
  local file=$1 rel
  rel=$(pkgvar "$file" pkgrel)
  [[ $rel =~ ^[0-9]+$ ]] || die "unexpected pkgrel in $file: '$rel'"
  set_pkgvar "$file" pkgrel "$((rel + 1))"
  log "$(basename "$(dirname "$(realpath "$file")")"): pkgrel $rel -> $((rel + 1))"
}

# package_dirs <repo-root>
# Prints one absolute path per package directory (sorted).
package_dirs() {
  local root=$1 dir
  for dir in "$root"/packages/*/; do
    [[ -f $dir/PKGBUILD ]] && printf '%s\n' "${dir%/}"
  done
}

# builds_from_source <repo-root> <package>
# True when the package compiles from source (it has a build() function) rather
# than repacking an upstream binary, so its binaries depend on the Arch libraries
# that existed on the day it was built.
builds_from_source() {
  grep -qE '^[[:space:]]*build[[:space:]]*\(\)' "$1/packages/$2/PKGBUILD"
}

# published_filename <repo-url> <db-name> <package>
# Prints the newest published package file for <package>, or nothing when the
# package is not in the published repository.
published_filename() {
  local repo_url=$1 db_name=$2 name=$3 db names
  [[ -n $repo_url ]] || return 1
  db=$(mktemp)
  if ! curl -fsSL --retry 2 --max-time 60 "${repo_url%/}/$db_name.db" -o "$db"; then
    rm -f "$db"
    return 1
  fi
  names=$(tar -xzOf "$db" --wildcards '*/desc' 2>/dev/null || true)
  rm -f "$db"
  grep -E '^[^/]+\.pkg\.tar\.zst$' <<<"$names" |
    grep -E "^${name}-[0-9]" | sort -V | tail -n 1
}
