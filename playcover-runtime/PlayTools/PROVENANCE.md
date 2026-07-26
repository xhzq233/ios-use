# PlayTools upstream provenance

- Upstream: https://github.com/PlayCover/PlayTools.git
- Pinned commit: `d688f695e83bf080be9ad4b7346e914c7c343d96`
- License: AGPL-3.0; see `LICENSE`
- Corresponding source: the release asset named
  `ios-use-v<version>-corresponding-source.tar.gz` contains this imported tree,
  the local Runtime integration, build recipe, license, and this record.

## Expected vendored upstream files

The audit requires this list, its script-owned counterpart, and the actual
vendored source tree to match exactly before comparing bytes with upstream.

<!-- audit-vendored-files:start -->
- `AKPlugin.swift`
- `PlayTools/Controls/Backend/Toucher.swift`
- `PlayTools/Controls/PTFakeTouch/Additions/IOHIDEvent+KIF.h`
- `PlayTools/Controls/PTFakeTouch/Additions/IOHIDEvent+KIF.m`
- `PlayTools/Controls/PTFakeTouch/Additions/UITouch-KIFAdditions.h`
- `PlayTools/Controls/PTFakeTouch/Additions/UITouch-KIFAdditions.m`
- `PlayTools/Controls/PTFakeTouch/NSObject+Swizzle.h`
- `PlayTools/Controls/PTFakeTouch/NSObject+Swizzle.m`
- `PlayTools/Controls/PTFakeTouch/PTFakeMetaTouch.h`
- `PlayTools/Controls/PTFakeTouch/PTFakeMetaTouch.m`
- `PlayTools/Controls/PTFakeTouch/UIApplication+Private.h`
- `PlayTools/Controls/PTFakeTouch/UIEvent+Private.h`
- `PlayTools/Controls/PTFakeTouch/UITouch+Private.h`
- `PlayTools/MysticRunes/PlayedApple.swift`
- `PlayTools/MysticRunes/PlayedAppleDB.swift`
- `PlayTools/MysticRunes/PlayedAppleDBConstants.swift`
- `PlayTools/PlayLoader.h`
- `PlayTools/PlayLoader.m`
- `PlayTools/PlayScreen.swift`
- `Plugin.swift`
<!-- audit-vendored-files:end -->

## Recorded local source patches

The audit compares imported sources directly with the pinned checkout and emits
their unified diffs. This is the complete allowlist; unrecorded changes and
stale entries both fail.

<!-- audit-local-patches:start -->
- `AKPlugin.swift`
- `PlayTools/Controls/Backend/Toucher.swift`
- `PlayTools/Controls/PTFakeTouch/Additions/UITouch-KIFAdditions.m`
- `PlayTools/Controls/PTFakeTouch/NSObject+Swizzle.m`
- `PlayTools/Controls/PTFakeTouch/PTFakeMetaTouch.h`
- `PlayTools/Controls/PTFakeTouch/PTFakeMetaTouch.m`
- `PlayTools/MysticRunes/PlayedApple.swift`
- `PlayTools/MysticRunes/PlayedAppleDB.swift`
- `PlayTools/MysticRunes/PlayedAppleDBConstants.swift`
- `PlayTools/PlayLoader.m`
- `PlayTools/PlayScreen.swift`
<!-- audit-local-patches:end -->

## Local Runtime integration

The imported sources are compiled into one mixed Objective-C/Swift Mac Catalyst
framework by `playcover-runtime/project.yml` and
`scripts/build_playcover_runtime.sh`. ios-use-owned files outside this directory
provide the fixed device contract, Simulator-style transparent AppKit host,
UDS automation, and capture diagnostics. They do not replace the imported
loader, screen, touch, swizzle, or PlayChain implementations.

The only packaging changes are project membership, Catalyst compilation flags,
and public headers required to link the Runtime. The release package keeps the
framework read-only under `<prefix>/share/ios-use/playcover/`; each prepared App
receives a copy during the pinned PlayCover prepare flow. The Runtime is never
rebuilt from or written to `IOS_USE_HOME` by installation.

### AKPlugin Catalyst boundary

`AKPlugin.swift` contains the deliberate Catalyst boundary patch. On Mac
Catalyst, upstream's `AKInterface.bundle` cannot be linked as an AppKit plugin,
so ios-use retains the `Plugin` protocol and moves only the fixed-window
observations/policy into `IOSUsePlayAppKitBridge` in the single injected
framework. The audit script emits the exact unified diff against the pinned
file and the non-live gate compiles it with warnings as errors before running
the compositor probe.

| Upstream symbol | Catalyst treatment | Reason and differential gate |
| --- | --- | --- |
| `init`, `screenCount`, `mousePoint`, `windowFrame`, `mainScreenFrame`, `isMainScreenEqualToFirst`, `isFullscreen`, `setMenuBarVisible` | Delegated to `IOSUsePlayAppKitBridge`. | The bridge presents a public transparent, resizable Simulator-style host while preserving a fixed 430 × 932 inner canvas and reports both host and canvas observations. Runtime build plus CGSHW compositor smoke is the executable differential gate. |
| `hideCursor`, `hideCursorMove`, `warpCursor`, `unhideCursor` | Explicit no-op. | Cursor capture/warping belongs to PlayCover's interactive desktop GUI and would alter the user's host pointer. ios-use injects touch through the retained `Toucher`/`PTFakeMetaTouch` path instead. |
| `terminateApplication` | Explicit no-op. | Lifecycle is host-owned by `ios-use stop`; an in-process GUI callback must not terminate an arbitrary app. |
| `setupKeyboard`, `setupMouseMoved`, `setupMouseButton`, `setupScrollWheel` | Explicit no-op after accepting the protocol callbacks. | Upstream uses local AppKit monitors for keymapping/editor interaction. ios-use has no GUI keymap/editor and routes supported automation through Runtime UDS and the touch backend. |
| `urlForApplicationWithBundleIdentifier` | Returns `nil`. | The GUI app-library lookup is outside the single-target session contract; `start` is the only lifecycle entry point. |

### Toucher Runtime adapter

The pinned `Toucher.touchcam` remains the Runtime gesture frontend and still
owns touch-ID allocation/reuse before calling `PTFakeMetaTouch`. Its local
adapter adds optional, already-resolved `UIWindow` and `UIView` arguments so a
fresh Runtime selector/hit-test cannot be silently replaced by PlayTools'
global key-window guess. Existing upstream callers keep their original
defaults. `IOSUsePlayTouchBridge` is the narrow Objective-C entry point; Runtime
automation does not bypass Toucher.

The retained `Plugin.swift` protocol, `PlayLoader`, `PlayScreen`, swizzle,
touch, and PlayChain sources are compared directly with the pinned checkout by
`scripts/audit_playcover_upstreams.sh`. Every allowed changed path is listed
above and emitted as a full unified diff; an unrecorded or stale path fails the
gate.
