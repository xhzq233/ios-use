# PlayCover upstream provenance

- Upstream: https://github.com/PlayCover/PlayCover.git
- Pinned commit: `7190cc9ce57c8dee0e222918468f2579acc95e1b`
- License: GPL-3.0; see `LICENSE`
- Imported files retain their upstream directory and file names.
- Corresponding source: the release asset named
  `ios-use-v<version>-corresponding-source.tar.gz` contains this imported tree,
  local headless integration, build recipes, license, and this record.

## Expected vendored upstream files

This list is duplicated deliberately in `scripts/audit_playcover_upstreams.sh`.
The audit requires the script list, this provenance list, and the actual
vendored tree (excluding the three local-only `Headless/` files) to match
exactly.

<!-- audit-vendored-files:start -->
- `AppInstaller/Installer.swift`
- `Model/AppInfo.swift`
- `Model/BaseApp.swift`
- `Model/PlayApp.swift`
- `Model/PlayRules.swift`
- `PlayCoverError.swift`
- `Rules/default.yaml`
- `Utils/Entitlements.swift`
- `Utils/Extensions/DataExtensions.swift`
- `Utils/Extensions/FileExtensions.swift`
- `Utils/Extensions/URLExtensions.swift`
- `Utils/KeyCover.swift`
- `Utils/Macho.swift`
- `Utils/PlayTools.swift`
- `Utils/Shell.swift`
- `Utils/SystemConfig.swift`
<!-- audit-vendored-files:end -->

## Recorded local source patches

The audit compares this tree directly with the pinned checkout. The following
paths are the complete allowlist of changed imported sources; a changed path
not listed here, or a listed path that becomes byte-identical, fails
`scripts/audit_playcover_upstreams.sh`.

<!-- audit-local-patches:start -->
- `PlayCover/AppInstaller/Installer.swift`
- `PlayCover/Model/BaseApp.swift`
- `PlayCover/Model/PlayRules.swift`
- `PlayCover/PlayCoverError.swift`
- `PlayCover/Utils/Entitlements.swift`
- `PlayCover/Utils/Extensions/DataExtensions.swift`
- `PlayCover/Utils/Extensions/FileExtensions.swift`
- `PlayCover/Utils/KeyCover.swift`
- `PlayCover/Utils/Macho.swift`
- `PlayCover/Utils/PlayTools.swift`
- `PlayCover/Utils/Shell.swift`
<!-- audit-local-patches:end -->

## Local headless integration

The imported source is the authority for iOS-to-Mac conversion and prepare
ordering.  `Package.swift` selects the non-GUI closure and
`PlayCover/Headless/PlayCoverUpstreamEngine.swift` provides the ios-use API.
`Model/PlayApp.swift` is nevertheless retained byte-for-byte, audited, and
included in corresponding source. It is explicitly excluded from the SwiftPM
target because the class also closes over non-vendored GUI/global application
state; exclusion is a link boundary, not a source omission.

Local patches are intentionally limited to:

- importing Darwin's Mach-O declarations when compiled by SwiftPM;
- exposing the pinned conversion primitives to the headless facade;
- replacing PlayCover GUI/preferences/container discovery with explicit
  `IOS_USE_HOME` inputs;
- using the embedded ios-use Runtime load path instead of the system-installed
  PlayTools path;
- preserving the pinned injection preflight failure boundary with an
  always-mapped view of the production executable, so validating an
  already-converted thin Mach-O does not eagerly copy the whole file before
  pinned Inject performs its mutation read; the independent pinned
  `installInIPA` oracle remains unchanged;
- explicit inside-out ad-hoc signing in the ios-use production path (never
  `codesign --deep` there), while retaining pinned `--deep` behavior solely in
  the independent differential oracle;
- owner-selected Unix-socket sandbox rules recorded in the entitlement diff;
- adding an empty `UILaunchScreen` only when both modern and storyboard launch
  declarations are absent, preventing Catalyst's legacy 320 x 480 canvas while
  preserving all existing launch-screen and scene keys;
- strict all-slice bounds, architecture, load-command, zero-padding,
  duplicate-signature-command, source-immutability, and signature-verification
  checks required by the ios-use backend and differential gate.

`Installer.swift` is intentionally the only large source-shaped patch. It is a
line-diffable headless dependency graph: the GUI prompt/progress callback,
IPA unzip/pack/export path and Finder application-library wrapper are removed.
The imported `resolveValidMachOs`, `saveEntitlements` and
`removeMobileProvision` symbols remain and are called by the engine. The
enumerator's extension filter is widened to recognize every supported Mach-O
magic, including fat64, so nested extensions/frameworks are not silently
skipped.

The pinned Installer sequence maps directly to the headless engine:

| Pinned Installer operation | Headless call |
| --- | --- |
| entitlement evidence | `Installer.saveEntitlements` |
| Mach-O enumeration | `Installer.resolveValidMachOs` |
| encryption rejection | `Macho.isMachoEncrypted` semantics in bounded inspection |
| per-object conversion | `Macho.convertMacho` |
| per-object signing | `Shell.signMacho` |
| main executable injection | `PlayTools.injectRuntime` → pinned `Inject.injectMachO` |
| provisioning removal | `Installer.removeMobileProvision` |
| minimum OS / Info write | pinned `AppInfo` semantics plus absent-launch-screen compatibility key |
| entitlement composition | `PlayApp.sign` → `Entitlements.composeEntitlements` |
| final sign | `PlayApp.sign` → `Shell.signAppWith`; code-object tree inside-out, never `--deep` |
| quarantine removal | pinned `/usr/bin/xattr -dr com.apple.quarantine` operation |
| completion | full inventory, load-command and strict signature verification |

### `PlayApp.sign` signing authority and headless boundary

Pinned `Model/PlayApp.swift` is the source authority for the entitlement/root
signing relationship. The audit checks the following statements in source
order, and the differential oracle records the two calls at their actual
adapter call sites:

| Pinned `PlayApp.sign` symbol | Headless preservation / strengthening |
| --- | --- |
| `Entitlements.composeEntitlements(self)` | Both paths call the vendored `Entitlements.composeEntitlements` directly on the staged `BaseApp`. Explicit `discordActivityEnabled`, `bypass`, `playSignActive`, and managed-home inputs replace GUI `AppSettings` reads. Production keeps the pinned rule that source entitlements are overlaid only when PlaySign is active, then appends only the managed Runtime socket/PlayChain sandbox rules. The manifest records every key removed from the source by the pinned non-PlaySign composition. |
| `conf.store(tmpEnts)` | Both paths serialize the resulting dictionary to an owner-private temporary plist before codesign. The pinned oracle uses its reference plist; production writes the final composed data immediately before each entitlement-bearing sign and removes it with `defer`. |
| `Shell.signAppWith(executable, entitlements: tmpEnts)` | The pinned oracle calls `Shell.signAppWithPinnedOracle` with the exact upstream root target and `--deep` arguments. Production deterministically reproduces the resulting code-object state inside-out: every child is ad-hoc signed without restoring source entitlements, each child is verified, and the root `.` is signed last with the final composed entitlements before the whole order is re-verified. |

The rest of `PlayApp` is corresponding source but is deliberately not linked:

| GUI/global `PlayApp` symbols | Why the headless target does not link them |
| --- | --- |
| `init`, alias URLs, `hasAlias`, Finder/cache/delete helpers | They create global Finder aliases, load keymap/Discord state, or mutate/delete the installed/source App. ios-use prepares only a managed clone and keeps the source read-only. |
| `launch`, `runAppExec`, `isInfoPlistSigned`, timeout assertions | ios-use owns launch/PID/session/UDS identity and termination. Linking PlayCover's `NSWorkspace` alias launch and display-sleep loop would create a second lifecycle owner. |
| `unlockKeyCover` / `lockKeyCover` UI branch | The methods depend on `NSAlert` and mutable GUI settings. The headless KeyCover/PlayChain primitives are invoked from the managed prepare/session boundary without modal UI. |
| `prohibitedToPlay`, `maliciousProhibited`, and their deletion/cache branch | These are PlayCover product policy and GUI recovery behavior, not conversion or signing semantics. In particular, deleting an input conflicts with ios-use's source-immutability contract. |

`Package.swift` therefore names `Model/PlayApp.swift` in `exclude` rather than
silently leaving an unhandled source. `scripts/audit_playcover_upstreams.sh`
requires that exact exclusion, the ordered `PlayApp.sign` symbols, and the
byte-identical pinned file. The full prepare differential test additionally
requires the adapter trace to execute composition before root signing and
requires the production signing manifest to list every nested code object
before `.`.

### Failure-layer boundary

The headless facade preserves the pinned primitive order while adding typed
ios-use error boundaries. This is diagnostic classification only; it does not
replace a PlayCover primitive or retry a failed mutation:

| Pinned/local operation | ios-use failure boundary |
| --- | --- |
| Mach-O conversion or Runtime load-command injection | `machOTransformFailed` / `playcover_macho_transform_failed` |
| `Entitlements.composeEntitlements` and composed-plist serialization | `entitlementFailed` / `playcover_entitlement_failed` |
| nested or root `Shell` signing/verification | `codeSigningFailed` / `playcover_codesign_failed` |
| `NSWorkspace` launch identity, dyld launch, or rollback | `launchFailed` / `playcover_dyld_launch_failed` |
| post-launch authenticated Runtime hello deadline | `launchTimedOut` / `playcover_runtime_hello_timed_out` |

Malformed Mach-O remains a validation failure before conversion. The Runtime
hello timeout is deliberately distinct from launch failure because the process
may exist but has not proven its direct Unix-socket identity. Machine JSON
exposes these stable phase/code pairs without embedding source paths, session
IDs, or signing material.

The complete prepare fixture exercises that sequence with a signed two-slice
arm64-iPhoneOS/x86_64-simulator main executable, `.appex`, framework, resource,
provisioning file, arm64 Catalyst Runtime, and a structurally valid
PlayTools/AKInterface resource tree. Additional fixtures cover thin/fat/fat64,
swapped input, Swift UIKit rewrite, exact/basename duplicate injection, nested
inventory, capability preservation and post-sign extension entitlement
recovery.

## Pinned headless Installer oracle

`Headless/PlayCoverPrepareDifferential.swift` contains two deliberately distinct
paths:

- `PlayCoverPinnedHeadlessInstallerOracle` is the authoritative differential
  reference. It calls the vendored `Installer`, `Macho`, `PlayTools`, `Inject`,
  `AppInfo`, `Entitlements`, and `Shell` APIs in the pinned Installer mutation
  order. Its `PlayApp.sign` adapter trace records direct entitlement
  composition before the exact pinned root sign. Its PlayTools step calls the complete pinned
  `PlayTools.installInIPA`, including plugin copy/signing and the pinned
  `Shell.signApp(--deep --preserve-metadata=entitlements)` operation.
- `PlayCoverPinnedPrimitiveCharacterization` is retained as a smaller diagnostic
  path and is explicitly not an Installer oracle.

Neither path calls `PlayCoverUpstreamEngine.prepare`, `PlayCoverService.prepare`,
or a shared prepare wrapper. The oracle therefore remains independent of the
ios-use side under comparison.

The pristine GUI `Installer.install` entry point is not linked into SwiftPM
because it depends on non-vendored `NSAlert`, preferences, IPA transport,
progress models, Finder-library placement, and `PlayApp` state. The headless
adapter removes only that UI/transport shell:

- a supplied unpacked signed `.app` replaces IPA allocate/unzip checks;
- an APFS clone to an explicit managed output replaces the wrapper's path move;
- UI choice and progress callbacks are omitted; their Installer preferences are
  fixed to the pinned defaults (`installPlayTools = true` and application
  category `.none`), including the default category mutation at its original
  sequence point.

All app mutations, including the final pinned `codesign --deep`, remain in exact
Installer order. `PlayTools.installInIPAForHeadlessOracle` changes only
`Bundle.main` resource discovery so the test can supply the built
PlayTools/AKInterface fixture; it delegates injection, plugin installation, and
signing to the pinned method and verifies their postconditions. The adapter
records those internal operations at their actual call sites. The fixture
starts its executables at mode `0700`, then asserts the pinned Installer's
in-sequence main-executable `0755` mutation and the matching ios-use result.

The differential analyzer's inventory boundary is every Mach-O object in the
prepared app. It inspects every thin/fat32/fat64 slice and compares
architecture, container kind/placement/endianness, header flags/reserved
fields, platform, minimum OS/SDK, encryption, RPATHs, dependencies, immutable
content, codesign metadata, and canonical entitlements. Embedded-signature
comparison covers the complete SuperBlob slot table and offsets, envelope and
alignment bytes, opaque slot hashes, CodeDirectory structure plus every
special/code-slot hash (including the resource seal), and separately decoded
XML/DER entitlements whose semantic parity is enforced. XML and DER slot bytes
also receive exact digest allowances after zeroing only the run-specific
managed-home path byte sequences, so alternate plist/DER encodings remain
observable; the displayed CDHash is recomputed and validated from the primary
CodeDirectory.
The parser independently rejects a nonzero FAT64 reserved word and nonzero
inter-slice or trailing fat-container padding; these are enforced zero
invariants, not allowance-bearing diff fields. Every load command retains a raw
digest except the known path-bearing dylib and RPATH commands, whose normalized
path semantics are compared exactly after their otherwise-unused padding has
been validated as zero. One-sided Runtime and AKInterface objects require
byte-exact pre-transform baselines.

The fixture separately asserts the preparation effects outside that per-Mach-O
inventory: canonical Info.plist and application-category output, provisioning
profile removal, quarantine removal, copied PlayTools localization and plugin
resources, embedded Runtime resources, and preservation of unrelated fixture
resources. It exercises real signed FAT32 and FAT64 multi-slice inputs and a
real secondary-slice mutation. The gate accepts only absent/exact expectations
plus the single typed 40-character lowercase CodeDirectory digest invariant;
broad `any`, presence, and substring expectations are rejected. Every actual
difference must consume exactly one non-stale allowance.

The dedicated gate is:

```sh
scripts/test_playcover_prepare_differential.sh
```

The gate runs in an isolated SwiftPM scratch directory and publishes a
schema-v1 attestation only after every exact allowance and one-sided baseline
is consumed. Its producer closure is a fixed 36-file list whose normalized
SHA-256 is embedded into the executing test binary at build time and checked
against source snapshots at both ends of attestation. The binary digest is read
through an open descriptor whose device/inode must match the vnode backing the
loaded `.xctest` Mach-O image. The source and both prepared Apps are then
re-inspected, and the pinned result must carry the full-PlayTools Installer
oracle producer identity. Managed-path normalization accepts only actual
lexical/canonical roots and their exact descendants; it does not invent
`/private` aliases or collapse sibling path prefixes.
