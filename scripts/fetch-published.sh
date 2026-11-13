#!/usr/bin/env bash
# Download the newest published build of a package into a directory.
#
# The smoke job re-checks an already published package when one of its runtime
# dependencies moved, so it needs that package even though this run did not
# build it. The repository is read through whatever access the configuration
# allows: the public URL when one is set, otherwise signed requests with the
# same S3 credentials the publisher uses.
#
# Usage: scripts/fetch-published.sh <package> <destination>
#
# Prints the downloaded file name on stdout.
#
# Exit codes:
#   0 - the package was downloaded
#   2 - nothing fetched: the package is not published, or the repository cannot
#       be read with the configuration available
#   3 - the repository was readable but the download failed (a retry may work)
#
# Environment:
#   S3_PUBLIC_BASE_URL  public base URL of the repository (preferred when set)
#   S3_BUCKET           bucket holding the repository (signed access)
#   S3_ENDPOINT         S3 endpoint URL; empty means AWS (default: none)
#   S3_REGION           signing region (default: us-east-1)
#   S3_PREFIX           key prefix inside the bucket (default: "")
#   S3_ADDRESSING_STYLE "path" or "virtual" (default: path)
#   REPO_DB             pacman db name (default: arch-repo)
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY - credentials for signed access
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$here/lib.sh"

[[ $# -eq 2 ]] || die "usage: $0 <package> <destination>"
pkg=$1
dest=$2
db=${REPO_DB:-arch-repo}

[[ -d $dest ]] || die "no such directory: $dest"

# Without a public URL the bucket is private, which is the default for an
# S3-compatible store, so the object is fetched with the publisher's own
# credentials rather than assuming anonymous reads work.
if [[ -z ${S3_PUBLIC_BASE_URL:-} ]]; then
  bucket=${S3_BUCKET:-}
  if [[ -z $bucket ]]; then
    log "$pkg: no published repository configured (S3_PUBLIC_BASE_URL or S3_BUCKET)"
    exit 2
  fi
  command -v aws >/dev/null || {
    log "$pkg: the aws CLI is required to read s3://$bucket"
    exit 2
  }

  export AWS_DEFAULT_REGION=${S3_REGION:-us-east-1}
  # MEGA S4 and other S3-compatible stores reject the CLI's default CRC32
  # headers; the publisher sets the same two variables.
  export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
  export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
  # Keep the CLI configuration out of the caller's ~/.aws, exactly as
  # scripts/publish.sh does.
  aws_config=$(mktemp "${TMPDIR:-/tmp}/aws-config.XXXXXX")
  trap 'rm -f "$aws_config"' EXIT
  export AWS_CONFIG_FILE=$aws_config
  aws configure set default.s3.addressing_style "${S3_ADDRESSING_STYLE:-path}" \
    >/dev/null 2>&1 || true

  prefix=${S3_PREFIX:-}
  prefix=${prefix#/}
  prefix=${prefix%/}
  if [[ -n $prefix ]]; then
    prefix="$prefix/"
  fi

  aws_opts=()
  if [[ -n ${S3_ENDPOINT:-} ]]; then
    aws_opts+=(--endpoint-url "${S3_ENDPOINT%/}")
  fi

  keys=$(aws s3api list-objects-v2 "${aws_opts[@]}" --bucket "$bucket" \
    --prefix "$prefix$pkg-" --query 'Contents[].Key' --output text 2>/dev/null) || {
    log "warning: $pkg: could not list s3://$bucket/$prefix"
    exit 3
  }
  key=$(printf '%s\n' "$keys" | tr '\t' '\n' |
    grep -E "^${prefix}${pkg}-[0-9].*\.pkg\.tar\.zst$" | sort -V | tail -n 1 || true)
  if [[ -z $key ]]; then
    log "$pkg: not in the published repository"
    exit 2
  fi

  file=${key#"$prefix"}
  if ! aws s3 cp "${aws_opts[@]}" --only-show-errors "s3://$bucket/$key" \
    "$dest/$file" >/dev/null; then
    log "warning: $pkg: could not download s3://$bucket/$key"
    exit 3
  fi
  printf '%s\n' "$file"
  exit 0
fi

repo_url=${S3_PUBLIC_BASE_URL%/}
file=$(published_filename "$repo_url" "$db" "$pkg" || true)
if [[ -z $file ]]; then
  # Tell "the package is not published" apart from "the repository is not
  # reachable": the former is normal, the latter is a configuration problem
  # worth reporting, and both would otherwise look the same from here.
  if curl -fsSL --retry 2 --max-time 60 "$repo_url/$db.db" -o /dev/null; then
    log "$pkg: not in the published repository"
    exit 2
  fi
  log "warning: $pkg: could not read $repo_url/$db.db"
  exit 3
fi

if ! curl -fsSL --retry 2 --max-time 300 "$repo_url/$file" -o "$dest/$file"; then
  log "warning: $pkg: could not download $repo_url/$file"
  exit 3
fi
printf '%s\n' "$file"
