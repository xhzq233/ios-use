# Mac Backend (PlayCover-derived)

## Scope

The source-build-only Mac backend runs a managed, unencrypted arm64
iPhone App on Apple silicon without the PlayCover GUI. It directly ports the
non-GUI preparation graph from pinned PlayCover sources and injects one
Mac Catalyst Runtime containing the pinned PlayTools compatibility and touch
code.

The public lifecycle is intentionally small:

```bash
./ios-use config --mac
./ios-use start --mac --app /path/to/Source.app --log
./ios-use status
# normal ios-use UI, screenshot, capture, URL, and log commands
./ios-use stop
```

`config --mac` is the only public initialization path for the stable
Mac-backend signer. It is run once per macOS account, not once per
`IOS_USE_HOME`. The first run creates and trusts the identity with one macOS
authentication. If authentication is cancelled, the binding remains on the
same identity and retrying the command safely resumes trust configuration.
Ordinary start only resolves the existing identity and fails with an explicit
`config --mac` instruction when it is missing or still needs trust. Other
unhealthy states fail closed without start-time mutation.

`start --mac --reuse` explicitly reuses the most recent verified generation
from the current `IOS_USE_HOME`. There are no public `playcover inspect`,
`prepare`, or `verify` commands; those are internal start steps and test
entry points. After rebuilding a source App, pass `--app` again; `--reuse`
deliberately does not inspect, hash, or otherwise depend on the original source
path.

`--log` is optional. It asks the CLI to create a unique owner-only file under
`$IOS_USE_HOME/logs/mac`, then sends the already-open file descriptor to the
injected Runtime over the authenticated Runtime socket. The Runtime verifies
the descriptor identity before redirecting stdout and stderr; it never opens a
Home path itself. Start prints the path, and `status` reports it as `stdio log`.
The file is
retained after a successful stop, an App crash, or a failed launch so it remains
usable as evidence. The flag and path are per-session state only; they do not
participate in source inspection, the Runtime hash, or the generation key. This
capture begins at the Runtime's earliest controllable C constructor.
Objective-C `+load` and dyld diagnostics that precede constructors are outside
its contract; exact-PID unified logging remains a separate source.

## Fixed Device Contract

`swift-cli/Sources/IOSUsePlayDevice/include/IOSUsePlayDevice.h` is the single
compile-time authority used by the Swift host, Objective-C Runtime, PlayTools
adapter, AppKit bridge, and tests:

| Field | Fixed value |
| --- | --- |
| Product type | `iPhone16,2` |
| Portrait logical screen | 430 x 932 points |
| Scale | 3x |
| Virtual native raster | 1290 x 2796 pixels |

The Runtime does not read a device profile or bootstrap file. Fixed geometry
is not persisted independently in session or prepared-cache state. A header
change alters the Runtime build hash and therefore selects a new
final-generation identity naturally.

The outer AppKit surface is an opaque, rectangular, resizable system window.
Its public title bar displays `CFBundleDisplayName`, falling back to
`CFBundleName` and then the bundle ID. UIKitMacHelper's scene-owning
`UINSWindow`/`NSWindow` subclass is retained because moving the scene's view
tree into a second plain `NSWindow` backgrounds the UIKit scene. After
validating the private AppKit method signatures, the Runtime installs the two
resize compatibility methods only on the exact current `UINS*` class, makes
all four resize edges available, accepts valid proposed host sizes, and
applies a 430:932 content aspect ratio. A missing selector, mismatched ABI, or
partial edge mask fails readiness. It leaves `_startLiveResize` untouched and
does not create a second mirror/forwarding window.

UIKit is fixed by `UIWindowScene.sizeRestrictions` plus the observed
430 x 932 `UIWindow.bounds`. The Mac `effectiveGeometry.systemFrame` includes
the system title bar, so the Runtime deliberately neither forces nor treats
that outer frame as the device canvas.

If UIKitMacHelper publishes a first integral-point content size before the
aspect policy settles, the Runtime performs one bounded, asynchronous
bootstrap `setContentSize:` to the already resolved aspect-fit size and
verifies it on later probes. This touches neither the window position nor
UIKit bounds, and it is permanently disabled for that host before user resize
begins. System-restored sizes already within half of one physical pixel are
accepted unchanged; in particular, a restored 316 x 685 content size is not
normalized.

The content view has no transparent spacer or synthetic chrome. It applies
only one uniform display scale and origin to the inner render canvas; the
canvas bounds and UIKit scene remain exactly 430 x 932 points. Input removes
that origin and applies the inverse scale before target hit testing, while
title-bar and outside-canvas points are rejected. A host cannot shrink below
the explicit 0.5x complete-canvas policy. One layout records both the ideal
uniform canvas and its nearest backing-pixel rectangle. Rendering and inverse
input use the ideal transform; CGWindow projection and capture use the
backing-pixel rectangle. Runtime and CLI readiness validate their agreement
with `0.5 / backingScaleFactor` points. A source raster may differ from its
reported logical extent by at most half a physical pixel, but all four crop
edges must map exactly onto that source's own pixel grid; an ambiguous edge
fails closed instead of rounding outward into host decoration or independently
dropping the first/last row.

The full device frame is the target App's complete 430 x 932 logical rendering.
The Runtime does not create a fallback system-chrome window or draw synthetic
Dynamic Island, status glyphs, time, battery, or Home Indicator. Safe-area
compatibility uses the compile-time iPhone16,2 contract of 59/0/34/0 points.
The provider hook is installed pre-main, before the App can cache its first
Safe Area or status-bar value. It applies the fixed device values to the
eligible primary App window in both foreground-active and
foreground-inactive states while preserving the App's own
`additionalSafeAreaInsets`. Scene/window observation may become ready later,
but it does not install or repair the required hook. Safe areas never crop the
output or consume App touch events.

## Architecture and Session

```text
ios-use start --mac (--app <source-or-prepared.app> | --reuse) [--log]
  -> PlayCoverManagedAppService
     -> source classification or managed-generation selection
     -> account-global content-addressed final lookup or construction
     -> current Home last-generation selection
  -> PlayCoverService
     -> pinned PlayCover prepare graph and full verification
     -> one bounded integrity verification immediately before launch
     -> pinned-shape session App facade under ~/Applications/ios-use
     -> NSWorkspace facade launch with exact environment and PID
  -> IOSUsePlayRuntime.framework
     -> pinned PlayTools platform/geometry/keychain hooks
     -> opaque resizable AppKit host, fixed canvas, and complete App compositor
     -> DOM, wait, touch/input, compositor, URL, and diagnostics
     -> owner-only AF_UNIX listener
  -> PlayCoverRuntimeClient
     -> direct authenticated request; no intermediate server
```

The only runtime identity is one random `sessionID`. Start passes the session
ID and derived socket path through the launch environment. The Runtime binds
that socket and never reads a sidecar configuration file. NSWorkspace overlays
launch variables rather than replacing the caller environment, so ios-use
explicitly clears every inherited non-allowlisted key before launch; shell
credentials are never forwarded to the target App.

For `--log`, the CLI creates the file without following symlinks, verifies a
regular 0600 single-link file owned by the current user, and sends its file
descriptor plus device/inode evidence with `SCM_RIGHTS`. The Runtime accepts
that bootstrap only from the authenticated session peer, revalidates the
descriptor, then redirects file descriptors 1 and 2. Runtime hello reports
that exact outcome, and start does not commit the session unless it matches.

The launch facade is a real `.app` directory whose top-level children are
symlinks to the immutable prepared App, matching pinned PlayCover's
`createAlias` shape. Each random session gets a collision-free facade name.
An NSWorkspace callback may establish rollback ownership only for a new process
that reports the exact session facade and prepared executable; it cannot by
itself commit a session. A newly observed PID grants no ownership. Polling may
challenge a new process whose bundle URL is either that facade or the canonical
immutable prepared App, because LaunchServices can expose the latter after
resolving the facade. The process must retain the exact prepared executable and
authenticate this start's random session, socket, PID, bundle, and executable
through Runtime identified ping before a prepared-App path may be claimed.
Final Runtime `hello` must still pass before session commit.
An account-wide bundle start lock and live-process census reject an already
running copy of the same bundle ID before launch. ios-use neither attaches to
nor terminates that existing process, and it has no direct-spawn fallback.
The launch journal has exactly three transient phases:
`intent -> owned -> driverLockCommitted`. `intent` is durable before the single
NSWorkspace submission; `owned` requires an exact callback or authenticated
Runtime owner; `driverLockCommitted` is reached only after that owner becomes
the active session, then the journal is removed. A submitted launch that never
yields an exact owner keeps both its intent and facade and returns
`mac_pending_launch_unresolved`; later commands do not guess that a delayed
LaunchServices completion is impossible. There is no automatic unresolved-
intent recovery or cross-process cleanup.
Confirmed stop and rollback of an exact owned process remove its facade.
Launch discovery uses the full validated `start --timeout` value rather than a
shorter hidden deadline.

Each connection carries one four-byte big-endian length-prefixed JSON request:

```json
{
  "requestId": "unique-request-id",
  "sessionID": "active-session-id",
  "command": "dom",
  "arguments": {},
  "refreshAlertStatus": true
}
```

The response echoes the request ID and session ID and contains either
a command-specific typed payload or structured error. A public command's first
Runtime request sets `refreshAlertStatus`; later internal requests from the same
CLI invocation do not repeat the refresh. The response reports the measured
alert-refresh duration plus the fresh interaction state; command timing remains
internal to `cli.log` and is not added to public output.
Host-only lifecycle and internal discovery requests omit the optional field
entirely; only the one fresh public-command request encodes it as `true`.
CLI and Runtime identity are bound by the exact Runtime build hash and prepare
revision; there is no schema negotiation or old-Runtime fallback.
`hello` is a control-plane response only. It returns process identity,
capabilities, stdio state, required pre-main hook state, and a cached UI-state
snapshot without synchronously entering the UIKit main thread. `start` commits
as soon as that control identity is healthy, even while UI state remains
`initializing`. An installed required hook that has not yet received its first
eligible UIKit call remains `waiting-for-required-hook-observation`; it is not a
permanent hook failure. UI commands then fail immediately with typed
`runtime_ui_not_ready`, `runtime_ui_backgrounded(reason)`, or
`runtime_ui_failed` errors until the Runtime publishes `ready`. `waitFor` is the
exception: it polls readiness within its own requested timeout and returns the
last typed readiness error only if that deadline expires. `diagnostics` retains
the complete observational payload used by
`status`; ordinary DOM, screenshot, wait, and action responses contain only
their command result. Request and response sizes, absolute deadlines, and
one-request-per-connection behavior are bounded. The CLI authenticates the
peer UID and PID plus the live executable at the Unix transport, then verifies
bundle, prepared generation, and Runtime identity during handshake and status.
A mutation whose bytes may have reached the Runtime is never replayed
automatically.

UI availability follows the real scene-owning host surface, not
`NSApplication.isActive` or key-window status. A visible window on the active
Space remains automatable while non-key or occluded, and ios-use never activates,
orders front, unhides, or changes the user's Space. A backgrounded/disconnected
scene, hidden or minimized window, inactive Space, or unavailable display
returns retryable `runtime_ui_backgrounded` with that exact reason while
control `status` and `stop` remain available. Screen lock is not inferred as
background by itself: if WindowServer keeps the same live surface, commands may
continue; if the surface disappears, the same typed gate applies.

All applicable commands keep routing to this Runtime until `ios-use stop`.
`stop` does not call a lifecycle RPC: the host revalidates the exact
generation, PID, and executable, sends termination only to that process, and
clears only matching session state. The host never probes or unlinks a Runtime
socket: on Darwin, even a live listener can return `ECONNREFUSED` when its
accept queue is full, and pathname deletion cannot be made conditional on an
inode. The Runtime owns its freshly bound random path, marks its listener
close-on-exec, and removes that path from its `atexit` and `SIGTERM` exits.
Crash/SIGKILL residue and all unknown run-directory entries remain preserved;
the next random session uses a different path. Start fails closed if its new
path unexpectedly exists. As with the generation namespace guard, this is an
owner-only cache boundary rather than a defense against a malicious process
running as the same user: the Runtime's signal-safe `unlink` assumes another
same-UID writer does not replace its bound pathname. The injected Runtime owns
the host lifecycle for this backend, so it installs the process `SIGTERM`
handler and exits with `_exit(143)` after removing that pathname.
`activateApp`, `terminateApp`, `home`, and DDI operations fail as unsupported
before touching another backend.

## Prepare, Signing, and Cache

The signer is persistent per macOS user and deliberately independent of
`IOS_USE_HOME`. Its private key and certificate live in the user's Keychain,
while the exact non-secret binding is an owner-only file at
`~/Library/Application Support/dev.ios-use/mac-stable-signing-binding-v1.json`.
Initialization is serialized by a per-user operation lock and claims the first
binding atomically. It then installs code-signing-specific user trust and
performs a real sign/strict-verify probe. A cancelled trust authentication does
not remove the binding or create a replacement, so the next explicit
`config --mac` continues with the same certificate.

All ordinary prepare, managed-selection, and start paths resolve this exact
binding with initialization disabled. They never create, rotate, or repair the
identity or modify Trust Settings. An explicit `start --mac --app` resolves and
validates the signer before routing, Home locking, source inspection, hashing,
or cache state is read. Missing and trust-required states direct the operator
to `config --mac`; replaced, expired, or inaccessible state also fails closed.

Final prepared Apps are shared by the macOS account. The fixed owner-only cache
root is:

```text
~/Library/Caches/dev.ios-use/mac/prepared/
  objects/<generation>/App.app
  locks/

$IOS_USE_HOME/mac/last-generation.json

~/Library/Application Support/dev.ios-use/homes/<home-id>.json
```

`objects` contains the only final generation for a content key and `locks`
serializes per-generation publication. Each Home keeps only its own last
generation for explicit `--reuse`; normal lifecycle commands never enumerate
other Homes. The small account support records only let the read-only `ios-use du`
command discover known Homes. Changing `IOS_USE_HOME` changes session and
configuration state, but it does not create a second final App when the
generation key is identical.

The source App is always read-only. A cold prepare creates a sibling staging
directory below `objects`, copies the source once, applies the pinned
conversion/dependency/rpath changes, embeds and injects the Runtime, removes
the copied mobile provision, composes entitlements, signs inside-out, removes
quarantine, and performs full verification. Only then does one atomic rename
publish `<generation>`. Failures remove only transaction-owned staging;
existing generations and the source are never overwritten or repaired in
place.

The immutable generation key contains:

- the complete source content hash;
- the Runtime/build content hash;
- the pinned prepare implementation revision;
- the account namespace policy hash, derived from the canonical account
  PlayChain root, the fixed UID socket root, and its policy revision;
- the signer's public-key SPKI SHA-256;
- the signer's certificate SHA-256;
- the signing-policy revision.

The namespace policy hash deliberately excludes the logical
`IOS_USE_HOME` and Home ID. It changes the generation only when the absolute
paths authorized by the final entitlement change.

Every reuse validates the immutable markers, executable and Runtime hashes,
recorded code-object inventory, strict signatures, stable signer, designated
requirement, CDHash, signing identifier, and managed-path identity. The
manifest is the single current compact cache-integrity seal: it stores only
relative paths and stable hashes/evidence and contains no source, prepared, or
Runtime absolute path. Rich source inventories, Mach-O observations, and the
entitlement differential remain in memory for the preparation result and are
not persisted. The completed marker binds the canonical manifest hash and the
critical executable hashes. Both sidecars are bounded, owner-only, single-link
regular files.

The explicit-source path builds one immutable preparation plan containing the
source inspection, Runtime hash, prepare revision, signer evidence, and
generation key. The same plan is used through final publication, and the
copied Runtime plus signer are checked again before the generation can win the
atomic publish. If another process already published the key, the candidate is
discarded and the immutable winner is fully verified.

ios-use does not garbage-collect generations, logs, artifacts, Frida development
caches, or historical Home records. Lifecycle commands access only the current Home and
never enumerate the Home discovery index. `ios-use du` is the explicit,
read-only account report. Its default output groups rebuildable cache,
persistent App data, logical Home data, and metadata/residue so the cleanup
impact is visible before a user removes anything. Each group shows allocated
size and latest descendant modification time; prepared Apps also show their
version and capability. `--json` retains raw paths, Home/session generation
references, and any incomplete-statistics warnings. The command follows no
symlink, has a bounded traversal, and does no source hashing, signing
verification, Runtime connection, recovery, or deletion. It does not write its
own `cli.log` entry. A Home is added to the small discovery index only after a
successful executable `start`.

Each logical Home keeps only its own Runtime log files under:

```text
<IOS_USE_HOME>/logs/mac/
  stdio-<session-id>.log
```

The Runtime's Unix socket is under `/private/tmp/dev.ios-use-<uid>/`; that
socket root follows the effective UID rather than `HOME` or `IOS_USE_HOME`.
The log root is deliberately Home-local. The account-global cache holds shared
prepared Apps and publication locks; Application Support holds the
discovery-only Home index and per-bundle KeyCover databases. The App
entitlement allows the account-level PlayChain root and
fixed UID socket root; Home-local log access arrives only as the verified
descriptor capability. Logical-Home operation locks serialize local session
and pending-journal mutations, while per-generation locks coordinate shared
final Apps.

A separate hermetic differential gate continues to compare the pinned
full-PlayTools Installer result with the production prepare result. It uses
disjoint test roots, re-inspects both outputs, binds the fixed source closure
and loaded XCTest identity, and publishes its attestation without overwrite.
Allowances remain reviewed inputs and cannot be generated from observed
differences. External-App characterization remains diagnostic-only and cannot
produce an acceptance decision.

## Runtime Distribution

The Runtime and pinned Frida Engine are release-built, ad-hoc-signed frameworks,
not artifacts built inside a user's mutable state directory. The Engine build
normalizes compiler-visible source paths so local source, cache, and temporary
build-root paths are not embedded. Frida-generated source maps may still vary,
so each release records the actual framework digest and size. A release contains
one Mac-backend-resources archive, SHA-256 manifest, applicable licenses, upstream
provenance, and an exact corresponding-source archive. `scripts/install.sh`
verifies the manifest before placing both frameworks under
`<prefix>/share/ios-use/mac/`, re-verifies their signatures, and never
copies executable Runtime content into `IOS_USE_HOME`. The frameworks are
read-only preparation inputs: prepare signs only managed App copies.
Installed-layout acceptance hashes both complete source frameworks before and
after fixture execution.

Runtime resolution honors a valid framework explicitly managed by an explicit
`IOS_USE_HOME`, then the adjacent development layout, and finally this stable
prefix share location. The implicit default Home is mutable session state and
is never a Runtime source, so a stale framework left there cannot shadow the
Runtime beside a development build. Account-global prepared objects are also
never Runtime sources. Changing `IOS_USE_HOME` selects different logical
session/reference/log state, but identical generation keys
reuse the same account-global final App. It does not require a second Runtime
installation or allow the installer to put mutable executable code in that
Home.

## Optional GumJS Debug Engine

`start --mac --frida --app <source.app>` validates the installed arm64 Mac
Catalyst `IOSUseFridaEngine.framework` against the pinned version, Gum commit,
Engine ABI, Agent digest, and wrapper-source closure. Its actual framework
digest participates in the generation key, so toolchain output cannot alias a
different prepared App. A genuine generation miss revalidates the resource
immediately before copying it, then performs one normal prepare/sign/publication
pass. A prepared Frida generation remains launchable through bare reuse without
re-reading that input. Base generations contain no Gum or Engine code, and
ordinary start never accesses the installed Engine or network.
There is no start-time Engine download, object cache, lock, environment override,
or compatibility path.

`ios-use debug`, `--reset`, and `--stream` use the existing authenticated
Runtime Unix socket and one in-process GumJS Agent. The Runtime does not start
Frida Server, Gadget, a TCP listener, a script watcher, or a second RPC system.
Stream connections are served independently from the serial UI command lane,
and disconnect cleanup drains in-flight callbacks before releasing their
connection context. Eval/reset operations are serialized on their own Debug
lane; the Engine's ten-second Promise deadline fits inside the CLI's
fifteen-second Runtime deadline, so a slow script neither steals the UI lane
nor continues after a shorter client timeout.

Symbol discovery deliberately remains part of the raw GumJS channel. Callers
compose `ApiResolver`, `Module`, `DebugSymbol`, and `Interceptor` inside
`ios-use debug`; the CLI does not add a symbol command, dSYM registry, symbol
cache, demangling wrapper, or automatic attachment policy. Queries stay narrow
and bounded, and raw addresses are never reused after a rebuild or new session.

The installed product does not inspect Engine exports with a host tool.
Release builds gate the exported C ABI, while Runtime loading resolves all five
required Engine functions with `dlsym` and reports the exact missing symbol.
This keeps the installed Mac path independent of developer command-line tools
without duplicating its symbol parser.

## Runtime Commands

DOM snapshots enumerate foreground scenes, z-ordered windows, UIView
hierarchy, and accessibility-container elements. They expose stable
label/value/identifier/hint/traits/state/class/hierarchy/frame fields and one
snapshot generation. Selectors follow the existing ios-use clean, merge,
match, ambiguity, traits, and `cindex` rules. SwiftUI and WKWebView use their
accessibility bridges; custom Metal/Unity content is reported as opaque when
it has no semantic nodes.

`ui-tree` is a separate, read-only Mac Runtime diagnostic. It serializes the
actual foreground UIKit `UIView` subtree, including concrete class names,
geometry, layout flags, and a small allowlist of public properties for common
UIKit controls. An optional semantic target is first resolved through one
fresh Runtime DOM snapshot, then inspected through its current backing view.
The response is bounded by caller depth (0...20), a fixed 1,000-node limit,
and bounded strings. The nested response exposes no object identity, address,
or live object registry. UI actions continue to use DOM rather than `ui-tree`.

Tap, long press, and direct swipe use the directly ported PlayTools fake-touch
backend with begin/move/end/cancel phases and monotonic timing. The Runtime
resolves selectors against a fresh snapshot, performs a UIKit hit test in
430 x 932 logical coordinates, and proves that the expected touch phases were
delivered. A semantic `swipe --to` instead walks the target scrollable in
bounded steps and rebuilds the DOM until the target is interactable. A target
missing from the DOM requires a visible `--from` anchor so the Runtime never
guesses a container. Repeated offsets, a reached boundary, or a delivered
fixed-distance swipe whose content offset did not change return typed scroll
errors instead of success. Absolute `tap x,y` points are already in the fixed
logical space and are never reinterpreted as an element-relative ratio. A
valid no-op control remains a successful delivery; callers use `--dom`,
`waitFor`, or an explicit screenshot when they require a visible result. Text
input separately verifies the exact first responder and final
text; secure, custom, or unsupported input returns a structured error. Native
AppKit alert panels are projected into the same logical canvas, but their
buttons are invoked through the panel's real target/action rather than falling
through to a UIKit touch beneath the panel. Alert dismissal and URL opening
likewise keep their command-specific disappearance/delivery checks.

Before a public Runtime command is dispatched, one lightweight fresh snapshot
checks App-owned UIKit/AppKit alerts and Runtime-known outstanding PhotoKit
authorization requests. `status`, screenshot, DOM, and wait remain readable
and return the interaction warning. Mutations are rejected before delivery;
only `dismissAlert` may act on an App-owned alert. Its bare/default selection
is `onlyButton` and therefore refuses a multi-action alert; index and exact
label are explicit, while `visualPrimary` uses the same guarded horizontal
trailing or vertical top geometry rule as the real-device driver. A PhotoKit
request whose callback has not completed is reported as an external interaction
with unknown window visibility and no invented owner, text, or actions. The
host does not use Accessibility APIs or UI scripting to inspect or click TCC,
UserNotificationCenter, or Automation prompts; those remain manual or
Computer Use interactions.

`waitFor` does not perform a separate alert refresh before entering its loop;
the loop's own fresh snapshots preserve both its timeout budget and current
interaction state. Other public Runtime commands refresh once per CLI
invocation.

Mac-start and command-invocation performance measurements are not part of
user-facing text or JSON envelopes. `cli.log` keeps only `commandElapsedMs` and,
for commands that refresh App alert state, `alertRefreshElapsedMs`. Existing
command-specific result data, such as screenshot capture measurements, is
unchanged.

Screenshot and capture crop and normalize only the inner fixed canvas from the
target process's WindowServer backing surfaces, including Metal. The AppKit
title bar, traffic lights, desktop, and host decoration are excluded, and no
synthetic chrome overlay is created. They do not use
ScreenCaptureKit or request Screen Recording permission. A frame is accepted
only when source surfaces are live, complete, nontransparent, geometrically
consistent, and produce the strict 1290 x 2796 output. UIKit-only rendering is
diagnostic and cannot silently replace the compositor.

`status` performs a fresh Runtime diagnostics request and reports the actual
observed UIScreen, UIKit window bounds, scene, safe-area, host frame, canvas
rect, display/inverse input scale, four-edge resize mask, backing scale, and
canvas-capture geometry. The fixed UIKit bounds are never synthesized in
diagnostics, so a host drag that relayouts the scene makes Runtime health fail.
`open` delivers only to the exact active target. Unified
logs are constrained to the exact PID/executable, and failure evidence keeps
screenshot and DOM generations coherent.

The lock-independent public-fixture stress gate runs before any unlocked
global-mouse acceptance. It refuses fixture overrides and freshly rebuilds the
Runtime, workspace CLI, and public fixture from one clean Git checkout on every
invocation; CLI object files use a new SwiftPM scratch directory and fixture
objects use new DerivedData. Its evidence binds the unchanged HEAD to the exact
CLI, Runtime, complete fixture App tree, protocol-probe, and
prepared-generation digests. A raw authenticated `hello` probe attests the
exact minimal readiness field set and the absence of status-only AppKit fields,
then proves the same session remains healthy through a full `status` request.
The gate also exercises zero-length, oversized, exact-limit, malformed,
invalid-UTF-8, and truncated Runtime frames and proves listener health after
each one. One cold prepare is followed by 20 bare
start/status/stop cycles with unique session IDs and one immutable generation;
each cycle verifies the exact lock/PID/socket identity and the eventual removal
of only that cycle's lock and Runtime-owned socket. The same gate verifies
scene replacement, endpoint-loss classification, fixture-owned self-`SIGKILL`
stale cleanup,
preservation of the crash socket residue, and recovery through a fresh random
session. Its exact attestation records every clean-stop absence result and
the crash residue's before/after device, inode, owner, and mode observations.
The fixture self-crash is requested through a session-specific Darwin
notification, so the host never signals a potentially recycled PID. The
non-live aggregate also runs the full CLI suite, including deterministic
recorded-PID-reuse cases that cannot be forced safely in a host live run.
The run directory and attestation candidate are exclusively created and the
final is a no-clobber hard link; it does not rely on `ditto` preserving a Unix
socket in the archived home.
These process-local checks, together with the pending-launch same-boot crash
gate, are the required core live aggregate. CI runs that aggregate on the
provisioned Apple-silicon host with its stable signer already initialized and
an unlocked, launch-capable GUI session. It does not consume a private App,
two-display matrix, or external-App attestation.

Every script that launches a Mac backend App, and the entitlement capability
gate that writes audit fixtures into account PlayChain/socket roots, requires an
explicit disposable-account contract before mutation:

```text
IOS_USE_PLAYCOVER_DISPOSABLE_ACCOUNT_ACK=I_UNDERSTAND_THIS_ACCOUNT_IS_DISPOSABLE
IOS_USE_PLAYCOVER_EXPECTED_ACCOUNT_HOME=<canonical-passwd-home>
```

The second value must match the effective account's canonical passwd Home.
Cache, PlayChain, and socket roots are then derived from that verified account
and UID. Missing or mismatched input exits with `EX_CONFIG` (78). GitHub
workflows receive both private values through secrets. A temporary
`IOS_USE_HOME` alone is not isolation for account-global objects, Runtime
socket residue, PlayChain, or Home discovery records.

The unlocked real cursor, popup, and mouse/touch workflows remain optional
additive diagnostics. Their live display matrix requires exactly one
main display and one eligible active, online, non-mirrored extended display
with an NSScreen and a different backing scale; missing hardware or a locked
console is an `EX_CONFIG` (78) failure. The same PID, session, prepared
generation, and AppKit window number must survive exact-window interpolated
title-bar drags main → extended → main. Each phase binds Runtime diagnostics to
the selected screen ID, backing scale, and visible frame while requiring host
display scales 0.75, 1.0, and 0.875 respectively. The external-App diagnostic
may still publish its redacted evidence artifact when invoked directly,
but the core `test_playcover_backend.sh --live` and CI job neither require nor
upload it.

## Upstream Provenance

The vendored source and license records are under `ThirdParty/` and
`playcover-runtime/PlayTools/`:

- PlayCover `7190cc9ce57c8dee0e222918468f2579acc95e1b`
  (GPL-3.0);
- PlayTools `d688f695e83bf080be9ad4b7346e914c7c343d96`
  (AGPL-3.0);
- `inject` `e6d3aa4abe106f90fd8c5a1ca04db15c19d324eb`
  (GPL-3.0);
- Yams `3036ba9d69cf1fd04d433527bc339dc0dc75433d`, version `5.1.3`
  (MIT).

Each provenance file records the upstream URL, pinned revision, imported
files, and local headless patches. The audit requires the script-owned expected
file sets, provenance manifests, and actual vendored trees to match, then runs
the Git diff. It also requires the Yams manifest and both resolved-package pins
to agree and compares every distributed license byte-for-byte with its pinned
checkout. `ThirdParty/LICENSES.md` is the release license index. Release
corresponding source includes the complete Yams tree and a Runtime-input digest
matching the forced fresh build.
