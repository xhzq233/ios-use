#!/usr/bin/env python3
"""Prepare an unencrypted arm64 iOS .app/IPA copy for the standalone runtime."""
import argparse
import json
from pathlib import Path, PurePosixPath
import plistlib
import shutil
import stat
import struct
import subprocess
import tempfile
import zipfile
from retarget_metallib import retarget

MACH_MAGICS = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}


def command(*args):
    return subprocess.check_output(list(map(str, args)), stderr=subprocess.STDOUT, text=True)


def inspect(path):
    data = path.read_bytes()
    if len(data) < 32 or data[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError(f'{path.name}: expected a thin 64-bit Mach-O')
    _, cpu, subtype, kind, count, size, _, _ = struct.unpack_from('<8I', data)
    if cpu != 0x100000c or subtype & 0xffffff not in (0, 1):
        raise ValueError(f'{path.name}: requires ordinary arm64, not arm64e or another architecture')
    if kind not in (2, 6, 8) or 32 + size > len(data):
        raise ValueError(f'{path.name}: unsupported or truncated Mach-O')
    result = {'platform': None, 'minimum': None, 'sdk': None, 'dependencies': [], 'rpaths': []}
    offset = 32
    for _ in range(count):
        if offset + 8 > 32 + size:
            raise ValueError(f'{path.name}: truncated load command')
        cmd, length = struct.unpack_from('<2I', data, offset)
        if length < 8 or offset + length > 32 + size:
            raise ValueError(f'{path.name}: invalid load command size')
        if cmd in (0x21, 0x2c):
            if length < 20 or struct.unpack_from('<I', data, offset + 16)[0]:
                raise ValueError(f'{path.name}: encrypted binary; provide an unencrypted development build')
        if cmd == 0x32:
            if length < 24: raise ValueError('Truncated build version')
            result['platform'], result['minimum'], result['sdk'] = struct.unpack_from('<3I', data, offset + 8)
        elif cmd == 0x25:
            if length < 16: raise ValueError('Truncated iOS version')
            result['platform'] = 2
            result['minimum'], result['sdk'] = struct.unpack_from('<2I', data, offset + 8)
        if cmd in (0xc, 0x80000018, 0x8000001f, 0x80000023, 0x8000001c):
            if length < 12: raise ValueError('Truncated path command')
            start = struct.unpack_from('<I', data, offset + 8)[0]
            if start < 12 or start >= length: raise ValueError('Invalid load path offset')
            raw = data[offset + start:offset + length]
            if b'\0' not in raw: raise ValueError('Unterminated load path')
            name = raw.split(b'\0', 1)[0].decode('utf-8')
            if cmd == 0x8000001c: result['rpaths'].append(name)
            else: result['dependencies'].append({'path': name, 'weak': cmd == 0x80000018})
        offset += length
    if offset != 32 + size or result['platform'] not in (2, 7):
        raise ValueError(f'{path.name}: expected iOS or iOS Simulator platform metadata')
    return result


def version(value):
    return f'{value >> 16}.{(value >> 8) & 255}.{value & 255}'


def unpack(source, work):
    if source.is_dir() and source.suffix == '.app':
        # Preserve internal links without importing arbitrary files outside the app.
        for path in source.rglob('*'):
            if path.is_symlink() and not path.resolve().is_relative_to(source):
                raise ValueError(f'Bundle symlink escapes the app: {path.relative_to(source)}')
        app = work / source.name
        shutil.copytree(source, app, symlinks=True)
        return app
    with zipfile.ZipFile(source) as archive:
        for entry in archive.infolist():
            path = PurePosixPath(entry.filename)
            if path.is_absolute() or '..' in path.parts or stat.S_ISLNK(entry.external_attr >> 16):
                raise ValueError('IPA contains an escaping path or unsupported symlink')
        archive.extractall(work / 'unpacked')
    apps = list((work / 'unpacked/Payload').glob('*.app'))
    if len(apps) != 1: raise ValueError('IPA must contain exactly one Payload/*.app')
    return apps[0]


def prepare(source, destination, runtime):
    source, destination, runtime = source.resolve(), destination.absolute(), runtime.resolve()
    if destination.exists() or destination.is_symlink(): raise ValueError('Output already exists; choose a new .app path')
    if destination.suffix != '.app': raise ValueError('Output must end in .app')
    if source.is_dir() and destination.resolve().is_relative_to(source): raise ValueError('Output must be outside the input app')
    with (runtime / 'System/Library/CoreServices/SystemVersion.plist').open('rb') as f:
        runtime_version = plistlib.load(f)['ProductVersion']
    parts = list(map(int, runtime_version.split('.')))
    runtime_min = sum(value << shift for value, shift in zip(parts + [0, 0], (16, 8, 0)))
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='import-', dir=destination.parent) as directory:
        work = Path(directory)
        app = unpack(source, work)
        with (app / 'Info.plist').open('rb') as f: info = plistlib.load(f)
        executable = info.get('CFBundleExecutable', '')
        if not executable or Path(executable).name != executable or not (app / executable).is_file():
            raise ValueError('App has no valid CFBundleExecutable')
        binaries = {}
        libraries = []
        for path in sorted(app.rglob('*')):
            if not path.is_file() or path.is_symlink(): continue
            with path.open('rb') as f: magic = f.read(4)
            if magic == b'MTLB':
                libraries.append(path)
            elif magic in MACH_MAGICS:
                if magic != b'\xcf\xfa\xed\xfe':
                    architectures = command('xcrun', 'lipo', '-archs', path).split()
                    if 'arm64' not in architectures: raise ValueError(f'{path.relative_to(app)}: no arm64 slice')
                    thin = work / 'thin'
                    command('xcrun', 'lipo', path, '-thin', 'arm64', '-output', thin)
                    thin.replace(path)
                record = inspect(path)
                if record['minimum'] > runtime_min:
                    raise ValueError(f'{path.relative_to(app)}: minimum iOS {version(record["minimum"])} exceeds runtime {runtime_version}')
                binaries[path] = record
        main = app / executable
        if main not in binaries: raise ValueError('Main executable is not supported Mach-O')
        # Resolve bundled dependencies, including transitive @rpath inheritance.
        def expand(name, loader):
            return name.replace('@loader_path', str(loader.parent)).replace('@executable_path', str(main.parent))
        resolved = set()
        def resolve(path, inherited, visited):
            if path in visited: return
            visited = visited | {path}
            resolved.add(path)
            record = binaries[path]
            search = [expand(p, path) for p in record['rpaths']] + inherited
            for dep in record['dependencies']:
                name = dep['path']
                if name.startswith(('/System/Library/', '/usr/lib/')):
                    # Shared-cache images are validated by dyld when launching;
                    # their absence on disk does not mean the dependency is missing.
                    dep['resolution'] = 'runtime (dyld validation at launch)'
                    continue
                candidates = ([Path(p) / name[7:] for p in search] if name.startswith('@rpath/') else [Path(expand(name, path))])
                runtime_candidate = next((str(p) for p in candidates if str(p).startswith(('/System/Library/', '/usr/lib/'))), None)
                found = next((p.resolve() for p in candidates if p.is_file() and p.resolve().is_relative_to(app)), None)
                if found is None:
                    if runtime_candidate:
                        dep['resolution'] = runtime_candidate + ' (dyld validation at launch)'
                        continue
                    if dep['weak']:
                        dep['resolution'] = 'missing optional dependency'
                        continue
                    raise ValueError(f'{path.relative_to(app)}: unresolved dependency {name}')
                if found not in binaries: raise ValueError(f'{name}: dependency is not supported Mach-O')
                dep['resolution'] = str(found.relative_to(app))
                resolve(found, search, visited)
        resolve(main, [], set())
        for path in binaries:
            if path not in resolved:
                resolve(path, [expand(p, main) for p in binaries[main]['rpaths']], set())
        for path, record in binaries.items():
            converted = work / 'converted'
            command('xcrun', 'vtool', '-set-build-version', 'iossim', version(record['minimum']),
                    version(record['sdk']), '-replace', '-output', converted, path)
            converted.replace(path)
            path.chmod(path.stat().st_mode | 0o111)
        for path in libraries:
            converted = work / 'converted.metallib'
            retarget(path, converted)
            converted.replace(path)
        for path in app.rglob('Info.plist'):
            with path.open('rb') as f: metadata = plistlib.load(f)
            if 'CFBundleExecutable' not in metadata: continue
            metadata['CFBundleSupportedPlatforms'] = ['iPhoneSimulator']
            metadata['DTPlatformName'] = 'iphonesimulator'
            with path.open('wb') as f: plistlib.dump(metadata, f)
        for path in list(app.rglob('_CodeSignature')):
            if path.is_dir(): shutil.rmtree(path)
        for path in app.rglob('embedded.mobileprovision'): path.unlink()
        # New ad-hoc identities; never copy device signing rights onto the Mac.
        for path in sorted(binaries, key=lambda p: len(p.parts), reverse=True):
            command('codesign', '--force', '--sign', '-', path)
        bundles = [p for p in app.rglob('*') if p.is_dir() and p.suffix in ('.framework', '.appex', '.app', '.xpc')]
        for path in sorted(bundles, key=lambda p: len(p.parts), reverse=True) + [app]:
            command('codesign', '--force', '--sign', '-', path)
        command('codesign', '--verify', '--deep', '--strict', app)
        report = {'runtime': runtime_version, 'binaries': [{**record, 'source_platform': record['platform'], 'platform': 7, 'path': str(path.relative_to(app))} for path, record in binaries.items()],
                  'metal_libraries': [str(path.relative_to(app)) for path in libraries],
                  'limitations': ['Platform retargeting does not guarantee ABI or API compatibility.',
                                  'App extensions and system-library availability require runtime validation.']}
        # Keep the import report outside the signed application bundle.
        app.rename(destination)
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('output', type=Path, help='New .app directory; never overwrites existing data')
    parser.add_argument('--runtime-root', required=True, type=Path)
    args = parser.parse_args()
    try:
        report = prepare(args.input, args.output, args.runtime_root)
        print(json.dumps(report, indent=2))
    except (ValueError, OSError, KeyError, struct.error, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        detail = error.output if isinstance(error, subprocess.CalledProcessError) else str(error)
        parser.exit(1, f'App import failed: {detail}\n')
