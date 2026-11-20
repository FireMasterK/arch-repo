#!/usr/bin/env python3
"""Report the shared libraries a built package links to, and who owns them.

Usage:
  link-audit.py <repo-root> <pkg-dir> <pacman-dump> [--verbose]
                [--file-db-map <path>] <package>...
  link-audit.py --sonames [--tarball <path>] <repo-root> <pkg-dir> <package>...

Every ELF file inside the package's built `.pkg.tar.zst` is read for its
`DT_NEEDED` entries, which is the set of sonames the linker actually recorded.
Each soname is then mapped to the Arch package that ships it and compared with
the package's declared runtime dependencies:

  direct      the owning package is named in `depends=`
  transitive  it is reached through another dependency (expected, but visible)
  undeclared  nothing in `depends=` leads to it: a missing dependency
  unresolved  no package in the repositories provides that soname

`<pacman-dump>` is the output of `pacman -Si` (all packages in the sync
databases), the same input `dep-drift.py` takes. The runtime closure is walked
with that module's own helpers so both scripts agree on what a dependency is.

Soname ownership comes from the `provides` entries in that dump, which is fast
but incomplete: Qt and GStreamer declare no sonames at all. `--file-db-map`
takes a `soname<TAB>package` table built from `pacman -F` (see
link-audit.sh --file-db) and uses it in preference to `provides`.
"""

from __future__ import annotations

import importlib.util
import pathlib
import re
import subprocess
import sys
import tarfile
import tempfile

# glibc ships the C runtime but declares no soname provides, so these cannot be
# resolved from the repositories. They all belong to the one package.
GLIBC_SONAMES = frozenset(
    {
        "ld-linux-x86-64.so.2",
        "libc.so.6",
        "libm.so.6",
        "libmvec.so.1",
        "libpthread.so.0",
        "libdl.so.2",
        "librt.so.1",
        "libresolv.so.2",
        "libutil.so.1",
        "libanl.so.1",
        "libnsl.so.1",
        "libcrypt.so.1",
    }
)

# `libgtk-4.so.1` -> `libgtk-4.so`, the name Arch packages list in `provides`.
SONAME_VERSION = re.compile(r"\.\d+$")
NEEDED = re.compile(r"\(NEEDED\)\s+Shared library: \[([^\]]+)\]")


def load_dep_drift(here: pathlib.Path):
    """Import dep-drift.py, whose hyphenated name is not importable directly."""
    spec = importlib.util.spec_from_file_location("dep_drift", here / "dep-drift.py")
    if spec is None or spec.loader is None:
        raise SystemExit(f"error: cannot load {here / 'dep-drift.py'}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def elf_sonames(path: str) -> list[str]:
    """The DT_NEEDED entries of one ELF file."""
    result = subprocess.run(["readelf", "-d", path], capture_output=True, text=True)
    if result.returncode != 0:
        return []
    return NEEDED.findall(result.stdout)


def package_sonames(tarball: pathlib.Path) -> tuple[set[str], int]:
    """Every soname linked by any ELF file in the package, and how many there were.

    Members are streamed and only ELF files are written out, so a package with
    large data files (an Electron app, a 60 MiB Qt client) is not unpacked.
    """
    sonames: set[str] = set()
    elfs = 0
    with tarfile.open(tarball) as archive:
        for member in archive:
            if not member.isfile():
                continue
            handle = archive.extractfile(member)
            if handle is None:
                continue
            head = handle.read(4)
            if head != b"\x7fELF":
                continue
            elfs += 1
            with tempfile.NamedTemporaryFile() as tmp:
                tmp.write(head)
                tmp.write(handle.read())
                tmp.flush()
                sonames.update(elf_sonames(tmp.name))
    return sonames, elfs


def load_file_db(path: pathlib.Path) -> dict[str, list[str]]:
    """Read a `soname<TAB>package` table built from `pacman -F`.

    Several packages can ship the same soname (zlib and zlib-ng-compat both
    provide `libz.so.1`), so every candidate is kept and the caller picks.
    """
    owners: dict[str, list[str]] = {}
    if not path.is_file():
        return owners
    for line in path.read_text().splitlines():
        soname, _, package = line.partition("\t")
        if soname and package:
            owners.setdefault(soname, []).append(package)
    return owners


def soname_owner(
    soname: str,
    providers: dict[str, list[str]],
    file_db: dict[str, list[str]],
    preferred: set[str],
) -> str | None:
    """The Arch package that ships a soname, or None when nothing provides it."""
    if soname in GLIBC_SONAMES:
        return "glibc"
    # The file database names the packages that actually ship the file, so it
    # settles the cases `provides` cannot (Qt, GStreamer) and the ones where
    # several packages provide the same soname (zlib vs zlib-ng-compat).
    if soname in file_db:
        candidates = file_db[soname]
    else:
        base = SONAME_VERSION.sub("", soname)
        candidates = [c for c in providers.get(base, []) if not c.startswith("lib32-")]
    if not candidates:
        return None
    # Several packages can provide one soname. Prefer the one this package
    # already depends on, so `libz.so.1` resolves to the declared `zlib`
    # instead of whichever provider happened to come first in the dump.
    for candidate in candidates:
        if candidate in preferred:
            return candidate
    return candidates[0]


def find_tarball(root: pathlib.Path, pkg_dir: pathlib.Path, package: str) -> pathlib.Path | None:
    """The newest built package, staged flat in PKG_DIR or kept beside the PKGBUILD."""
    tarballs = sorted(
        path
        for directory in (pkg_dir, root / "packages" / package)
        for path in directory.glob(f"{package}-[0-9]*.pkg.tar.zst")
        if "-debug-" not in path.name
    )
    return tarballs[-1] if tarballs else None


def audit(root: pathlib.Path, package: str, tarball: pathlib.Path, packages, providers, file_db, dd):
    """Classify every soname the package links into the four buckets."""
    declared = set(dd.parse_srcinfo_depends(root / "packages" / package / ".SRCINFO"))
    closure = dd.runtime_closure(root, package, packages, providers)
    preferred = declared | closure

    sonames, elfs = package_sonames(tarball)
    buckets: dict[str, list[tuple[str, str | None]]] = {
        "direct": [],
        "transitive": [],
        "undeclared": [],
        "unresolved": [],
    }
    for soname in sorted(sonames):
        owner = soname_owner(soname, providers, file_db, preferred)
        if owner is None:
            buckets["unresolved"].append((soname, None))
        elif owner in declared:
            buckets["direct"].append((soname, owner))
        elif owner in closure:
            buckets["transitive"].append((soname, owner))
        else:
            buckets["undeclared"].append((soname, owner))
    return buckets, elfs


def owners(entries: list[tuple[str, str | None]]) -> str:
    """The distinct owning packages of a bucket, sorted."""
    names = sorted({owner for _, owner in entries if owner})
    return " ".join(names) if names else "(none)"


def main() -> int:
    argv = sys.argv[1:]
    if not argv:
        sys.stderr.write(__doc__)
        return 2

    # `--sonames` is the first phase of `link-audit.sh --file-db`: it prints the
    # sonames to look up, before any ownership is known. `--tarball` names the
    # package file directly, which is what publish.sh has (it stages the build
    # under a name that does not match the package directory).
    if argv[0] == "--sonames":
        rest = argv[1:]
        tarball_override: pathlib.Path | None = None
        if rest and rest[0] == "--tarball":
            if len(rest) < 2:
                sys.stderr.write(__doc__)
                return 2
            tarball_override = pathlib.Path(rest[1])
            rest = rest[2:]
        if len(rest) < 3:
            sys.stderr.write(__doc__)
            return 2
        root, pkg_dir = pathlib.Path(rest[0]), pathlib.Path(rest[1])
        found: set[str] = set()
        for package in rest[2:]:
            tarball = tarball_override or find_tarball(root, pkg_dir, package)
            if tarball is not None:
                found.update(package_sonames(tarball)[0])
        for soname in sorted(found):
            print(soname)
        return 0

    if len(argv) < 4:
        sys.stderr.write(__doc__)
        return 2

    root = pathlib.Path(argv[0])
    pkg_dir = pathlib.Path(argv[1])
    dump = pathlib.Path(argv[2])
    rest = argv[3:]

    verbose = False
    file_db_map: pathlib.Path | None = None
    requested: list[str] = []
    index = 0
    while index < len(rest):
        arg = rest[index]
        if arg == "--verbose":
            verbose = True
        elif arg == "--file-db-map":
            index += 1
            if index >= len(rest):
                sys.stderr.write(__doc__)
                return 2
            file_db_map = pathlib.Path(rest[index])
        else:
            requested.append(arg)
        index += 1

    here = pathlib.Path(__file__).resolve().parent
    dd = load_dep_drift(here)
    packages, providers = dd.load_dump(dump)
    file_db = load_file_db(file_db_map) if file_db_map else {}

    status = 0
    for package in requested:
        tarball = find_tarball(root, pkg_dir, package)
        if tarball is None:
            print(f"==> {package}: no built package in {pkg_dir}, skipping")
            status = max(status, 2)
            continue

        buckets, elfs = audit(root, package, tarball, packages, providers, file_db, dd)
        total = sum(len(entries) for entries in buckets.values())
        print(f"==> {package}  ({total} sonames, {elfs} ELF files)")

        for name in ("direct", "transitive", "undeclared", "unresolved"):
            entries = buckets[name]
            if verbose:
                print(f"    {name} ({len(entries)})")
                for soname, owner in entries:
                    print(f"      {soname:30} {owner or '?'}")
            elif name == "unresolved":
                # These have no owning package, so list the sonames themselves.
                print(f"    {name:11} {' '.join(s for s, _ in entries) or '(none)'}")
            else:
                print(f"    {name:11} {owners(entries)}")

        if buckets["undeclared"]:
            status = max(status, 1)
        print()

    return status


if __name__ == "__main__":
    sys.exit(main())
