#!/usr/bin/env bash
# Publish the freshly built packages to an S3-compatible bucket.
#
# The bucket doubles as a pacman repository:
#   Server = https://<cdn-or-bucket>/<prefix>
#
# Environment:
#   S3_BUCKET          - target bucket (required unless DRY_RUN=1)
#   S3_ENDPOINT        - S3 endpoint URL; empty means AWS (default: none)
#   S3_REGION          - region/signing region (default: us-east-1)
#   S3_PREFIX          - key prefix inside the bucket (default: "")
#   S3_ADDRESSING_STYLE- "path" or "virtual" (default: path for custom endpoints)
#   CLOUDFRONT_DISTRIBUTION_ID - optional; invalidated after the db changes
#   REPO_DB            - pacman db name (default: arch-repo)
#   KEEP_VERSIONS      - package versions to retain per package (default: 3)
#   DRY_RUN            - "1" to build the db locally without touching S3
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY - credentials for the upload
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=${GITHUB_WORKSPACE:-$(cd -- "$here/.." && pwd)}
# shellcheck source=lib.sh
source "$here/lib.sh"

db=${REPO_DB:-arch-repo}
keep=${KEEP_VERSIONS:-3}
bucket=${S3_BUCKET:-}
prefix=${S3_PREFIX:-}
dry_run=${DRY_RUN:-0}

# Object keys in the repo root are flat; a prefix keeps the URL tidy.
prefix=${prefix#/}
prefix=${prefix%/}
[[ -n $prefix ]] && prefix="$prefix/"
base="s3://${bucket}/${prefix}"

art=$root/_artifacts
# Packages rebuilt by the smoke-test retry live in their own artifact, so they
# can supersede the original build of the same package.
retry=$root/_retry
# Dependency sets that a passing re-check proved still work; the publish job is
# the only writer, so it records them on the branch.
verified=$root/_verified
repo=$root/_repo

if [[ $dry_run != 1 ]]; then
  [[ -n $bucket ]] || die 'S3_BUCKET is required'
  command -v aws >/dev/null || die 'the aws CLI is required'
fi

shopt -s nullglob

# The smoke job also re-checks already published builds. When they all still
# start (or nothing could be rebuilt) this run has nothing new to ship.
mkdir -p "$art"
if [[ -d ${retry:-} ]]; then
  log 'using rebuilt packages from the smoke-test retry'
  cp -f "$retry"/PKGBUILD.* "$retry"/SRCINFO.* "$art"/ 2>/dev/null
  cp -f "$retry"/*.pkg.tar.zst "$art"/ 2>/dev/null
fi

if ! compgen -G "$art/*.pkg.tar.zst" >/dev/null; then
  if [[ ${EXPECT_ARTIFACTS:-true} == true ]]; then
    die "no packages found in $art"
  fi
  log 'nothing to publish'
  # A re-check that passed still has something to record: without it the plan
  # job would re-check the same dependency drift on every run until the package
  # is rebuilt for another reason.
  sync_verified "$verified" "$root"
  commit_packages "$root"
  exit 0
fi

# Records of re-checks that passed alongside packages being published here.
sync_verified "$verified" "$root"

rm -rf "$repo"
mkdir -p "$repo"

# Restore the PKGBUILDs / .SRCINFO files that the build jobs produced.
for file in "$art"/PKGBUILD.*; do
  pkg=${file##*.}
  cp -f "$file" "$root/packages/$pkg/PKGBUILD"
  cp -f "$art/SRCINFO.$pkg" "$root/packages/$pkg/.SRCINFO"
done

for file in "$art"/*.pkg.tar.zst; do
  mv -f "$file" "$repo/"
done
(($(find "$repo" -maxdepth 1 -name '*.pkg.tar.zst' | wc -l) > 0)) ||
  die "no packages found in $art"

# A package can be staged twice: the original build and a rebuild from the smoke
# retry. Keep the highest pkgrel of each pkgver so the database never lists both.
python3 - "$repo" <<'PY'
import pathlib
import re
import sys

repo = pathlib.Path(sys.argv[1])
PATTERN = re.compile(
    r"^(?P<name>.+)-(?P<ver>[^-]+)-(?P<rel>[0-9]+)-(?P<arch>[^-]+)\.pkg\.tar\.zst$"
)

# Group by name + pkgver; a rebuild keeps the upstream version and bumps pkgrel.
groups = {}
for path in repo.glob("*.pkg.tar.zst"):
    match = PATTERN.match(path.name)
    if not match:
        continue  # Unrecognised name: leave it alone rather than guess.
    key = (match["name"], match["ver"])
    groups.setdefault(key, []).append((int(match["rel"]), path))

for (name, ver), items in groups.items():
    if len(items) < 2:
        continue
    items.sort()
    kept = items[-1]
    for rel, path in items[:-1]:
        print(f"superseded: {path.name} (kept {kept[1].name} for {name} {ver})")
        path.unlink()
PY

# Record what each source package was built against: `.BUILDINFO` lists the
# packages present at build time. The smoke job compares this with the current
# repositories and only re-checks the published build when something moved.
# Binary repacks cannot be rebuilt, so they are not tracked.
for dir in "$root"/packages/*/; do
  pkg=$(basename "$dir")
  builds_from_source "$root" "$pkg" || continue
  name=$(sed -n 's/^pkgname = //p' "$dir/.SRCINFO" 2>/dev/null | head -n 1)
  [[ -n $name ]] || continue
  file=$(find "$repo" -maxdepth 1 -name "$name-[0-9]*.pkg.tar.zst" | sort -V | tail -n 1)
  [[ -n $file ]] || continue
  tmp=$(mktemp)
  bsdtar -xOf "$file" .BUILDINFO 2>/dev/null | grep '^installed = ' >"$tmp" || true
  if [[ -s $tmp ]]; then
    mv -f "$tmp" "$dir/build-env.txt"
    # A new build starts from a fresh baseline, so what a previous re-check
    # verified about the build it replaces no longer applies.
    rm -f "$dir/smoke-verified.txt"
    log "recorded the build environment of $pkg ($(wc -l <"$dir/build-env.txt") packages)"
  else
    rm -f "$tmp"
    log "warning: $pkg has no .BUILDINFO, cannot track its dependencies"
  fi
done

# S3 clients need explicit configuration for non-AWS endpoints.
if [[ $dry_run != 1 ]]; then
  export AWS_DEFAULT_REGION=${S3_REGION:-us-east-1}
  export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
  export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
  addressing=${S3_ADDRESSING_STYLE:-path}
  # --endpoint-url is accepted by both `aws s3` and `aws s3api`; --only-show-errors
  # is only valid on the `s3` subcommands, so it is passed explicitly there.
  aws_opts=()
  [[ -n ${S3_ENDPOINT:-} ]] && aws_opts+=(--endpoint-url "${S3_ENDPOINT%/}")
  # Keep the CLI config out of the user's ~/.aws; _repo is scratch space.
  export AWS_CONFIG_FILE=$repo/.aws-config
  aws configure set default.s3.addressing_style "$addressing"

  # A source package that was not rebuilt here still needs a baseline, otherwise
  # it stays untracked until its next upstream release. Read the .BUILDINFO of
  # the copy that is already in the bucket.
  for dir in "$root"/packages/*/; do
    pkg=$(basename "$dir")
    builds_from_source "$root" "$pkg" || continue
    [[ -f $dir/build-env.txt ]] && continue
    name=$(sed -n 's/^pkgname = //p' "$dir/.SRCINFO" 2>/dev/null | head -n 1)
    [[ -n $name ]] || continue
    # No match is normal: the package is not in the bucket yet, so it stays
    # untracked until its next build. The trailing `|| true` keeps pipefail
    # from turning that empty grep result into a fatal error and aborting the
    # first publish against an empty bucket.
    key=$(aws s3api list-objects-v2 "${aws_opts[@]}" --bucket "$bucket" \
      --prefix "$prefix$name-" --query 'Contents[].Key' --output text 2>/dev/null |
      tr '\t' '\n' | grep -E "^${prefix}${name}-[0-9].*\.pkg\.tar\.zst$" |
      sort -V | tail -n 1 || true)
    [[ -n $key ]] || continue
    tmp=$(mktemp -d)
    if aws s3 cp "${aws_opts[@]}" --only-show-errors "s3://$bucket/$key" \
      "$tmp/package.pkg.tar.zst" >/dev/null 2>&1 &&
      bsdtar -xOf "$tmp/package.pkg.tar.zst" .BUILDINFO 2>/dev/null |
      grep '^installed = ' >"$tmp/baseline" &&
      [[ -s $tmp/baseline ]]; then
      mv -f "$tmp/baseline" "$dir/build-env.txt"
      log "$pkg: recorded the build environment of the published $key"
    fi
    rm -rf "$tmp"
  done
fi

# repo-add merges into an existing database, but only needs the db itself (not
# the old package files). Without this, every publish would drop packages that
# were not part of this build batch.
if [[ $dry_run != 1 ]]; then
  for asset in "$db.db" "$db.files"; do
    if aws s3api head-object "${aws_opts[@]}" --bucket "$bucket" --key "$prefix$asset" >/dev/null 2>&1; then
      log "fetching current $asset from S3"
      aws s3 cp "${aws_opts[@]}" --only-show-errors "$base$asset" "$repo/$asset.tar.gz" >/dev/null ||
        die "failed to download $asset"
    fi
  done
fi

log "creating $db database"
repo-add --nocolor "$repo/$db.db.tar.gz" "$repo"/*.pkg.tar.zst >/dev/null

# Pacman asks for the literal arch-repo.db / arch-repo.files names.
rm -f "$repo/$db.db" "$repo/$db.files"
cp "$repo/$db.db.tar.gz" "$repo/$db.db"
cp "$repo/$db.files.tar.gz" "$repo/$db.files"
rm -f "$repo/$db.db.tar.gz" "$repo/$db.files.tar.gz" \
  "$repo/$db.db.tar.gz.old" "$repo/$db.files.tar.gz.old"

if [[ $dry_run == 1 ]]; then
  log "dry run complete; repository contents:"
  ls -lh "$repo"
  exit 0
fi

# Packages first: the database must never reference a missing object.
log "uploading packages to $base"
for file in "$repo"/*.pkg.tar.zst; do
  aws s3 cp "${aws_opts[@]}" --only-show-errors "$file" "$base$(basename "$file")" \
    --content-type application/octet-stream \
    --cache-control 'public, max-age=31536000, immutable' >/dev/null
done

# The db changes on every publish, so keep its TTL short for CDN clients.
log "uploading database and signatures"
for file in "$repo"/*.sig "$repo/$db.db" "$repo/$db.files"; do
  [[ -f $file ]] || continue
  cache='public, max-age=60'
  case $file in
  *.sig) type=application/pgp-signature ;;
  *) type=application/gzip ;;
  esac
  aws s3 cp "${aws_opts[@]}" --only-show-errors "$file" "$base$(basename "$file")" \
    --content-type "$type" --cache-control "$cache" >/dev/null
done

if [[ -n ${CLOUDFRONT_DISTRIBUTION_ID:-} ]]; then
  log 'invalidating the CDN cache'
  aws cloudfront create-invalidation \
    --distribution-id "$CLOUDFRONT_DISTRIBUTION_ID" \
    --paths "/${prefix}${db}.db" "/${prefix}${db}.files" >/dev/null ||
    log 'warning: CDN invalidation failed; clients may see a stale database briefly'
fi

# Keep only the newest $keep versions of each package; old objects are only
# useful for downgrades and they cost storage.
log "pruning to $keep versions per package"
assets_json=$root/.s3-objects.json
aws s3api list-objects-v2 "${aws_opts[@]}" --bucket "$bucket" \
  --prefix "$prefix" --output json >"$assets_json"

delete_list=$root/.s3-delete.txt
python3 - "$assets_json" "$keep" "$db" "$prefix" >"$delete_list" <<'PY'
import json
import pathlib
import re
import sys

objects_file, keep, db, prefix = (
    sys.argv[1],
    int(sys.argv[2]),
    sys.argv[3],
    sys.argv[4],
)
contents = json.loads(pathlib.Path(objects_file).read_text()).get("Contents", [])
PATTERN = re.compile(
    r"^(?P<name>.+)-(?P<ver>[^-]+)-(?P<rel>[0-9]+)-(?P<arch>[^-]+)\.pkg\.tar\.zst$"
)

groups = {}
for obj in contents:
    key = obj["Key"]
    name = key[len(prefix) :] if key.startswith(prefix) else key
    if "/" in name or name.startswith(db + "."):
        continue
    # Anything that is not a package filename is left untouched.
    match = PATTERN.match(name)
    if not match:
        continue
    groups.setdefault(match["name"], []).append((obj["LastModified"], key))

for items in groups.values():
    items.sort(reverse=True)
    for _, key in items[keep:]:
        print(key)
PY

while IFS= read -r key; do
  [[ -n $key ]] || continue
  log "pruning old object: $key"
  aws s3 rm "${aws_opts[@]}" --only-show-errors "s3://$bucket/$key" >/dev/null
done <"$delete_list"

rm -f "$assets_json" "$delete_list"

# Commit the refreshed PKGBUILDs and baselines so the repo records what was
# shipped. Untracked files count too: a baseline is new the first time.
commit_packages "$root"

if [[ -n ${S3_PUBLIC_BASE_URL:-} ]]; then
  log "published to ${S3_PUBLIC_BASE_URL%/}/"
else
  log 'published'
fi
