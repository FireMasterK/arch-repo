#!/usr/bin/env bash
# List the packages present in the published repository.
#
# The plan job uses this to notice a package nobody has published yet, so it is
# built once instead of waiting for its next upstream release. That covers a
# binary repack added by a push that did not force it: it has an updater, so
# every later run reports it as up to date, and without this check it would stay
# unpublished until upstream happened to bump its version.
#
# Usage: scripts/published-packages.sh
#
# Prints one `<name>-<version>-<rel>-<arch>.pkg.tar.zst` per line.
#
# Exit codes:
#   0 - the repository was read
#   2 - no repository is configured, or it could not be read
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

db=${REPO_DB:-arch-repo}
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

# Same access rules as scripts/fetch-published.sh: the public URL when one is
# configured, otherwise the publisher's credentials against the private bucket.
if [[ -z ${S3_PUBLIC_BASE_URL:-} ]]; then
  bucket=${S3_BUCKET:-}
  if [[ -z $bucket ]]; then
    log 'no published repository configured (S3_PUBLIC_BASE_URL or S3_BUCKET)'
    exit 2
  fi
  command -v aws >/dev/null || {
    log "the aws CLI is required to read s3://$bucket"
    exit 2
  }

  export AWS_DEFAULT_REGION=${S3_REGION:-us-east-1}
  export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
  export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
  # Keep the CLI configuration out of the caller's ~/.aws, exactly as
  # scripts/fetch-published.sh does.
  aws_config=$(mktemp "${TMPDIR:-/tmp}/aws-config.XXXXXX")
  trap 'rm -f "$tmp" "$aws_config"' EXIT
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

  key="${prefix}${db}.db"
  if ! aws s3 cp "${aws_opts[@]}" --only-show-errors "s3://$bucket/$key" \
    "$tmp" >/dev/null; then
    log "warning: could not read s3://$bucket/$key"
    exit 2
  fi
else
  repo_url=${S3_PUBLIC_BASE_URL%/}
  if ! curl -fsSL --retry 2 --max-time 60 "$repo_url/$db.db" -o "$tmp"; then
    log "warning: could not read $repo_url/$db.db"
    exit 2
  fi
fi

# `repo-add` stores one directory per package in the db tarball; each holds a
# `desc` file whose first entry is the file name. The package directory also
# holds `desc`/`files`, so match only the file-name entry.
tar -xzOf "$tmp" --wildcards '*/desc' 2>/dev/null |
  grep -E '^[^/]+\.pkg\.tar\.zst$' || true
