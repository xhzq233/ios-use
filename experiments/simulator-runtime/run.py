#!/usr/bin/env python3
"""Build and run the standalone runtime service experiments. Does not invoke simctl."""
import argparse
import os
import plistlib
import shutil
from pathlib import Path
import signal
import subprocess
import tempfile

SOURCE = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--runtime-root", type=Path, required=True,
                    help="Installed .simruntime/Contents/Resources/RuntimeRoot")
CASES = {
    "clear": ["metal"],
    "surface": ["metal", "iosurface"],
    "compute-source": ["metal", "compiler"],
    "compute-metallib": ["metal", "compiler"],
    "source": ["metal", "compiler", "iosurface"],
    "metallib": ["metal", "compiler", "iosurface"],
    "uikit": [],
    "application": [],
}
parser.add_argument("--cases", nargs="+", choices=CASES, default=[case for case in CASES if case != "application"])
parser.add_argument("--services", nargs="*", choices=["metal", "compiler", "iosurface"],
                    help="Override each case's service list; an empty list starts none")
parser.add_argument("--audit", action="store_true", help="Also run service deletion experiments (failures are observations)")
parser.add_argument("--app-adapters", nargs="*", choices=["display", "scene"], default=["display", "scene"],
                    help="In-process adapters injected only into the application case")
args = parser.parse_args()
runtime = args.runtime_root.resolve()
compiler = runtime / "System/Library/Frameworks/Metal.framework/XPCServices/MTLCompilerService.xpc/MTLCompilerService"
if not compiler.is_file():
    parser.error(f"Runtime compiler does not exist: {compiler}")
artifact_root = Path(os.environ.get("IOS_USE_HOME", SOURCE.parents[1] / ".ios-use")) / "artifacts" / "runtime-probe"
artifact_root.mkdir(parents=True, exist_ok=True)
output = Path(tempfile.mkdtemp(prefix="run-", dir=artifact_root)).resolve()
print(f"Artifacts: {output}", flush=True)

def build(*command):
    subprocess.run(command, check=True)

sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
sim_flags = ["-target", "arm64-apple-ios26.0-simulator", "-isysroot", sdk]
build("xcrun", "clang", "-arch", "arm64", "-fobjc-arc", "-fblocks", str(SOURCE / "HostBroker.m"),
      "-framework", "Foundation", "-framework", "Metal", "-o", str(output / "broker"))
build("xcrun", "clang", *sim_flags, "-fblocks", "-dynamiclib", str(SOURCE / "ServiceEndpoints.c"),
      "-o", str(output / "endpoints.dylib"))
build("xcrun", "clang", *sim_flags, "-fobjc-arc", str(SOURCE / "GPUProbe.m"),
      "-framework", "Foundation", "-framework", "UIKit", "-framework", "Metal", "-framework", "IOSurface", "-o", str(output / "probe"))
build("xcrun", "clang", *sim_flags, "-fobjc-arc", str(SOURCE / "UIKitProbe.m"),
      "-framework", "Foundation", "-framework", "UIKit", "-framework", "QuartzCore", "-framework", "CoreGraphics", "-o", str(output / "uikit-probe"))
build("xcrun", "-sdk", "iphonesimulator", "metal", "-std=metal3.0", "-target", "air64-apple-ios17.0-simulator",
      "-c", str(SOURCE / "probe.metal"), "-o", str(output / "probe.air"))
build("xcrun", "-sdk", "iphonesimulator", "metallib", str(output / "probe.air"), "-o", str(output / "probe.metallib"))

app = output / "RuntimeProbe.app"
if "application" in args.cases:
    app.mkdir()
    shutil.copy2(output / "uikit-probe", app / "RuntimeProbe")
    with (app / "Info.plist").open("wb") as info:
        plistlib.dump({"CFBundleExecutable": "RuntimeProbe", "CFBundleIdentifier": "io.iosuse.runtime-probe",
                       "CFBundleName": "RuntimeProbe", "CFBundlePackageType": "APPL",
                       "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
                       "MinimumOSVersion": "26.0", "UIDeviceFamily": [1]}, info)
    build("xcrun", "clang", *sim_flags, "-fobjc-arc", "-fblocks", "-dynamiclib",
          str(SOURCE / "SceneBootstrap.m"), str(SOURCE / "LocalSceneHost.m"),
          "-framework", "Foundation", "-framework", "UIKit", "-o", str(output / "scene.dylib"))
    build("xcrun", "clang", *sim_flags, "-fobjc-arc", "-fblocks", "-dynamiclib",
          str(SOURCE / "LocalDisplay.m"), "-Wl,-F," + str(runtime / "System/Library/PrivateFrameworks"),
          "-framework", "Foundation", "-framework", "UIKit", "-framework", "GraphicsServices",
          "-framework", "BackBoardServices", "-o", str(output / "display.dylib"))

failed = False
runs = [(mode, args.services if args.services is not None else CASES[mode], args.app_adapters, False)
        for mode in args.cases]
if args.audit:
    for mode, services, adapters, _ in list(runs):
        for service in services:
            runs.append((mode, [item for item in services if item != service], adapters, True))
        if mode == "application":
            for adapter in adapters:
                runs.append((mode, services, [item for item in adapters if item != adapter], True))
results = []
for number, (mode, services, adapters, deletion) in enumerate(runs):
    home = output / f"home-{number:02d}-{mode}"
    home.mkdir()
    client = output / ("uikit-probe" if mode == "uikit" else "probe")
    environment = os.environ.copy()
    environment.pop("IOS_USE_RUNTIME_CLIENT_LIBRARIES", None)
    if mode == "application":
        client = app / "RuntimeProbe"
        environment["IOS_USE_RUNTIME_CLIENT_LIBRARIES"] = ":".join(str(output / f"{name}.dylib") for name in adapters)
    command = [str(output / "broker"), str(runtime), str(client),
               str(output / "endpoints.dylib"), str(home), ",".join(services)]
    if mode != "uikit":
        command.append(mode)
    if mode.endswith("metallib"):
        command.append(str(output / "probe.metallib"))
    log_path = output / f"{number:02d}-{mode}.log"
    with log_path.open("w") as log:
        process = subprocess.Popen(command, env=environment, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            status = process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            status = 124
        finally:
            # Also clean up the runtime compiler if the broker crashed or timed out.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
    print(log_path.read_text(), end="")
    print(f"{mode}: exit={status}", flush=True)
    results.append((mode, services, adapters if mode == "application" else [], status, deletion))
    failed |= status != 0 and not deletion
print("\nCase                 Services                      App adapters    Exit   Experiment")
for mode, services, adapters, status, deletion in results:
    print(f"{mode:20} {','.join(services) or '(none)':29} {','.join(adapters) or '(none)':15} {status:4}   {'observation' if deletion else 'selected'}")
raise SystemExit(1 if failed else 0)
