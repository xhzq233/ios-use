#!/usr/bin/env python3
"""Build and run the standalone runtime service experiments. Does not invoke simctl."""
import argparse
import ctypes
import math
import os
import plistlib
import select
import shutil
import sqlite3
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit

SOURCE = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--runtime-root", type=Path, required=True,
                    help="Installed .simruntime/Contents/Resources/RuntimeRoot")
CASES = {
    "clear": ["metal"],
    "surface": ["metal", "iosurface"],
    "compute-source": ["metal", "compiler"],
    "linear-buffer": ["metal", "compiler"],
    "compute-metallib": ["metal", "compiler"],
    "retarget-metallib": ["metal", "compiler"],
    "source": ["metal", "compiler", "iosurface"],
    "metallib": ["metal", "compiler", "iosurface"],
    "uikit": [],
    "trust": ["trust"],
    "keychain": ["keychain"],
    "network": ["trust"],
    "notify": ["notify"],
    "notify-isolation": ["notify"],
    "photo-status": ["tcc"],
    "photo-prompt": ["tcc"],
    "photo-roundtrip": ["tcc", "photos", "notify", "launchservices"],
    "gles-surface": ["iosurface"],
    "angle": ["metal", "compiler", "iosurface"],
    "gles-angle": ["metal", "compiler", "iosurface"],
    "gles-window": ["metal", "compiler", "iosurface"],
    "application": ["metal", "compiler", "iosurface"],
    "presentation": ["metal", "compiler", "iosurface"],
    "lifecycle": ["metal", "compiler", "iosurface"],
    "webkit": ["metal", "compiler", "iosurface"],
    "text-input": ["metal", "compiler", "iosurface"],
}
parser.add_argument("--cases", nargs="+", choices=CASES, default=[case for case in CASES if case not in ("application", "presentation", "lifecycle", "webkit", "network", "photo-prompt", "gles-surface", "gles-window", "text-input")])
parser.add_argument("--services", nargs="*", choices=["metal", "compiler", "iosurface", "trust", "tcc", "photos", "notify", "launchservices", "keychain"],
                    help="Override each case's service list; an empty list starts none")
parser.add_argument("--notify-backend", choices=["runtime", "host"], default="runtime",
                    help="Use isolated runtime notifyd (default), or host notifyd with per-run notification names")
parser.add_argument("--audit", action="store_true", help="Also run service deletion experiments (failures are observations)")
parser.add_argument("--app-adapters", nargs="*", choices=["display", "scene", "compositor", "input", "angle", "metal-buffer"],
                    help="Application adapters (default: display scene compositor; input is optional)")
target = parser.add_mutually_exclusive_group()
target.add_argument("--app", type=Path, help="Run an already Simulator-compatible .app; capture startup unless --present is set")
target.add_argument("--network-url", help="Select network case and issue an HTTPS HEAD request with normal certificate validation")
parser.add_argument("--photo-fixture", action="store_true", help="With --app, seed a temporary synthetic photo library; use --present for the app's consent dialog")
parser.add_argument("--present", action="store_true", help="Present the supplied app or photo-prompt consent dialog in a native window")
parser.add_argument("--tap", nargs=2, type=float, metavar=("X", "Y"), help="Tap after 8 seconds (native mouse events with --present, UIKit otherwise)")
parser.add_argument("--duration", type=float, default=60, help="Lifecycle workload duration in seconds (minimum 10)")
parser.add_argument("--webkit-launcher", choices=["system", "standalone"], default="system",
                    help="Diagnostic only: current paths are blocked by launch domains or endpoint authorization")
args = parser.parse_args()
if not math.isfinite(args.duration) or args.duration < 10:
    parser.error("--duration must be finite and at least 10 seconds")
external_app = args.app.resolve() if args.app else None
if args.photo_fixture and not external_app:
    parser.error("--photo-fixture requires --app")
if args.tap and (not external_app or not all(math.isfinite(x) for x in args.tap)):
    parser.error("--tap requires --app and finite coordinates")
if args.tap and "input" not in (args.app_adapters or []):
    parser.error("--tap requires --app-adapters display scene compositor input")
if args.network_url:
    url = urlsplit(args.network_url)
    if url.scheme != "https" or not url.hostname:
        parser.error("--network-url requires an HTTPS URL")
    args.cases = ["network"]
elif "network" in args.cases:
    parser.error("network case requires --network-url")
if external_app:
    CASES["application"].extend(["trust", "keychain"])
    args.cases = ["application"]
    with (external_app / "Info.plist").open("rb") as info:
        app_info = plistlib.load(info)
        app_executable = external_app / app_info["CFBundleExecutable"]
    if args.photo_fixture:
        CASES["application"].extend(CASES["photo-roundtrip"])
    if not app_executable.is_file():
        parser.error(f"App executable does not exist: {app_executable}")
if args.present and not external_app and args.cases != ["photo-prompt"]:
    parser.error("--present requires --app or --cases photo-prompt")
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
      str(SOURCE / "HostWindow.m"), str(SOURCE / "HostUserNotifications.m"),
      "-framework", "Foundation", "-framework", "CoreFoundation", "-framework", "Metal",
      "-framework", "AppKit", "-framework", "QuartzCore", "-framework", "IOSurface", "-o", str(output / "broker"))
build("xcrun", "clang", *sim_flags, "-fblocks", "-dynamiclib", str(SOURCE / "ServiceEndpoints.c"),
      str(SOURCE / "NotifyTransport.c"),
      "-framework", "Security", "-framework", "CoreFoundation", "-o", str(output / "endpoints.dylib"))
build("xcrun", "clang", *sim_flags, "-fblocks", "-dynamiclib", str(SOURCE / "NotifyTransport.c"),
      "-o", str(output / "notify-transport.dylib"))
build("xcrun", "clang", *sim_flags, "-fobjc-arc", "-dynamiclib", str(SOURCE / "TCCContext.m"),
      "-framework", "Foundation", "-o", str(output / "tcc-context.dylib"))
build("xcrun", "clang", *sim_flags, "-fobjc-arc", "-dynamiclib", str(SOURCE / "LaunchServicesContext.m"),
      "-framework", "Foundation", "-o", str(output / "launchservices-context.dylib"))
if not external_app:
    build("xcrun", "clang", *sim_flags, "-fobjc-arc", str(SOURCE / "GPUProbe.m"),
          "-framework", "Foundation", "-framework", "UIKit", "-framework", "Metal", "-framework", "IOSurface", "-o", str(output / "probe"))
if "linear-buffer" in args.cases or "metal-buffer" in (args.app_adapters or []):
    build("xcrun", "clang", *sim_flags, "-fobjc-arc", "-dynamiclib", str(SOURCE / "MetalBufferContext.m"),
          "-framework", "Foundation", "-framework", "Metal", "-o", str(output / "metal-buffer.dylib"))
if "linear-buffer" in args.cases:
    build("xcrun", "clang", *sim_flags, "-fobjc-arc", str(SOURCE / "BufferTextureProbe.m"),
          "-framework", "Foundation", "-framework", "Metal", "-o", str(output / "linear-buffer-probe"))
if not external_app:
    build("xcrun", "clang", *sim_flags, "-fobjc-arc", str(SOURCE / "UIKitProbe.m"),
          "-framework", "Foundation", "-framework", "UIKit", "-framework", "QuartzCore", "-framework", "CoreGraphics",
          "-framework", "IOSurface", "-o", str(output / "uikit-probe"))
if any(case.endswith("metallib") for case in args.cases):
    build("xcrun", "-sdk", "iphonesimulator", "metal", "-std=metal3.0", "-target", "air64-apple-ios17.0-simulator",
          "-c", str(SOURCE / "probe.metal"), "-o", str(output / "probe.air"))
    build("xcrun", "-sdk", "iphonesimulator", "metallib", str(output / "probe.air"), "-o", str(output / "probe.metallib"))
if any(case in args.cases for case in ("gles-surface", "gles-angle")):
    build("xcrun", "clang", *sim_flags, "-fobjc-arc", str(SOURCE / "GLESProbe.m"),
          "-framework", "Foundation", "-framework", "CoreVideo", "-framework", "OpenGLES",
          "-framework", "GLKit", "-framework", "CoreGraphics", "-o", str(output / "gles-surface-probe"))
if any(case in args.cases for case in ("gles-angle", "gles-window")) or ("application" in args.cases and "angle" in (args.app_adapters or [])):
    build(sys.executable, str(SOURCE / "generate_gles_forwarders.py"), sdk, str(output / "GLESForwarders.inc"))
    build("xcrun", "clang", *sim_flags, "-fno-objc-arc", "-fblocks", "-dynamiclib",
          "-Wno-deprecated-declarations", "-I", str(output), str(SOURCE / "ANGLEAdapter.m"),
          "-framework", "Foundation", "-framework", "CoreVideo", "-framework", "OpenGLES",
          "-framework", "QuartzCore", "-o", str(output / "angle.dylib"))
if "angle" in args.cases:
    build("xcrun", "clang", *sim_flags, "-fobjc-arc", str(SOURCE / "ANGLEProbe.m"),
          "-framework", "Foundation", "-framework", "CoreVideo", "-o", str(output / "angle-probe"))
if any(case in args.cases for case in ("notify", "notify-isolation")):
    build("xcrun", "clang", *sim_flags, "-fblocks", str(SOURCE / "NotifyProbe.c"), "-o", str(output / "notify-probe"))
if "notify-isolation" in args.cases:
    build("xcrun", "clang", "-arch", "arm64", "-fblocks", str(SOURCE / "NotifyProbe.c"), "-o", str(output / "native-notify-probe"))
if args.photo_fixture or any(case.startswith("photo-") for case in args.cases):
    photo_app = output / "PhotoProbe.app"
    photo_app.mkdir()
    with (photo_app / "Info.plist").open("wb") as info:
        plistlib.dump({"CFBundleExecutable": "PhotoProbe", "CFBundleIdentifier": "io.iosuse.runtime-photo-probe",
                      "CFBundleName": "Runtime Photo Probe", "CFBundleDisplayName": "Runtime Photo Probe",
                      "CFBundlePackageType": "APPL", "MinimumOSVersion": "26.0",
                      "NSPhotoLibraryUsageDescription": "Use the isolated experimental photo library."}, info)
    build("xcrun", "clang", *sim_flags, "-fobjc-arc", "-fblocks", str(SOURCE / "PhotoProbe.m"),
          "-framework", "Foundation", "-framework", "Photos", "-framework", "CoreGraphics",
          "-framework", "ImageIO", "-framework", "UniformTypeIdentifiers", "-o", str(photo_app / "PhotoProbe"))
    build("codesign", "-f", "-s", "-", "--identifier", "io.iosuse.runtime-photo-probe", str(photo_app))

if "keychain" in args.cases:
    keychain_app = output / "KeychainProbe.app"
    other_keychain_app = output / "OtherKeychainProbe.app"
    for bundle, identifier in ((keychain_app, "io.iosuse.runtime-keychain-probe"),
                               (other_keychain_app, "io.iosuse.other-keychain-probe")):
        bundle.mkdir()
        with (bundle / "Info.plist").open("wb") as info:
            plistlib.dump({"CFBundleExecutable": "KeychainProbe", "CFBundleIdentifier": identifier,
                          "CFBundleName": "Runtime Keychain Probe", "CFBundlePackageType": "APPL", "MinimumOSVersion": "26.0"}, info)
        entitlements = output / f"{bundle.stem}-entitlements.plist"
        with entitlements.open("wb") as info:
            plistlib.dump({"application-identifier": f"IOSUSETEST.{identifier}",
                          "keychain-access-groups": [f"IOSUSETEST.{identifier}"]}, info)
        # Match Xcode's Simulator entitlement section, not host code-signing rights.
        build("xcrun", "clang", *sim_flags, "-fobjc-arc", str(SOURCE / "KeychainProbe.m"),
              "-Wl,-sectcreate,__TEXT,__entitlements," + str(entitlements),
              "-framework", "Foundation", "-framework", "Security", "-o", str(bundle / "KeychainProbe"))
        build("codesign", "-f", "-s", "-", "--identifier", identifier, str(bundle))

if "retarget-metallib" in args.cases:
    build("xcrun", "-sdk", "iphoneos", "metal", "-std=metal3.0", "-target", "air64-apple-ios17.0",
          "-c", str(SOURCE / "probe.metal"), "-o", str(output / "device.air"))
    build("xcrun", "-sdk", "iphoneos", "metallib", str(output / "device.air"), "-o", str(output / "device.metallib"))
    build(sys.executable, str(SOURCE / "retarget_metallib.py"),
          str(output / "device.metallib"), str(output / "retargeted.metallib"))

for case in ("trust", "network"):
    if case in args.cases:
        build("xcrun", "clang", *sim_flags, "-fobjc-arc", "-fblocks",
              str(SOURCE / ("TrustProbe.m" if case == "trust" else "NetworkProbe.m")),
              "-framework", "Foundation", "-framework", "Security", "-o", str(output / f"{case}-probe"))
if "trust" in args.cases:
    # Disposable CA/leaf fixtures, never installed in a system or user trust store.
    certificates = output / "certificates"
    certificates.mkdir(mode=0o700)
    (certificates / "root.cnf").write_text("""[req]
distinguished_name=dn
x509_extensions=ca
[dn]
[ca]
basicConstraints=critical,CA:TRUE
keyUsage=critical,keyCertSign,cRLSign
""")
    (certificates / "leaf.cnf").write_text("""basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:runtime-probe.invalid
""")
    def openssl(*arguments):
        subprocess.run(["/usr/bin/openssl", *arguments], cwd=certificates, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "root.key",
            "-out", "root.pem", "-days", "2", "-subj", "/CN=ios-use ephemeral root", "-config", "root.cnf")
    openssl("req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", "leaf.key",
            "-out", "leaf.csr", "-subj", "/CN=runtime-probe.invalid")
    openssl("x509", "-req", "-in", "leaf.csr", "-CA", "root.pem", "-CAkey", "root.key",
            "-set_serial", "2", "-days", "1", "-extfile", "leaf.cnf", "-out", "leaf.pem")
    for name in ("root", "leaf"):
        openssl("x509", "-in", f"{name}.pem", "-outform", "DER", "-out", f"{name}.der")
    for item in certificates.iterdir():
        if item.suffix != ".der":
            item.unlink()

app = output / "RuntimeProbe.app"
if "application" in args.cases and not external_app:
    app.mkdir()
    shutil.copy2(output / "uikit-probe", app / "RuntimeProbe")
    with (app / "Info.plist").open("wb") as info:
        plistlib.dump({"CFBundleExecutable": "RuntimeProbe", "CFBundleIdentifier": "io.iosuse.runtime-probe",
                       "CFBundleName": "RuntimeProbe", "CFBundlePackageType": "APPL",
                       "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
                       "MinimumOSVersion": "26.0", "UIDeviceFamily": [1]}, info)
if any(case in args.cases for case in ("application", "presentation", "lifecycle", "webkit", "gles-window", "text-input")):
    build("xcrun", "clang", *sim_flags, "-fobjc-arc", "-fblocks", "-dynamiclib",
          str(SOURCE / "SceneBootstrap.m"), str(SOURCE / "LocalSceneHost.m"), str(SOURCE / "LocalInput.m"),
          "-framework", "Foundation", "-framework", "UIKit", "-o", str(output / "scene.dylib"))
    build("xcrun", "clang", *sim_flags, "-fobjc-arc", "-fblocks", "-dynamiclib",
          str(SOURCE / "LocalDisplay.m"), "-Wl,-F," + str(runtime / "System/Library/PrivateFrameworks"),
          "-framework", "Foundation", "-framework", "UIKit", "-framework", "GraphicsServices",
          "-framework", "BackBoardServices", "-o", str(output / "display.dylib"))
    build("xcrun", "clang", *sim_flags, "-fobjc-arc", "-fblocks", "-dynamiclib",
          str(SOURCE / "LocalCompositor.m"), str(SOURCE / "FrameStream.m"),
          *([str(SOURCE / "AppCapture.m")] if external_app and not args.present else []),
          "-framework", "Foundation", "-framework", "UIKit", "-framework", "QuartzCore",
          "-framework", "CoreGraphics", "-framework", "IOSurface", "-o", str(output / "compositor.dylib"))
    if "input" in (args.app_adapters or []) or (not external_app and any(case in args.cases for case in ("application", "text-input"))):
        build("xcrun", "clang", *sim_flags, "-fobjc-arc", "-fblocks", "-dynamiclib",
              str(SOURCE / "TouchInput.m"), str(SOURCE / "KeyboardContext.m"),
              str(runtime / "usr/lib/libMobileGestalt.dylib"),
              "-framework", "Foundation", "-framework", "UIKit", "-o", str(output / "input.dylib"))

for mode, name in (("presentation", "Presentation"), ("lifecycle", "Lifecycle")):
    if mode not in args.cases: continue
    bundle = output / f"{name}Probe.app"
    bundle.mkdir()
    with (bundle / "Info.plist").open("wb") as info:
        plistlib.dump({"CFBundleExecutable": f"{name}Probe", "CFBundleIdentifier": f"io.iosuse.{mode}-probe",
                      "CFBundleName": f"Runtime {name} Probe", "CFBundlePackageType": "APPL", "MinimumOSVersion": "26.0"}, info)
    build("xcrun", "clang", *sim_flags, "-fobjc-arc", "-fblocks", str(SOURCE / f"{name}Probe.m"),
          "-framework", "Foundation", "-framework", "UIKit", "-framework", "QuartzCore", "-framework", "IOSurface", "-o", str(bundle / f"{name}Probe"))
    build("xcrun", "clang", "-arch", "arm64", "-fobjc-arc", "-fblocks", str(SOURCE / "HostBroker.m"),
          str(SOURCE / "HostWindow.m"), str(SOURCE / "HostUserNotifications.m"), str(SOURCE / f"{name}ProbeHost.m"),
          "-framework", "Foundation", "-framework", "CoreFoundation", "-framework", "Metal",
          "-framework", "AppKit", "-framework", "QuartzCore", "-framework", "IOSurface", "-o", str(output / f"{mode}-broker"))

if "webkit" in args.cases:
    web_app = output / "WebKitProbe.app"
    web_app.mkdir()
    with (web_app / "Info.plist").open("wb") as info:
        plistlib.dump({"CFBundleExecutable": "WebKitProbe", "CFBundleIdentifier": "io.iosuse.webkit-probe",
                      "CFBundlePackageType": "APPL"}, info)
    build("xcrun", "clang", *sim_flags, "-fobjc-arc", "-fblocks", str(SOURCE / "WebKitProbe.m"),
          "-framework", "Foundation", "-framework", "UIKit", "-framework", "WebKit", "-framework", "CoreGraphics", "-o", str(web_app / "WebKitProbe"))
    if args.webkit_launcher == "standalone":
        build("xcrun", "clang", *sim_flags, "-fobjc-arc", "-fblocks", str(SOURCE / "WebKitChildProbe.m"),
              "-framework", "Foundation", "-framework", "WebKit", "-o", str(output / "WebKitChild"))
        build("xcrun", "clang", *sim_flags, "-fobjc-arc", "-fblocks", "-dynamiclib", str(SOURCE / "WebKitLauncherProbe.m"),
              "-framework", "Foundation", "-framework", "BrowserEngineKit", "-o", str(output / "webkit-launcher.dylib"))

if "text-input" in args.cases:
    keyboard_app = output / "KeyboardProbe.app"
    keyboard_app.mkdir()
    with (keyboard_app / "Info.plist").open("wb") as info:
        plistlib.dump({"CFBundleExecutable": "KeyboardProbe", "CFBundleIdentifier": "io.iosuse.keyboard-probe",
                      "CFBundleName": "Runtime Keyboard Probe", "CFBundlePackageType": "APPL", "MinimumOSVersion": "26.0"}, info)
    build("xcrun", "clang", *sim_flags, "-fobjc-arc", "-fblocks", str(SOURCE / "KeyboardProbe.m"),
          "-framework", "Foundation", "-framework", "UIKit", "-o", str(keyboard_app / "KeyboardProbe"))
    build("xcrun", "clang", "-arch", "arm64", "-fobjc-arc", "-fblocks", str(SOURCE / "HostBroker.m"),
          str(SOURCE / "HostWindow.m"), str(SOURCE / "HostUserNotifications.m"), str(SOURCE / "KeyboardProbeHost.m"),
          "-framework", "Foundation", "-framework", "CoreFoundation", "-framework", "Metal",
          "-framework", "AppKit", "-framework", "QuartzCore", "-framework", "IOSurface", "-o", str(output / "keyboard-broker"))

if "gles-window" in args.cases:
    gles_app = output / "GLESWindowProbe.app"
    gles_app.mkdir()
    with (gles_app / "Info.plist").open("wb") as info:
        plistlib.dump({"CFBundleExecutable": "GLESWindowProbe", "CFBundleIdentifier": "io.iosuse.gles-window-probe",
                      "CFBundleName": "GLES Window Probe", "CFBundlePackageType": "APPL", "MinimumOSVersion": "26.0"}, info)
    build("xcrun", "clang", *sim_flags, "-fobjc-arc", "-fblocks", str(SOURCE / "GLESWindowProbe.m"),
          "-framework", "Foundation", "-framework", "UIKit", "-framework", "QuartzCore", "-framework", "OpenGLES",
          "-framework", "IOSurface", "-framework", "CoreGraphics", "-o", str(gles_app / "GLESWindowProbe"))

def reclaim(process):
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()
    # Only the owned runtime daemon uses this shared-memory name.
    ctypes.CDLL(None).shm_unlink(f"iosuse.notify.{process.pid}".encode())

def execute(command, environment, log, present=False, timeout=30):
    process = subprocess.Popen(command, env=environment, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        return process.wait(timeout=None if present else timeout)
    except subprocess.TimeoutExpired:
        return 124
    finally:
        # Reclaim the entire owned group on normal exit, failure, or interruption.
        reclaim(process)

def execute_notify_isolation(command, environment, log):
    home = Path(command[4])
    name = f"io.iosuse.runtime-probe.scope.{os.getpid()}.{home.name}"
    holders = []
    try:
        for index, value in enumerate((7, 42, 84)):
            owned_home = home / f"holder-{index}"
            (owned_home / "tmp").mkdir(parents=True)
            if index == 0:
                launch = [str(output / "native-notify-probe")]
                child_environment = {"PATH": "/usr/bin:/bin", "HOME": str(owned_home),
                                     "CFFIXED_USER_HOME": str(owned_home), "TMPDIR": str(owned_home / "tmp")}
            else:
                launch = command[:6]
                launch[4] = str(owned_home)
                child_environment = environment
            ready_read, ready_write = os.pipe()
            release_read, release_write = os.pipe()
            launch.extend(["--scope", name, str(value), str(ready_write), str(release_read)])
            process = subprocess.Popen(launch, env=child_environment, stdout=log, stderr=subprocess.STDOUT,
                                       pass_fds=(ready_write, release_read), start_new_session=True)
            holders.append((process, release_write))
            os.close(ready_write)
            os.close(release_read)
            with os.fdopen(ready_read, "rb") as ready:
                if not select.select([ready], [], [], 10)[0]:
                    return 124
                message = ready.read(4)
            if len(message) != 4 or int.from_bytes(message, sys.byteorder):
                return 76
        # All three values now coexist. Each process reads its own value only
        # after both other processes have written the same logical name.
        for process, release in holders:
            os.write(release, b"1")
        statuses = [process.wait(timeout=10) for process, _ in holders]
        log.write(f"[notify-isolation] host/runtime-A/runtime-B exits={statuses}\n")
        log.flush()
        return 0 if all(status == 0 for status in statuses) else 76
    except subprocess.TimeoutExpired:
        return 124
    finally:
        for process, release in holders:
            os.close(release)
            reclaim(process)

def configure_photo_fixture(home, value):
    # Only the synthetic probe gets a fixture grant. The supplied app requests
    # its own permission through tccd and the native host's consent dialog.
    with sqlite3.connect(home / "Library/TCC/TCC.db") as database:
        database.execute("INSERT OR REPLACE INTO access(service,client,client_type,auth_value,auth_reason,auth_version) VALUES(?,?,?,?,?,?)",
                         ("kTCCServicePhotos", "io.iosuse.runtime-photo-probe", 0, value, 2, 2))

failed = False
def adapters_for(mode):
    if mode == "linear-buffer":
        return ["metal-buffer"]
    base = ["display", "scene", "compositor"]
    if mode in ("presentation", "lifecycle"):
        return base
    if mode == "webkit":
        return base + (["webkit-launcher"] if args.webkit_launcher == "standalone" else [])
    if mode == "gles-window":
        return base + ["angle"]
    if args.app_adapters is not None:
        return args.app_adapters
    # These fixtures exercise touch/text explicitly; supplied apps need neither.
    return base + (["input"] if not external_app and mode in ("application", "text-input") else [])

runs = [(mode, args.services if args.services is not None else CASES[mode],
         adapters_for(mode), False)
        for mode in args.cases]
if args.audit:
    for mode, services, adapters, _ in list(runs):
        for service in services:
            runs.append((mode, [item for item in services if item != service], adapters, True))
        if mode in ("application", "linear-buffer"):
            for adapter in adapters:
                runs.append((mode, services, [item for item in adapters if item != adapter], True))
results = []
for number, (mode, services, adapters, deletion) in enumerate(runs):
    home = output / f"home-{number:02d}-{mode}"
    home.mkdir()
    (home / "tmp").mkdir()
    client = output / ("uikit-probe" if mode == "uikit" else "probe")
    environment = os.environ.copy()
    environment.update(HOME=str(home), CFFIXED_USER_HOME=str(home), TMPDIR=str(home / "tmp") + "/")
    environment["IOS_USE_RUNTIME_NOTIFY_BACKEND"] = args.notify_backend
    environment.pop("IOS_USE_RUNTIME_CLIENT_LIBRARIES", None)
    environment.pop("IOS_USE_RUNTIME_PRESENT", None)
    environment.pop("IOS_USE_RUNTIME_TAP", None)
    environment.pop("IOS_USE_RUNTIME_STATIC_PROBE", None)
    if args.present or mode in ("presentation", "lifecycle", "text-input"):
        environment["IOS_USE_RUNTIME_PRESENT"] = "1"
    if mode in ("application", "presentation", "lifecycle", "webkit", "gles-window", "text-input", "linear-buffer"):
        client = app_executable if external_app else app / "RuntimeProbe"
        if mode == "gles-window":
            client = gles_app / "GLESWindowProbe"
        elif mode in ("presentation", "lifecycle"):
            name = "Presentation" if mode == "presentation" else "Lifecycle"
            client = output / f"{name}Probe.app/{name}Probe"
        elif mode == "webkit":
            client = web_app / "WebKitProbe"
        elif mode == "text-input":
            client = keyboard_app / "KeyboardProbe"
        elif mode == "linear-buffer":
            client = output / "linear-buffer-probe"
        environment["IOS_USE_RUNTIME_CLIENT_LIBRARIES"] = ":".join(str(output / f"{name}.dylib") for name in adapters)
        if args.tap:
            environment["IOS_USE_RUNTIME_TAP"] = ",".join(str(x) for x in args.tap)
    command = [str(output / "broker"), str(runtime), str(client),
               str(output / "endpoints.dylib"), str(home), ",".join(services)]
    if mode == "text-input":
        command[0] = str(output / "keyboard-broker")
    elif mode in ("presentation", "lifecycle"):
        command[0] = str(output / f"{mode}-broker")
    if mode in ("trust", "network"):
        command[2] = str(output / f"{mode}-probe")
        if mode == "trust":
            command.extend([str(certificates / "root.der"), str(certificates / "leaf.der")])
        else:
            command.append(args.network_url)
    elif mode in ("notify", "notify-isolation", "angle", "gles-surface"):
        command[2] = str(output / ("notify-probe" if mode == "notify-isolation" else f"{mode}-probe"))
    elif mode == "gles-angle":
        command[2] = str(output / "gles-surface-probe")
        environment["IOS_USE_RUNTIME_CLIENT_LIBRARIES"] = str(output / "angle.dylib")
    elif mode.startswith("photo-"):
        command[2] = str(photo_app / "PhotoProbe")
        command.append(mode)
    elif mode == "keychain":
        command[2] = str(keychain_app / "KeychainProbe")
        command.append("write")
    elif mode == "lifecycle":
        command.append(str(args.duration))
    elif mode not in ("uikit", "linear-buffer"):
        command.append(mode)
    if mode == "retarget-metallib":
        command.extend([str(output / "device.metallib"), str(output / "retargeted.metallib")])
    elif mode.endswith("metallib"):
        command.append(str(output / "probe.metallib"))
    log_path = output / f"{number:02d}-{mode}.log"
    if args.present and os.isatty(0):
        print(f"Window commands: tap X Y, text TEXT, backspace, capture, quit. Diagnostics: {log_path}", flush=True)
    with log_path.open("w") as log:
        if mode == "notify-isolation":
            status = execute_notify_isolation(command, environment, log)
        elif mode == "application" and args.photo_fixture:
            fixture_environment = environment.copy()
            for key in ("IOS_USE_RUNTIME_CLIENT_LIBRARIES", "IOS_USE_RUNTIME_PRESENT", "IOS_USE_RUNTIME_TAP"):
                fixture_environment.pop(key, None)
            setup = [str(output / "broker"), str(runtime), str(photo_app / "PhotoProbe"),
                     str(output / "endpoints.dylib"), str(home), "tcc", "photo-status"]
            status = execute(setup, fixture_environment, log)
            if status == 0:
                configure_photo_fixture(home, 2)
                setup[5:] = [",".join(CASES["photo-roundtrip"]), "photo-roundtrip", "fixture"]
                status = execute(setup, fixture_environment, log)
            if status == 0:
                log.write("[fixture] synthetic photo library ready; supplied app must request its own access\n")
                log.flush()
                status = execute(command, environment, log, args.present)
        elif mode == "photo-roundtrip":
            # Let this runtime create its own schema. Seed a test grant only for
            # our probe and its generated image, never for an external app/home.
            setup = command[:]
            setup[5], setup[6] = "tcc", "photo-status"
            status = execute(setup, environment, log)
            if status == 0:
                configure_photo_fixture(home, 2)
                log.write("[fixture] configured photo access for isolated synthetic library\n")
                log.flush()
                status = execute(command, environment, log)
        else:
            status = execute(command, environment, log, args.present, args.duration + 30 if mode == "lifecycle" else 30)
            if mode == "presentation" and status == 0:
                # Exercise the ordinary host after both successful and failed
                # client exits; the window-close path ran in the pixel workload.
                for expected in (0, 61):
                    lifecycle = command[:6] + ["--exit-code", str(expected)]
                    lifecycle[0] = str(output / "broker")
                    lifecycle_home = output / f"home-{number:02d}-exit-{expected}"
                    lifecycle_home.mkdir()
                    lifecycle[4] = str(lifecycle_home)
                    actual = execute(lifecycle, environment, log)
                    log.write(f"[presentation-probe] app exit={expected} host exit={actual}\n")
                    log.flush()
                    if actual != expected:
                        status = 112
                        break
                if status == 0:
                    for option in ("--static", "--ignore-term"):
                        close_home = output / f"home-{number:02d}{option}"
                        close_home.mkdir()
                        closing = command[:6] + [option]
                        closing[4] = str(close_home)
                        close_environment = environment.copy()
                        if option == "--static": close_environment["IOS_USE_RUNTIME_STATIC_PROBE"] = "1"
                        status = execute(closing, close_environment, log)
                        if status: break
            if mode == "keychain" and status == 0:
                other = command[:]
                other[2], other[-1] = str(other_keychain_app / "KeychainProbe"), "other"
                status = execute(other, environment, log)
                if status == 0:
                    command[-1] = "read-delete"
                    status = execute(command, environment, log)
            if mode == "photo-status" and status == 0:
                for value, expected in ((2, 3), (0, 2)):
                    configure_photo_fixture(home, value)
                    status = execute(command + [str(expected)], environment, log)
                    if status: break
    print(log_path.read_text(), end="")
    print(f"{mode}: exit={status}", flush=True)
    results.append((mode, services, adapters if mode in ("application", "presentation", "lifecycle", "webkit", "gles-window", "text-input", "linear-buffer") else [], status, deletion))
    failed |= status != 0 and not deletion
print("\nCase                 Services                      App adapters    Exit   Experiment")
for mode, services, adapters, status, deletion in results:
    print(f"{mode:20} {','.join(services) or '(none)':29} {','.join(adapters) or '(none)':15} {status:4}   {'observation' if deletion else 'selected'}")
raise SystemExit(1 if failed else 0)
