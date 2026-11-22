#!/usr/bin/env python3
"""Build a device app with nested code and Metal, import it, and run real GPU/UIKit work."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import zipfile
from import_app import prepare, inspect

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--runtime-root', required=True, type=Path)
parser.add_argument('--skip-runtime', action='store_true', help='Verify import, signing, and rejection boundaries without launching GPU/UIKit')
args = parser.parse_args()
source = Path(__file__).resolve().parent
root = Path(os.environ.get('IOS_USE_HOME', source.parents[1] / '.ios-use')) / 'artifacts/runtime-import'
root.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='test-', dir=root) as directory:
    work = Path(directory).resolve()
    def run(*command): subprocess.run(list(map(str, command)), check=True)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
    flags = ['-target', 'arm64-apple-ios17.0', '-isysroot', sdk]
    app = work / 'Payload/ImportProbe.app'
    framework = app / 'Frameworks/Arithmetic.framework'
    framework.mkdir(parents=True)
    helpers = framework / 'Helpers'
    helpers.mkdir()
    (work / 'Leaf.c').write_text('int leafValue(void) { return 42; }\n')
    (work / 'Helper.c').write_text('extern int leafValue(void); int helperValue(void) { return leafValue(); }\n')
    (work / 'Arithmetic.c').write_text('extern int helperValue(void); int importedValue(void) { return helperValue(); }\n')
    run('xcrun', 'clang', *flags, '-dynamiclib', work / 'Leaf.c', '-install_name', '@rpath/Leaf.dylib', '-o', helpers / 'Leaf.dylib')
    run('xcrun', 'clang', *flags, '-dynamiclib', work / 'Helper.c', helpers / 'Leaf.dylib', '-install_name', '@rpath/Helper.dylib', '-o', helpers / 'Helper.dylib')
    run('xcrun', 'clang', *flags, '-dynamiclib', work / 'Arithmetic.c', helpers / 'Helper.dylib',
        '-Wl,-rpath,@loader_path/Helpers', '-install_name', '@rpath/Arithmetic.framework/Arithmetic', '-o', framework / 'Arithmetic')
    for bundle, executable, kind in ((app, 'ImportProbe', 'APPL'), (framework, 'Arithmetic', 'FMWK')):
        with (bundle / 'Info.plist').open('wb') as f:
            plistlib.dump({'CFBundleIdentifier': 'io.iosuse.' + executable.lower(), 'CFBundleExecutable': executable,
                          'CFBundlePackageType': kind, 'MinimumOSVersion': '17.0'}, f)
    (work / 'ImportProbe.m').write_text('''
#define main gpuMain
#include "GPUProbe.m"
#undef main
#define main presentationMain
#include "PresentationProbe.m"
#undef main
extern int importedValue(void);
int main(int argc, char **argv) {
    @autoreleasepool {
        if (importedValue() != 42) return 113;
        NSString *library = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"device.metallib"];
        char *gpu[] = {"probe", "compute-metallib", (char *)library.UTF8String};
        int result = gpuMain(3, gpu);
        if (result) return result;
        char *ui[] = {argv[0], "--exit-code", "0"};
        return presentationMain(3, ui);
    }
}
''')
    run('xcrun', 'clang', *flags, '-fobjc-arc', '-fblocks', '-I', source, work / 'ImportProbe.m',
        '-F', app / 'Frameworks', '-framework', 'Arithmetic', '-Wl,-rpath,@executable_path/Frameworks',
        '-framework', 'Foundation', '-framework', 'UIKit', '-framework', 'Metal', '-framework', 'IOSurface', '-o', app / 'ImportProbe')
    run('xcrun', '-sdk', 'iphoneos', 'metal', '-std=metal3.0', '-target', 'air64-apple-ios17.0', '-c', source / 'probe.metal', '-o', work / 'probe.air')
    run('xcrun', '-sdk', 'iphoneos', 'metallib', work / 'probe.air', '-o', app / 'device.metallib')
    thin = work / 'device-arm64'
    shutil.copy2(app / 'ImportProbe', thin)
    (work / 'Other.c').write_text('int main(void) { return 0; }\n')
    sim_sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
    run('xcrun', 'clang', '-target', 'x86_64-apple-ios17.0-simulator', '-isysroot', sim_sdk,
        work / 'Other.c', '-o', work / 'other-arch')
    run('xcrun', 'lipo', '-create', thin, work / 'other-arch', '-output', app / 'ImportProbe')

    # Separate executable roots share a framework and its helper, but each
    # contributes a different leaf through its own inherited run-path stack.
    nested_framework = app / 'Frameworks/Nested.framework'
    nested_helpers = nested_framework / 'Helpers'
    nested_helpers.mkdir(parents=True)
    with (nested_framework / 'Info.plist').open('wb') as f:
        plistlib.dump({'CFBundleIdentifier': 'io.iosuse.nested', 'CFBundleExecutable': 'Nested',
                      'CFBundlePackageType': 'FMWK', 'MinimumOSVersion': '17.0'}, f)
    nested_entries = []
    for index, (relative, layout, kind) in enumerate((('PlugIns/Widget.appex', '', 'XPC!'),
                                                    ('Watch/Companion.app', '', 'APPL'),
                                                    ('XPCServices/Worker.xpc', 'Contents/MacOS', 'XPC!')), 1):
        bundle = app / relative
        executable = bundle / layout / bundle.stem
        executable.parent.mkdir(parents=True)
        metadata = bundle / ('Contents/Info.plist' if layout else 'Info.plist')
        with metadata.open('wb') as f:
            plistlib.dump({'CFBundleIdentifier': 'io.iosuse.' + bundle.stem.lower(),
                          'CFBundleExecutable': executable.name, 'CFBundlePackageType': kind,
                          'MinimumOSVersion': '17.0'}, f)
        leaf = bundle / ('Contents/Frameworks/Leaf.dylib' if layout else 'Libraries/Leaf.dylib')
        leaf.parent.mkdir()
        leaf_source = work / f'NestedLeaf{index}.c'
        leaf_source.write_text(f'int leafValue(void) {{ return {index}; }}\n')
        run('xcrun', 'clang', *flags, '-dynamiclib', leaf_source, '-install_name', '@rpath/Leaf.dylib', '-o', leaf)
        nested_entries.append((executable, leaf, index))
    run('xcrun', 'clang', *flags, '-dynamiclib', work / 'Helper.c', nested_entries[0][1],
        '-install_name', '@rpath/Common.dylib', '-o', nested_helpers / 'Common.dylib')
    (work / 'Nested.c').write_text('extern int helperValue(void); int nestedValue(void) { return helperValue(); }\n')
    run('xcrun', 'clang', *flags, '-dynamiclib', work / 'Nested.c', nested_helpers / 'Common.dylib',
        '-Wl,-rpath,@loader_path/Helpers', '-install_name', '@rpath/Nested.framework/Nested', '-o', nested_framework / 'Nested')
    for executable, leaf, value in nested_entries:
        entry_source = work / f'{executable.name}.c'
        entry_source.write_text(f'extern int nestedValue(void); int main(void) {{ return nestedValue() != {value}; }}\n')
        run('xcrun', 'clang', *flags, entry_source, nested_framework / 'Nested',
            '-Wl,-rpath,@executable_path/' + os.path.relpath(leaf.parent, executable.parent),
            '-Wl,-headerpad_max_install_names', '-o', executable)
        run('xcrun', 'install_name_tool', '-change', '@rpath/Nested.framework/Nested',
            '@executable_path/' + os.path.relpath(nested_framework / 'Nested', executable.parent), executable)
    # Code not reachable from LC_LOAD_DYLIB still belongs to its enclosing entry
    # point; it must not receive the outer application's rpaths as a fallback.
    run('xcrun', 'clang', *flags, '-dynamiclib', work / 'Helper.c', nested_entries[0][1],
        '-install_name', '@loader_path/Optional.dylib', '-o', nested_entries[0][0].parent / 'Optional.dylib')

    originals = {p.relative_to(app): p.read_bytes() for p in app.rglob('*') if p.is_file()}
    ipa = work / 'fixture.ipa'
    with zipfile.ZipFile(ipa, 'w') as archive:
        for relative in originals: archive.write(app / relative, 'Payload/ImportProbe.app/' + str(relative))
    converted = work / 'Converted.app'
    report = prepare(ipa, converted, args.runtime_root)
    assert len(report['binaries']) == 13 and len(report['metal_libraries']) == 1
    for relative, original in originals.items(): assert (app / relative).read_bytes() == original
    for record in report['binaries']: assert inspect(converted / record['path'])['platform'] == 7
    common = next(record for record in report['binaries'] if app / record['path'] == nested_helpers / 'Common.dylib')
    resolutions = next(dep['resolutions'] for dep in common['dependencies'] if 'resolutions' in dep)
    assert {(app / entry, app / leaf) for entry, leaf in resolutions.items()} == {(entry, leaf) for entry, leaf, _ in nested_entries}
    if not args.skip_runtime:
        env = os.environ.copy(); env['IOS_USE_HOME'] = str(work / 'runtime')
        process = subprocess.Popen([sys.executable, str(source / "run.py"), "--runtime-root", str(args.runtime_root),
                                    "--app", str(converted), "--present", "--services", "metal", "compiler", "iosurface"],
                                   env=env, start_new_session=True)
        try:
            assert process.wait(timeout=60) == 0
        finally:
            if process.poll() is None:
                process.send_signal(signal.SIGINT)
                try: process.wait(timeout=10)
                except subprocess.TimeoutExpired: process.kill()
            try: os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            process.wait()

    def reject(bundle, name):
        destination = work / f'rejected-{name}.app'
        inputs = {p: p.read_bytes() for p in bundle.rglob('*') if p.is_file()} if bundle.is_dir() else {bundle: bundle.read_bytes()}
        try: prepare(bundle, destination, args.runtime_root)
        except ValueError: pass
        else: raise AssertionError(f'{name}: import should fail')
        assert not destination.exists()
        assert not list(work.glob('import-*'))
        for path, original in inputs.items(): assert path.read_bytes() == original
    missing = work / 'Missing.app'; shutil.copytree(app, missing)
    shutil.rmtree(missing / 'Frameworks')
    reject(missing, 'missing-dependency')
    missing_nested = work / 'MissingNested.app'; shutil.copytree(app, missing_nested)
    (missing_nested / nested_entries[-1][1].relative_to(app)).unlink()
    # An outer-app fallback must not satisfy a separately launched child's leaf.
    shutil.copy2(helpers / 'Leaf.dylib', missing_nested / 'Frameworks/Leaf.dylib')
    reject(missing_nested, 'missing-nested-dependency')
    encrypted = work / 'Encrypted.app'; shutil.copytree(app, encrypted)
    binary = bytearray(thin.read_bytes())
    offset = 32
    for _ in range(struct.unpack_from('<I', binary, 16)[0]):
        cmd, length = struct.unpack_from('<2I', binary, offset)
        if cmd == 0x2c:
            struct.pack_into('<I', binary, offset + 16, 1)
            break
        offset += length
    else: raise AssertionError('Device fixture should have an encryption command')
    (encrypted / 'ImportProbe').write_bytes(binary)
    reject(encrypted, 'encrypted')
    converted_contents = {p: p.read_bytes() for p in converted.rglob('*') if p.is_file()}
    try: prepare(ipa, converted, args.runtime_root)
    except ValueError: pass
    else: raise AssertionError('Existing output must not be overwritten')
    for path, original in converted_contents.items(): assert path.read_bytes() == original
    hostile = work / 'escape.ipa'
    with zipfile.ZipFile(hostile, 'w') as archive: archive.writestr('../escaped', 'test')
    reject(hostile, 'escaping-archive')
    assert not (work / 'escaped').exists()
    if args.skip_runtime:
        print('Import file checks passed: device IPA, nested executable contexts, transitive dependencies, signing, source preservation, and rejection/cleanup boundaries')
    else:
        print('Import E2E passed: device IPA, nested executable contexts, framework call, Metal compute, UIKit, source preservation, and rejection/cleanup boundaries')
