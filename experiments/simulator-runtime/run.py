#!/usr/bin/env python3
"""Build and run the standalone runtime GPU experiment. Does not invoke simctl."""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import tempfile

SOURCE = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--runtime-root", type=Path, required=True,
                    help="Installed .simruntime/Contents/Resources/RuntimeRoot")
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
sim_flags = ["-target", "arm64-apple-ios17.0-simulator", "-isysroot", sdk]
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

failed = False
for mode in ("source", "metallib", "uikit"):
    home = output / f"home-{mode}"
    home.mkdir()
    client = output / ("uikit-probe" if mode == "uikit" else "probe")
    command = [str(output / "broker"), str(runtime), str(client),
               str(output / "endpoints.dylib"), str(home)]
    if mode == "metallib":
        command.append(str(output / "probe.metallib"))
    log_path = output / f"{mode}.log"
    with log_path.open("w") as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
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
    failed |= status != 0
raise SystemExit(1 if failed else 0)
