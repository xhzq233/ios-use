#!/usr/bin/env python3
"""Managed iPhoneOS fixture: live config, player preservation and restart state."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--live', action='store_true', required=True)
parser.add_argument('--home', type=Path, required=True, help='isolated IOS_USE_HOME')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
home = args.home.expanduser().resolve()
home.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, IOS_USE_HOME=str(home))
cli = root / 'ios-use'
evidence = []


def run(*arguments):
    result = subprocess.run([str(cli), *arguments, '--json'], cwd=root, env=env,
                            text=True, capture_output=True, timeout=90)
    evidence.append({'args': arguments, 'rc': result.returncode,
                     'stdout': result.stdout, 'stderr': result.stderr})
    assert result.returncode == 0, result.stderr or result.stdout
    value = json.loads(result.stdout)
    assert value['ok'], value
    return value['data']


def state():
    script = '''
const get=new NativeFunction(Module.getExportByName('IOSUsePlayRuntime','IOSUsePlayAudioState'),'pointer',[]);
new Promise(resolve=>ObjC.schedule(ObjC.mainQueue,()=>{
 const s=new ObjC.Object(get()),p=ObjC.classes.UIApplication.sharedApplication().delegate().player();
 resolve({volume:s.objectForKey_('volume').intValue(),muted:!!s.objectForKey_('muted').boolValue(),
 effective:s.objectForKey_('effectiveVolume').intValue(),outputs:s.objectForKey_('outputCallbacks').intValue(),
 unsupported:s.objectForKey_('unsupportedOutputs').intValue(),playing:!!p.isPlaying(),playerVolume:p.volume()});
}));'''
    data = run('debug', '-d', 'mac', script)
    # The debug command exposes its final expression as display text.
    return json.loads(data.get('debug', data)['display'])


initial = run('status')
mac = next((d for d in initial['devices'] if d['id'] == 'mac'), None)
assert mac is None or mac['driver']['status'] == 'notRunning', 'Test Home already has an active Mac App'
app = home / 'artifacts' / 'AudioFixture.app'
app.mkdir(parents=True, exist_ok=True)
with (app / 'Info.plist').open('wb') as out:
    plistlib.dump({'CFBundleIdentifier': 'com.iosuse.playfixture.audio51',
                  'CFBundleName': 'Audio Fixture', 'CFBundleExecutable': 'AudioFixture',
                  'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
                  'CFBundleShortVersionString': '1.0', 'MinimumOSVersion': '15.0',
                  'UIDeviceFamily': [1, 2], 'UILaunchScreen': {}}, out)
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
subprocess.run(['xcrun', '--sdk', 'iphoneos', 'clang', '-target', 'arm64-apple-ios15.0',
                '-isysroot', sdk, '-fobjc-arc', '-framework', 'UIKit', '-framework', 'AVFoundation',
                str(root / 'playcover-runtime/tests/AudioAppFixture.m'), '-o', str(app / 'AudioFixture')], check=True)
started = False
try:
    configured = run('config', '--mac', '--volume', '25', '--mute', 'on')
    assert configured['appliesOn'] == 'nextColdStart'
    # Ownership is established before the call, so a readiness failure still
    # cleans up this fixture's launched process through the isolated context.
    started = True
    run('start', '--mac', '--app', str(app), '--timeout', '30s')
    first = state()
    assert first['volume'] == 25 and first['muted'] and first['effective'] == 0, first
    assert first['playing'] and first['outputs'] > 0 and first['unsupported'] == 0, first
    assert abs(first['playerVolume'] - .4) < .001, first
    for options, volume, muted in [(['--mute', 'off'], 25, False),
                                  (['--volume', '60', '--mute', 'on'], 60, True),
                                  (['--mute', 'off'], 60, False),
                                  (['--volume', '0'], 0, False),
                                  (['--volume', '35', '--mute', 'on'], 35, True)]:
        changed = run('config', '--mac', *options)
        assert changed['appliesOn'] == 'currentSession', changed
        assert changed['audio']['volume'] == volume and changed['audio']['muted'] == muted, changed
        current = state()
        assert current['volume'] == volume and current['muted'] == muted, current
        assert current['effective'] == (0 if muted else volume), current
        assert current['playing'] and abs(current['playerVolume'] - .4) < .001, current
    run('stop', '-d', 'mac')
    run('start', '--mac', '--timeout', '30s')
    restarted = state()
    assert restarted['volume'] == 35 and restarted['muted'] and restarted['effective'] == 0, restarted
    print('[audio-live] cold launch, live config, native player preservation and restart PASS')
finally:
    if started:
        run('stop', '-d', 'mac')
    (home / 'audio-e2e.json').write_text(json.dumps(evidence, indent=2))
