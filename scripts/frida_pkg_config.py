#!/usr/bin/env python3
"""Small hermetic pkg-config reader for the pinned Frida source build.

Frida's Catalyst cross build needs one native QuickJS package and one target
package tree.  A host pkg-config is not guaranteed to be installed on a
developer machine, so the release build uses this deliberately narrow reader
for the generated .pc files only.  It implements the flags Meson and
frida-gum's mkdevkit consume; it never consults the system package database.
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path


def package_paths() -> list[Path]:
    paths: list[Path] = []
    seen: set[str] = set()
    for raw in (
        os.environ.get("PKG_CONFIG_PATH", ""),
        os.environ.get("IOS_USE_FRIDA_PKG_CONFIG_PATH", ""),
    ):
        for item in raw.split(os.pathsep):
            if item and item not in seen:
                seen.add(item)
                paths.append(Path(item))
    return paths


def find_package(name: str) -> Path | None:
    candidates = [name]
    if name.endswith("-uninstalled"):
        candidates.append(name.removesuffix("-uninstalled"))
    else:
        candidates.append(name + "-uninstalled")
    for directory in package_paths():
        for candidate in candidates:
            for suffix in (".pc", "-uninstalled.pc"):
                path = directory / (candidate + suffix)
                if path.is_file():
                    return path
    return None


def parse(path: Path) -> tuple[dict[str, str], dict[str, str]]:
    variables: dict[str, str] = {}
    fields: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" in line and ":" not in line.split("=", 1)[0]:
            key, value = line.split("=", 1)
            variables[key.strip()] = value.strip()
        elif ":" in line:
            key, value = line.split(":", 1)
            fields[key.strip()] = value.strip()

    def expand(value: str) -> str:
        previous = None
        while previous != value:
            previous = value
            value = re.sub(
                r"\$\{([^}]+)\}",
                lambda match: variables.get(match.group(1), ""),
                value,
            )
        return value

    return (
        {key: expand(value) for key, value in variables.items()},
        {key: expand(value) for key, value in fields.items()},
    )


def dependencies(value: str) -> list[str]:
    result: list[str] = []
    for token in re.split(r"\s+", value.strip()):
        token = token.strip(",")
        if not token or token[0].isdigit() or token[0] in "<>=!~":
            continue
        token = re.split(r"[<>=!~]", token, 1)[0]
        if token and token not in result:
            result.append(token)
    return result


def resolve(names: list[str], include_private: bool) -> list[tuple[dict[str, str], dict[str, str]]]:
    result: list[tuple[dict[str, str], dict[str, str]]] = []
    seen: set[str] = set()

    def visit(name: str) -> None:
        if name in seen:
            return
        path = find_package(name)
        if path is None:
            raise SystemExit(f"missing pkg-config package: {name}")
        seen.add(name)
        variables, fields = parse(path)
        result.append((variables, fields))
        for dependency in dependencies(fields.get("Requires", "")):
            visit(dependency)
        if include_private:
            for dependency in dependencies(fields.get("Requires.private", "")):
                visit(dependency)

    for name in names:
        visit(name)
    return result


def main(argv: list[str]) -> int:
    if argv == ["--version"]:
        print("0.29.2")
        return 0
    static = "--static" in argv
    variable_name: str | None = None
    variable_value_index: int | None = None
    for index, item in enumerate(argv):
        if item.startswith("--variable="):
            variable_name = item.split("=", 1)[1]
            variable_value_index = index
            break
        if item == "--variable" and index + 1 < len(argv):
            variable_name = argv[index + 1]
            variable_value_index = index + 1
            break
    args = [
        item for index, item in enumerate(argv)
        if not item.startswith("--")
        and index != variable_value_index
    ]
    if not args:
        return 1
    mode = next(
        (item for item in argv if item in {
            "--exists", "--modversion", "--cflags", "--libs",
            "--cflags-only-I", "--libs-only-L", "--libs-only-l",
            "--variable",
        }),
        "--variable" if variable_name is not None else "--exists",
    )
    names = args
    try:
        records = resolve(names, static)
    except SystemExit:
        return 1
    if mode == "--exists":
        return 0
    if mode == "--modversion":
        print(records[0][1].get("Version", ""))
        return 0
    if mode == "--variable":
        if variable_name is None:
            return 1
        print(records[0][0].get(variable_name, ""))
        return 0

    flags: list[str] = []
    for variables, fields in records:
        del variables
        if mode in {"--cflags", "--cflags-only-I"}:
            values = fields.get("Cflags", "").split()
            if mode == "--cflags-only-I":
                values = [value for value in values if value.startswith("-I")]
        else:
            values = fields.get("Libs", "").split()
            if static:
                values += fields.get("Libs.private", "").split()
            if mode == "--libs-only-L":
                values = [value for value in values if value.startswith("-L")]
            elif mode == "--libs-only-l":
                values = [value for value in values if value.startswith("-l")]
        for value in values:
            if value not in flags:
                flags.append(value)
    print(" ".join(flags))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
