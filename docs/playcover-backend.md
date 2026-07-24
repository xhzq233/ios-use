# Headless PlayCover Backend

## Status

This backend is experimental and source-build-only. Its first working slice
provides deterministic profile, prepare, verify, launch, and terminate
operations for unencrypted thin arm64 iPhone Apps on Apple silicon.

The current slice does not yet expose the ios-use DOM/action protocol. The
injected runtime is deliberately bounded to device/profile compatibility,
UIKit/AppKit geometry, and a versioned hello record.

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

## Architecture

The GUI-free preparation path is:

```text
ios-use playcover
  -> PlayCoverService
     -> bounded Mach-O inspection/conversion
     -> APFS clone + runtime embedding
     -> per-Mach-O and top-level ad-hoc signing
     -> launch with a credential-minimized environment
  -> IOSUsePlayRuntime.framework
     -> iPhone model/platform interposition
     -> UIScreen/FBS fixed geometry
     -> dynamically loaded AppKit window bridge
     -> bounded JSON hello
```

Lifecycle uses the normal active-session surface:

```text
ios-use start --playcover
  -> last-prepared.json (or explicit --app)
  -> verify + launch + runtime hello
  -> driver.lock { deviceType: playcover, app, pid, profile hash }
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
bash scripts/build_playcover_runtime.sh

./ios-use playcover inspect /path/to/Source.app --json

./ios-use playcover prepare /path/to/Source.app \
  --output /path/to/Prepared.app \
  --runtime .ios-use/playcover/IOSUsePlayRuntime.framework \
  --json

./ios-use playcover verify /path/to/Prepared.app --json
./ios-use start --playcover
./ios-use status
./ios-use stop
```

Successful preparation records
`IOS_USE_HOME/playcover/last-prepared.json`. Use
`ios-use start --playcover --app /path/to/Prepared.app --timeout 20s` to
override that selection. The active backend, exact App path, PID, bundle, and
profile hash are stored in the ordinary `driver.lock`; normal `ios-use stop`
validates and terminates only that App process before clearing the lock.

All session-bound commands consult this lock. Driver commands therefore route to
PlayCover and cannot silently use XCTest, although DOM/actions currently return
an explicit unsupported-capability error until the injected runtime transport
is implemented.

Mutable backend state and hello records resolve through `IOSUsePaths` under
`IOS_USE_HOME/playcover/`. The App is signed with a narrow Mac sandbox profile;
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
