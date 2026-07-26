# Headless PlayCover Backend

## Scope

The source-build-only PlayCover backend runs a managed, unencrypted arm64
iPhone App on Apple silicon without the PlayCover GUI. It directly ports the
non-GUI preparation graph from pinned PlayCover sources and injects one
Mac Catalyst Runtime containing the pinned PlayTools compatibility and touch
code.

The public lifecycle is intentionally small:

```bash
./ios-use start --playcover --app /path/to/Source.app
./ios-use status
# normal ios-use UI, screenshot, capture, URL, and log commands
./ios-use stop
```

`start --playcover` without `--app` reuses the most recent verified generation
from the current `IOS_USE_HOME`. There are no public `playcover inspect`,
`prepare`, or `verify` commands; those are internal start steps and test
entry points.

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

The AppKit window is borderless and non-resizable. Its frame,
`contentLayoutRect`, and content-view bounds must all be exactly 430 x 932
points with an identity AppKit-to-UIKit logical transform. A display that
cannot fit that window causes start to fail; the backend does not introduce a
second scaled coordinate system.

The full device frame is the target App's complete 430 x 932 logical rendering.
The Runtime does not create a fallback system-chrome window or draw synthetic
Dynamic Island, status glyphs, time, battery, or Home Indicator. Safe-area
values are observed from the App/platform rather than forced to an iPhone
constant; they never crop the output or consume App touch events.

## Architecture and Session

```text
ios-use start --playcover [--app <source-or-managed-prepared.app>]
  -> PlayCoverManagedAppService
     -> source classification or bounded managed-generation verification
     -> deterministic generation selection under this IOS_USE_HOME
  -> PlayCoverService
     -> pinned PlayCover prepare graph and full verification
     -> NSWorkspace launch with exact environment and PID
  -> IOSUsePlayRuntime.framework
     -> pinned PlayTools platform/geometry/keychain hooks
     -> fixed AppKit window and complete App compositor
     -> DOM, wait, touch/input, compositor, URL, and diagnostics
     -> owner-only AF_UNIX listener
  -> PlayCoverRuntimeClient
     -> direct authenticated request; no intermediate server
```

The only runtime identity is one random `sessionID`. Start passes the session
ID and derived socket path through the launch environment. The Runtime binds
that socket and never reads a sidecar configuration file.

Each connection carries one four-byte big-endian length-prefixed JSON request:

```json
{
  "schemaVersion": 2,
  "requestId": "unique-request-id",
  "sessionID": "active-session-id",
  "command": "dom",
  "arguments": {}
}
```

The response echoes the schema, request ID, and session ID and contains either
a typed payload or structured error. Request and response sizes, absolute
deadlines, and one-request-per-connection behavior are bounded. The CLI checks
the peer UID and PID, live process executable, bundle, prepared generation,
and Runtime response identity before accepting data. A mutation whose bytes
may have reached the Runtime is never replayed automatically.

All applicable commands keep routing to this Runtime until `ios-use stop`.
`stop` does not call a lifecycle RPC: the host revalidates the exact
generation, PID, and executable, sends termination only to that process, and
clears only matching session state. `activateApp`, `terminateApp`, `home`, and
DDI operations fail as unsupported before touching another backend.

## Prepare, Signing, and Cache

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
7. sign nested binaries and bundles from the inside out, preserving each
   nested code object's source entitlements, then sign the outer App;
8. remove quarantine and verify every Mach-O, dependency, load command,
   entitlement, nested signature, and outer seal.

Failures remove only transaction-owned staging. Existing generations and the
source are not overwritten.

The immutable generation key contains:

- the complete source content hash;
- the Runtime/build content hash;
- the pinned prepare implementation revision.

Initial preparation performs full verification. Reuse checks the immutable
marker, key executable and Runtime hashes, signature validity, and managed
path identity without enumerating or re-preparing the entire App. Different
`IOS_USE_HOME` values never share prepared state.

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

Runtime resolution first honors a valid framework explicitly managed by the
current `IOS_USE_HOME`, then the adjacent development layout, and finally this
stable prefix share location. Therefore changing `IOS_USE_HOME` isolates only
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
430 x 932 logical coordinates, and validates a fresh post-action snapshot or
pixel condition. Text input first verifies the supported first responder;
secure, custom, or unsupported input returns a structured error.

Screenshot and capture read only the target process's WindowServer backing
surfaces, including Metal, with no synthetic chrome overlay. They do not use
ScreenCaptureKit or request Screen Recording permission. A frame is accepted
only when source surfaces are live, complete, nontransparent, geometrically
consistent, and produce the strict 1290 x 2796 output. UIKit-only rendering is
diagnostic and cannot silently replace the compositor.

`status` performs a fresh Runtime ping and reports the actual observed
UIScreen, scene, safe-area, AppKit-window, backing-scale, mouse-transform, and
capture geometry. `open` delivers only to the exact active target. Unified
logs are constrained to the exact PID/executable, and failure evidence keeps
screenshot and DOM generations coherent.

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
