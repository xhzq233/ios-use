#!/usr/bin/env python3
"""Verify scroll search against App callbacks; run folded and expanded separately."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--udid', required=True, help='Booted test Simulator with a running Driver')
    parser.add_argument('--home', required=True, help='Isolated IOS_USE_HOME for that Driver')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    home = Path(args.home).resolve()
    env = dict(os.environ, IOS_USE_HOME=str(home))
    bundle = 'com.iosuse.playfixture.stablev1'
    devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'booted', '--json']))
    assert any(d['udid'] == args.udid for group in devices['devices'].values() for d in group), 'Use a booted test Simulator'
    container = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', args.udid, bundle, 'data'], text=True).strip())
    evidence = home / 'artifacts' / ('scroll-axis-' + str(time.time_ns()))
    evidence.mkdir(parents=True)
    calls = []

    def cli(*command, error=None):
        begin = time.monotonic()
        p = subprocess.run([str(root / 'ios-use'), *command, '-d', args.udid, '--json'], env=env,
                           capture_output=True, text=True, timeout=90)
        reply = json.loads(p.stdout or p.stderr)
        calls.append({'command': command, 'milliseconds': (time.monotonic() - begin) * 1000, 'reply': reply})
        (evidence / 'commands.json').write_text(json.dumps(calls, indent=2))
        if error:
            assert not reply['ok'] and reply['error']['code'] == error, reply
        else:
            assert p.returncode == 0 and reply['ok'], reply
        return reply['data']

    def dom():
        return cli('dom', '--nodiff')['elements']

    def visible(identifier):
        return any(e.get('identifier') == identifier and 'invisible' not in e['traits'] for e in dom())

    def offsets():
        return json.loads((container / 'Documents' / 'scroll-state.json').read_text())

    subprocess.run(['xcrun', 'simctl', 'launch', '--terminate-running-process', args.udid, bundle], env=env, capture_output=True, check=True)
    cli('activateApp', bundle)
    for _ in range(30):
        if visible('fixture.uikit.increment'):
            break
        time.sleep(.1)
    else:
        raise AssertionError('Fixture did not reach its initial UIKit page')
    before = dom()
    original = float(next(e['value'] for e in before if e.get('identifier') == 'fixture.scroll.status'))
    cli('swipe', '--from', 'fixture.uikit.increment', '--find', 'fixture.uikit.longpress')
    assert visible('fixture.uikit.longpress')
    current = float(next(e['value'] for e in dom() if e.get('identifier') == 'fixture.scroll.status'))
    assert current > original, (original, current)

    cli('tap', 'fixture.tab.scroll')
    cli('tap', 'fixture.scroll.reset')
    cli('swipe', '--from', 'fixture.left.row.0', '--find', 'fixture.left.row.8')
    s = offsets()
    assert s['left'] > 0 and s['right'] == s['strip'] == 0, s
    assert visible('fixture.left.row.8')

    cli('tap', 'fixture.scroll.reset')
    cli('swipe', '--from', 'fixture.strip.0', '--find', 'fixture.strip.6')
    s = offsets()
    assert s['strip'] > 0 and s['left'] == s['right'] == 0, s
    assert visible('fixture.strip.6')

    cli('tap', 'fixture.scroll.reset')
    cli('swipe', '--from', 'fixture.left.row.0', '--dir', 'forth', '--distance', '200')
    s = offsets()
    assert s['left'] > 0 and s['right'] == s['strip'] == 0, s

    # Isolate unknown-axis probing from gesture hand-off to an outer list.
    cli('tap', 'fixture.scroll.sparse')
    assert offsets()['sparseStrip']
    assert not any(e.get('identifier') == 'fixture.strip.2' for e in dom()), 'Target must be absent, not merely offscreen'
    result = cli('swipe', '--from', 'fixture.strip.0', '--find', 'fixture.strip.2')
    assert result['direction'] == 'right', result
    s = offsets()
    assert s['strip'] > 0 and s['left'] == s['right'] == 0, s
    assert visible('fixture.strip.2')
    gestures = json.loads((container / 'Documents' / 'gesture-state.json').read_text())
    drags = [v for v in gestures['vectors'] if max(abs(v[0]), abs(v[1])) > 20]
    assert len(drags) >= 2 and abs(drags[0][1]) > abs(drags[0][0]), drags
    assert all(abs(v[0]) > abs(v[1]) for v in drags[1:]), drags

    # Go to the real end, then verify a missing target terminates at a boundary.
    cli('tap', 'fixture.scroll.sparse')
    cli('swipe', '--from', 'fixture.strip.0', '--find', 'fixture.strip.14')
    cli('swipe', '--from', 'fixture.scroll.strip', '--find', '__absent_scroll_target__', error='scroll_boundary')
    cli('tap', 'fixture.scroll.reset')
    print(json.dumps({'passed': ['UIKit offscreen target', 'vertical list', 'nested horizontal strip',
                                'distance scroll', 'unknown-axis search', 'real boundary'],
                      'evidence': str(evidence)}))


if __name__ == '__main__':
    main()
