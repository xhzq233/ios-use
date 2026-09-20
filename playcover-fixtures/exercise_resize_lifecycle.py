#!/usr/bin/env python3
"""Record real callbacks from an already running, isolated Mac Fixture session."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
assert os.environ.get("IOS_USE_HOME"), "Use an isolated IOS_USE_HOME"
root = Path(__file__).resolve().parents[1]
args.output.mkdir(parents=True, exist_ok=True)


def cli(*arguments, source=None):
    result = subprocess.run([str(root / "ios-use"), *arguments, "--json"],
                            input=source, text=True, capture_output=True, timeout=30)
    assert result.stdout, (arguments, result.returncode, result.stderr)
    value = json.loads(result.stdout)
    assert result.returncode == 0 and value["ok"], value.get("error", result.stderr)
    return value["data"]


def debug(body):
    source = "new Promise(resolve => ObjC.schedule(ObjC.mainQueue, () => {" + body + "}));"
    return json.loads(cli("debug", "-", source=source)["display"])


def scroll_to(label):
    # A resize can leave every label in the scroll view offscreen. Derive the
    # fallback gesture point from its current DOM frame, never an old anchor.
    dom = cli("dom", "--nodiff", "-d", "mac")
    frame = next(e["frame"] for e in dom["elements"] if e.get("identifier") == "fixture.uikit.scroll")
    point = f"{frame[0] + frame[2] / 2},{frame[1] + frame[3] / 2}"
    cli("swipe", "--to", label, "--from", point, "--dom", "-d", "mac")


toolbar = """
const windows = ObjC.classes.NSApplication.sharedApplication().windows();
let toolbar;
for (let i = 0; i < windows.count(); i++) {
    const candidate = windows.objectAtIndex_(i).toolbar();
    if (candidate && candidate.delegate().$className === 'IOSUsePlayDeviceChromeController') toolbar = candidate;
}
if (!toolbar) throw Error('Fixture toolbar unavailable');
function button(name) {
    const items = toolbar.items();
    for (let i = 0; i < items.count(); i++) {
        const item = items.objectAtIndex_(i);
        if (item.itemIdentifier().toString() === name) return item.view();
    }
    throw Error('Missing toolbar item: ' + name);
}
"""


def press(name, twice=False):
    observed = debug(toolbar + """
const control = button(%s);
control.performClick_(ptr(0));
const disabled = !control.isEnabled();
%s
resolve({disabled});
""" % (json.dumps(name), "control.performClick_(ptr(0));" if twice else ""))
    assert observed["disabled"], "Toolbar returned without marking the transition pending"
    deadline = time.monotonic() + 7
    while time.monotonic() < deadline:
        if debug(toolbar + "resolve(Boolean(button('rotate').isEnabled()));"):
            return
        time.sleep(0.02)
    raise AssertionError("Toolbar transition never completed")


def record(name, action, orientation_notifications):
    debug("ObjC.classes.FixtureLifecycleTrace.reset(); resolve(true);")
    action()
    # Capture immediately after CLI completion / toolbar re-enablement.
    trace = debug("const t=ObjC.classes.FixtureLifecycleTrace; t.finish(); resolve(JSON.parse(t.json().toString()));")
    (args.output / (name + ".json")).write_text(json.dumps(trace, indent=2) + "\n")
    start, end = trace[0], trace[-1]
    roots = [e for e in trace if e["controller"] == "FixtureTabBarController"]
    begins = [e for e in roots if e["event"] == "transition.begin"]
    completions = [e for e in roots if e["event"] == "transition.complete"]
    changed_size = start["window"] != end["window"]
    if changed_size:
        assert begins and len(begins) == len(completions), (name, "uncompleted native resize")
        for e in roots:
            if e["index"] < begins[0]["index"] and e["event"] in ("layout.will", "layout.did", "safeArea.changed", "traits.changed"):
                assert e["controllerTraits"] == start["controllerTraits"] and e["safeArea"] == start["safeArea"], (name, "new state laid out before native resize", e)
        assert completions[-1]["window"] == end["window"], (name, "wrong completion geometry")
        assert completions[-1]["controllerTraits"] == end["controllerTraits"], (name, "late traits")
    assert all(e["retainedTraits"] == start["retainedTraits"] for e in trace), (name, "previous trait collection changed retroactively")
    assert not end["coordinator"], (name, "returned during native transition")
    notifications = [e for e in trace if e["event"] == "orientation.notification"]
    assert len(notifications) == orientation_notifications, (name, "unexpected orientation notification", notifications)
    for e in notifications:
        assert e["window"] == end["window"], (name, "notified before geometry")
    assert sum(e["event"] == "transition.begin" for e in trace) == sum(e["event"] == "transition.complete" for e in trace), (name, "child/presentation transition incomplete")
    cli("dom", "-d", "mac")
    print(f"{name}: {start['window']} -> {end['window']}, {len(begins)} native transitions, {len(notifications)} orientation notifications", flush=True)
    return end


assert debug("resolve(Boolean(ObjC.classes.FixtureLifecycleTrace));"), "Start the current public Fixture first"
cli("config", "--mac", "--device-model", "iphone-duo", "--window-mode", "fixed")
cli("rotate", "--to", "portrait", "-d", "mac")
for orientation in ("landscape-left", "portrait-upside-down", "landscape-right", "portrait"):
    record("rotate-" + orientation, lambda: cli("rotate", "--to", orientation, "-d", "mac"), 1)
record("same-orientation", lambda: cli("rotate", "--to", "portrait", "-d", "mac"), 0)
record("fold", lambda: press("expand"), 0)
record("unfold", lambda: press("expand"), 0)
record("rapid-fold", lambda: press("expand", twice=True), 0)
record("toolbar-rotate", lambda: press("rotate", twice=True), 1)
for preset in ("iphone-se", "iphone-13", "ipad-pro-11", "iphone-duo"):
    record("model-" + preset, lambda: cli("config", "--mac", "--device-model", preset), 0)
record("chrome-off", lambda: cli("config", "--mac", "--device-chrome", "off"), 0)
record("chrome-on", lambda: cli("config", "--mac", "--device-chrome", "on"), 0)
scroll_to("Scroll Target End")
record("scrolled-fold", lambda: press("expand"), 0)
record("scrolled-unfold", lambda: press("expand"), 0)
record("scrolled-se", lambda: cli("config", "--mac", "--device-model", "iphone-se"), 0)
record("resizable", lambda: cli("config", "--mac", "--window-mode", "resizable"), 0)

cli("config", "--mac", "--device-model", "iphone-duo", "--window-mode", "fixed")
cli("rotate", "--to", "portrait", "-d", "mac")
scroll_to("Fixture Input")
cli("input", "--tap", "Fixture Input", "--content", "resize", "--dom", "-d", "mac")
record("input-fold", lambda: press("expand"), 0)
record("input-rotate", lambda: cli("rotate", "--to", "landscape-left", "-d", "mac"), 1)
cli("input", "--content", "", "--enter", "--dom", "-d", "mac")
debug("ObjC.classes.FixtureLifecycleTrace.presentSheet(); resolve(true);")
deadline = time.monotonic() + 5
while time.monotonic() < deadline:
    settled = debug("const r=ObjC.classes.UIApplication.sharedApplication().delegate().window().rootViewController(); resolve(Boolean(r.presentedViewController()) && !r.transitionCoordinator());")
    if settled:
        break
    time.sleep(0.02)
else:
    raise AssertionError("Fixture sheet presentation did not finish")
record("sheet-unfold", lambda: press("expand"), 0)
record("sheet-se", lambda: cli("config", "--mac", "--device-model", "iphone-se"), 0)
debug("ObjC.classes.FixtureLifecycleTrace.dismissSheet(); resolve(true);")

print("Callback traces saved. App and isolated configuration remain available for inspection.")
