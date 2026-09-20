# Minimal standalone Simulator runtime (issue #20)

This harness loads an installed iOS Simulator runtime in ordinary macOS child
processes and starts only the selected rendering, trust, keychain, notification, photo,
and LaunchServices components. It does not invoke
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
source and metallib compute, device-library retargeting, UIKit offscreen drawing,
certificate validation, keychain persistence/signing, cross-process notifications, and PhotoKit authorization
states, PhotoKit image creation/readback, and ANGLE GLES shaders through Metal.
The EAGL adapter case also checks shared contexts, APPLE multisample resolve, GLKit image upload, texture
lifetime after cache release, and repeated CPU/GPU pixel-buffer access.
Each case uses the
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

# Shared Metal buffer/texture aliasing, video-plane sampling, and deletion checks.
python3 experiments/simulator-runtime/run.py --runtime-root "$RUNTIME_ROOT" \
  --cases linear-buffer --audit

# Certificate validation, including wrong-host, expired, and untrusted chains.
python3 experiments/simulator-runtime/run.py --runtime-root "$RUNTIME_ROOT" \
  --cases trust --audit

# Isolated keychain CRUD, identity separation, and a persistent EC signing key.
python3 experiments/simulator-runtime/run.py --runtime-root "$RUNTIME_ROOT" \
  --cases keychain --audit

# Optional live HTTPS request; excluded from the default offline cases.
python3 experiments/simulator-runtime/run.py --runtime-root "$RUNTIME_ROOT" \
  --network-url https://www.apple.com/ --audit

# Notification delivery and isolated PhotoKit authorization states.
python3 experiments/simulator-runtime/run.py --runtime-root "$RUNTIME_ROOT" \
  --cases notify photo-status --audit

# Create a generated image, fetch it, and read its original bytes through PhotoKit.
python3 experiments/simulator-runtime/run.py --runtime-root "$RUNTIME_ROOT" \
  --cases photo-roundtrip --audit

# Runtime ANGLE: GLES shaders render into a CVPixelBuffer-backed IOSurface via Metal.
python3 experiments/simulator-runtime/run.py --runtime-root "$RUNTIME_ROOT" \
  --cases angle --audit

# EAGL/CoreVideo callers use the same ANGLE backend without changing their source.
python3 experiments/simulator-runtime/run.py --runtime-root "$RUNTIME_ROOT" \
  --cases gles-angle --audit

# Present from an app-owned thread without a RunLoop; verify composed pixels and resize.
python3 experiments/simulator-runtime/run.py --runtime-root "$RUNTIME_ROOT" \
  --cases gles-window --audit

# Present the real PhotoKit consent request; click Allow Full Access to pass.
python3 experiments/simulator-runtime/run.py --runtime-root "$RUNTIME_ROOT" \
  --cases photo-prompt --present

# CoreVideo/GLES interoperation currently fails with -6683; no proprietary app needed.
python3 experiments/simulator-runtime/run.py --runtime-root "$RUNTIME_ROOT" \
  --cases gles-surface

# Application startup and deletion of each in-process adapter.
python3 experiments/simulator-runtime/run.py --runtime-root "$RUNTIME_ROOT" \
  --cases application --audit

# Native keyboard events, Unicode deletion, focus switching, and editing delegates.
# Opens a test window and exits automatically; retains the 30-second case timeout.
python3 experiments/simulator-runtime/run.py --runtime-root "$RUNTIME_ROOT" \
  --cases text-input

# Observe startup of a user-supplied app that already targets the Simulator.
# Writes app-composited.png, then exits; does not convert the app.
python3 experiments/simulator-runtime/run.py --runtime-root "$RUNTIME_ROOT" \
  --app /path/to/Converted.app

# Keep the app running in a native macOS window. Close it or press Ctrl-C to stop.
# Optional tap exercises native mouse -> Mach message -> UIKit delivery.
python3 experiments/simulator-runtime/run.py --runtime-root "$RUNTIME_ROOT" \
  --app /path/to/Converted.app --present --tap 280 840

# Give that app a disposable library containing one generated 1024×768 test image.
# The supplied app requests access through a native consent dialog.
python3 experiments/simulator-runtime/run.py --runtime-root "$RUNTIME_ROOT" \
  --app /path/to/Converted.app --photo-fixture --present

# Opt in to the experimental GLES and EAGL drawable adapter.
python3 experiments/simulator-runtime/run.py --runtime-root "$RUNTIME_ROOT" \
  --app /path/to/Converted.app --photo-fixture --present \
  --app-adapters display scene compositor input angle metal-buffer
```

`--services` overrides the case's service array. `--app` defaults to
`metal compiler iosurface trust keychain`; the built-in offline application probe omits
`trust` and `keychain`. The `keychain` entry starts runtime securityd with an
isolated database. The optional `tcc`, `photos`, `notify`, and `launchservices` entries start
runtime tccd, assetsd, notifyd, and lsd respectively. `--photo-fixture` requires
`--app`, adds these four services to its default array, creates and verifies the
generated image through PhotoKit. Only the seeding probe gets a fixture grant;
the supplied app must request its own access. Use `--present` to display its
consent dialog. It never uses an existing photo library.
`photo-prompt` and `gles-surface` are excluded from the passing default cases
because the former needs an interactive choice and the latter's original
CoreVideo/GLES interoperation is unfinished. Without `--present`, `photo-prompt`
still fails because no notification presenter is available.
`--network-url` selects a live HTTPS HEAD request and is mutually
exclusive with `--app`. Default cases require no network access.
`--app-adapters display scene compositor input` selects application-only adapters;
an empty list injects none. Add `angle` to opt into the EAGL/GLES/BGRA bridge,
and `metal-buffer` for shared linear Metal textures on the tested Apple GPU path;
it is never injected into runtime service processes. `--app` selects the application case and captures its
composited display after 15 seconds. `--tap X Y` sends a single tap after eight
seconds in the fixed 402×874 logical coordinate space. With `--present` it uses
native mouse events; otherwise it delivers UIKit events in the app. Timing and
coordinates are diagnostic inputs, not app-readiness detection.
Use a disposable converted copy of the app.
The runner does not install it or alter its platform metadata. In a terminal,
`--present` also accepts `tap X Y`, `text TEXT`, `backspace`, `capture`, and `quit` on stdin. Taps follow the
same native mouse path as the window. While a consent dialog is open, `tap`
coordinates refer to that dialog's content area; its button centers are logged.
Focus an app input field before `text` or `backspace`. Text preserves spaces after
the command separator, supports UTF-8, and is limited to 4096 bytes per command;
longer input is rejected without truncation. These commands use the native view's
committed-text/delete callbacks. Native key events support character entry,
backspace, and return. Marked-text/IME composition, paste, and general key commands
are not yet implemented.
`capture` saves that native view as `prompt-NNN.png`, or the app's displayed
shared buffer as `capture-NNN.png`; wait for the UI transition before requesting
it. These view/buffer diagnostics do not prove physical display visibility.
`quit` or closing the window terminates the owned app and services and returns
success for that intentional close. `--audit` reports deletion cases as observations, including their nonzero exits. Selected
cases must succeed for the runner to return zero; an observed dependency
failure does not become a successful workload.

Artifacts go into a new `$IOS_USE_HOME/artifacts/runtime-probe/run-*` directory
(default: repository `.ios-use/artifacts/runtime-probe/`). Each case has a fresh
home and `TMPDIR`, a log, and process-group cleanup. Headless cases have a
30-second timeout; `--present` runs until the window closes, the app exits, or
Ctrl-C. On exit, the broker gives each owned service two seconds to finish after
SIGTERM, then kills and reaps it if needed; trustd can retain background XPC
transactions. The runner also reclaims the whole owned process group and unlinks
its uniquely named notify shared-memory object, including after a timeout or
interruption. Both `HOME` and `TMPDIR` point into the case directory. PNGs are
stored in the corresponding `home-NN-case/` directory. The native host saves one `streamed-frame.png` diagnostic; this proves the received pixels,
not visibility on the physical display. `native-window.png` is attempted only
when the window is unoccluded. No device or Simulator state is modified. Once a
run has stopped, its `run-*` directory can be deleted to remove its home, caches,
temporary files, logs, and build products.

The broker looks for an existing arm64 Simulator dyld cache under
`/Library/Developer/CoreSimulator/Caches/dyld/<host-build>/<runtime-id>.<runtime-build>`.
It derives these values from the host, selected runtime, and runtime bundle
metadata, and supplies a readable match through `DYLD_SHARED_CACHE_DIR`. The
selected directory is logged. With no match it retains dyld's defaults; it does
not build, download, modify, or delete system caches, or start CoreSimulator.
Apple's [dyld cache selection code](https://github.com/apple-oss-distributions/dyld/blob/main/dyld/DyldProcessConfig.cpp)
describes this environment override and the runtime's own prebuilt-cache path.
The installed cache is a runtime artifact, not a connection to Simulator services.

## Measured minimum by workload

| Workload | Service array | Result and deletion evidence |
| --- | --- | --- |
| PhotoKit create/fetch/original-byte readback | `[tcc, photos, notify, launchservices]` | A generated 64×48 PNG is created, fetched with matching dimensions, and read back byte-for-byte. Removing TCC fails authorization; removing photos, notify, or LaunchServices fails creation. |
| ANGLE GLES shaders and shared pixel buffer | `[metal, compiler, iosurface]` | The installed runtime ANGLE Metal backend reads red BGRA pixels from an IOSurface, compiles/draws a green GLSL triangle, and writes green pixels back across the whole buffer. |
| EAGL/GLKit/CoreVideo through ANGLE | `[metal, compiler, iosurface]` | ES 2/3 callers upload a GLKit image, share a texture between contexts, release its cache, change pixels from CPU and GPU, and verify the whole buffer. Removing Metal fails context creation; removing compiler fails compilation-dependent GPU work; removing IOSurface fails pixel-buffer allocation. |
| EAGL drawable presentation | `[metal, compiler, iosurface]` | A long-lived render thread without a RunLoop draws four colored quadrants, then moves/resizes the view and changes the colors. Read-only snapshots of the published CA display verify position, orientation, size, GL state restoration, and layer release after deleting the renderbuffer. |
| Cross-process Darwin notification | `[notify]` | A spawned sender sets state 42 and posts; the other process receives the callback and reads 42. Removing notify fails registration (exit 73). |
| PhotoKit authorization state | `[tcc]` | A fresh database reports not determined; explicit allow/deny fixtures for our probe report authorized/denied. Removing tcc fails the initial state check (exit 61). This does not exercise permission UI or photo storage. |
| PhotoKit consent via native host | `[tcc]` | With `--present`, native clicks return authorized/denied through the real PhotoKit callback; fresh processes confirm persistence. No SpringBoard or additional child is needed. Limited selection is unavailable. |
| Certificate-chain validation | `[trust]` | Correct chain accepted; wrong host, expired leaf, and untrusted root rejected with the corresponding Security errors. Removing trust fails the valid-chain check (exit 51). |
| Keychain CRUD and persistent EC signing | `[keychain]` | Add, duplicate rejection, update and read succeed; new service/client processes read the same data and sign with the persisted EC key, reject a changed message, then delete. A separately entitled identity cannot access the item or claim its access group. Removing securityd returns -25291. No notifyd or trustd is needed for these operations. |
| HTTPS HEAD | `[trust]` | `www.apple.com` validates and returns HTTP 200. Removing trust fails with NSURLError -1202 (exit 52). No GPU services needed. |
| UIKit view-tree rasterization | `[]` | 320×180 PNG, 1,670 white text pixels, iOS 26 green capsule. IOSurface lookup fails and drawing still succeeds. |
| Metal texture clear | `[metal]` | All 16 BGRA pixels verified. No compiler or IOSurface service. Removing Metal yields no device, exit 10. |
| Metal clear into shared IOSurface | `[metal, iosurface]` | GPU write, texture readback, and CPU surface mapping agree. Without IOSurface, allocation fails, exit 19. |
| Source compute | `[metal, compiler]` | GPU result 42. Without compiler, library creation fails, exit 14. No IOSurface needed. |
| Device metallib retargeting | `[metal, compiler]` | The original device library loads but pipeline creation fails; rebuilding its AIR target for Simulator lets the same kernel run and return 42. |
| Simulator metallib compute | `[metal, compiler]` | GPU result 42. Without compiler, pipeline creation fails, exit 16. Precompiling AIR does not remove this compiler dependency. |
| UIKit application software composition | `[iosurface]` plus all four adapters | CA falls back without Metal; the visible window and pixel checks pass with no compiler child. |
| UIKit application GPU composition | `[metal, compiler, iosurface]` plus all four adapters | Real launch callback, visible window, and GPU-composited IOSurface with white text, blue background, and green capsule. |
| Shared-surface clear plus compute | `[metal, compiler, iosurface]` | Both source and metallib paths pass. Deletions reproduce the component failures above. |

`metal` and `iosurface` are listener objects in the native broker, not separate
daemon processes. `compiler`, `trust`, `keychain`, `tcc`, `photos`, `notify`, and `launchservices` each add one
Apple service child when selected. With
no services, the native broker launches just the probe child. Certificate trust
is a separate network dependency; it is not needed for the rendering-only cases.

The render check requires completed commands and BGRA `191,128,64,255` across
all 16 pixels (one quantization level allowed). Shared-surface checks also read
the CPU mapping. Compute checks require a completed command and result `42`.
UIKit uses real UIView/UILabel, `UICornerConfiguration`,
`UIGraphicsImageRenderer`, and `CALayer.renderInContext:`. It verifies PNG size,
file creation, and white text pixels; this does not establish window composition.

## What the host supplies

```text
native macOS broker (+ optional AppKit window)
  ├─ [metal] host MTLSimImplementation + anonymous XPC listener
  ├─ [iosurface] host IOSurfaceRemoteServer + anonymous XPC listener
  ├─ [compiler] runtime MTLCompilerService child + anonymous XPC listener
  ├─ [trust] runtime trustd child + anonymous XPC listener, isolated data
  ├─ [keychain] runtime securityd child + anonymous XPC listener, isolated keychain
  ├─ [tcc] runtime tccd child + anonymous XPC listener, isolated TCC database
  ├─ [photos] runtime assetsd child + anonymous Photos XPC listener
  ├─ [notify] runtime notifyd child + inherited Mach port, isolated shared memory
  ├─ [launchservices] runtime lsd child + anonymous mapdb listener, isolated containers
  └─ Simulator-linked client
       ├─ runtime UIKitCore / MTLSimDriver / IOSurface
       └─ application-only: display metadata + scene endpoint + CA server/display
                            + input-registration peer + single-pointer delivery
```

`HostBroker.m` passes selected endpoints through an inherited Mach right using
`mach_ports_register`. `ServiceEndpoints.c` redirects the selected XPC service lookups
and replaces the compiler's `xpc_main` listener setup. Disabled services return
a dead anonymous endpoint: callers receive a real connection failure and may
use their own software fallback. They cannot silently discover a booted
Simulator's version of these services. `NotifyTransport.c` routes libnotify's
Mach lookup through a second inherited right, available before other daemons
finish starting. With notify disabled, lookup fails.

The notify daemon receives only the C transport adapter. It uses a separate
shared-memory name, passed explicitly with `-shm` and also used by its clients.
The harness supplies an empty initial list of launchd-triggered subscriptions;
it does not schedule background jobs. Direct notification registration, shared
state, posting, and delivery use Apple's implementation. Without that initial
barrier, notifyd never starts servicing its Mach port. This startup sequence is
visible in [Apple's notifyd source](https://github.com/apple-oss-distributions/Libnotify/blob/main/notifyd/notifyd.c).

Apple's renderer, compiler, IOSurface server, request handlers, and shader code
are retained. Exported private endpoint functions avoid XPC object-layout
assumptions. Metal and IOSurface use Simulator-to-host XPC format on both ends;
the compiler uses Simulator-to-Simulator format and the runtime's own compiler.
Substituting the host compiler failed in an earlier experiment.

All connections to the single runtime compiler share one serial request queue.
Without this, simultaneous CoreAnimation function specialization crashes the
compiler in LLVM optimization passes; the app subsequently reports an unavailable
MTLCompilerService. Removing the oneshot-instance setting did not fix that crash.
Serializing requests did. This trades compiler throughput for one service process
and avoids corrupting its shared state; it does not serialize GPU command execution.

The IOSurface listener hosts an actual `IOSurfaceRemoteServer` with empty
options, following the locally inspected SimRenderServer setup. IOSurface's
shared-buffer role is described in
[Apple's documentation](https://developer.apple.com/documentation/iosurface).

The `trust` child uses the installed runtime's `trustd` and trust-store resources.
Its original request handler performs certificate validation. The shim replaces
only listener discovery, preserves the logical `com.apple.trustd` connection
name, and sets Security's custom home to the run directory. Security reconstructs
foreground-user connections using `xpc_connection_get_name`; returning NULL for
an anonymous endpoint redirected that reconstruction to securityd and produced
an internal error (-26276), surfaced by CFNetwork as TLS -9807 / URL error -1202.
With the name preserved, the same runtime client validates Apple's certificate
and receives HTTP 200. No trust result, policy, or certificate exception is patched.

`TrustProbe.m` verifies an ephemeral CA/leaf chain and rejects the wrong hostname
(-67602), an expired certificate (-67818), and an untrusted root (-67843). OpenSSL
generates these fixtures in the run directory, removes the private keys after
conversion, and installs nothing in any trust store. Explicit anchors and the
future verification date apply only to individual test SecTrust objects. The
separate `NetworkProbe.m` uses ordinary NSURLSession authentication and the
runtime's system anchors. Relevant upstream control flow appears in
[Apple's Security XPC client](https://github.com/apple-oss-distributions/Security/blob/main/OSX/sec/ipc/client.c)
and [trustd entry point](https://github.com/apple-oss-distributions/Security/blob/main/trust/trustd/trustd.c).

Native iOSSupport on the test machine exposes UIKit 18.7 and an AGX Metal
device. The newer Simulator runtime exposes UIKit 26.0.1 and `MTLSimDevice`,
which forwards GPU work to the host. Replacing Simulator Metal with the host
Metal framework is unnecessary for these measured workloads.

## Keychain and Simulator entitlement metadata

`keychain` runs the installed runtime's securityd and exposes only its main
`com.apple.securityd` listener. `SecSetCustomHomeURL` directs its database to
the owned `HOME/Library/Keychains`; no host keychain or iCloud account is used.
Securityd's other listeners remain anonymous and unexposed. It starts last
because it begins looking up its TCC peer immediately after listener activation;
the broker can then serve the complete selected endpoint array. The local
keychain workload succeeds with every other runtime service absent.

The probe uses generated values and two application identities. It verifies
CRUD, duplicate rejection, persistence across securityd/client restarts,
access-group separation, and a persisted software EC key's signature behavior.
A probe without application entitlements is rejected with -34018. These checks retain
Apple's SecItem/SecKey implementation and entitlement decisions; no operation
result, access-group check, or key is synthesized by the broker. They do not
establish Secure Enclave, biometric, passkey, or iCloud behavior.

An Xcode 26 Simulator control build puts application entitlements into
`__TEXT,__entitlements`, while its host code-signing entitlement dictionary is
empty. Placing device-style claims into an ad-hoc host signature instead caused
AMFI to terminate the probe before main. The runner embeds the Simulator
section at link time. Runtime [SecTask's entitlement reader](https://github.com/apple-oss-distributions/Security/blob/main/sectask/SecTask.c)
uses the Simulator entitlement-blob path; keychain storage paths are described in
[Apple's Security file-location code](https://github.com/apple-oss-distributions/Security/blob/main/OSX/utilities/SecFileLocations.c).

For a converted executable that lost its original entitlement declarations,
`embed_simulator_entitlements.py SOURCE ENTITLEMENTS OUTPUT` copies a thin arm64
iOS Simulator executable and adds the supplied XML section using existing zero
padding in the header and at the end of `__TEXT`. It preserves code/data offsets,
adjusts later symbol section ordinals, refuses existing entitlement sections,
relocation tables or insufficient padding, and never edits
the source. It is not a general Mach-O relinker or application converter.
Extract the original app's declarations with `codesign -d --entitlements - --xml
/path/to/Original.app`, save that plist locally, run the helper on the disposable
converted executable, replace that copy's executable with the output, then
ad-hoc sign the converted bundle. This supplies Simulator metadata, not host
privileges. Do not include app entitlement files in the repository.

An externally supplied executable processed by the embedding helper passes
real keychain CRUD and persisted EC-signature checks without link-time
entitlement sections. The application service list includes keychain; rendering
probes retain their smaller arrays. Per-application entitlement data stays local.

In that run, securityd's physical footprint was 16.7 MiB after app initialization.
A 10-second idle `proc_pid_rusage` sample measured no CPU-time increase. This is
an observed local-service cost, not an active authentication benchmark. All
fifteen default workloads plus the application and GLES-window cases pass with
the additional endpoint slot. The keychain deletion control still fails.

## PhotoKit and LaunchServices

`photo-status` asks the real PhotoKit API for authorization against a fresh
runtime tccd database, then repeats in new owned processes with explicit allow
and deny fixtures. `photo-roundtrip` grants only `io.iosuse.runtime-photo-probe`
access to the generated test image in that run's isolated
`HOME/Library/TCC/TCC.db`. The separate `--app --photo-fixture` workflow uses this
probe to seed the disposable library, then leaves the supplied app's permission
undetermined so it can request consent itself. Neither
workflow accesses personal photos, a host TCC database, or an existing Simulator.
PhotoKit's distinction between authorization and library access is described in
[Apple's PHPhotoLibrary documentation](https://developer.apple.com/documentation/photos/phphotolibrary).

Runtime assetsd creates `Media/PhotoData/Photos.sqlite` under the owned HOME.
The image probe generates and decodes a PNG, creates an asset, fetches it with
matching dimensions, and reads identical original bytes. Its `[tcc, photos,
notify, launchservices]` array passes; all four service deletions fail at their
respective API boundary. Without notifyd, assetsd throws while subscribing to
photo-library changes (`notify_register_dispatch` status 9).

The earlier `PHPhotosErrorInvalidResource` 3302 failure came with PNG incorrectly
failing the system's image-type conformance check. The runtime's own lsd restores
that type data through its `com.apple.lsd.mapdb` interface. Other lsd listeners
remain anonymous and unexposed. `LaunchServicesContext.m` supplies its system
and user container paths and secure-preference URL under the owned HOME, avoiding
containermanagerd. The broker also supplies runtime version/build values from
that runtime's `SystemVersion.plist`; those values alone did not fix PNG typing.
No type relation, image validator, or database query result is replaced. An
attempt to create a process-local LaunchServices database did not restore types
and reached daemon-only application-protection assertions; it is not used.

With `--present`, `TCCContext.m` supplies the actual bundle's display name when
missing and routes tccd's `com.apple.SBUserNotification` lookup to an anonymous
Mach port in the existing host broker. `HostUserNotifications.m` displays the
request in an AppKit alert and returns the clicked button's original response
number. Runtime CoreFoundation still creates the notification object, owns the
reply callback, and delivers the result to tccd; the host does not write grants
or replace authorization results. This transport follows the request/reply
layout in Apple's [CFUserNotification source](https://github.com/apple-oss-distributions/CF/blob/main/CFUserNotification.c),
checked against the installed runtime's actual requests. It adds no daemon.

The measured Photos dialog maps response 0 to Don't Allow and response 2 to
Allow Full Access. Response 1 requires the Photos selection extension, which
this host does not load; Limit Access is visibly disabled. Other extension
interfaces and permission categories are not established by this experiment.
Fresh-home probe runs verified both enabled buttons through native mouse input:
PhotoKit returned authorized (3) or denied (2), tccd persisted the corresponding
grant/refusal, and a new runtime process read the same status. Clicking disabled
Limit Access produced no database entry. Quitting with an unanswered request
also reclaimed the client, tccd, and native alert. These are API/database and
input-path observations, not proof of visibility on the locked physical display.
Without `--present`, the original missing-service error remains: creation fails
with status 5 and PhotoKit returns denied without recording user refusal.

No SpringBoard, cloudphotod, photoanalysisd, or mediaanalysisd is started for
these image probes. This measures basic local image operations; other photo
features and the full application's minimum service array remain unverified.

## GLES editing boundary and ANGLE

Without the optional ANGLE adapter, the converted external application reaches its local
album and displays the generated 1024×768 image. Selecting it raises
`Create texture failed` in its offscreen GLES surface. `GLESProbe.m` (`--cases gles-surface`)
reproduces `CVOpenGLESTextureCacheCreateTextureFromImage` returning -6683 for a
valid BGRA IOSurface-backed pixel buffer, with and without the GLES compatibility
creation attribute. Ordinary GLES drawing still produces correct pixels, but
reports `Apple Software Renderer`. Starting Metal/IOSurface/compiler services
does not turn that GLES implementation into a hardware renderer.

The runtime already contains WebKit's `libANGLE-shared.dylib`. `ANGLEProbe.m`
loads its exported EGL/GL entry points and selects the Metal backend. It creates
an ES 3 context, imports a CVPixelBuffer-backed IOSurface as an EGL pbuffer,
binds it as a GLES texture, verifies the original red pixel, and draws a green
triangle using compiled GLSL shaders. After releasing the texture binding, it
verifies green pixels across the entire original buffer. Renderer identity,
compiler routing, framebuffer completeness, and actual pixels are observed;
no app rendering code or Apple library is copied into this repository.

This follows ANGLE's [Metal display extension](https://github.com/google/angle/blob/main/extensions/EGL_ANGLE_platform_angle_metal.txt)
and [IOSurface client-buffer extension](https://github.com/google/angle/blob/main/extensions/EGL_ANGLE_iosurface_client_buffer.txt).
The latter describes special read/write handling on Simulator: pixel agreement
alone does not establish an absence of internal copies.

`ANGLEAdapter.m` now supplies an optional client bridge. It associates EGL
contexts with the original EAGL objects and sharegroups, forwards typed GLES
calls through pointers resolved once at startup, and manages BGRA IOSurface
textures behind the CoreVideo cache APIs. The generator reads the installed SDK,
not an app's imports; generated SDK declarations stay in the disposable build.
Missing ANGLE entry points stop with a diagnostic rather than calling a different
renderer. No per-call symbol lookup or process-wide render queue is introduced.
The shared buffer is released from EGL before CPU access and rebound afterwards;
this is a synchronization/copy boundary, not a zero-copy guarantee.

An additional upload difference matters for existing clients: Apple's
[BGRA extension](https://registry.khronos.org/OpenGL/extensions/APPLE/APPLE_texture_format_BGRA8888.txt)
allows RGBA internal format with BGRA source bytes, whereas the
[EXT variant](https://registry.khronos.org/OpenGL/extensions/EXT/EXT_texture_format_BGRA8888.txt)
requires matching BGRA tokens. Translating that parameter, without changing the
bytes, allows the original runtime GLKit loader to upload the test image through
ANGLE. A premultiplied-last bitmap independently fails GLKit decoding even on the
original software renderer; the accepted premultiplied-first BGRA bitmap isolates
the upload difference. The loader itself is unchanged.

The drawable bridge provides RGBA8/RGB565 storage for a CAEAGLLayer-backed
renderbuffer. Presentation uses a GPU blit from that retained renderbuffer into
an ANGLE window surface hosted by a CAMetalLayer child. It restores the caller's
framebuffer and scissor state, retains no app renderbuffer in its private read
framebuffer between presents, and removes the Metal layer when its public
renderbuffer is deleted. It introduces no CPU pixel readback or rendering timer.

ANGLE's [Metal window-surface implementation](https://github.com/google/angle/blob/main/src/libANGLE/renderer/metal/SurfaceMtl.mm)
uses CAMetalLayer. That layer still requires CoreAnimation transaction delivery:
An external GLES render thread has neither a RunLoop nor a per-frame autorelease-pool
drain. Its renderbuffer contained the correctly drawn photo while the composed
window remained black. Flushing that thread's pending transaction immediately
made the image visible in the same process. The bridge now flushes background
presentation transactions and retains UIKit's automatic main-thread commit.
Apple documents explicit [transaction flushing](https://developer.apple.com/documentation/quartzcore/catransaction/flush())
for threads without a RunLoop.

`GLESWindowProbe.m` models that long-lived thread. Its observer samples the
already-published display without updating or flushing the view tree; the
previous presentation implementation fails with four black quadrants. A GCD
queue or an observer that prepares the layer tree can conceal this boundary.
The corrected ES 3 RGBA8 path passes both rendering phases and resource deletion. The
existing prepared-window capture remains available for its earlier diagnostics.

ES 1, sRGB/timed EAGL presentation, general CoreImage GLES use, non-BGRA CoreVideo
formats, concurrent CPU access while another thread owns the cache context, and
complete CoreVideo object-type compatibility remain outside this measured
bridge. Color measurements must account for the app's automatic editing effects;
active editing performance still needs investigation.

## Application startup: remove processes, retain required functions

The application diagnostic uses the same directly spawned process with the three
rendering services. Four small adapters supply the measured startup functions:

- `LocalDisplay.m` supplies a fixed 402×874 logical screen at 3× through actual
  FBS display configuration/mode objects. It initializes GraphicsServices and
  updates UIKit's initially zero-sized screen through UIKit's implementation.
  Its FBS configuration is built from the local CADisplay. FBS's synthetic
  "virtualized" configuration deliberately returns no CADisplay; it let static
  screenshots work but crashed the home video's MTKView display-link creation.
  The CA display uses the runtime's main-display name, `LCD`, and refreshes display
  discovery after creation. The application probe checks actual screen-bound
  display-link callbacks with increasing timestamps (31 in a one-second run).
  It supplies the screen before `UIApplicationMain`, since legacy AppDelegate
  initializers can create their window before BKS starts. The matching model and
  product class are supplied for camera-capability enumeration.
- `LocalSceneHost.m` hosts an anonymous workspace peer inside the app. It accepts
  connection setup, the scene handshake, and client-settings notifications,
  including BoardServices batches. Without batch handling, the peer disconnects
  and the app can lose its foreground scene. `SceneBootstrap.m` delivers one
  scene through the runtime's `FBSWorkspaceScenesClient`; UIKit invokes the app's
  delegate. No code calls AppDelegate directly. A legacy window without a scene
  is assigned the unique connected window scene when it becomes key and visible.
- `LocalCompositor.m` starts the runtime's actual CoreAnimation render server and
  a 1206×2622 `CAWindowServerVirtualDisplay`. The server's `local` option avoids
  display discovery and launchd registration. `CA_FORCE_LOCAL_SERVER` is set at
  process launch so display links also find it. UIKit's non-displayable contexts
  are embedded through `CALayerHost` under one displayable parent, scaled from
  points to 3× pixels. Simply supplying a context's render-server port was enough
  for a layer snapshot, but not for full-display capture or a continuous stream.
  `IOSUseCopyWindowSurface` lays out/displays pending layers, requests a bounded
  rendering wait, then takes a whole-display `CARenderServerSnapshot`. Snapshot
  pixels remain the check when the context does not acknowledge that wait.
- `LocalInput.m` supplies an actual BoardServices initiating connection for
  `BKHIDEventDeliveryManager` and accepts delivery-rule registration. Unsupported
  operations close the peer. `TouchInput.m` separately constructs a single
  IOHID-backed UITouch/UIEvent sequence and calls `UIApplication.sendEvent:`.
  It makes the hit window key before delivery. It does not call app button
  actions directly or replace a complete backboardd HID dispatcher. Keyboard,
  multitouch, and general gesture compatibility remain unverified.

All four adapters load only in the application, never in the runtime services.
The scene diagnostic uses private selectors, one named workspace ivar, and a
one-second scheduling delay. It supports one initially empty scene source.

Removing the Metal endpoint allows this simple CoreAnimation workload to fall
back to software rendering. A further run with only `iosurface` also passes,
confirming that this path needs no compiler child. Removing the compiler
while Metal remains enabled aborts during specialization; removing IOSurface
prevents the destination allocation (exit 40). Thus the hardware path needs all
three services, but those dependencies must not be generalized to every UIKit
view. Removing display or input registration traps during startup; removing compositor
reaches the runner timeout, and removing scene delivery reaches the 15-second
launch deadline.

The generic application reaches `didFinishLaunching`, completes
`makeKeyAndVisible`, and verifies both its software view drawing and a separate
GPU-composited IOSurface. The current GPU snapshot contains 2,048 white,
339,209 blue, and 9,776 green pixels. First-capture timings include shader work
and the bounded acknowledgement wait; they are not frame-rate measurements.

`FrameStream.m` uses the runtime's `CAContentStream`, with the stable parent
context as its filter. An active stream rejects context-list updates. Streaming
starts after UIKit has assigned its child roots and the parent has rendered;
starting earlier crashed the virtual display's render thread. The virtual display
already owns a refresh loop, so there is no additional `renderForTime:` timer.

The stream caps delivery at 30 Hz, downscales the 3× display to 804×1748 for a
2× native window, and uses a three-surface pool. Mach messages transfer IOSurface
rights to `HostWindow.m`, whose CALayer displays the same shared buffers. The
currently displayed frame stays leased until a native transaction replaces it;
the host then acknowledges the old surface so the runtime can reuse it. Apart
from one-shot diagnostic PNGs, this path does not map pixels or encode images on
each frame. Idle notifications without a surface are ignored. Mouse down, drag,
and up return through a private Mach port to the app's main thread.

Before network support, a roughly four-minute external application run delivered
7,290 frames with at most three outstanding (usually two). After replacing the
video library, the renderer creates `nv12_rgb` pipelines and the captured home
banner changes with playback, without the prior platform-rejection loop. In one
later ten-second sample, app/broker CPU time grew by 6.47/1.36 seconds; compiler
and trustd CPU time did not grow. App RSS reached about 1,730 MiB. RSS includes
shared pages and is not additive physical memory. The earlier sample contained
H.264 software decoding and GIF/WebP decoding activity; media execution still
needs investigation. These are different animated Dev home feeds under a locked
macOS session, not a controlled performance comparison. Removing the shader
errors has not established acceptable MVP performance. Occlusion suspension,
display-rate policy, context retirement/order, and complete window lifecycle
also remain unfinished.

Before shared-cache selection was added, a 10.07-second sample on the actual
external application's export-result page consumed 0.55 seconds of app CPU time and 0.02
seconds of broker CPU time: about 5.5% and 0.2% of one core. The six service
children had no measurable CPU-time increase at `ps` resolution. This was an
idle, occluded window; it does not measure active editing, visible presentation,
or improvement against the different home-feed workload above.

The large helper footprints led to a loader comparison. For the same runtime
26.0.1 build, the standalone notifyd had an 86.2 MiB physical footprint, including
82.9 MiB of dirty file mappings; an existing Simulator's notifyd was about
11.6 MiB. The latter supplied `DYLD_SHARED_CACHE_DIR`, which the broker had
omitted. Selecting the matching installed cache replaces those individual
library mappings with the runtime's cache; vmmap confirms its shared-cache
segments in the new process. No additional service or daemon retirement is
needed for this saving.

Per-process `proc_pid_rusage(RUSAGE_INFO_V4)` readings on the external application's export
result page, rounded to MiB:

| Process | Before cache selection | With matching cache |
| --- | ---: | ---: |
| notifyd | 86 | 4 |
| MTLCompilerService | 94 | 5 |
| trustd | 97 | 12 |
| tccd | 94 | 14 |
| lsd | 101 | 16 |
| assetsd | 118 | 27 |
| External application | 739 | 523 |
| Native broker | 288 | 426 |

These are per-process accounting values, not an additive unique-memory total.
The repeated import/rotation/undo/export flow retained identical decoded output
pixels. The app supplied different recommendation/promotion layouts in the two
runs, so app/broker changes are not a controlled attribution to the cache alone.
A 10.01-second idle sample after the cache change used about 0.47% of one core
in the app and 0.13% in the broker; each helper used at most 0.002%. Active
editing, visible-window performance, and repeated window/resource retirement
still need measurement.

The earlier sixteen-workload cache check passed. PhotoKit's four service
deletions retain their expected failures. With runtime-bundle metadata absent,
the loader-default fallback still passes the real Metal clear pixel check.
No new daemon, per-frame CPU readback, or extra render timer was introduced.

A later app-session experiment exited only the owned `lsd` after import and
export had initialized its clients. That child had a 100.69 MiB physical
footprint. The still-running app reopened its album, imported a newly generated
JPEG, and saved another 768×1024 JPEG while `lsd` remained exited. The new export
differed from the imported JPEG by 0.28/255 on average, consistent with another
JPEG encode. A fresh-process control then initialized the temporary library
with `lsd`, exited that setup group, and launched the app and its services without
`lsd`. Import still reached the editor, but export failed with PhotoKit error
3302 and created no new asset. The mapped type data held by an initialized client
does not make the service dispensable for new clients. The selected service
remains enabled; database changes and broader lifecycle management are unverified.

The snapshot SPI and its option layout also appear in
[WebKit's QuartzCore declarations](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/PAL/pal/spi/cocoa/QuartzCoreSPI.h)
and [WKWebView's snapshot implementation](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/ios/WKWebViewIOS.mm).

## Retarget a device Metal library

A Mach-O platform change does not retarget bundled Metal AIR. For a library with
uncompressed iOS AIR modules, rebuild it into a disposable converted app copy:

```sh
python3 experiments/simulator-runtime/retarget_metallib.py \
  /path/to/Original.app/ExampleShaders.metallib /path/to/Converted.app/ExampleShaders.metallib
codesign --force --sign - --preserve-metadata=entitlements /path/to/Converted.app
```

The converter leaves its input unchanged, preserves the AIR version and minimum
iOS version while adding the Simulator target, and uses Xcode's `metal-opt` and
`metallib`. Temporary modules are removed, and failed linking does not replace
an existing output. Both older `air64` and Xcode 26's versioned AIR target are
covered by real compilation. The `retarget-metallib` workload first requires the
device pipeline to fail, then verifies a completed GPU command and result 42 from
the converted library. No application or Apple shader code is included here.

This is not a whole-app converter. Mach-O platform conversion remains separate;
compressed AIR, embedded libraries, and dynamic-linking containers need further
work. A local multi-module library containing repeated `air.dyld_lib_table`
symbols still fails relinking. The converted library must replace the corresponding resource in the disposable
application copy; generating a sidecar alone does not change the loaded shader code.

## Shared Metal buffer textures

Apple documents private storage for Simulator linear textures. The actual
Apple M4 host and the existing Simulator Metal transport also support a shared
buffer's linear texture. `MetalBufferContext.m`, selected with `metal-buffer`,
keeps that existing allocation and transport. The broker reports whether its
real GPU has unified memory and supports the Apple GPU family; only then does
the adapter scope MTLSimBuffer's texture-creation call. Within that call, it
allows only the specific private-storage restriction to continue. Other Metal
failures retain their normal handling, including invalid descriptor rejection.
No installed framework is modified, and the buffer and texture still report
their real shared storage, buffer identity, byte offset, and row stride.

`linear-buffer` uses `metal compiler` to check R8, RG8, RGBA8, BGRA8, and a 1080p
luma plane. Eight rounds per texture check later CPU writes, GPU sampling, GPU
writes back through the texture, and untouched offset/row padding. A separate
child verifies that a zero-width descriptor remains rejected. Removing either
service or the adapter fails the selected workload. Measured texture-creation
calls were 0.023–0.085 ms in this run; this small sample is not a whole-video
performance measurement. The adapter adds no pixel copy, staging texture,
render loop, or service. Existing decoder and framework work still remains.

For an app-level reproduction, a temporary diagnostic selected the supplied
player's existing software-decoding option. With the adapter, the external application rendered video, created at least 6,000 shared R8 textures (1920×1080 luma
and 960×540 chroma), and continued running. A process sample confirms the actual
software-decoding upload path. Removing only the adapter restored the
same Simulator assertion and SIGABRT. The diagnostic software-decoding override
is not part of the implementation; normal decoder selection is retained.
This adapter is verified on the stated M4/runtime combination, not all Metal
features or other Simulator/host GPU combinations.

## Keyboard input

`KeyboardContext.m` is linked into the app's existing input adapter. UIKit normally
uses a remote KeyboardManagement service; when that connection fails, its own
failure handler resigns the active UITextView. Selecting UIKit's local keyboard
implementation preserves real focus and also presents its software keyboard in
the app. No KeyboardManagement, text-input, or Assistant daemon is added.

The standalone environment does not host speech services. Its MobileGestalt
boolean query reports the `dictation` capability as unavailable, leaving other
capabilities unchanged. Advertising dictation triggered repeated Assistant
availability callbacks on the main queue: a text-only probe consumed about 62%
of one CPU core. Disabling that capability stopped the observed callback loop.
Merely writing a disabled Dictation preference did not stop it; advertising a
hardware keyboard through notifyd also did not resolve it. Neither extra setup
is required by the selected text-input case.

AppKit key events and committed-text callbacks send UTF-8 or deletion messages
through the existing private input port. UIKit finds its first responder through
the normal action chain, checks the UIKeyInput contract, and forwards edits through
UIKeyboardImpl's input pipeline. Directly calling the responder's insertText:
rendered characters but bypassed UITextField's shouldChange delegate; the keyboard
pipeline preserves that validation. The bridge does not assign view text or
manufacture editing callbacks. The host sends pointer, text, and frame-release
messages through one serial background
queue. Kernel queue backpressure waits there; the earlier nonblocking sends lost
two deletion events in the keyboard burst. AppKit's main thread remains available
while the app consumes input.

The `text-input` case exercises native character/backspace/return events, committed
Chinese text, preserved spaces, a family emoji deleted as one grapheme, focus
transfer from UITextView to UITextField, and a delegate rejecting an edit. It
uses only `metal compiler iosurface`, including its visible runtime keyboard.
After unlocking the Mac, this case passed again and the native-window screenshot
shows both edited text controls and the runtime software keyboard inside the
AppKit window. Native IME composition and manual physical-keyboard interaction
remain unverified.

## External application validation

A disposable, converted arm64 application was launched with iOS runtime 26.0.1
without booting a Simulator. Its UIKit content reached an AppKit window. The
measured workflows used generated images and an isolated PhotoKit library:
import, rotation, undo, text insertion/deletion, and JPEG export. Native consent
was requested through the real TCC callback rather than a preconfigured app grant.
An untreated 1024×768 export had mean source RGB error 0.58/255 and 99th percentile
3/255. These observations cover one external application, not general application
compatibility. Application identities, resources, logs, screenshots, entitlement
values, and business-specific diagnostics are intentionally excluded.

The reusable experiments retain the platform findings: associate a legacy window
with its local scene, use a real local CADisplay for display links, release ended
touches so dismissed windows do not intercept later input, publish background
render-thread transactions, and preserve shared Metal buffer/texture semantics.
No application-name branch or application-specific data replacement is used.

An earlier interpretation of idle captures as missing static content was corrected
by checking the original pixels. Samples spanning 282 and 312 seconds preserved
the image region. An independent UIKit probe retained twelve static text rows
while another layer animated across captures 177 seconds apart. No speculative
surface-pinning change was retained. These are sampled-frame observations, not
proof of every frame or every application lifecycle transition.

Unlocked native-window captures verified presentation of both the UIKit probe
and external application. HTTPS certificate checks, keychain persistence, and
PhotoKit read/write have separate executable probes. General editing, online
features, other color spaces, and independent WebKit hosting remain unestablished.

Private touch signatures were cross-checked against the runtime and
[KIF's UITouch additions](https://github.com/kif-framework/KIF/blob/master/Sources/KIF/Additions/UITouch-KIFAdditions.m)
and [IOHID construction](https://github.com/kif-framework/KIF/blob/master/Sources/KIF/Classes/IOHIDEvent%2BKIF.m).

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

Device-app retargeting also involves Mach-O platform metadata, embedded Metal
AIR targets, and potentially OpenGL ES. Keep untested app services out of the
"unnecessary" category until a relevant workload exercises them.

Standalone UIKit emits a duplicate `_NoAnimationDelegate` warning. Without the
IOSurface endpoint, it also emits `IOSurface not available`; the software PNG
still contains the expected text. An earlier visual interpretation of that
warning as missing text was corrected by decoded pixel evidence.
