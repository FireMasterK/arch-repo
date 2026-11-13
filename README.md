# arch-repo

A self-updating Arch Linux package repository, built and published by GitHub
Actions. It checks upstream every 30 minutes, rebuilds only the packages whose
version changed, and publishes a pacman database plus packages to an
S3-compatible bucket behind a CDN.

Current packages:

| Package | Upstream | Version source |
| --- | --- | --- |
| `cursor` | [Cursor](https://cursor.com) `.deb` | `cursor.com/api/download` |
| `grok-bot` | [Grok Bot](https://x.ai/bot) `.deb` | hashed download link on `x.ai/bot` |
| `codspeed` | [CodSpeed](https://github.com/CodSpeedHQ/codspeed) runner tarball | GitHub `releases/latest` |
| `valgrind-codspeed` | [valgrind-codspeed](https://github.com/CodSpeedHQ/valgrind-codspeed) source | GitHub `releases/latest` + submodule pin |
| `lightning-matrix` | [Lightning](https://github.com/Mizerd/lightning) source | GitHub `releases/latest` |

`cursor` and `grok-bot` are binary repacks (based on the AUR `cursor-bin` /
`grok-bot-bin` packages); `codspeed` repacks upstream's prebuilt musl runner.
`cursor` provides/conflicts with `cursor-bin`, `grok-bot`
provides/conflicts with `grok-bot-bin`, `codspeed` provides/conflicts with
`codspeed-bin`.

`valgrind-codspeed` (AUR `valgrind-codspeed`) is built from source and
provides/conflicts with `valgrind`: CodSpeed's fork carries a Capstone-based
cycle-estimation decoder for Callgrind, and `codspeed` depends on it. It pins
the Capstone commit that the fork's `third_party/capstone` submodule points at,
because the release tarball does not contain the submodule. Do not install it
alongside the distro `valgrind`.

It is compiled with CachyOS' flag set — `-O3 -march=x86-64-v3`, `mold`, LTO,
`-fno-plt`, `_FORTIFY_SOURCE=3`, `-fcf-protection`, `-z now`,
`pack-relative-relocs` — so **it needs an x86-64-v3 CPU** (AVX2, BMI2, FMA).
`-march=native` and `-march=znver*` are avoided on purpose: the package is
built on GitHub's Azure runners (Skylake/EPYC), so `native` would silently
target the wrong microarchitecture.

`lightning-matrix` (AUR `lightning-matrix-appimage`) is built from upstream's
source release instead of repacking the AppImage: Qt 6/QML for the UI and the
official Rust Matrix SDK for sync, E2EE and calls. It conflicts with the AUR
AppImage package. The Rust crates are fetched from `Cargo.lock` in `prepare()`
and the build then runs cargo with `--offline --locked`; the bundled updater is
left in its `development` install type so it never replaces pacman-managed
files.

## How it works

```
schedule (*/30) ─► plan ─────────► build (matrix, archlinux container) ─► publish
                    │                 │                                  │
                    │ runs            │ one container per package        │ repo-add + aws s3 cp
                    │ packages/       │                                  │ commits refreshed PKGBUILDs
                    │ */update.sh     ▼                                  ▼
                │           smoke (matrix, headless Wayland)   S3 bucket (+ CDN)
                ▼                 │ re-checks published builds when deps moved
              matrix of changed pkgs
```

1. `plan` runs every `packages/*/update.sh`. An updater resolves the latest
   upstream version and rewrites `pkgver`, `pkgrel` and the upstream commit in
   the PKGBUILD. Unchanged packages are skipped. The `cursor` updater also reads
   the Electron major bundled in the new `.deb` and rewrites `_electron` (the
   system `electronNN` dependency) when Cursor moves to a new major.
2. `build` runs one Arch container per changed package: `updpkgsums`,
   `makepkg --printsrcinfo`, `makepkg`, then uploads the package and refreshed
   metadata as a workflow artifact.
3. `smoke` installs each built package into a clean `archlinux:latest`
   container, starts it under a headless Wayland compositor, and checks that it
   actually opens a window (see [Startup checks](#startup-checks)). Source
   packages that were not rebuilt are re-checked too, but only when one of their
   runtime dependencies has a new version. A package that fails is rebuilt once
   against the current Arch packages and retested; if it still fails, a GitHub
   issue with the logs is opened. Failures do not block publishing.
4. `publish` restores the current `arch-repo.db` from S3, runs `repo-add`,
   uploads the packages first and the database last (so the db never points at
   a missing object), prunes old versions, and commits the refreshed PKGBUILDs
   back to `main`. A package rebuilt by the smoke job replaces the original
   build of the same version. When a run only re-checked published builds and
   nothing was rebuilt, this job leaves the bucket alone and commits at most the
   re-check records.

Because the publishing token is `GITHUB_TOKEN`, the bot's commit does not
re-trigger the workflow.

### Caching

The workflow stores three things in the Actions cache so a run only downloads
what actually changed:

| Cache key | Contents | Used by |
| --- | --- | --- |
| `curl-impersonate-<version>-*` | the extracted curl-impersonate binary (newest release, resolved per run) | `plan` |
| `srcdest-<package>-<pkgver>` | upstream sources in makepkg's `SRCDEST` | `build`, retry rebuild in `smoke` |
| `ccache-<package>-*` | ccache compiler results | source builds in `build`, retry rebuild in `smoke` |

Only source packages (`build()` in the PKGBUILD — currently
`valgrind-codspeed` and `lightning-matrix`) use ccache; the binary repacks have
nothing to compile.
ccache is enabled through makepkg's own `ccache` `BUILDENV` in
`scripts/container-build.sh`, so no PKGBUILD needs to change, and it is capped
at 1 GiB (`CCACHE_MAXSIZE`). Each build job prints `ccache --show-stats`, which
shows whether a compile was served from the cache.

The download cache is keyed by the version the plan job resolved, so a new
upstream release starts from an empty `SRCDEST` instead of restoring the old
release and throwing it away; a rebuild of the same version (push, `force`, or
the smoke retry) reuses it. ccache is restored by key prefix (newest first)
because its entries are content-addressed and stay valid across versions; it is
saved once per package version and `gcc` version, so repeated rebuilds do not
keep adding multi-hundred-megabyte cache entries.

`scripts/prune-srcdest.sh` runs after every build and deletes downloads that the
version just built does not reference, in case a cache outlives the sources it
was created for (Cursor's deb alone is ~225 MiB). ccache evicts its own entries
above `CCACHE_MAXSIZE`, and `smoke` only restores it (restore-only, never saves)
for a possible retry rebuild.

Arch package downloads are deliberately not cached: a fresh `archlinux` image
typically needs only a few MiB of upgrades and ~30 MiB of makedepends, which is
less than restoring a package cache would cost. Docker images are not cached
either; `archlinux:latest` is pulled per smoke job.

To inspect or clear the caches, use the repository's *Actions → Caches* page or
`gh cache list` / `gh cache delete`. Deleting a cache only costs one slower run.

### Why S3 and a CDN?

Package files are 100–250 MiB each, and the db is rewritten on every publish.
Object storage keeps both out of git entirely, lets the db be replaced in place
with a short TTL, and serves packages with a long immutable cache — none of
which a git repository or GitHub Pages can do at this size.

MEGA S4 is used because it is S3-compatible and has no egress fees; any
S3-compatible store works, including AWS S3, R2 and MinIO.

## Installing packages

Replace `REPO_URL` with the public base URL of the bucket (the CDN hostname, or
`https://<bucket>.<endpoint>`):

```ini
[arch-repo]
SigLevel = Optional TrustAll
Server = https://REPO_URL
```

Then:

```bash
sudo pacman -Sy arch-repo
sudo pacman -S cursor grok-bot codspeed lightning-matrix
```

Pacman appends `arch-repo.db`, `arch-repo.files` and package filenames to that
URL, so the bucket must serve those objects at its root (or set `S3_PREFIX` and
append it to `Server`).

The database is cached for at most 60 seconds; package files are served
`immutable` for a year. If a CDN sits in front of the bucket, set
`CLOUDFRONT_DISTRIBUTION_ID` so the db is invalidated right after each publish
instead of waiting for the TTL.

> The repo is unsigned by default. `SigLevel = Optional TrustAll` is required.
> See [Signing](#signing).

## Adding a package

Create `packages/<name>/PKGBUILD` and, if it should auto-update,
`packages/<name>/update.sh`.

An updater is a normal bash script. It receives no arguments, runs with the
package directory as `$PWD` (but should resolve its own directory), may change
`pkgver`, `pkgrel` and any `_upstream` variables in the PKGBUILD, and exits
non-zero if it cannot resolve a version. `scripts/lib.sh` provides:

```bash
source "$(dirname "$0")/../../scripts/lib.sh"
pkgvar PKGBUILD pkgver        # read a variable
set_pkgvar PKGBUILD pkgver X  # write a variable
bump_pkgrel PKGBUILD          # pkgrel += 1
die "message"                 # fail the updater with a clean error
```

Two hard requirements:

- Keep the integrity arrays (e.g. `sha256sums`) valid. CI runs `updpkgsums`
  before every build, so you can leave new entries as `'SKIP'`.
- Sources must be deterministic for a given `pkgver` (no `-git` checkouts),
  otherwise every 30-minute check will rebuild the package.

`makedepends` are installed by `scripts/build-package.sh` before building, so a
source package only needs to list them. Entries that are not in the configured
repos (for example a sibling package from this repo) are skipped, because
`makepkg` runs with `--nodeps`; `depends` and `checkdepends` are never
installed. Updaters that query the GitHub API can read `$GITHUB_TOKEN`, which
the workflow provides to avoid the anonymous rate limit.

Packages without an `update.sh` are built only on `push` to `main` or when
forced, so they can be maintained by hand. A push to `main` also rebuilds the
packages it touched with a `pkgrel` bump; that is how hand-edited PKGBUILDs get
published. A push that changes `scripts/**` instead forces every package,
because the build scripts shape how all of them are produced.
`scripts/changed-packages.sh` works out which of the two a push is.

To push something under `packages/**` or `scripts/**` that should not rebuild,
put `[skip build]` in the head commit's message:

```bash
git commit -m "chore(docs): explain the smoke config [skip build]"
```

No package is force-rebuilt then; the run only does what a scheduled run does,
so an upstream version change in the same window still builds. This suits
metadata refreshes and comment or README edits. A different marker can be set
with `SKIP_MARKER` when running the script by hand.

## Startup checks

Every package is started once in a disposable `archlinux:latest` container
before publishing, so a package that builds but cannot launch (usually a
missing runtime dependency or a broken Electron wrapper) is caught
immediately. GUI packages are started inside
[Weston](https://wayland.freedesktop.org/)'s `headless-backend`, which is a
virtual framebuffer with no display, GPU or seat required.

A GUI package passes when:

1. it installs together with its dependencies (sibling packages built in the
   same run are installed too),
2. Weston's scene graph contains an `xdg_toplevel` window owned by the package,
3. the app is still running a few seconds later, and
4. if `SMOKE_DEVTOOLS_PORT` is set, Chromium reports a loaded renderer page
   (catches a blank/crashed workbench or renderer).

CLI packages instead run a command and check its exit status and output.

Testing is configured per package in `packages/<name>/smoke.conf`, which is
sourced by `scripts/smoke-runner.sh` inside the container:

| Variable | Meaning |
| --- | --- |
| `SMOKE_WAYLAND` | `true` to start a headless compositor, `false` for CLI tools |
| `SMOKE_CMD` | argv to launch (use `$SMOKE_LOG_DIR` for log paths) |
| `SMOKE_WINDOW_PATTERN` | regex matched against `weston-debug scene-graph` to detect the window |
| `SMOKE_PROCESS_PATTERN` | how to find the app process (needed when the launcher forks) |
| `SMOKE_DEVTOOLS_PORT` | optional Chromium remote-debugging port for the renderer check |
| `SMOKE_TIMEOUT` | seconds to wait for the window (default 90) |
| `SMOKE_EXPECT_OUTPUT` | CLI only: regex the output must match |
| `SMOKE_REBUILD_ON_FAILURE` | optional `true`/`false`; overrides the rebuild decision described below |

A package without a `smoke.conf` gets a default `--version` check.

### When a package is checked

A package that was just built is always tested. A source package that was *not*
built is re-checked against the current Arch packages only when one of its
runtime dependencies has a different version than the one it was compiled
against — otherwise every scheduled run would start a container to prove that
nothing changed.

That decision is made while planning (`scripts/plan-smoke-tests.sh`), before the
matrix is expanded, so packages with no drift get no smoke job at all. The Arch
databases are read once and compared in a single process (about 1 ms per
package, so the plan stage stays flat as the repository grows), and only
packages with drift (or a build from this run) appear in `test_matrix`.

`scripts/dep-drift.sh` compares the dependency values recorded at publish time
(`packages/<name>/build-env.txt`, taken from the published package's
`.BUILDINFO`) with the versions in the current Arch repositories, walking the
runtime dependency closure and resolving sonames such as `libncursesw.so=6` to
the package that provides them. Build-only dependencies (makedepends, the
toolchain) are ignored, and reported drift looks like:

```text
glibc 2.43-2 2.44+r50+g1848099f063e-1
libarchive 3.7.7-1 3.8.11-1
```

Only source packages are tracked this way: a binary repack cannot be rebuilt, so
re-checking it would only cost time.

The re-check runs against the *published* package, which that run did not build,
so the smoke job reads the repository itself (`scripts/fetch-published.sh`):
`S3_PUBLIC_BASE_URL` when it is set, otherwise signed requests using the same
`S3_BUCKET`, `S3_ENDPOINT`, `S3_PREFIX` and `AWS_*` credentials the publisher
uses. When none of that works — no public URL and no credentials, no `aws` CLI,
the package is not published yet, or the download fails — the re-check is
skipped with a warning instead of failing the job, so a missing setting costs a
delayed check rather than a red run.

A re-check that passes records the exact dependency set it proved still works in
`packages/<name>/smoke-verified.txt` (the smoke job uploads it, and `publish`
commits it). `plan` skips a package whose drift matches that record, so a
library update costs one check instead of one per run until the package is
rebuilt; the record is deleted when a new build's baseline replaces it.

### Rebuilding source packages when a check fails

Packages with a `build()` function are compiled against whatever Arch packages
exist on the day they are built, so an old binary can stop starting after a
glibc, gcc or library update even though nothing in this repo changed. When such
a package fails its check, the workflow rebuilds it once against the current
Arch packages (`pkgrel` bumped, upstream version untouched) and tests the result:

* rebuild passes — the rebuilt package is uploaded as a `retry-<package>`
  artifact, the publish job prefers it over the original build, and the run
  continues with a warning instead of an issue;
* the rebuild itself fails — the original failure is reported as an issue, and
  the first attempt's logs are the ones attached;
* the rebuilt package still fails — the retest's logs are reported, and the
  rebuilt package is still published (it is at least built against current
  Arch packages).

Binary repacks have no `build()` and cannot be rebuilt, so they fail
immediately. `SMOKE_REBUILD_ON_FAILURE` in `smoke.conf` overrides the decision
either way.

The retest writes to `smoke-logs/<package>/retry/` so the failing attempt's logs
are preserved. Both modes share one entry point: `scripts/smoke-package.sh`
tests what was built, or falls back to re-checking the published build when its
dependencies moved.

When a check fails, the workflow uploads a `smoke-logs-<package>-<attempt>`
artifact, then opens an issue labelled `smoke-test` (or comments on the existing
open one with the same title) containing the failure reason plus `app.log`,
`chrome.log`, `scene-graph.txt`, `weston.log`, `devtools.json` and the pacman
output. To keep noise down the issue title is stable per package and version, so
repeated failures of the same build update one issue instead of opening many.

Smoke test failures do not block publishing: the package is still shipped and
the issue is the signal to fix it. Packages that failed to build are skipped
rather than reported as broken.

Run the same checks locally against `out/` (or any directory with
`PKG_DIR=/path`):

```bash
./scripts/local-smoke.sh                 # every package with a built artifact
./scripts/local-smoke.sh cursor          # one package
LOG_DIR=/tmp/logs ./scripts/local-smoke.sh grok-bot
./scripts/dep-drift.sh valgrind-codspeed # did its runtime dependencies move?
./scripts/fetch-published.sh valgrind-codspeed /tmp/pub   # download the published build
REPORT_DRY_RUN=1 ./scripts/report-smoke-failure.sh grok-bot   # print the issue body
```

Logs land in `smoke-logs/<package>/`, which is gitignored. Build products staged
for the container live in a temporary directory and are cleaned up on exit. A
source package that fails is rebuilt and retested, with the retest's logs in
`smoke-logs/<package>/retry/`.

## Running locally

Requires Docker and an `archlinux:base-devel` image (pulled automatically):

```bash
./scripts/local-build.sh                 # build every package
./scripts/local-build.sh cursor          # build one package
FORCE=true ./scripts/local-build.sh      # bump pkgrel and rebuild
./scripts/local-publish.sh               # repo-add dry run, no GitHub calls
```

`out/` receives `*.pkg.tar.zst`, `PKGBUILD.<pkg>` and `SRCINFO.<pkg>`.
`local-publish.sh` assembles `_repo/arch-repo.db` and the packages for
inspection. Nothing is uploaded and no commits are made.

Local builds share CI's compiler cache in `.ccache/` (gitignored, capped at
1 GiB); delete it to force a full recompile. Downloaded sources stay in
`.srcdest/`.

To test only the version checks on the host (needs `bash`, `curl`, `jq`, and
`bsdtar` or `ar` plus `tar` for Cursor's deb inspection):

```bash
./scripts/plan-updates.sh
```

To see which published source builds the next run would re-check (needs
`docker` to read the Arch databases):

```bash
BUILT='[]' CANDIDATES='["valgrind-codspeed"]' ./scripts/plan-smoke-tests.sh
```

## Scheduled workflow caveats

- GitHub's minimum schedule interval is 5 minutes; runs are queued and can be
  delayed at busy times. `*/30` is best-effort.
- GitHub disables scheduled workflows in public repositories after 60 days
  without repository activity. The bot's commits count as activity; if no
  package changes for 60 days, re-enable the workflow manually or watch it
  fail.
- `workflow_dispatch` lets you run a check on demand, with an optional package
  filter and `force` rebuild.
- A scheduled run that starts while an earlier run is still going skips itself
  (the `guard` job) rather than queueing behind it, so a long build does not
  leave a backlog of ticks that each re-check the same upstream state. Pushes
  and manual runs are never skipped.
- The `publish` job has its own `concurrency` group, so the only step that
  touches the bucket and `main` never overlaps. Everything before it runs
  independently, which is what lets a newer run start early enough to notice
  the older one.

## Signing

Unsigned is the default because it requires no secrets. To sign the database:

1. Export a signing key: `gpg --armor --export-secret-keys <KEY_ID> | base64 -w0`.
2. Add repository secrets `GPG_PRIVATE_KEY` (the base64 blob) and
   `GPG_KEY_ID`.
3. Import the key in `scripts/publish.sh` before `repo-add` and pass
   `--sign --key "$GPG_KEY_ID"`; the publisher already uploads any
   `arch-repo.db.sig` it finds next to the database.
4. Publish the public key and set
   `SigLevel = Required DatabaseRequired` plus `TrustedOnly` after adding the
   key with `pacman-key --add`.

Packages themselves are not signed by `makepkg`; sign them too (or use
`repo-add` with `.sig` files present) before switching to `Required`.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `grok-bot: no linux-x64 download link found` | `x.ai/bot` changed its JS chunk layout. Open the page, find the `grok-bot-<hash>` link, and update the regex in `packages/grok-bot/update.sh`. |
| `cursor: deb URL layout changed` | Cursor changed its download URL scheme. Update `expected` in `packages/cursor/update.sh` and the `source=` line in its PKGBUILD. |
| `cursor: could not read the bundled Electron version` | Cursor renamed the launcher binary or stopped embedding an `Electron/` version string in it. Update `deb_electron_version` in `packages/cursor/update.sh`, and set `_electron` by hand if the release is urgent. |
| `valgrind-codspeed: unexpected latest release URL` | The fork changed its tag scheme (`<valgrind>-0codspeed<N>`). Update the regex in `packages/valgrind-codspeed/update.sh`. |
| `valgrind-codspeed: failed to read the Capstone submodule pin` | GitHub API rate limit, or the fork stopped vendoring Capstone. Set `GITHUB_TOKEN` locally, or point `_capstone` at the right commit by hand. |
| `valgrind: Fatal error at startup: a function redirection ... cannot be set up` | `ld.so` in the running container has no debuginfo. Set `DEBUGINFOD_URLS=https://debuginfod.archlinux.org`; this happens with distro `valgrind` too. |
| `404` from pacman | The bucket, prefix or `Server` URL is wrong, or the first publish never ran. Check `S3_PREFIX` matches the `Server` path. |
| pacman sees an old package list | The CDN is serving a cached db. Set `CLOUDFRONT_DISTRIBUTION_ID` so publishes invalidate it, or purge `/arch-repo.db` manually. |
| `403`/`SignatureDoesNotMatch` on upload | Wrong keys, wrong `S3_REGION` for the signing endpoint, or the key lacks `PutObject`/`ListBucket` on the bucket. |
| Upload fails with a checksum error | The store does not accept AWS CLI v2's default CRC32 headers. The publisher sets `AWS_REQUEST_CHECKSUM_CALCULATION=when_required`; keep it if you run the CLI by hand. |
| `aws: error: invalid endpoint` / DNS-style bucket errors | Endpoint uses path-style addressing. Keep `S3_ADDRESSING_STYLE=path` for MEGA S4 and MinIO. |
| Build fails in `updpkgsums` | Upstream URL is dead or rate-limited. The previous version stays in the bucket, so clients are unaffected. |
| `error: failed to push` | Branch protection on `main`. Allow GitHub Actions to bypass it, or publish from an unprotected branch. |
| Smoke test times out with `no Wayland window appeared` | The app needs longer to show its window (raise `SMOKE_TIMEOUT`) or upstream renamed the window/app id (update `SMOKE_WINDOW_PATTERN`). Check `scene-graph.txt` in the logs. |
| Smoke test fails with `renderer page appeared` / `no renderer page` | The wrapper launched but the UI never rendered. Compare `chrome.log` with the previous release; this usually means a missing runtime dependency or a broken asar/wrapper patch. |
| Smoke test fails on `failed to install` | A runtime dependency is missing from `depends=`, or the package name changed upstream. The pacman error is in `pacman-install.log`. |
| Source package rebuilt for no obvious reason | Its check failed against the current Arch packages and passed after a rebuild — usually a library or toolchain update. `REBUILD=fixed` in `smoke-logs/<package>/retry/summary.txt` confirms it; the rebuilt package (higher `pkgrel`) is what got published. |
| Source package shows `runtime dependencies changed` and passes | The published build still works on the new libraries. Nothing is rebuilt, the dependency set is recorded in `packages/<name>/smoke-verified.txt` so it is not re-checked again, and the next publish refreshes `packages/<name>/build-env.txt`. |
| Smoke job skipped with `could not fetch the published build` | The smoke job could not read the repository. Set `S3_PUBLIC_BASE_URL`, or keep `S3_BUCKET` plus the `AWS_*` secrets set (the workflow passes the publisher's settings). The reason is logged as a warning just above the skip. |
| `no build baseline recorded yet` | The package has not been published since `build-env.txt` tracking was added. The next successful publish writes it. |
| `REBUILD=failed` in a summary | The rebuild itself broke (upstream source gone, checksum change). The attached logs are from the failing original build. |
| `REBUILD=ineffective` in `retry/summary.txt` | The package was rebuilt against current Arch packages and still fails. The issue logs are from the retest, so they reflect the newest build. |
| Smoke job opens issues but the app works for you | The CI container has no GPU, D-Bus session or desktop portal. Only pass `SMOKE_*` settings that tolerate that; existing packages already pass `--disable-gpu` as a test-only workaround. |
