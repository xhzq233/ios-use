# Minimal standalone Simulator runtime (issue #20)

This harness loads an installed iOS Simulator runtime in ordinary macOS child
processes and starts only the selected rendering services. It does not invoke
`simctl`, boot a Simulator, borrow a Simulator bootstrap namespace, or register
launchd services. SpringBoard, backboardd, runningboardd, and launchd_sim are not
started by the harness. Normal macOS system services are still present.

Tested on Apple M4 Pro, macOS 15.7.7, Xcode 26, iOS runtime 26.0.1. This is a
private-API feasibility experiment, separate from the production CLI. It needs
an installed runtime and Xcode Metal tools. Apple frameworks and the runtime
compiler are loaded in place; no Apple or application binaries are included.

## Run

```sh
python3 experiments/simulator-runtime/run.py \
  --runtime-root '/path/to/iOS.simruntime/Contents/Resources/RuntimeRoot'
```

The default cases verify texture clear/readback, shared IOSurface storage,
source and metallib compute, and UIKit offscreen drawing. Each case uses the
smallest service list measured for that workload. Add `--audit` to remove each
selected service in turn and observe the failure or fallback. These are real
GPU/UI operations, not comparisons of log strings.

```sh
# Empty service list: UIKit software rasterization.
python3 experiments/simulator-runtime/run.py --runtime-root "$RUNTIME_ROOT" \
  --cases uikit --services

# Choose an explicit service array.
python3 experiments/simulator-runtime/run.py --runtime-root "$RUNTIME_ROOT" \
  --cases surface --services metal iosurface

# Application startup and deletion of each in-process adapter.
# Currently exits nonzero: window presentation lacks a remote CAContext.
python3 experiments/simulator-runtime/run.py --runtime-root "$RUNTIME_ROOT" \
  --cases application --audit
```

`--services` overrides the case's service array. `--app-adapters display scene`
selects the application-only adapters; an empty list injects neither. `--audit`
reports deletion cases as observations, including their nonzero exits. Selected
cases must succeed for the runner to return zero; an observed dependency
failure does not become a successful workload.

Artifacts go into a new `$IOS_USE_HOME/artifacts/runtime-probe/run-*` directory
(default: repository `.ios-use/artifacts/runtime-probe/`). Each case has a fresh
home, a log, and a 30-second timeout with process-group cleanup. PNGs are stored
in the corresponding `home-NN-case/` directory. No device or Simulator state is
modified.

## Measured minimum by workload

| Workload | Service array | Result and deletion evidence |
| --- | --- | --- |
| UIKit view-tree rasterization | `[]` | 320×180 PNG, 1,670 white text pixels, iOS 26 green capsule. IOSurface lookup fails and drawing still succeeds. |
| Metal texture clear | `[metal]` | All 16 BGRA pixels verified. No compiler or IOSurface service. Removing Metal yields no device, exit 10. |
| Metal clear into shared IOSurface | `[metal, iosurface]` | GPU write, texture readback, and CPU surface mapping agree. Without IOSurface, allocation fails, exit 19. |
| Source compute | `[metal, compiler]` | GPU result 42. Without compiler, library creation fails, exit 14. No IOSurface needed. |
| Simulator metallib compute | `[metal, compiler]` | GPU result 42. Without compiler, pipeline creation fails, exit 16. Precompiling AIR does not remove this compiler dependency. |
| Shared-surface clear plus compute | `[metal, compiler, iosurface]` | Both source and metallib paths pass. Deletions reproduce the component failures above. |

`metal` and `iosurface` are listener objects in the native broker, not separate
daemon processes. Only `compiler` adds an Apple service child. With no services,
the native broker launches just the probe child.

The render check requires completed commands and BGRA `191,128,64,255` across
all 16 pixels (one quantization level allowed). Shared-surface checks also read
the CPU mapping. Compute checks require a completed command and result `42`.
UIKit uses real UIView/UILabel, `UICornerConfiguration`,
`UIGraphicsImageRenderer`, and `CALayer.renderInContext:`. It verifies PNG size,
file creation, and white text pixels; this does not establish window composition.

## What the host supplies

```text
native macOS broker
  ├─ [metal] host MTLSimImplementation + anonymous XPC listener
  ├─ [iosurface] host IOSurfaceRemoteServer + anonymous XPC listener
  ├─ [compiler] runtime MTLCompilerService child + anonymous XPC listener
  └─ Simulator-linked client
       ├─ runtime UIKitCore / MTLSimDriver / IOSurface
       └─ application-only: local display metadata + local scene endpoint
```

`HostBroker.m` passes selected endpoints through an inherited Mach right using
`mach_ports_register`. `ServiceEndpoints.c` redirects the three service lookups
and replaces the compiler's `xpc_main` listener setup. Disabled services return
a dead anonymous endpoint: callers receive a real connection failure and may
use their own software fallback. They cannot silently discover a booted
Simulator's version of these three services.

Apple's renderer, compiler, IOSurface server, request handlers, and shader code
are retained. Exported private endpoint functions avoid XPC object-layout
assumptions. Metal and IOSurface use Simulator-to-host XPC format on both ends;
the compiler uses Simulator-to-Simulator format and the runtime's own compiler.
Substituting the host compiler failed in an earlier experiment.

The IOSurface listener hosts an actual `IOSurfaceRemoteServer` with empty
options, following the locally inspected SimRenderServer setup. IOSurface's
shared-buffer role is described in
[Apple's documentation](https://developer.apple.com/documentation/iosurface).

Native iOSSupport on the test machine exposes UIKit 18.7 and an AGX Metal
device. The newer Simulator runtime exposes UIKit 26.0.1 and `MTLSimDevice`,
which forwards GPU work to the host. Replacing Simulator Metal with the host
Metal framework is unnecessary for these measured workloads.

## Application startup: remove processes, retain required functions

The application diagnostic uses the same directly spawned process and empty
service array. Its two adapters supply narrowly scoped functions:

- `LocalDisplay.m` supplies a fixed 402×874 logical screen at 3× through actual
  FBS display configuration/mode objects. It initializes GraphicsServices and
  updates UIKit's initially zero-sized screen through UIKit's implementation.
  It replaces the two BackBoard screen-information entry points. It does not
  supply a compositor, physical display, or input server.
- `LocalSceneHost.m` hosts an anonymous workspace peer inside the app. It accepts
  BoardServices connection setup, the scene handshake, and client-settings
  notifications. Unknown operations close the peer. `SceneBootstrap.m` registers
  this endpoint and delivers one scene through the runtime's
  `FBSWorkspaceScenesClient`. UIKit invokes the app's launch delegate; no code
  calls AppDelegate directly.

These adapters load only in the application, never in MTLCompilerService.
The scene diagnostic uses private selectors, one named workspace ivar, and a
one-second scheduling delay. It supports one initially empty scene source,
not arbitrary applications or multiple scenes.

With both adapters, UIKit reaches the real `didFinishLaunching` callback with
a 402×874 screen. The delegate creates UIWindow and its view tree, saves
`launch.png` using software rasterization, then requests `makeKeyAndVisible`.
That request fails with **Failed to create remote render context**, in
`_UIContextBinder` / CoreAnimation. The diagnostic returns nonzero; reaching the
callback and saving its view tree are intermediate milestones, not a completed
application launch. Even an unpresented window can encounter the same context
requirement when its foreground scene prepares to resume.

Removing display setup traps at `BKSDisplayServicesStart`. Keeping display
setup but removing scene delivery leaves the UIKit event loop running without
the launch callback; the probe exits at its 15-second deadline. Thus display
information and scene delivery are necessary here, while the full SpringBoard
and backboardd processes are not necessary to reach the callback. The next
missing function is a usable CoreAnimation rendering context. These findings
do not prove that Apple's full render-server process is the only way to supply
one. Keyboard service lookup also fails without preventing the callback;
keyboard input itself has not been tested.

## WebKit and full-app boundary

Earlier controlled experiments isolated a separate process-domain dependency.
They borrowed an experimental Simulator's bootstrap namespace and used the
same local scene-delivery method, without `LocalSceneHost` or `LocalDisplay`.

| Execution path | UIKit callback / window | WebKit |
| --- | --- | --- |
| Normal Simulator app launch | Yes | Loads HTML |
| Raw `simctl spawn`, no scene delivery | No | No window |
| Raw `simctl spawn` + scene delivery | Yes; window snapshot | JavaScript body text and webpage snapshot pass |
| Native exec + borrowed bootstrap + scene delivery | Yes; window snapshot | Extension launch fails: missing launchd domain |

The directly executed process has `RBSOpaqueProcessIdentity`, even at the
installed app path; normally launched apps have `RBSEmbeddedAppProcessIdentity`.
The scene handshake was received, but the initialization context lacked the
default scene. Local scene delivery supplied it. Matching `SIMULATOR_ROOT`,
`SIMULATOR_RUNTIME_VERSION`, and `SIMULATOR_RUNTIME_BUILD_VERSION` resolved the
initial LaunchServices mismatch. WebKit then failed with
`OSLaunchdErrorDomain Code=112`, "Could not find specified domain". An inherited
bootstrap Mach port is insufficient to establish process-domain membership.

`SceneBootstrap.m` can still be compiled alone for that diagnostic; without the
local host/display libraries it uses the existing workspace source and screen.
The standalone runner does not rely on that borrowed namespace.

Native NSWindow presentation, input, standalone WebKit child hosting, and a
complete converted device app remain unverified. Device-app retargeting also
involves Mach-O platform metadata, embedded Metal AIR targets, and potentially
OpenGL ES; the generic probes do not validate those paths. Keep untested app
services out of the "unnecessary" category until a relevant workload exercises
them.

Standalone UIKit emits a duplicate `_NoAnimationDelegate` warning. Without the
IOSurface endpoint, it also emits `IOSurface not available`; the software PNG
still contains the expected text. An earlier visual interpretation of that
warning as missing text was corrected by decoded pixel evidence.
