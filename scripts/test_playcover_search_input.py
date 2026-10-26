#!/usr/bin/env python3
"""Check exact input through a running opt-in public search fixture on Mac."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--home', required=True, help='Isolated IOS_USE_HOME with the fixture running')
    parser.add_argument('--state-dir', required=True, help="Fixture's Documents directory")
    parser.add_argument('--target', default='搜索', help='Observed search label; use Search for field mode')
    args = parser.parse_args()
    home = Path(args.home).resolve()
    state_dir = Path(args.state_dir)
    cli = Path(__file__).resolve().parent.parent / 'ios-use'
    env = dict(os.environ, IOS_USE_HOME=str(home))
    evidence = home / 'artifacts' / ('search-input-' + str(time.time_ns()))
    evidence.mkdir(parents=True)
    commands = []

    def state():
        return json.loads((state_dir / 'search-state.json').read_text())

    def check_value(expected):
        actual = state()
        (evidence / 'app-state.json').write_text(json.dumps(actual, indent=2))
        assert actual['latest']['text'] == expected, actual

    def run(*command, expected_error=None):
        result = subprocess.run([str(cli), *command, '-d', 'mac', '--json'], env=env,
                                text=True, capture_output=True, timeout=60)
        reply = json.loads(result.stdout or result.stderr)
        commands.append({'command': command, 'reply': reply})
        (evidence / 'commands.json').write_text(json.dumps(commands, indent=2))
        if expected_error:
            assert not reply['ok'] and reply['error']['code'] == expected_error, reply
        else:
            assert result.returncode == 0 and reply['ok'], reply
        return reply

    check_value('')  # Start a fresh fixture process before each run.
    run('input', '--tap', args.target, '--content', 'EC')
    check_value('EC')
    assert state()['latest']['inputIsFirstResponder'], state()
    run('input', '--content', ' 搜索🧪')
    check_value('EC 搜索🧪')
    run('input', '--delete', '2', '--content', '好')
    check_value('EC 搜好')
    run('tap', 'fixture.search.dismiss')
    dismissed_value = state()['latest']['text']  # UISearchController may clear on dismissal.
    assert not state()['latest']['inputIsFirstResponder'], state()
    run('input', '--content', 'BAD', expected_error='input_not_ready')
    check_value(dismissed_value)
    run('input', '--tap', args.target, '--content', 'Z')
    check_value(dismissed_value + 'Z')
    run('dom', '--nodiff')
    assert not (state_dir / 'search-exception.json').exists(), 'Fixture recorded an uncaught exception'
    print(json.dumps({'ok': True, 'mode': state()['mode'], 'evidence': str(evidence)}))


if __name__ == '__main__':
    main()
