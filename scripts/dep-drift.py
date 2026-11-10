#!/usr/bin/env python3
"""Compare a package's runtime dependency versions with what it was built against.

Usage: dep-drift.py <repo-root> <package> <baseline> <pacman-dump>

<pacman-dump> is the output of `pacman -Si` (all packages in the sync databases)
on a current Arch install. The baseline is the `installed = ...` block from the
`.BUILDINFO` of the package that is currently published, recorded at publish
time: it lists every package present when the binary was compiled.

Prints one `<name> <built> <now>` line per dependency whose version moved, and
exits 0 when there is drift, 1 when there is none, 2 when nothing is comparable.
"""

from __future__ import annotations

import pathlib
import sys

ARCH_SUFFIXES = ("x86_64", "any", "i686", "aarch64")


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
    if name in packages:
        return name
    candidates = providers.get(name.split("=", 1)[0])
    if not candidates:
        return None
    for candidate in candidates:
        if candidate in packages:
            return candidate
    return candidates[0]


def main() -> int:
    if len(sys.argv) != 5:
        sys.stderr.write(__doc__)
        return 2

    repo, package, baseline_path, dump_path = sys.argv[1:]
    root = pathlib.Path(repo)
    baseline = pathlib.Path(baseline_path)

    packages = parse_dump(pathlib.Path(dump_path).read_text())
    providers: dict[str, list[str]] = {}
    for name, info in packages.items():
        for provided in info["provides"]:
            providers.setdefault(provided.split("=", 1)[0], []).append(name)

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

    built = parse_baseline(baseline, closure | set(packages))
    changed = []
    for name in sorted(closure):
        was = built.get(name)
        now = packages[name]["version"]
        if was and was != now:
            changed.append((name, was, now))

    for name, was, now in changed:
        print(f"{name} {was} {now}")

    if changed:
        return 0
    if not built:
        return 2
    return 1


if __name__ == "__main__":
    sys.exit(main())
