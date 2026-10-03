#!/usr/bin/env python3
"""Exercise real touch delivery against late/moving UIKit geometry on Simulator."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import statistics
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--udid", required=True, help="Booted test Simulator with a running Driver")
    parser.add_argument("--home", required=True, help="Isolated IOS_USE_HOME containing that Driver session")
    parser.add_argument("--fixture-app", required=True, help="Simulator IOSUsePlayFixture.app")
    parser.add_argument("--iterations", type=int, default=6)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    env = dict(os.environ, IOS_USE_HOME=str(Path(args.home).resolve()))
    devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "booted", "--json"]))
    assert any(device["udid"] == args.udid for group in devices["devices"].values() for device in group), "Use a booted Simulator"
    fixture = Path(args.fixture_app).resolve()
    with (fixture / "Info.plist").open("rb") as info:
        bundle = plistlib.load(info)["CFBundleIdentifier"]

    def cli(*command, check=True):
        result = subprocess.run([str(root / "ios-use"), "-d", args.udid, *command, "--json"],
                                env=env, capture_output=True, text=True, timeout=30)
        reply = json.loads(result.stdout or result.stderr)
        if check:
            assert result.returncode == 0 and reply["ok"], f"{command[0]} failed: {reply.get('error', {}).get('code')}"
        return result.returncode, reply

    subprocess.run(["xcrun", "simctl", "install", args.udid, str(Path(args.fixture_app).resolve())], check=True)
    container = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", args.udid, bundle, "data"], text=True).strip())

    def state():
        return json.loads((container / "Documents" / "touch-state.json").read_text())

    def cold_open(duration):
        launch_env = dict(env, SIMCTL_CHILD_IOS_USE_TOUCH_DURATION=str(duration))
        subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process", args.udid, bundle],
                       env=launch_env, check=True, capture_output=True)
        cli("activateApp", bundle)
        cli("dom", "--nodiff")

    latencies = []
    for index in range(args.iterations):
        cold_open(0.8)
        options = ["--offset-ratio", "0.8,0.5"] if index % 2 else []
        cli("tap", "fixture.touch.target", *options)
        observed = state()
        assert observed["targetTaps"] == 1 and observed["otherTaps"] == 0, f"Restored target was missed: {observed}"
        assert not observed["moving"], "Touch was delivered before geometry settled"

        cold_open(0)
        started = time.monotonic()
        cli("tap", "fixture.touch.target")
        latencies.append(time.monotonic() - started)
        observed = state()
        assert observed["targetTaps"] == 1 and observed["otherTaps"] == 0

    cold_open(4)
    code, reply = cli("tap", "fixture.touch.target", check=False)
    assert code != 0 and not reply["ok"] and reply["error"]["retryable"], "Continuous motion must report a retryable failure"
    observed = state()
    assert observed["targetTaps"] == 0 and observed["otherTaps"] == 0, "Failure dispatched a touch"

    cold_open(0.8)
    cli("longpress", "fixture.touch.target", "--duration", "600ms")
    observed = state()
    assert observed["presses"] == 1 and observed["otherTaps"] == 0
    print(json.dumps({"restoredTargetPasses": args.iterations, "stableTargetPasses": args.iterations,
                      "continuousMotionRejectedWithoutTouch": True, "longPressPasses": 1,
                      "stableTapMedianSeconds": round(statistics.median(latencies), 3)}))


if __name__ == "__main__":
    main()
