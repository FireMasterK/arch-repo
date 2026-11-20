#!/usr/bin/env python3
"""Compare a package's runtime dependency versions with what it was built against.

Usage:
  dep-drift.py <repo-root> <package> <baseline> <pacman-dump>
  dep-drift.py --batch <repo-root> <pacman-dump> <package>...

<pacman-dump> is the output of `pacman -Si` (all packages in the sync databases)
on a current Arch install. The baseline is the `installed = ...` block from the
`.BUILDINFO` of the package that is currently published, recorded at publish
time: it lists every package present when the binary was compiled.

When `packages/<name>/link-env.txt` exists, only the packages that ship the
libraries the binary actually links are compared (see `link_drift`). Without it
the declared runtime closure is walked instead, which also covers packages the
binary never loads — a CA bundle, for example.

The single-package form prints one `<name> <built> <now>` line per dependency
whose version moved, and exits 0 when there is drift, 1 when there is none, 2
when nothing is comparable.

`--batch` checks many packages against one already-parsed dump, so a caller that
has thousands of packages does not re-parse the whole database per package. It
prints one `@@ <package> <code>` header per package (codes as above) followed by
that package's drift lines, and always exits 0: a header is emitted for every
package requested.
"""

from __future__ import annotations

import pathlib
import re
import sys

ARCH_SUFFIXES = ("x86_64", "any", "i686", "aarch64")

DRIFT = 0
UNCHANGED = 1
NO_BASELINE = 2


def parse_dump(text: str) -> dict[str, dict]:
    """Parse `pacman -Si` output into name -> {version, depends, provides}."""
    packages: dict[str, dict] = {}
    entry: dict | None = None

    def flush() -> None:
        if entry and entry.get("name"):
            packages[entry["name"]] = entry

    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        if ":" in line:
            key, _, value = line.partition(":")
            key, value = key.strip(), value.strip()
            if key == "Name":
                flush()
                entry = {"name": value, "version": "", "depends": [], "provides": []}
                continue
            if entry is None:
                continue
            if key == "Version":
                entry["version"] = value
            elif key == "Depends On":
                entry["depends"] = [] if value == "None" else value.split()
            elif key == "Provides":
                entry["provides"] = [] if value == "None" else value.split()
    flush()
    return packages


def parse_srcinfo_depends(path: pathlib.Path) -> list[str]:
    """Runtime `depends` entries of a package, without versions or descriptions."""
    if not path.is_file():
        return []
    deps = []
    for line in path.read_text().splitlines():
        key, _, value = line.partition(" = ")
        if key.strip() != "depends":
            continue
        name = value.split(":", 1)[0]
        name = name.split("<", 1)[0].split(">", 1)[0].split("=", 1)[0].strip()
        if name:
            deps.append(name)
    return sorted(set(deps))


def parse_baseline(path: pathlib.Path, known: set[str]) -> dict[str, str]:
    """Map package name -> version from the `.BUILDINFO` `installed` lines.

    Entries look like `name-pkgver-pkgrel-arch`, and both names and versions can
    contain hyphens, so the name is matched against packages we know about
    (longest first) instead of splitting the line.
    """
    versions: dict[str, str] = {}
    names = sorted(known, key=len, reverse=True)
    for line in path.read_text().splitlines():
        if not line.startswith("installed = "):
            continue
        entry = line[len("installed = ") :].strip()
        for name in names:
            if not entry.startswith(name + "-"):
                continue
            version = entry[len(name) + 1 :]
            arch = version.rsplit("-", 1)[-1]
            if arch not in ARCH_SUFFIXES:
                break
            versions.setdefault(name, version[: -len(arch) - 1])
            break
    return versions


def resolve(name: str, packages: dict[str, dict], providers: dict[str, list[str]]) -> str | None:
    """Map a dependency name (possibly a soname or virtual) to a package name."""
    # `pacman -Si` writes a versioned dependency as `name=version` (or `>=`),
    # and the bare name is what identifies the package. Without this the whole
    # subtree behind a versioned dependency is dropped from the closure.
    base = re.split(r"[<>=]", name, maxsplit=1)[0]
    if base in packages:
        return base
    candidates = providers.get(base)
    if not candidates:
        return None
    for candidate in candidates:
        if candidate in packages:
            return candidate
    return candidates[0]


def load_dump(path: pathlib.Path) -> tuple[dict[str, dict], dict[str, list[str]]]:
    """Parse the dump once and index what each package provides."""
    packages = parse_dump(path.read_text())
    providers: dict[str, list[str]] = {}
    for name, info in packages.items():
        for provided in info["provides"]:
            providers.setdefault(provided.split("=", 1)[0], []).append(name)
    return packages, providers


def runtime_closure(
    root: pathlib.Path,
    package: str,
    packages: dict[str, dict],
    providers: dict[str, list[str]],
) -> set[str]:
    """Every Arch package the binary needs at runtime, directly or indirectly."""
    direct = parse_srcinfo_depends(root / "packages" / package / ".SRCINFO")
    # Sibling packages from this repo are not in the Arch repositories and have
    # their own build pipeline, so they are not part of this comparison.
    direct = [dep for dep in direct if not (root / "packages" / dep).is_dir()]

    # Walk the runtime closure so a bumped library behind libarchive or curl is
    # caught, not just the dependencies named in the PKGBUILD.
    closure: set[str] = set()
    queue = [dep for dep in (resolve(name, packages, providers) for name in direct) if dep]
    while queue:
        name = queue.pop()
        if name in closure:
            continue
        closure.add(name)
        queue.extend(
            dep
            for dep in (resolve(dep, packages, providers) for dep in packages[name]["depends"])
            if dep
        )
    return closure


def link_drift(
    baseline: pathlib.Path,
    link_env: pathlib.Path,
    packages: dict[str, dict],
) -> tuple[list[tuple[str, str, str]], int]:
    """Compare the versions of the packages that ship the libraries the binary links.

    `link-env.txt` records `soname<TAB>package` for every DT_NEEDED entry, so
    only libraries the binary actually loads are tracked. A data-only package
    such as a CA bundle never appears, because it ships no shared object.
    """
    owners = set()
    for line in link_env.read_text().splitlines():
        _, _, owner = line.partition("\t")
        if owner:
            owners.add(owner)
    built = parse_baseline(baseline, owners)

    changed = []
    for name in sorted(owners):
        was = built.get(name)
        now = packages.get(name, {}).get("version")
        if was and now and was != now:
            changed.append((name, was, now))
    return changed, len(built)


def drift(
    root: pathlib.Path,
    package: str,
    baseline: pathlib.Path,
    packages: dict[str, dict],
    providers: dict[str, list[str]],
) -> tuple[int, list[tuple[str, str, str]]]:
    """Return the exit code and the `<name> <built> <now>` entries for a package."""
    if not baseline.is_file():
        return NO_BASELINE, []

    # A recorded link set is the stricter baseline: only the libraries the
    # binary actually loads are compared, so a data-only package that its
    # declared dependencies pull in (a CA bundle) cannot trigger a re-check.
    link_env = root / "packages" / package / "link-env.txt"
    if link_env.is_file():
        changed, matched = link_drift(baseline, link_env, packages)
        if changed:
            return DRIFT, changed
        if not matched:
            return NO_BASELINE, []
        return UNCHANGED, []

    closure = runtime_closure(root, package, packages, providers)
    # Only closure names are ever read back out of the result, and matching
    # against every package in the repositories makes this quadratic in the
    # size of the dump (hundreds of ms per package). Longest-first matching
    # within the closure is enough to disambiguate hyphenated names.
    built = parse_baseline(baseline, closure)

    changed = []
    for name in sorted(closure):
        was = built.get(name)
        now = packages[name]["version"]
        if was and was != now:
            changed.append((name, was, now))

    if changed:
        return DRIFT, changed
    if not built:
        return NO_BASELINE, []
    return UNCHANGED, []


def main() -> int:
    argv = sys.argv[1:]

    if argv and argv[0] == "--batch":
        if len(argv) < 3:
            sys.stderr.write(__doc__)
            return 2
        root = pathlib.Path(argv[1])
        packages, providers = load_dump(pathlib.Path(argv[2]))
        for package in argv[3:]:
            baseline = root / "packages" / package / "build-env.txt"
            code, changed = drift(root, package, baseline, packages, providers)
            print(f"@@ {package} {code}")
            for name, was, now in changed:
                print(f"{name} {was} {now}")
        return 0

    if len(argv) != 4:
        sys.stderr.write(__doc__)
        return 2

    repo, package, baseline_path, dump_path = argv
    root = pathlib.Path(repo)
    packages, providers = load_dump(pathlib.Path(dump_path))
    code, changed = drift(root, package, pathlib.Path(baseline_path), packages, providers)

    for name, was, now in changed:
        print(f"{name} {was} {now}")
    return code


if __name__ == "__main__":
    sys.exit(main())
