#!/usr/bin/env python3
"""Check explicit scroll directions on a running public fixture (XCTest or Mac)."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--home', required=True, help='Isolated IOS_USE_HOME')
    parser.add_argument('--state-dir', required=True, help="Public fixture's Documents directory")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    home = Path(args.home).resolve()
    env = dict(os.environ, IOS_USE_HOME=str(home))
    state_dir = Path(args.state_dir)
    evidence = home / 'artifacts' / ('scroll-directions-' + str(time.time_ns()))
    evidence.mkdir(parents=True)
    calls = []

    def cli(*command, failure=False):
        p = subprocess.run([str(repo / 'ios-use'), *command, '-d', args.device, '--json'], env=env,
                           text=True, capture_output=True, timeout=90)
        reply = json.loads(p.stdout or p.stderr)
        calls.append({'command': command, 'reply': reply})
        (evidence / 'commands.json').write_text(json.dumps(calls, indent=2))
        if failure:
            assert not reply['ok'] and reply['error']['code'] in ('scroll_boundary', 'scroll_no_effect'), reply
        else:
            assert p.returncode == 0 and reply['ok'], reply
        return reply['data']

    def state():
        return json.loads((state_dir / 'scroll-state.json').read_text())

    def visible(identifier):
        return any(e.get('identifier') == identifier and 'invisible' not in e['traits']
                   for e in cli('dom', '--nodiff')['elements'])

    cli('tap', 'fixture.tab.uikit')
    cli('swipe', '--from', 'fixture.uikit.increment', '--find', 'fixture.uikit.longpress', '--dir', 'down')
    assert visible('fixture.uikit.longpress')
    cli('swipe', '--from', 'fixture.uikit.longpress', '--find', 'fixture.uikit.increment', '--dir', 'up')
    assert visible('fixture.uikit.increment')

    cli('tap', 'fixture.tab.scroll')
    cli('tap', 'fixture.scroll.reset')
    # A target below the viewport must not override an explicit upward request.
    cli('swipe', '--from', 'fixture.left.row.0', '--find', 'fixture.left.row.8', '--dir', 'up', failure=True)
    assert state()['left'] == state()['right'] == state()['strip'] == 0, state()
    cli('swipe', '--from', 'fixture.left.row.0', '--find', 'fixture.left.row.8', '--dir', 'down')
    assert state()['left'] > 0 and state()['right'] == state()['strip'] == 0, state()
    assert visible('fixture.left.row.8')
    cli('swipe', '--from', 'fixture.left.row.8', '--find', 'fixture.left.row.0', '--dir', 'up')
    assert visible('fixture.left.row.0')

    cli('tap', 'fixture.scroll.reset')
    cli('swipe', '--from', 'fixture.strip.0', '--find', 'fixture.strip.6', '--dir', 'right')
    assert state()['strip'] > 0 and state()['left'] == state()['right'] == 0, state()
    assert visible('fixture.strip.6')
    cli('swipe', '--from', 'fixture.strip.6', '--find', 'fixture.strip.0', '--dir', 'left')
    assert visible('fixture.strip.0')

    cli('tap', 'fixture.scroll.reset')
    for forward, backward, anchor, field in [('down', 'up', 'fixture.scroll.left', 'left'),
                                            ('right', 'left', 'fixture.scroll.strip', 'strip'),
                                            ('forth', 'back', 'fixture.scroll.left', 'left'),
                                            ('forth', 'back', 'fixture.scroll.strip', 'strip')]:
        cli('swipe', '--from', anchor, '--dir', forward, '--distance', '100')
        before = state()[field]
        assert before > 0, state()
        cli('swipe', '--from', anchor, '--dir', backward, '--distance', '100')
        assert state()[field] < before, state()
        cli('tap', 'fixture.scroll.reset')

    # The sparse standalone carousel supplies no trustworthy layout-axis hint.
    cli('tap', 'fixture.scroll.sparse')
    cli('swipe', '--from', 'fixture.strip.0', '--find', 'fixture.strip.2', '--dir', 'up', failure=True)
    assert state()['strip'] == state()['left'] == state()['right'] == 0, state()
    cli('tap', 'fixture.scroll.reset')
    # This virtualized fixture exposes a page only after its leading edge has
    # entered the viewport. Mac's fixed offset steps can discover it too late
    # to fit it fully without reversing. Explicit directions must not reverse.
    cli('swipe', '--from', 'fixture.strip.0', '--find', 'fixture.strip.2', '--dir', 'right',
        failure=args.device == 'mac')
    if args.device != 'mac':
        assert visible('fixture.strip.2')
    assert state()['strip'] > 0 and state()['left'] == state()['right'] == 0, state()
    if args.device == 'mac':
        cli('swipe', '--from', 'fixture.strip.14', '--find', 'fixture.strip.2', '--dir', 'left')
        assert visible('fixture.strip.2')
    else:
        gestures = json.loads((state_dir / 'gesture-state.json').read_text())
        drags = [v for v in gestures['vectors'] if max(map(abs, v)) > 20]
        assert drags and all(abs(v[0]) > abs(v[1]) for v in drags), drags
        (evidence / 'explicit-right-gestures.json').write_text(json.dumps(gestures, indent=2))
    cli('tap', 'fixture.scroll.sparse')
    cli('tap', 'fixture.scroll.reset')
    print(json.dumps({'explicitDirectionsPassed': ['up', 'down', 'left', 'right'],
                      'wrongDirectionDidNotSwitchAxes': True,
                      'virtualizedForwardTargetFound': args.device != 'mac', 'evidence': str(evidence)}))


if __name__ == '__main__':
    main()
