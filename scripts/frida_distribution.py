#!/usr/bin/env python3
"""Verify the exact Frida GumJS source/license closure used by ios-use."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import re
import subprocess
from typing import NoReturn


FRIDA_VERSION = "16.5.6"


@dataclass(frozen=True)
class Component:
    key: str
    name: str
    source_relative: str
    repository: str
    commit: str
    license_label: str
    license_paths: tuple[str, ...] = ()
    wrap_relative: str | None = None


COMPONENTS = (
    Component(
        "frida-gum",
        "Frida Gum",
        ".",
        "https://github.com/frida/frida-gum.git",
        "0afeb85fcdeae1d995a55bc07f0fe57b197aecae",
        "wxWindows Library Licence 3.1 and bundled BSD notices",
        ("COPYING",),
    ),
    Component(
        "releng",
        "Frida releng (build source only)",
        "releng",
        "https://github.com/frida/releng.git",
        "4622f5c4c432d94c1c625e598b120425a68a8414",
        "Source-only build tooling; see the upstream tree",
    ),
    Component(
        "quickjs",
        "QuickJS",
        "subprojects/quickjs",
        "https://github.com/frida/quickjs.git",
        "12de2e4904b63405052508c891b215d056962c18",
        "MIT",
        ("LICENSE",),
        "subprojects/quickjs.wrap",
    ),
    Component(
        "glib",
        "GLib and proxy-libintl-static",
        "subprojects/glib",
        "https://github.com/frida/glib.git",
        "148f677c620b57893e3fcdb872d241b61870ef0d",
        "LGPL-2.1-or-later plus the licenses recorded by GLib; proxy-libintl-static is LGPL-2.0",
        (
            "COPYING",
            "LICENSES/Apache-2.0.txt",
            "LICENSES/CC0-1.0.txt",
            "LICENSES/GPL-2.0-or-later.txt",
            "LICENSES/LGPL-2.1-or-later.txt",
            "LICENSES/LLVM-exception.txt",
            "LICENSES/LicenseRef-old-glib-tests.txt",
            "LICENSES/MIT.txt",
            "proxy-libintl-static/COPYING.LIB.txt",
        ),
        "subprojects/glib.wrap",
    ),
    Component(
        "libffi",
        "libffi",
        "subprojects/libffi",
        "https://github.com/frida/libffi.git",
        "10bcbcc6295e559b7c952b054e7669a912d3ce06",
        "MIT",
        ("LICENSE",),
        "subprojects/libffi.wrap",
    ),
    Component(
        "capstone",
        "Capstone",
        "subprojects/capstone",
        "https://github.com/frida/capstone.git",
        "e98746112da0a40b2ccd0340db0d20cca5f97950",
        "BSD-3-Clause and LLVM University of Illinois/NCSA",
        ("LICENSE.TXT", "LICENSE_LLVM.TXT"),
        "subprojects/capstone.wrap",
    ),
    Component(
        "json-glib",
        "JSON-GLib",
        "subprojects/json-glib",
        "https://github.com/frida/json-glib.git",
        "1f40dc373415b728efa8315af7f975bd5a4e2490",
        "LGPL-2.1-or-later",
        ("COPYING",),
        "subprojects/json-glib.wrap",
    ),
    Component(
        "tinycc",
        "TinyCC",
        "subprojects/tinycc",
        "https://github.com/frida/tinycc.git",
        "722c253d8dece3bc9a46b6f510c6682329d838b7",
        "LGPL-2.1-or-later",
        ("COPYING",),
        "subprojects/tinycc.wrap",
    ),
    Component(
        "sqlite",
        "SQLite",
        "subprojects/sqlite",
        "https://github.com/frida/sqlite.git",
        "9337327a50008f2d2236112ccb6f44059b1bafbd",
        "Public domain",
        wrap_relative="subprojects/sqlite.wrap",
    ),
    Component(
        "pcre2",
        "PCRE2",
        "subprojects/pcre2",
        "https://github.com/frida/pcre2.git",
        "b47486922fdc3486499b310dc9cf903449700474",
        "BSD-3-Clause",
        ("LICENCE",),
        "subprojects/glib/subprojects/pcre2.wrap",
    ),
)

NOTICE_KEYS = {
    "frida-gum",
    "quickjs",
    "glib",
    "libffi",
    "capstone",
    "json-glib",
    "tinycc",
    "sqlite",
    "pcre2",
}

EXPECTED_ENGINE_SYMBOLS = {
    "Frida Gum": "_gum_",
    "QuickJS": "_JS_",
    "GLib": "_g_object_",
    "proxy-libintl-static": "_proxy_libintl_",
    "libffi": "_ffi_",
    "Capstone": "_cs_",
    "JSON-GLib": "_json_",
    "TinyCC": "_tcc_",
    "SQLite": "_sqlite3_",
    "PCRE2": "_pcre2_",
}

UNREVIEWED_ENGINE_SYMBOLS = {
    "libsoup": "_soup_",
    "nghttp2": "_nghttp2_",
    "libpsl": "_psl_",
}


def fail(message: str) -> NoReturn:
    raise SystemExit(f"frida-distribution: {message}")


def run(*args: str, cwd: Path | None = None) -> str:
    result = subprocess.run(
        args,
        cwd=cwd,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        fail(f"command failed ({' '.join(args)}): {detail}")
    return result.stdout.strip()


def canonical_remote(value: str) -> str:
    value = value.strip().removesuffix(".git")
    if value.startswith("git@github.com:"):
        value = "https://github.com/" + value.removeprefix("git@github.com:")
    return value


def component_path(source_root: Path, component: Component) -> Path:
    return source_root if component.source_relative == "." else source_root / component.source_relative


def verify_wrap(source_root: Path, component: Component) -> None:
    if component.wrap_relative is None:
        return
    wrap = source_root / component.wrap_relative
    if not wrap.is_file() or wrap.is_symlink():
        fail(f"missing pinned wrap: {component.wrap_relative}")
    data = wrap.read_text(encoding="utf-8")
    revisions = re.findall(r"(?m)^revision\s*=\s*([0-9a-f]{40})\s*$", data)
    urls = re.findall(r"(?m)^url\s*=\s*(\S+)\s*$", data)
    if revisions != [component.commit] or len(urls) != 1:
        fail(f"{component.name} wrap does not name its one reviewed pin")
    if canonical_remote(urls[0]) != canonical_remote(component.repository):
        fail(f"{component.name} wrap remote differs from the reviewed remote")


def verify_git_sources(source_root: Path) -> None:
    for component in COMPONENTS:
        path = component_path(source_root, component)
        if run("git", "rev-parse", "--is-inside-work-tree", cwd=path) != "true":
            fail(f"{component.name} is not a Git checkout: {path}")
        actual = run("git", "rev-parse", "HEAD", cwd=path)
        if actual != component.commit:
            fail(f"{component.name} is {actual}, expected {component.commit}")
        if run(
            "git",
            "status",
            "--porcelain=v1",
            "--untracked-files=no",
            cwd=path,
        ):
            fail(f"{component.name} has tracked source changes")
        remote = run("git", "remote", "get-url", "origin", cwd=path)
        if canonical_remote(remote) != canonical_remote(component.repository):
            fail(f"{component.name} checkout remote differs from {component.repository}")
        verify_wrap(source_root, component)

    releng_entry = run("git", "ls-tree", "HEAD", "releng", cwd=source_root).split()
    if len(releng_entry) < 3 or releng_entry[0] != "160000" or releng_entry[2] != COMPONENTS[1].commit:
        fail("Frida Gum releng gitlink differs from the reviewed pin")


def metadata_lines() -> list[str]:
    return [
        f"| {component.name} | {component.repository} | `{component.commit}` | {component.license_label} |"
        for component in COMPONENTS
    ]


def validate_metadata(repository_root: Path) -> None:
    provenance = repository_root / "ThirdParty/Frida/PROVENANCE.md"
    license_manifest = repository_root / "ThirdParty/LICENSES.md"
    if not provenance.is_file() or not license_manifest.is_file():
        fail("Frida provenance or third-party license manifest is missing")
    text = provenance.read_text(encoding="utf-8")
    if text.count(f"- Pinned Frida version: `{FRIDA_VERSION}`") != 1:
        fail("Frida provenance lacks the reviewed release version")
    for line in metadata_lines():
        if text.count(line) != 1:
            fail(f"Frida provenance must contain exactly one reviewed row: {line}")
    manifest_line = (
        "| Frida GumJS static closure | See `ThirdParty/Frida/PROVENANCE.md` | "
        "wxWindows/LGPL/MIT/BSD/Public Domain — generated as "
        "`IOSUseFridaEngine.framework/Resources/ThirdPartyNotices.txt` | "
        "`ThirdParty/Frida/PROVENANCE.md` |"
    )
    if license_manifest.read_text(encoding="utf-8").count(manifest_line) != 1:
        fail("third-party license manifest lacks the exact Frida GumJS closure row")
    gum_builder = repository_root / "scripts/build_playcover_frida_gum_catalyst.sh"
    if gum_builder.read_text(encoding="utf-8").count(
        f'FRIDA_BUILD_VERSION="{FRIDA_VERSION}"'
    ) != 1:
        fail("Frida Gum builder version differs from the reviewed release version")
    engine_builder = repository_root / "scripts/build_playcover_frida_engine.sh"
    if engine_builder.read_text(encoding="utf-8").count(
        f"plutil -insert CFBundleShortVersionString -string {FRIDA_VERSION}"
    ) != 1:
        fail("Frida Engine bundle version differs from the reviewed release version")
    engine_service = (
        repository_root
        / "swift-cli/Sources/IOSUseCLI/Backends/PlayCover/PlayCoverFridaEngineService.swift"
    )
    if engine_service.read_text(encoding="utf-8").count(
        f'static let descriptorVersion = "{FRIDA_VERSION}"'
    ) != 1:
        fail("Frida Engine descriptor version differs from the reviewed release version")


def sqlite_notice(sqlite_source: Path) -> str:
    lines = (sqlite_source / "sqlite3.h").read_text(encoding="utf-8").splitlines()
    marker = "** The author disclaims copyright to this source code.  In place of"
    indices = [index for index, line in enumerate(lines) if line == marker]
    if not indices:
        fail("SQLite public-domain notice is missing")
    start = indices[0]
    while start >= 0 and lines[start] != "/*":
        start -= 1
    end = indices[0]
    while end < len(lines) and lines[end] != "*/":
        end += 1
    if start < 0 or end >= len(lines):
        fail("SQLite public-domain notice boundaries are invalid")
    notice = "\n".join(lines[start : end + 1]) + "\n"
    if "May you share freely, never taking more than you give." not in notice:
        fail("SQLite public-domain notice changed unexpectedly")
    return notice


def verify_engine(engine: Path) -> None:
    if not engine.is_file() or engine.is_symlink():
        fail(f"Frida Engine binary is missing: {engine}")
    symbols = run("/usr/bin/nm", str(engine))
    for component, token in EXPECTED_ENGINE_SYMBOLS.items():
        if token not in symbols:
            fail(f"Frida Engine lacks the reviewed {component} static-symbol evidence")
    for component, token in UNREVIEWED_ENGINE_SYMBOLS.items():
        if token in symbols:
            fail(f"Frida Engine now contains unreviewed {component} code")
    dynamic = run("/usr/bin/otool", "-L", str(engine)).splitlines()[1:]
    for line in dynamic:
        dependency = line.strip().split(" ", 1)[0]
        if not dependency.startswith(("/System/Library/Frameworks/", "/usr/lib/", "@rpath/")):
            fail(f"Frida Engine has an unreviewed dynamic dependency: {dependency}")


def generate_notices(source_root: Path, engine: Path, output: Path) -> None:
    verify_git_sources(source_root)
    verify_engine(engine)
    chunks = [
        "ios-use Frida Engine third-party notices\n",
        "This file applies to IOSUseFridaEngine.framework. The framework statically "
        "links the pinned components listed below. Exact source is available from "
        "each public upstream repository at the pinned commit shown below; ios-use "
        "integration source and build scripts are available from the matching "
        "ios-use release tag. "
        "Apple frameworks and libraries dynamically loaded from /System/Library or "
        "/usr/lib are not copied into the release.\n",
    ]
    for component in COMPONENTS:
        if component.key not in NOTICE_KEYS:
            continue
        chunks.extend(
            (
                "\n===============================================================================\n",
                f"Component: {component.name}\n",
                f"Upstream: {component.repository}\n",
                f"Pinned commit: {component.commit}\n",
                f"License: {component.license_label}\n",
                "Exact source locator: upstream repository + pinned commit above\n",
            )
        )
        source = component_path(source_root, component)
        if component.key == "sqlite":
            chunks.extend(("\n--- sqlite3.h public-domain notice ---\n", sqlite_notice(source)))
            continue
        for relative in component.license_paths:
            license_path = source / relative
            if not license_path.is_file():
                fail(f"missing {component.name} license material: {relative}")
            chunks.extend(
                (
                    f"\n--- {relative} ---\n",
                    license_path.read_text(encoding="utf-8"),
                )
            )
            if not chunks[-1].endswith("\n"):
                chunks.append("\n")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("".join(chunks), encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "action",
        choices=("validate-metadata", "validate-source", "notices"),
    )
    parser.add_argument("--repository-root", type=Path)
    parser.add_argument("--source-root", type=Path)
    parser.add_argument("--engine", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    repository_root = (args.repository_root or Path(__file__).resolve().parent.parent).resolve()
    validate_metadata(repository_root)
    if args.action == "validate-metadata":
        return
    if args.source_root is None:
        parser.error("--source-root is required")
    source_root = args.source_root.resolve()
    if args.action == "validate-source":
        verify_git_sources(source_root)
    else:
        if args.engine is None or args.output is None:
            parser.error("notices requires --engine and --output")
        generate_notices(source_root, args.engine.resolve(), args.output.resolve())


if __name__ == "__main__":
    main()
