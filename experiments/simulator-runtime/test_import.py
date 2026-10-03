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
    originals = {p.relative_to(app): p.read_bytes() for p in app.rglob('*') if p.is_file()}
    ipa = work / 'fixture.ipa'
    with zipfile.ZipFile(ipa, 'w') as archive:
        for relative in originals: archive.write(app / relative, 'Payload/ImportProbe.app/' + str(relative))
    converted = work / 'Converted.app'
    report = prepare(ipa, converted, args.runtime_root)
    assert len(report['binaries']) == 4 and len(report['metal_libraries']) == 1
    for relative, original in originals.items(): assert (app / relative).read_bytes() == original
    assert inspect(converted / 'ImportProbe')['platform'] == 7
    assert inspect(converted / 'Frameworks/Arithmetic.framework/Arithmetic')['platform'] == 7
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
        try: prepare(bundle, destination, args.runtime_root)
        except ValueError: pass
        else: raise AssertionError(f'{name}: import should fail')
        assert not destination.exists()
    missing = work / 'Missing.app'; shutil.copytree(app, missing)
    shutil.rmtree(missing / 'Frameworks')
    reject(missing, 'missing-dependency')
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
    try: prepare(ipa, converted, args.runtime_root)
    except ValueError: pass
    else: raise AssertionError('Existing output must not be overwritten')
    hostile = work / 'escape.ipa'
    with zipfile.ZipFile(hostile, 'w') as archive: archive.writestr('../escaped', 'test')
    reject(hostile, 'escaping-archive')
    assert not (work / 'escaped').exists()
    print('Import E2E passed: device IPA, framework call, Metal compute, UIKit, source preservation, and rejection/cleanup boundaries')
