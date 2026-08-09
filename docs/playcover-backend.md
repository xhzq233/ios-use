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

`start --mac --app` installs or updates the single account-global App slot for
that Bundle ID; `start --mac --reuse` launches the current installed slot for
the Bundle ID recorded by the current `IOS_USE_HOME`. There are no public
`playcover inspect`, `prepare`, or `verify` commands; those are internal start
steps and test entry points. After rebuilding a source App, pass `--app` again
to reinstall the slot; `--reuse` deliberately does not inspect, hash, or
otherwise depend on the original source path, and it does not select a
historical build.

`--log` is optional. It asks the CLI to create a unique owner-only file under
`$IOS_USE_HOME/logs/mac`, then sends the already-open file descriptor to the
injected Runtime over the authenticated Runtime socket. The Runtime verifies
the descriptor identity before redirecting stdout and stderr; it never opens a
Home path itself. Start prints the path, and `status` reports it as `stdio log`.
The file is
retained after a successful stop, an App crash, or a failed launch so it remains
usable as evidence. The flag and path are per-session state only; they do not
participate in source inspection, the Runtime hash, or the slot install
revision. This capture begins at the Runtime's earliest controllable C
constructor.
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
is not persisted independently in session or slot state. A header change alters
the Runtime build hash, which feeds the slot install revision, so the next
`--app` reinstall naturally supersedes an incompatible slot.

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
ios-use start --mac (--app <source.app> | --reuse) [--log]
  -> PlayCoverSessionService
     -> resolve the Bundle ID (source Info.plist for --app, current-bundle for --reuse)
     -> account-wide bundle start lock and live-process census
  -> PlayCoverSlotService
     -> --app: prepare + inject Runtime/Frida Engine + sign + verify in a
        sibling staging dir, then atomic rename/swap the single <bundleID> slot
     -> --reuse: read slot.json and verify the installed slot's install revision
  -> PlayCoverSlotLauncher
     -> write the minimal launching.json crash handle
     -> NSWorkspace launches the slot App directly with exact environment and PID
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

NSWorkspace launches the slot App directly; there is no symlink facade or
per-session App copy. An account-wide bundle start lock and live-process census
reject an already running copy of the same Bundle ID before launch. ios-use
neither attaches to nor terminates that existing process, and it has no
direct-spawn fallback.

Because the NSWorkspace submission is asynchronous, start atomically writes one
minimal `launching.json` crash handle before submitting. It is not a phase
journal: it holds only the session ID, Runtime socket, Bundle ID, relative
executable, submit time, and optional log path, and it never grants process
ownership. An NSWorkspace callback or polled `NSRunningApplication` census
identifies the new process, which must authenticate this start's exact session,
socket, PID, Bundle ID, and executable through an identified Runtime ping before
it can be claimed; a newly observed PID grants no ownership. Final Runtime
`hello` must still pass, after which start writes `driver.lock` and removes
`launching.json`.

Recovery is limited to that one crash window. If a later start or `stop` finds a
leftover `launching.json`, it re-acquires the same bundle lock and resolves it
without guessing: a single same-Bundle process that authenticates the recorded
session is adopted as active or terminated by `stop`; no matching process past
one full start timeout means the record is stale and is removed; a same-Bundle
process that cannot authenticate leaves the App for the user to close and only
clears the tool-side record. Launch discovery uses the full validated
`start --timeout` value rather than a shorter hidden deadline.

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
Bundle ID, slot install revision, and Runtime identity during handshake and
status. A mutation whose bytes may have reached the Runtime is never replayed
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
install revision, PID, and executable, sends termination only to that process,
and clears only matching session state. The host never probes or unlinks a Runtime
socket: on Darwin, even a live listener can return `ECONNREFUSED` when its
accept queue is full, and pathname deletion cannot be made conditional on an
inode. The Runtime owns its freshly bound random path, marks its listener
close-on-exec, and removes that path from its `atexit` and `SIGTERM` exits.
Crash/SIGKILL residue and all unknown run-directory entries remain preserved;
the next random session uses a different path. Start fails closed if its new
path unexpectedly exists. This is an owner-only cache boundary rather than a
defense against a malicious process running as the same user: the Runtime's
signal-safe `unlink` assumes another
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

All ordinary prepare and start paths resolve this exact binding with
initialization disabled. They never create, rotate, or repair the identity or
modify Trust Settings. An explicit `start --mac --app` resolves and validates
the signer before routing, Home locking, source inspection, or slot state is
read. Missing and trust-required states direct the operator to `config --mac`;
replaced, expired, or inaccessible state also fails closed.

Each Bundle ID has exactly one App slot, shared by the macOS account. The fixed
owner-only layout is:

```text
~/Library/Caches/dev.ios-use/mac/apps/<bundleID>/
  <displayName>.app
  slot.json
~/Library/Caches/dev.ios-use/mac/locks/bundle-<sha256(bundleID)>.lock

$IOS_USE_HOME/mac/current-bundle.json

~/Library/Application Support/dev.ios-use/homes/<home-id>.json
```

The slot directory holds exactly one user-readable `<displayName>.app` and a
small `slot.json`; the per-Bundle lock serializes install and launch. Each Home
records only the current Bundle ID for `--reuse`; normal lifecycle commands
never enumerate other Homes. The small account support records only let the
read-only `ios-use du` command discover known Homes. Changing `IOS_USE_HOME`
changes session and configuration state and which Bundle ID `--reuse` selects,
but all Homes share the same single account-global slot per Bundle ID.

`start --mac --app` always installs or updates the slot; it does not compute a
source-tree hash to reuse an earlier build. The source App is always read-only.
Install creates a sibling staging directory beside the slot, copies the source
once, applies the pinned conversion/dependency/rpath changes, embeds and injects
the Runtime and Frida Engine, removes the copied mobile provision, composes
entitlements, signs inside-out, removes quarantine, and performs full
verification. Only then does one atomic operation publish the slot: first
install is an atomic rename from "no slot"; an update is an atomic swap of the
whole `<bundleID>` directory, never delete-then-create, so a changed display
name never briefly exposes two Apps. The swapped-out directory is deleted as
transaction residue, not kept as a rollback build. Failures remove only
transaction-owned staging, and the source is never overwritten or repaired in
place.

`slot.json` records only the Bundle ID, the App relative path, the executable
relative path, and one unified `installRevision`. That revision is a single
compatibility seal over the install-contract version, the Runtime build hash,
the pinned prepare revision (which includes the Frida Engine ABI), the account
namespace policy hash, and the signing-policy revision. The namespace policy
hash derives from the canonical account PlayChain root, the fixed UID socket
root, and its policy revision, and deliberately excludes the logical
`IOS_USE_HOME` and Home ID. `--reuse` reads `slot.json` and refuses to launch
when the installed `installRevision` no longer matches the current prepare
contract, directing the operator to reinstall with `--app`. There is no
separate `manifest + completed` marker, persisted source inventory, generation
key, or CDHash sidecar.

ios-use does not garbage-collect slots, logs, artifacts, Frida development
caches, or historical Home records. Lifecycle commands access only the current
Home and never enumerate the Home discovery index. `ios-use du` is the explicit,
read-only account report. Its default output groups rebuildable cache,
persistent App data, logical Home data, and metadata/residue so the cleanup
impact is visible before a user removes anything. Each group shows allocated
size and latest descendant modification time; the current App slot also shows
its display name and version. `--json` retains raw paths, references, and any
incomplete-statistics warnings. The command follows no symlink, has a bounded
traversal, and does no source hashing, signing verification, Runtime connection,
recovery, or deletion. It does not write its own `cli.log` entry. A Home is
added to the small discovery index only after a successful executable `start`.

Each logical Home keeps only its own Runtime log files under:

```text
<IOS_USE_HOME>/logs/mac/
  stdio-<session-id>.log
```

The Runtime's Unix socket is under `/private/tmp/dev.ios-use-<uid>/`; that
socket root follows the effective UID rather than `HOME` or `IOS_USE_HOME`.
The log root is deliberately Home-local. The account-global cache holds the
per-Bundle App slots and their locks; Application Support holds the
discovery-only Home index and per-bundle KeyCover databases. The App
entitlement allows the account-level PlayChain root and
fixed UID socket root; Home-local log access arrives only as the verified
descriptor capability. Logical-Home operation locks serialize local session and
`launching.json` mutations, while per-Bundle locks coordinate the shared slot.

`v2.0.1` does not read, migrate, or auto-remove any pre-2.0.1 state. Legacy
content-addressed prepared caches, launch facades, generation locks, and Home
generation/pending references are simply ignored by the fixed-slot model, so no
production start, `status`, or `stop` path touches them. Upgrading is a cache
reset: stop any running Mac session, then run `start --mac --app` once per
Bundle to build its new slot. Existing legacy caches remain on disk until you
clear them yourself; `ios-use du` reports the fixed legacy roots as generic
rebuildable cache so their size is visible, but ios-use never deletes them for
you.

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
build-root paths are not embedded. A release contains one Mac resource archive
with these two frameworks and one SHA-256 manifest covering it together with the
CLI and two driver IPAs. `scripts/install.sh` verifies the manifest before placing both frameworks under
`<prefix>/share/ios-use/mac/`, re-verifies their signatures, and never
copies executable Runtime content into `IOS_USE_HOME`. The frameworks are
read-only preparation inputs: prepare signs only the account-global slot copy.
Installed-layout acceptance hashes both complete source frameworks before and
after fixture execution.

The exact Git tag carries ios-use and vendored source/license records. The
Frida Engine build separately fetches and validates every public repository and
commit recorded in `ThirdParty/Frida/PROVENANCE.md`; its required notices live
inside the framework. These source and license carriers are not duplicated as
standalone Release assets.

Runtime resolution checks the adjacent development layout and then this stable
prefix share location. `IOS_USE_HOME`, legacy Home-local frameworks, and
account-global App slots are never Runtime sources, so mutable or stale state
cannot shadow the Runtime shipped beside ios-use. Changing `IOS_USE_HOME`
selects different logical session/reference/log state and which Bundle ID
`--reuse` targets, but all Homes share the same single account-global slot per
Bundle ID and require no second Runtime installation.

## Resident GumJS Debug Engine

`start --mac --app <source.app>` always validates the installed arm64 Mac
Catalyst `IOSUseFridaEngine.framework` against the pinned version, Gum commit,
Engine ABI, Agent digest, and wrapper-source closure, then injects it into the
slot during every install. The Engine ABI feeds the slot install revision, so an
incompatible toolchain output cannot alias the current slot. The installed slot
stays launchable through bare `--reuse` without re-reading that input, so the
debug Engine is resident for every Mac session. The installed Engine is
validated from the local read-only resource only; there is no start-time Engine
download, object cache, lock, environment override, or compatibility path.

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
CLI, Runtime, complete fixture App tree, protocol-probe, and installed-slot
digests. A raw authenticated `hello` probe attests the
exact minimal readiness field set and the absence of status-only AppKit fields,
then proves the same session remains healthy through a full `status` request.
The gate also exercises zero-length, oversized, exact-limit, malformed,
invalid-UTF-8, and truncated Runtime frames and proves listener health after
each one. It proves fixed-slot A ↔ B atomic replacement, then runs 20 bare
start/status/stop cycles through `--reuse` with unique session IDs against one
installed slot; each cycle verifies the exact lock/PID/socket identity and the
eventual removal of only that cycle's `launching.json` and Runtime-owned socket.
The same gate verifies
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
These process-local checks, together with the same-boot launch crash/recovery
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
`IOS_USE_HOME` alone is not isolation for account-global App slots, Runtime
socket residue, PlayChain, or Home discovery records.

The unlocked real cursor, popup, and mouse/touch workflows remain optional
additive diagnostics. Their live display matrix requires exactly one
main display and one eligible active, online, non-mirrored extended display
with an NSScreen and a different backing scale; missing hardware or a locked
console is an `EX_CONFIG` (78) failure. The same PID, session, install
revision, and AppKit window number must survive exact-window interpolated
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
  (GPL-3.0).

Each provenance file records the upstream URL, pinned revision, imported
files, and local headless patches. The audit requires the script-owned expected
file sets, provenance manifests, and actual vendored trees to match, then runs
the Git diff and compares every vendored license byte-for-byte with its pinned
checkout. `ThirdParty/LICENSES.md` is the license index. The release build also
validates the public Frida source pins and embedded notices before packaging the
Engine.
