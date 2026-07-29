# Mac Backend (PlayCover-derived)

## Scope

The source-build-only Mac backend runs a managed, unencrypted arm64
iPhone App on Apple silicon without the PlayCover GUI. It directly ports the
non-GUI preparation graph from pinned PlayCover sources and injects one
Mac Catalyst Runtime containing the pinned PlayTools compatibility and touch
code.

The public lifecycle is intentionally small:

```bash
./ios-use config --playcover
./ios-use start --mac --app /path/to/Source.app --log
./ios-use status
# normal ios-use UI, screenshot, capture, URL, and log commands
./ios-use stop
```

`config --playcover` is the only public initialization path for the stable
PlayCover signer. It is run once per macOS account, not once per
`IOS_USE_HOME`. The first run creates and trusts the identity with one macOS
authentication. If authentication is cancelled, the binding remains on the
same identity and retrying the command safely resumes trust configuration.
Ordinary start only resolves the existing identity and fails with an explicit
`config --playcover` instruction when it is missing or still needs trust. Other
unhealthy states fail closed without start-time mutation.

`start --mac --reuse` explicitly reuses the most recent verified generation
from the current `IOS_USE_HOME`. There are no public `playcover inspect`,
`prepare`, or `verify` commands; those are internal start steps and test
entry points. After rebuilding a source App, pass `--app` again; `--reuse`
deliberately does not inspect, hash, or otherwise depend on the original source
path.

`--log` is optional. It asks the CLI to create a unique owner-only file under
`IOS_USE_HOME/playcover/logs/`, then makes the injected Runtime redirect the
target App's stdout and stderr to that exact pre-created file. Start prints the
path, and `status` reports it as `stdio log`. The file is retained after a
successful stop, an App crash, or a failed launch so it remains usable as
evidence. The flag and path are per-session state only; they do not participate
in source inspection, the Runtime hash, or the generation key. This capture
begins at the Runtime's earliest controllable C constructor. Objective-C
`+load` and dyld diagnostics that precede constructors are outside its
contract; exact-PID unified logging remains a separate source.

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
is not persisted in the session or cache key. A header change alters the
Runtime build hash and therefore selects a new prepared generation naturally.

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
values are observed from the App/platform rather than forced to an iPhone
constant; they never crop the output or consume App touch events.

## Architecture and Session

```text
ios-use start --mac (--app <source-or-managed-prepared.app> | --reuse) [--log]
  -> PlayCoverManagedAppService
     -> source classification or managed-generation selection
     -> deterministic generation selection under this IOS_USE_HOME
  -> PlayCoverService
     -> pinned PlayCover prepare graph and full verification
     -> one bounded integrity verification immediately before launch
     -> pinned-shape session App facade under ~/Applications/PlayCover
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

For `--log`, the same restricted environment also carries the CLI-generated
canonical path plus the pre-created file's device and inode. The Runtime opens
the owner-only parent and leaf without following symlinks, verifies a regular
0600 file owned by the current user with exactly one link and the expected
identity, then redirects file descriptors 1 and 2. Runtime hello reports that
exact outcome, and start does not commit the session unless it matches.

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
Confirmed stop and confirmed rollback remove the facade. A facade whose
asynchronous open was submitted without yielding an owned process remains
fail-closed so a late LaunchServices completion cannot lose its Bundle
resources; the next CLI start uses a new session facade. Launch discovery uses
the full validated `start --timeout` value rather than a shorter hidden
deadline.

Each connection carries one four-byte big-endian length-prefixed JSON request:

```json
{
  "schemaVersion": 3,
  "requestId": "unique-request-id",
  "sessionID": "active-session-id",
  "command": "dom",
  "arguments": {},
  "refreshAlertStatus": true
}
```

The response echoes the schema, request ID, and session ID and contains either
a command-specific typed payload or structured error. A public command's first
Runtime request sets `refreshAlertStatus`; later internal requests from the same
CLI invocation do not repeat the refresh. The response reports the measured
Runtime request and alert-refresh durations plus the fresh interaction state.
Host-only lifecycle and internal discovery requests omit the optional field
entirely, preserving wire compatibility with an already-running older Runtime;
only the one fresh public-command request encodes it as `true`.
If an active older Runtime rejects that field, the CLI fails safely with an
explicit stop/start upgrade instruction; it does not retry the mutation without
the modal gate.
`hello` returns process
identity, capabilities, and only the exact fixed-geometry observations consumed
by the launch readiness predicate. It deliberately omits window/view
inventories, screen topology, alert state, resize history, and mouse delivery
state. `diagnostics` retains the complete observational payload used by
`status`; ordinary DOM, screenshot, wait, and action responses contain only
their command result. Request and response sizes, absolute deadlines, and
one-request-per-connection behavior are bounded. The CLI authenticates the
peer UID and PID plus the live executable at the Unix transport, then verifies
bundle, prepared generation, and Runtime identity during handshake and status.
A mutation whose bytes may have reached the Runtime is never replayed
automatically.

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
`~/Library/Application Support/dev.ios-use/playcover-stable-signing-binding-v1.json`.
Initialization is serialized by a per-user operation lock and claims the first
binding atomically. It then installs code-signing-specific user trust and
performs a real sign/strict-verify probe. A cancelled trust authentication does
not remove the binding or create a replacement, so the next explicit
`config --playcover` continues with the same certificate.

All ordinary prepare, managed-selection, and start paths resolve this exact
binding with initialization disabled. They never create, rotate, or repair the
identity or modify Trust Settings. Missing and trust-required states direct the
operator to the explicit configuration command; replaced, expired, or
inaccessible state also fails closed and is never silently replaced. Separate
`IOS_USE_HOME` values share the signer but not prepared generations, session
state, or cache references.

The source App is always read-only. Preparation takes place in a new staging
directory under `IOS_USE_HOME/playcover/` and becomes visible only after the
complete transaction verifies.

The headless dependency graph retains the pinned Installer order:

1. inspect the source tree, signatures, entitlements, provisioning, and every
   code object;
2. reject encryption and unsupported or malformed Mach-O objects;
3. APFS-clone the source into managed staging;
4. convert each arm64 thin, fat, or fat64 Mach-O with the pinned PlayCover
   converter, including its dependency and rpath rewrites;
5. embed the Runtime and inject exactly one load command into the main
   executable with the pinned `inject` implementation;
6. update only required Info.plist compatibility keys, remove the copied
   mobile provision, and compose entitlements through pinned PlayCover,
   KeyCover, and PlayChain paths;
7. sign nested binaries and bundles from the inside out using the stable
   identity's full certificate SHA-1 selector and the same non-PlaySign
   entitlement result as pinned PlayCover, then sign the outer App with the
   composed root entitlements;
8. remove quarantine and verify every Mach-O, dependency, load command,
   entitlement, nested signature, and outer seal.

Failures remove only transaction-owned staging. Existing generations and the
source are not overwritten.

On macOS, prepare opens staging relative to retained managed-directory FDs and
performs writes through its stable `/.vol/<device>/<inode>` vnode path. While
prepare is running, the ios-use-owned `playcover` and `prepared` directories
also carry a temporary `UF_APPEND` namespace guard. Descendants remain
writable, but staging and its retained parents cannot be renamed or unlinked.
The guard validates the anchored FD links before and after prepare and restores
the original flags on success or failure; a flag left by a killed process is
recovered under the next exclusive operation lock. The opened `IOS_USE_HOME`
root vnode is the capability boundary, not a same-UID privilege boundary.

The ordinary `IOS_USE_HOME` path remains the cache identity and is checked
against the retained vnode before preparation and publication. Clone,
conversion, signing, rollback, and directory enumeration stay attached to the
original staging directory. Subprocesses such as `codesign` inherit the stable
vnode as their working directory and receive relative staging arguments; no
optimized-build `fcntl(F_GETPATH)` bridge is used.

The immutable generation key contains:

- the complete source content hash;
- the Runtime/build content hash;
- the pinned prepare implementation revision;
- the signer's public-key SPKI SHA-256;
- the signer's certificate SHA-256;
- the signing-policy revision.

Initial preparation performs full verification. Reuse checks the immutable
marker, key executable and Runtime hashes, signature validity, stable signer,
root designated requirement, root CDHash, and managed path identity without
enumerating or re-preparing the entire App. Different `IOS_USE_HOME` values
never share prepared state, even though they resolve the same per-user signer.

The explicit-source path creates one immutable preparation plan containing the
source inspection, Runtime hash, prepare revision, and generation key. Managed
selection, prepare, and the pinned upstream engine consume that same evidence;
the copied Runtime is checked against the recorded hash before signing. Source
inventory, per-file SHA-256, framed tree hash, and Mach-O identification share
one content pass. Cold prepare performs three deliberate full-content passes:
the source App inspection, the original Runtime build hash, and the
authoritative final prepared-App inspection. It does not re-read the live
source after cloning; callers must provide a completed source build that stays
byte-stable through publication.

The schema-version-4 production prepare manifest remains a cache-integrity
seal. It records the complete stable-signer evidence and the prepared root's
certificate SHA-256, serialized designated requirement plus its SHA-256,
CDHash, and signing identifier. Fast verification first validates the anchored
App's strict code seal and recorded nested signatures, then requires the
current bound signer and the observed root signature evidence to match the
manifest exactly. Ordinary `start` never performs a second pinned prepare. A
separate hermetic
differential gate emits a Codable JSON attestation outside the checkout. It
consumes the two distinct, module-owned prepare result types and re-inspects
the source plus both outputs before publication. The two canonical managed
homes must be disjoint, each output must remain beneath its matching home, and
path normalization applies only at path-token boundaries. The evidence records
both complete object/slice selector sets, every App and inventory comparator
family (including fields that compare equal), source/output/revision identity,
static allowance reasons and symbols, one-sided baseline provenance, a fixed
44-file transitive source closure, and the SHA-256 plus device/inode of the
loaded XCTest image that executed the comparison. The normalized closure
digest is embedded at build time and must match both source snapshots; the gate
uses an isolated SwiftPM scratch directory. Managed-path replacement accepts
only actual lexical/canonical roots and exact descendants, and the pinned result
must identify the full-PlayTools Installer producer. Allowances are reviewed
inputs and cannot be generated from observed differences. A candidate is
published by hard link only after the entire filtered suite and all evidence
sentinels succeed; an existing final is never replaced. The attestation is
explicitly scoped
`hermetic-fixture`; a real external-App attestation requires its own reviewed
baseline/allowance configuration and is not inferred from the live UI
scenario.

External-App characterization is a separate diagnostic-only operation. It
clones a fresh source snapshot, uses disjoint fresh managed homes, runs the
full pinned PlayTools Installer oracle and the real
`PlayCoverService.inspectPreparationSource` → plan → `prepareArtifact` →
typed upstream-result path, and supplies signed Runtime/AKInterface one-sided
baselines plus external managed-path normalization to the raw differential
analyzer. It verifies that the original source, snapshot, Runtime, and
PlayTools trees remain unchanged. The owner-only no-overwrite report records
typed input identities, producer revisions, output hashes, and raw
differences with kind `playcover-external-prepare-characterization` and
disposition `diagnostic-only`. It does not call the enforcing or attesting
APIs and contains no generated review explanations, symbols, or acceptance
decision.

One owner-only cross-process operation lock serializes every backend's start
and stop mutation within an `IOS_USE_HOME`, including PlayCover prepare
publication, session commit, and cache collection. After a successful start,
cache collection preserves the current generation, active-session generation,
last-prepared generation, and three most recent inactive complete generations.
It removes only exact transaction-owned `.staging-<hash>-<UUID>` and
`.gc-<hash>-<UUID>` leftovers plus eligible complete generations after an
anchored tombstone rename. Recursive deletion is no-follow, owner checked, and
confined to the prepared filesystem device. Foreign, mounted, or
symbolic-link generation entries fail closed. After anchored ownership and
64-hex namespace validation, generations with missing, oversized, malformed,
or mismatched manifest/completed sidecars are quarantined with an explicit
warning and a bounded per-start budget, so later collection can recover the
same content key. Current, active-session, and last-prepared generations are
never quarantined. Generation metadata must be a single-link regular file;
malformed session/reference state skips all deletion.

## Runtime Distribution

The Runtime is a release-built, ad-hoc-signed framework, not an artifact built
inside a user's mutable state directory. A release contains the framework
archive, SHA-256 manifest, applicable licenses, upstream provenance, and an
exact corresponding-source archive. `scripts/install.sh` verifies the manifest
before placing the framework under
`<prefix>/share/ios-use/playcover/IOSUsePlayRuntime.framework`, re-verifies the
signature, and never copies executable Runtime content into `IOS_USE_HOME`.
The framework is a read-only source in the behavioral contract: prepare signs
only the managed App copy. Installed-layout acceptance hashes the complete
source framework before and after fixture execution.

Runtime resolution honors a valid framework explicitly managed by an explicit
`IOS_USE_HOME`, then the adjacent development layout, and finally this stable
prefix share location. The implicit default home is mutable session/cache state
and is never a Runtime source, so a stale framework left there cannot shadow the
Runtime beside a development build. Therefore changing `IOS_USE_HOME` isolates
prepared Apps and sessions for a release install; it does not require a second
Runtime installation or allow the installer to put mutable executable code in
that home.

## Runtime Commands

DOM snapshots enumerate foreground scenes, z-ordered windows, UIView
hierarchy, and accessibility-container elements. They expose stable
label/value/identifier/hint/traits/state/class/hierarchy/frame fields and one
snapshot generation. Selectors follow the existing ios-use clean, merge,
match, ambiguity, traits, and `cindex` rules. SwiftUI and WKWebView use their
accessibility bridges; custom Metal/Unity content is reported as opaque when
it has no semantic nodes.

Tap, long press, and swipe use the directly ported PlayTools fake-touch
backend with begin/move/end/cancel phases and monotonic timing. The Runtime
resolves selectors against one fresh snapshot, performs a UIKit hit test in
430 x 932 logical coordinates, and proves that the expected touch phases were
delivered. Absolute `tap x,y` points are already in that fixed logical space
and are never reinterpreted as an element-relative ratio. A valid no-op control
or a swipe already at its boundary is still a successful delivery; callers use
`--dom`, `waitFor`, or an explicit screenshot when they require a visible
result. Text input separately verifies the exact first responder and final
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
session. Its schema-v3 attestation records every clean-stop absence result and
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

The unlocked real cursor, popup, and mouse/touch workflows remain optional
additive diagnostics. Their version-2 live display matrix requires exactly one
main display and one eligible active, online, non-mirrored extended display
with an NSScreen and a different backing scale; missing hardware or a locked
console is an `EX_CONFIG` (78) failure. The same PID, session, prepared
generation, and AppKit window number must survive exact-window interpolated
title-bar drags main → extended → main. Each phase binds Runtime diagnostics to
the selected screen ID, backing scale, and visible frame while requiring host
display scales 0.75, 1.0, and 0.875 respectively. The external-App diagnostic
may still publish its redacted schema-v2 attestation when invoked directly,
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
