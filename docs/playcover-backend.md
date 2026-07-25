# Headless PlayCover Backend

## Status

This backend is experimental and source-build-only. Its current slice provides
deterministic profile, prepare, verify, launch, direct Runtime diagnostics,
window screenshot, capture reuse, and terminate operations for unencrypted
thin arm64 iPhone Apps on Apple silicon.

The current slice does not yet expose DOM, wait, touch, or input commands. The
injected runtime is deliberately bounded to device/profile compatibility,
UIKit/AppKit geometry, and a versioned local Unix-socket protocol.

## Fixed Device Profile

The initial profile matches the current vPhone default:

| Field | Value |
| --- | --- |
| Product type | `iPhone16,2` |
| Logical portrait size | 430 x 932 points |
| Native portrait size | 1290 x 2796 pixels |
| Scale | 3x |
| PPI | 460 |

The profile is immutable for one prepared generation. The host writes its
stable SHA-256 hash into the App, and `launch` rejects runtime evidence whose
hash or dimensions do not match.

UIKit stays in a 430 x 932 logical coordinate space. macOS may uniformly scale
the physical AppKit presentation down to fit the available display; that
presentation size is not a second logical coordinate system. Screenshots are
normalized back to 1290 x 2796 and carry 430 x 932 @3x metadata.

## Architecture

The GUI-free preparation path is:

```text
ios-use start --playcover --app <App.app>
  -> PlayCoverManagedAppService
     -> prepared marker verification, or iPhoneOS source classification
     -> default runtime discovery
     -> deterministic managed generation selection
  -> PlayCoverService
     -> bounded Mach-O inspection/conversion
     -> APFS clone + runtime embedding
     -> per-Mach-O and top-level ad-hoc signing
     -> NSWorkspace launch with an exact PID
        and credential-minimized environment
  -> IOSUsePlayRuntime.framework
     -> iPhone model/platform interposition
     -> UIScreen/FBS/scene fixed geometry
     -> key UIKit window to AppKit window bridge
     -> private runtime.sock listener
  -> PlayCoverRuntimeClient
     -> direct AF_UNIX hello/ping/diagnostics
     -> peer UID + launch nonce + generation/instance validation
```

There is no PlayCover backend server or helper process. The wire format is
versioned JSON with a four-byte big-endian length, a 64 KiB frame limit, and
one request per Unix-socket connection. It has no TCP fallback.

Lifecycle uses the normal active-session surface:

```text
ios-use start --playcover [--app <source-or-prepared.app>]
  -> explicit source prepare/reuse, explicit prepared verification,
     or last-prepared.json
  -> private bootstrap + verify + launch + direct runtime hello
  -> driver.lock { app, pid, profile/generation, socket, nonce, runtime instance }
  -> all session-bound commands resolve PlayCover until ios-use stop
```

The host never edits the source App. `prepare` requires a destination that does
not exist, preflights the source before copying, and removes only a partial
destination created by the failing transaction. It refuses encrypted,
fat/byte-swapped, non-arm64, malformed, or unsupported-platform Mach-Os.

Mach-O rewriting is bounded to the header and load-command area. Expansion is
allowed only when every consumed padding byte is zero and the first section
offset provides enough capacity. The main executable receives exactly one
`LC_LOAD_DYLIB` for:

```text
@executable_path/Frameworks/IOSUsePlayRuntime.framework/IOSUsePlayRuntime
```

## Build and Use

```bash
bash scripts/build_swift_cli.sh --debug

./ios-use playcover inspect /path/to/Source.app --json
./ios-use start --playcover --app /path/to/Source.app
./ios-use status
./ios-use screenshot
./ios-use stop
```

`screenshot` asks the Runtime for fresh PID/window/geometry identity, captures
that exact window with ScreenCaptureKit, removes the AppKit frame/title area,
and writes the normal ios-use JPEG artifact at 1290 x 2796. On first use, grant
the executing terminal or ios-use host Screen Recording access in System
Settings > Privacy & Security > Screen & System Audio Recording, then restart
the command. Permission denial is reported explicitly; it does not fall back
to a partial in-process render.

The local Swift CLI build keeps
`.ios-use/playcover/IOSUsePlayRuntime.framework` up to date when running on
Apple silicon with the iPhoneOS SDK. A source-built install copies that runtime
to `IOS_USE_HOME/playcover/`. The normal start command discovers it
automatically; callers do not pass a runtime path.

For explicit output control or backend debugging, the lower-level toolbox is
still available:

```bash
./ios-use playcover prepare /path/to/Source.app \
  --output /path/to/Prepared.app \
  --runtime .ios-use/playcover/IOSUsePlayRuntime.framework \
  --json

./ios-use playcover verify /path/to/Prepared.app --json
```

`start --playcover --app` first detects complete preparation markers. A marked
App must verify successfully and is never silently treated as source after a
verification failure. An unmodified iPhoneOS App is prepared under
`IOS_USE_HOME/playcover/prepared/`; a deterministic key covers source tree
metadata, source executable and Info.plist contents, runtime tree metadata and
executable contents, the fixed profile hash, and the preparation revision.
Existing keyed output is reused only after full verification. Preparation
never overwrites a keyed output.

Successful automatic or explicit preparation records
`IOS_USE_HOME/playcover/last-prepared.json`, so bare `ios-use start
--playcover` remains available. The active backend, exact App path, PID, bundle,
profile/generation, Runtime socket/instance, and launch nonce are stored in the
owner-only ordinary `driver.lock`; normal `ios-use stop` validates the signed
generation and the complete live Runtime identity, then checks the PID and
exact executable path before terminating only that App process and clearing
matching state. Lifecycle is host-owned: the Runtime does not implement
shutdown, activateApp, or terminateApp RPCs.

This backend has not been released yet. Its manifest, `last-prepared.json`, and
PlayCover `driver.lock` readers accept only the current complete schema; there
is no migration path for local development intermediates.

All session-bound commands consult this lock. Driver commands therefore route to
PlayCover and cannot silently use XCTest. Screenshot/capture use the PlayCover
window capture path; DOM/actions currently return an explicit
unsupported-capability error.

Mutable backend state, managed generations, the installed runtime, private
bootstrap/socket, and rollback identity record resolve through `IOSUsePaths`
under `IOS_USE_HOME/playcover/`. A local
workspace runtime next to the repo-root CLI and a conventional
`../share/ios-use/playcover/` installed layout are fallback discovery
locations. The App is signed with a narrow Mac sandbox profile;
restricted iOS application/team/keychain entitlements are not preserved.
Launch forwards only a small allowlist of ordinary locale/home variables, so
unrelated caller credentials are not inherited by the App.

## Upstream Provenance

The implementation is a GUI-free derivative informed by:

- PlayCover commit
  `7190cc9ce57c8dee0e222918468f2579acc95e1b`, particularly
  `PlayCover/Utils/Macho.swift`, installer conversion, and signing order
  (GPL-3.0).
- PlayTools commit
  `d688f695e83bf080be9ad4b7346e914c7c343d96`, particularly `PlayLoader`,
  `PlayScreen`, the UIKit/FBS swizzles, and the AppKit plugin bridge
  (AGPL-3.0).

ios-use is distributed under AGPL-3.0. Source files that directly derive these
approaches carry focused provenance comments; the repository's
[LICENSE](../LICENSE) applies to the combined work.
