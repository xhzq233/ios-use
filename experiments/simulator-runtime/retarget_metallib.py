#!/usr/bin/env python3
"""Rebuild an uncompressed iOS AIR metallib for Simulator; preserve the input."""
import argparse
from pathlib import Path
import re
import struct
import subprocess
import tempfile


def retarget(source: Path, destination: Path):
    if source.resolve() == destination.resolve():
        raise ValueError("Input and output must differ; use a disposable app copy")
    data = source.read_bytes()
    if data[:4] != b"MTLB":
        raise ValueError("Input is not a Metal library")
    destination.parent.mkdir(parents=True, exist_ok=True)
    metal_opt = subprocess.check_output(["xcrun", "-f", "metal-opt"], text=True).strip()
    linker = subprocess.check_output(["xcrun", "-f", "metallib"], text=True).strip()
    with tempfile.TemporaryDirectory(prefix="air-", dir=destination.parent) as directory:
        work = Path(directory)
        modules = []
        offset = 0
        while True:
            offset = data.find(b"\xde\xc0\x17\x0b", offset)
            if offset < 0:
                break
            if offset + 20 > len(data):
                raise ValueError("Truncated AIR wrapper")
            _, version, start, size, cpu = struct.unpack_from("<5I", data, offset)
            end = offset + start + size
            if start < 20 or end > len(data):
                raise ValueError("AIR wrapper exceeds library bounds")
            raw = data[offset + start:end]
            offset = end
            if raw[:4] != b"BC\xc0\xde":
                raise ValueError("Unsupported AIR encoding")
            index = len(modules)
            original = work / f"{index}.air"
            readable = work / f"{index}.ll"
            converted = work / f"{index}-sim.air"
            original.write_bytes(raw)
            subprocess.run([metal_opt, "-S", str(original), "-o", str(readable)], check=True)
            match = re.search(r'target triple = "(air64(?:_v[0-9]+)?-apple-ios[0-9.]+)(-simulator)?"', readable.read_text())
            if not match:
                raise ValueError("AIR target is not supported iOS bitcode")
            subprocess.run([metal_opt, "--mtriple=" + match[1] + "-simulator", str(original),
                            "-o", str(converted)], check=True)
            modules.append(converted)
        if not modules:
            raise ValueError("No uncompressed AIR modules found")
        # Link to temporary output first; a failed conversion leaves no partial library.
        result = work / "result.metallib"
        subprocess.run([linker, *map(str, modules), "-o", str(result)], check=True)
        result.replace(destination)
    print(f"Retargeted {len(modules)} AIR modules: {destination}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    try:
        retarget(args.input, args.output)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Metallib conversion failed: {error}\n")
