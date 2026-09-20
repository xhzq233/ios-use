"""Live regression against the already-running Fixture's Scroll tab.

IOS_USE_HOME selects an isolated test session. --state is that App's
Documents/scroll-state.json; --output retains CLI responses and measured offsets.
No global configuration, App startup or device installation is performed here.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--cli', type=Path, required=True)
parser.add_argument('--state', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
if not os.environ.get('IOS_USE_HOME'):
    parser.error('Set IOS_USE_HOME to the isolated Fixture session')
args.output.mkdir(parents=True, exist_ok=True)
cli = str(args.cli.resolve())
sequence = 0
results = []
timings = []


def call(name, *command, success=True):
    global sequence
    sequence += 1
    started = time.monotonic()
    response = subprocess.run([cli, *command, '--json'], capture_output=True, text=True, timeout=75)
    timings.append(dict(case=name, command=list(command), seconds=time.monotonic() - started,
                        success=response.returncode == 0))
    prefix = args.output / f'{sequence:02}-{name}'
    prefix.with_suffix('.out').write_text(response.stdout)
    prefix.with_suffix('.err').write_text(response.stderr)
    value = json.loads(response.stdout or response.stderr)
    assert (response.returncode == 0) == success, (name, value)
    return value


def elements():
    return call('full-geometry', 'dom', '--nodiff')['data']['elements']


def find(nodes, identifier):
    return next(n for n in nodes if n.get('identifier') == identifier or n['label'] == identifier)


def state():
    return json.loads(args.state.read_text())


def reset():
    nodes = elements()
    call('reset', 'tap', find(nodes, 'fixture.scroll.reset')['label'])
    time.sleep(.3)
    before = state()
    assert all(abs(before[k]) < 1 for k in ['left', 'right', 'strip']), before
    return before


def point(node):
    x, y, w, h = node['frame']
    return f'{x + w / 2},{y + h / 2}'


def check(name, command, changed, success=True):
    before = state()
    response = call(name, *command, success=success)
    time.sleep(.4)
    after = state()
    for key in ['left', 'right', 'strip']:
        if key == changed:
            assert abs(after[key] - before[key]) > 5, (name, before, after)
        else:
            assert abs(after[key] - before[key]) < 1, (name, key, before, after)
    results.append(dict(case=name, before=before, after=after, ok=response['ok']))
    print(name, after, flush=True)


for name, anchor, changed in [
    ('left-cell', 'fixture.left.row.0', 'left'),
    ('left-container', 'fixture.scroll.left', 'left'),
    ('right-cell', 'fixture.right.row.0', 'right'),
]:
    reset()
    check(name, ['swipe', '--from', anchor, '--dir', 'forth', '--distance', '150'], changed)

reset()
anchor_point = point(find(elements(), 'fixture.left.row.2'))
check('left-point', ['swipe', '--from', anchor_point, '--dir', 'forth', '--distance', '120'], 'left')
before = state()
check('left-back', ['swipe', '--from', 'fixture.scroll.left', '--dir', 'back', '--distance', '70'], 'left')
assert state()['left'] < before['left']

for name, mode in [('nested-container', 'container'), ('nested-cell', 'cell'), ('nested-point', 'point')]:
    reset()
    nodes = elements()
    anchor = 'fixture.scroll.strip' if mode == 'container' else (
        find(nodes, 'fixture.strip.0')['label'] if mode == 'cell' else point(find(nodes, 'fixture.scroll.strip')))
    check(name, ['swipe', '--from', anchor, '--dir', 'forth', '--distance', '40'], 'strip')

reset()
check('nested-long-distance', ['swipe', '--from', 'fixture.scroll.strip', '--dir', 'forth', '--distance', '400'], 'strip')
reset()
check('left-long-distance', ['swipe', '--from', 'fixture.scroll.left', '--dir', 'forth', '--distance', '700'], 'left')

reset()
nodes = elements()
for name, anchor in [
    ('missing-anchor', 'fixture.missing.anchor'),
    ('ambiguous-anchor', 'fixture.left.row'),
    ('non-scroll-anchor', find(nodes, 'fixture.scroll.reset')['label']),
    ('non-scroll-point', point(find(nodes, 'fixture.scroll.reset'))),
]:
    check(name, ['swipe', '--from', anchor, '--dir', 'forth', '--distance', '100'], None, success=False)

check('different-container', ['swipe', '--from', 'fixture.left.row.0', '--find', 'fixture.right.row.3'], None, success=False)
check('recycled-target', ['swipe', '--from', 'fixture.scroll.left', '--find', 'fixture.left.row.15'], 'left')
call('tap-reached-target', 'tap', 'fixture.left.row.15')
time.sleep(.2)
assert state()['selected'] == 'left.15', state()
results.append(dict(case='tap-reached-target', state=state()))
check('find-back', ['swipe', '--from', 'fixture.scroll.left', '--find', 'fixture.left.row.0', '--dir', 'back'], 'left')
call('tap-found-back', 'tap', 'fixture.left.row.0')
time.sleep(.2)
assert state()['selected'] == 'left.0', state()
results.append(dict(case='tap-found-back', state=state()))
reset()
check('default-region', ['swipe', '--dir', 'forth', '--distance', '120'], 'right')
reset()
check('find-visible-no-movement', ['swipe', '--from', 'fixture.scroll.left', '--find', 'fixture.left.row.2'], None)
check('drag-offscreen-end', ['swipe', '--from', 'fixture.left.row.0', '--to', 'fixture.left.row.15'], None, success=False)
check('drag-offscreen-start', ['swipe', '--from', 'fixture.left.row.15', '--to', 'fixture.left.row.0'], None, success=False)
check('mixed-intents', ['swipe', '--from', 'fixture.left.row.0', '--to', 'fixture.left.row.2', '--find', 'fixture.left.row.15'], None, success=False)


def assert_gesture(start, end):
    delivered = json.loads(args.state.with_name('gesture-state.json').read_text())
    points = delivered['points']
    for actual, expected in [(points[0], start), (points[-1], end)]:
        assert all(abs(a - b) < 5 for a, b in zip(actual, expected)), (delivered, start, end)
    assert len(points) > 2, delivered
    return delivered


for start_mode, end_mode in [('label', 'label'), ('label', 'point'), ('point', 'label'), ('point', 'point')]:
    reset()
    nodes = elements()
    start = find(nodes, 'fixture.left.row.2')
    end = find(nodes, 'fixture.left.row.0')
    command = ['swipe', '--from', start['label'] if start_mode == 'label' else point(start),
               '--to', end['label'] if end_mode == 'label' else point(end)]
    check(f'drag-{start_mode}-{end_mode}', command, 'left')
    results[-1]['gesture'] = assert_gesture(list(map(float, point(start).split(','))),
                                          list(map(float, point(end).split(','))))

reset()
nodes = elements()
start = find(nodes, 'fixture.left.row.0')
end = find(nodes, 'fixture.right.row.0')
call('drag-across-panels', 'swipe', '--from', start['label'], '--to', end['label'])
time.sleep(.2)
results.append(dict(case='drag-across-panels', gesture=assert_gesture(
    list(map(float, point(start).split(','))), list(map(float, point(end).split(','))))))
reset()
(args.output / 'results.json').write_text(json.dumps(results, indent=2))
(args.output / 'timings.json').write_text(json.dumps(timings, indent=2))
print(f'{len(results)} live swipe checks passed', flush=True)
