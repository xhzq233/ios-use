# Standalone Simulator runtime experiment (issue #20)

This experiment launches Simulator-linked executables as ordinary macOS child
processes, loads UIKit from an installed Simulator runtime, and connects Metal
and IOSurface to a small native host broker. It does not boot a Simulator,
invoke `simctl`, borrow a Simulator bootstrap namespace, or register launchd
services.

Tested on Apple M4 Pro, macOS 15.7.7, Xcode 26, iOS Simulator runtime 26.0.1.
This is an experiment using version-sensitive Apple private APIs, separate from
the production CLI. It requires the installed runtime and Xcode Metal tools.
Apple executables/frameworks are loaded in place; none are copied into the repo.

## Run

Find the installed `.simruntime` bundle, then pass its runtime root explicitly:

```sh
python3 experiments/simulator-runtime/run.py \
  --runtime-root '/path/to/iOS.simruntime/Contents/Resources/RuntimeRoot'
```

Build products, isolated child homes, logs, and the UIKit PNG go into a new
`$IOS_USE_HOME/artifacts/runtime-probe/run-*` directory (default: repository
`.ios-use/artifacts/runtime-probe/`). Each case has a 30-second timeout and its
process group is cleaned up. The runner does not alter Simulator/device state.

Three real execution cases run:

- Metal source compilation, pipeline creation, render-target clear/readback,
  and a compute kernel. The render target is backed by an IOSurface. All 16 BGRA
  pixels must match both Metal texture readback and the CPU-mapped IOSurface,
  allowing one quantization level. The compute output must equal 42 and both
  commands must complete.
- The same GPU operations using an offline-built Simulator metallib.
- UIKit view-tree rasterization through `UIGraphicsImageRenderer` and
  `CALayer.renderInContext:`. A UIView contains a UILabel and an iOS 26
  `UICornerConfiguration` capsule. The 320×180 PNG is saved at
  `home-uikit/uikit.png`. Exit status checks dimensions, file creation, and
  enough white text pixels to reject a blank blue image. Inspect the PNG for
  text and rounded green capsule appearance. This is offscreen drawing, not
  window presentation; it requires iOS 26 or newer.

## What is connected

```text
native macOS broker
  ├─ Metal XPC listener → host MTLSimImplementation → host GPU
  ├─ IOSurface XPC listener → host IOSurfaceRemoteServer
  ├─ runtime MTLCompilerService child → compiler XPC listener
  └─ Simulator-linked probe child
       ├─ UIKitCore / IOSurface from runtime
       └─ MTLSimDriver → Metal endpoint / compiler endpoint
```

`HostBroker.m` starts the runtime's actual compiler service and the probe with
`DYLD_ROOT_PATH` and Simulator environment variables. A Mach right inherited
through `mach_ports_register` carries three anonymous XPC endpoints.
`ServiceEndpoints.c` redirects Metal/compiler/IOSurface service discovery and
replaces the compiler's `xpc_main` listener setup. It retains Apple's renderer,
compiler, IOSurface server, request handlers, and shader code. It uses exported
private endpoint functions without assuming XPC object memory offsets.

The native Metal and IOSurface listeners enable Simulator-to-host XPC format
before activation. The corresponding runtime clients select this format in
MTLSimDriver and IOSurface. The compiler connection stays Simulator-to-Simulator,
using the runtime's own compiler; substituting the host compiler failed in an
exploratory run.

The runtime's `com.apple.IOSurface.Remote` connection goes to an instance of the
host `IOSurfaceRemoteServer`, initialized with its anonymous listener and empty
options. This follows the locally inspected SimRenderServer initialization.
IOSurface's purpose as shared framebuffer storage is described in
[Apple's documentation](https://developer.apple.com/documentation/iosurface).

## Findings and remaining boundary

The harness verified BGRA `191,128,64,255` through both texture readback and
IOSurface mapping, and compute result `42` for both source and metallib modes.
Disabling only the IOSurface redirect reproduced `IOSurface not available` and
failed surface allocation with exit 19.
A device-targeted metallib correctly failed pipeline creation with exit 16
(incompatible target OS). UIKit produced a blue background, white text, and a
rounded green capsule using the runtime's iOS 26 API. Logs identify loaded
frameworks and GPU implementation. The experiment's Simulator was shut down
for standalone runs; an unrelated booted Simulator was left untouched.

On this machine, native iOSSupport exposes UIKit 18.7 with an AGX Metal device;
the newer Simulator runtime exposes UIKit 26.0.1 with `MTLSimDevice`. The latter
forwards GPU work to a native host implementation. Successful standalone GPU
execution does not require replacing the Simulator Metal driver with the host
Metal framework.

`UIApplicationMain` remains a separate unresolved boundary. Direct startup
trapped in `BKSDisplayServicesStart`; local disassembly identifies missing
BackBoard display service communication. In a separate diagnostic, borrowing
a booted experimental Simulator's bootstrap namespace passed this failure.
Sampling then showed `UIApplication._run → GSEventRunModal → CFRunLoop` on the
main thread, with a UIKit event-fetch thread also waiting. Logs show a FrontBoard workspace connection and an outgoing scene handshake,
without the delegate's launch callback firing. This points to application/scene launch delivery
as the next investigation, not an observed GPU wait; the exact missing request
has not been established.

This harness does not emulate BackBoard, FrontBoard, RunningBoard, or window
composition. It does not establish native NSWindow presentation, input delivery,
WebKit processes, or full app execution. Standalone UIKit still emits a
duplicate `_NoAnimationDelegate` warning, which is not suppressed.

Before the IOSurface endpoint was added, whole-view-tree rendering emitted
`IOSurface not available`. An earlier visual inspection incorrectly concluded
that label text was absent: decoded pixels in those saved PNGs also contain
1,670 white text pixels. The warning did not establish software rasterization
failure. The new evidence is working shared IOSurface allocation and GPU/CPU
access, and disappearance of that warning with the endpoint connected.

Device-app retargeting is additional work: Mach-O platform metadata and embedded
Metal AIR targets both matter. The generic Simulator-built probe does not
validate arbitrary device frameworks, OpenGL ES paths, or a complete converted
app. The next UI experiment should investigate display/application launch
services while keeping the verified Metal and IOSurface connections reusable.
