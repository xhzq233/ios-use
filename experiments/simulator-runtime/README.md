# Standalone Simulator runtime experiment (issue #20)

This experiment launches Simulator-linked executables as ordinary macOS child
processes, loads UIKit from an installed Simulator runtime, and connects Metal
to a small native host broker. It does not boot a Simulator, invoke `simctl`,
borrow a Simulator bootstrap namespace, or register launchd services.

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
  and a compute kernel. All 16 BGRA pixels are checked, allowing one quantization
  level; the compute output must equal 42 and both commands must complete.
- The same GPU operations using an offline-built Simulator metallib.
- UIKit rasterization through `UIGraphicsImageRenderer`: a `UIView` background
  uses `CALayer.renderInContext:`, and a `UILabel` uses `drawTextInRect:` directly. A 320×180 PNG is saved at `home-uikit/uikit.png`.
  Exit status checks dimensions, file creation, and enough white text pixels to
  reject a blank blue image; inspect the image for visual correctness. This exercises CPU rasterization, not window presentation.

## What is connected

```text
native macOS broker
  ├─ anonymous XPC listener → host MTLSimImplementation → host GPU
  ├─ runtime MTLCompilerService child → anonymous compiler XPC listener
  └─ Simulator-linked probe child
       ├─ UIKitCore from runtime
       └─ MTLSimDriver → Metal endpoint / compiler endpoint
```

`HostBroker.m` starts the runtime's actual compiler service and the probe with
`DYLD_ROOT_PATH` and Simulator environment variables. A Mach right inherited
through `mach_ports_register` carries the two anonymous XPC endpoints.
`ServiceEndpoints.c` changes only Metal/compiler service discovery and the
compiler's `xpc_main` listener setup. It retains Apple's renderer, compiler,
request handlers, and shader code. It uses exported private endpoint functions,
without assuming XPC object memory offsets.

The native Metal listener must enable Simulator-to-host XPC format before
activation. The runtime client selects this format in MTLSimDriver. The compiler
connection stays Simulator-to-Simulator, using the runtime's own compiler;
substituting the host compiler failed in the exploratory run.

The UIKit raster case shares the launcher but does not exercise these Metal
endpoints. Logs identify the loaded UIKit framework and GPU implementation so
loading host iOSSupport by mistake is visible.

## Findings and remaining boundary

The cleaned harness verified BGRA `191,128,64,255` and compute result `42` for
both source and metallib modes. A device-targeted metallib correctly failed
pipeline creation with exit 16 (incompatible target OS). UIKit immediate drawing
produced the expected blue background with white text. The experiment's Simulator was shut down during these
runs; an unrelated booted Simulator was left untouched. Endpoint discovery is
explicit and does not borrow services from it.

On this machine, native iOSSupport exposes UIKit 18.7 with an AGX Metal device;
the newer Simulator runtime exposes UIKit 26.0.1 with `MTLSimDevice`. The latter
forwards GPU work to a native host implementation. Successful standalone GPU
execution therefore does not require replacing the Simulator Metal driver with
the host Metal framework.

`UIApplicationMain` remains a separate unresolved boundary. Direct startup
trapped in `BKSDisplayServicesStart`; local disassembly identifies missing
BackBoard display service communication. Borrowing a booted Simulator bootstrap
namespace passed that initial failure, but still stalled before application
launch completion. This harness does not patch or emulate BackBoard,
FrontBoard, RunningBoard, or window composition. It does not establish native
NSWindow presentation, input delivery, WebKit processes, or full app execution.

Standalone UIKit currently emits a duplicate `_NoAnimationDelegate` warning;
the whole-view-tree attempt also emitted `IOSurface not available`. These are not suppressed.
An initial whole-view-tree raster snapshot included label text, but repeated
runs produced only the background, even with explicit layout/display calls.
The retained probe therefore draws UILabel text directly into the CGContext;
it does not claim working cached label layers or reliable view-tree snapshots.
The successful immediate drawing does not establish IOSurface/compositor support.

Device-app retargeting is additional work: Mach-O platform metadata and embedded
Metal AIR targets both matter. The generic Simulator-built probe here does not
validate arbitrary device frameworks, OpenGL ES paths, or a complete converted
app. The next UI experiment should locate the minimum display/application
services needed for real window presentation, while keeping this verified GPU
path as a reusable component.
