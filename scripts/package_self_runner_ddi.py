#!/usr/bin/env python3
"""Copy only the DDI resources referenced by an extracted BuildManifest."""
import plistlib
from pathlib import Path
import shutil
import sys


def package(source: Path, destination: Path):
    source = source.resolve(strict=True)
    with (source / "BuildManifest.plist").open("rb") as stream:
        manifest = plistlib.load(stream)
    identities = manifest.get("BuildIdentities", [])
    if not identities:
        raise ValueError("BuildManifest contains no BuildIdentities")
    paths = {"BuildManifest.plist"}
    for identity in identities:
        entries = identity["Manifest"]
        image = entries.get("PersonalizedDMG", entries.get("PersonalizedDmg"))
        if image is None:
            continue  # A manifest may also contain non-personalized Cryptex identities.
        paths.update((image["Info"]["Path"], entries["LoadableTrustCache"]["Info"]["Path"]))
    if len(paths) == 1:
        raise ValueError("BuildManifest contains no personalized DDI")
    files = []
    total = 0
    for relative in sorted(paths):
        path = Path(relative)
        if path.is_absolute() or ".." in path.parts:
            raise ValueError(f"Invalid DDI resource path: {relative}")
        origin = (source / path).resolve(strict=True)
        origin.relative_to(source)  # Includes symlink containment.
        size = origin.stat().st_size
        if not origin.is_file() or size <= 0:
            raise ValueError(f"DDI resource is not a nonempty file: {relative}")
        total += size
        if total > 1024**3:
            raise ValueError("DDI resources exceed 1 GiB")
        files.append((origin, destination / path))
    if destination.exists():
        raise ValueError("DDI destination already exists")
    for origin, target in files:
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(origin, target)
    print(f"Bundled DDI: {len(files)} files, {total} bytes")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("Usage: package_self_runner_ddi.py <Restore directory> <new destination>")
    package(Path(sys.argv[1]), Path(sys.argv[2]))
