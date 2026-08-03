# Scripts Index

Run scripts from the repository root unless noted otherwise.

## Daily Development

| Script | Purpose |
| --- | --- |
| `scripts/build_swift_cli.sh [--debug]` | Build the Swift CLI, copy it to repo-root `./ios-use`, and keep the local PlayCover runtime current on supported Apple silicon/Xcode hosts. Release is the default. |
| `scripts/build_driver.sh [--debug\|--release] [--simulator-only]` | Generate the Xcode project and build driver IPA artifacts. Debug is the default and writes `IOS_USE_HOME`, or cwd `.ios-use/` when unset; release writes `driver/build/`. |
| `scripts/build_playcover_runtime.sh [--output <IOSUsePlayRuntime.framework>] [--replace] [--analyze]` | Build and ad-hoc sign the mixed Objective-C/Swift arm64 Mac Catalyst Runtime containing the pinned PlayTools sources; optionally run Clang static analysis. |
| `scripts/build_playcover_frida_gum_catalyst.sh [--source-root <path>] [--build-root <path>] [--replace]` | Reproduce the pinned official Frida GumJS QuickJS devkit for arm64 Mac Catalyst. The source checkout is verified at the pinned commit; native and Catalyst QuickJS plus the Gum devkit are built from source. |
| `scripts/build_playcover_frida_engine.sh [--source-root <path>] [--gum-build <path>\|--gum-devkit <path>\|--build-gum] [--output <IOSUseFridaEngine.framework>] [--replace]` | Build and ad-hoc sign the arm64 Mac Catalyst Engine wrapper against the official pinned Frida GumJS devkit. `--build-gum` checks out the exact pinned source, normalizes compiler-visible local paths, and disables only the generated libffi CFI metadata that Apple's non-ptrauth Catalyst assembler rejects; pinned source and executable libffi code are unchanged. The final static-symbol closure is checked and its exact upstream notices are embedded in the framework. Frida-generated source maps may still vary, so release records the actual framework digest instead of claiming byte-for-byte reproducibility. |
| `scripts/frida_distribution.py` | Verify the reviewed Frida static closure, generate the Engine notice, and stage the same pinned Git trees plus a content manifest into the release's corresponding source. It reuses the release build's source checkout and does not create another cache. |
| `scripts/test_playcover_frida_engine_live.sh <IOSUseFridaEngine.framework>` | Compile a temporary arm64 Mac Catalyst harness against a built Engine and prove real QuickJS initialization, console event delivery, synchronous and Promise evaluation, and Agent reset without launching an App. |

Local dev run standard:

```bash
bash scripts/build_swift_cli.sh --debug
./ios-use --help

./ios-use start --help
```

`build_playcover_runtime.sh` remains available when an explicit Runtime output
is needed for backend development. Normal
`start --mac --app <source-or-prepared.app>` discovers the
Runtime built by `build_swift_cli.sh`; users do not run a separate PlayCover
prepare command.

Before running a script that performs a real PlayCover prepare or launch,
initialize the host signer interactively once:

```bash
./ios-use config --mac
```

This explicit command creates and trusts the per-user identity; a cancelled
macOS authentication can be retried safely against the same identity. The
identity, final generation cache, Home discovery index, account PlayChain,
and UID socket root persist outside `IOS_USE_HOME`; each Home's selected
generation remains inside that Home. A temporary
`IOS_USE_HOME` isolates only logical Home state; it does not isolate those
account-global resources. Prepare/start paths only resolve the signer and must
not initialize or repair Keychain or Trust Settings from unattended
validation.

Any script that launches a PlayCover App, plus the entitlement capability
audit, must run only in a disposable macOS account and requires both private
environment values below:

```text
IOS_USE_PLAYCOVER_DISPOSABLE_ACCOUNT_ACK=I_UNDERSTAND_THIS_ACCOUNT_IS_DISPOSABLE
IOS_USE_PLAYCOVER_EXPECTED_ACCOUNT_HOME=<canonical-passwd-home>
```

The Home value must exactly match the effective account's canonical passwd
Home. The guard derives the account-global cache, Runtime, and socket roots from
that verified Home and UID. It exits with `EX_CONFIG` (78) before PlayCover
state or launch mutation when either value is absent or mismatched. Keep the
real Home value in private local configuration; GitHub workflows receive both
values through secrets, never repository variables or public artifacts.

Use `./ios-use`, not global `ios-use`, when validating current workspace changes.

## Validation

| Script | Purpose |
| --- | --- |
| `scripts/ci_test.sh [--skip-builds] [--skip-driver-sim-build]` | Main local Swift-only gate: script syntax checks, Swift CLI tests, driver tests, Swift CLI Release build, and Simulator driver build. Release CI uses `--skip-builds` to avoid duplicate artifact builds. |
| `scripts/ci_full_simulator.sh --driver-ipa <path> [--case CASES]` | Main full Simulator regression entry. Builds the Swift CLI, uses the caller-selected Simulator driver IPA, and runs the Node Simulator command matrix. |
| `scripts/test_swift_cli.sh` | Run Swift CLI unit tests plus installed-style CLI/nslog smoke checks and static driver log/version-stamp guards. |
| `scripts/test_driver_unit.sh` | Run Swift driver unit tests with an isolated default `IOS_USE_HOME` under `~/.ios-use/test-homes/driver-unit`. |
| `scripts/audit_playcover_upstreams.sh [--cache-dir <path>] [--metadata-only]` | Re-clone or reuse pinned PlayCover/PlayTools/inject/Yams checkouts; require script pins, provenance pins, SwiftPM resolutions, licenses, expected vendored file sets, and local-patch sets to agree exactly. `--metadata-only` runs the hermetic closure without cloning. |
| `scripts/test_playcover_packaging_contract.sh` | Hermetic packaging audit tests, including negative cases for a deleted expected source, a one-sided provenance pin change, and a mismatched Yams resolution. |
| `scripts/test_playcover_live_workflow_contract.sh` | Hermetic live-workflow contract with negative cases proving that both PlayCover CI jobs use the provisioned self-hosted runner, launch-capable CI/release jobs receive the two disposable-account values only from secrets, `test_playcover_backend.sh --live` invokes only the pending-launch and Runtime protocol/crash gates in that order, and the manual job has no private evidence or external-App attestation dependency and uploads only its runner-temporary `run.log`. |
| `scripts/test_playcover_pending_launch_crash_live.sh --live` | Clean-HEAD public-fixture gate that builds committed HEAD outside the checkout and applies `_exit(86)` at the five real persistence boundaries: workspace open returned, exact owner durable, `driver.lock` durable, journal committed, and journal removed. It proves the exact `intent → owned → driverLockCommitted` record, typed fail-closed behavior for an unowned intent, exact-owner stop, and normal reuse after every recoverable handoff. The disposable-account harness authenticates and records an owner only to clean up its final deliberately unresolved intent; product code performs no intent recovery. |
| `scripts/test_playcover_prepare_differential.sh` | Run the hermetic pinned Installer-vs-ios-use prepare differential suite in an isolated SwiftPM scratch directory and publish its fixture-only schema-v1 attestation without replacing existing evidence. It binds an embedded 50-file source-closure digest to the loaded XCTest image's exact device/inode and content hash; it does not consume a private live UI scenario. |
| `scripts/test_playcover_entitlement_capabilities.sh --prepared-app <App.app> --playchain-root <path>` | Test-only manual gate that copies the exact signed entitlements from an account-global prepared App's main executable onto a standalone probe, verifies semantic entitlement equality, and directly exercises the fixed UID socket root plus account PlayChain filesystem capabilities without `sandbox-exec`. |
| `scripts/test_playcover_runtime_stdio.sh` | Compiles the production early-constructor stdio redirector with a small harness and proves exact device/inode capture plus fail-closed rejection of missing identity, replacement, symlink, broad mode, and multiple-link files. |
| `scripts/characterize_playcover_external_prepare.sh --scenario <path> --runtime <path> --playtools <path> --work-root <path> --report <path> --commit <sha>` | Collect a diagnostic-only external-App prepare report from the full pinned PlayTools Installer oracle and the real ios-use service prepare path. Every input is mandatory; the clean committed HEAD, fresh absolute work/report paths outside the checkout, cleared environment, fixed XCTest, owner-only report, and no-overwrite publication are enforced. The schema-v2 report contains observed typed identities, raw differences, and only the SHA-256 binding of the canonical requested work-root path, never that path itself. The command deliberately retains the work root for operator inspection and never recursively removes it. |
| `scripts/test_playcover_external_prepare_characterization_contract.sh` | Negative contract for the diagnostic entrypoint: missing/duplicate inputs, relative, CR/LF-bearing, or existing work paths, checkout-confined work/report paths, mismatched or dirty HEAD, the fixed filtered XCTest, and recursive rejection of conclusion/configuration vocabulary or canonical work-root disclosure in report keys and values. |
| `scripts/test_playcover_external_prepare_differential.sh --profile <path> --profile-sha256 <sha256> --scenario <path> --runtime <path> --playtools <path> --work-root <path> --attestation <path> --commit <sha>` | Run the configured external-App prepare differential against one separately reviewed exact profile. Every input is mandatory; after the operator archives or explicitly removes the retained characterization tree, `--work-root` must reuse that same canonical requested path and again be fresh. The final owner-only attestation path must also be fresh and outside the checkout. The supplied commit must be the clean committed HEAD: tracked working-tree changes, index changes, and untracked non-ignored files are rejected, while ignored build output may remain. The entrypoint runs only the configured XCTest in a cleared environment, verifies the exact external schema and work-root binding before prepare, retains its own work root for operator inspection, and publishes by hard link without overwrite. It never derives allowances from a raw diagnostic report or recursively removes the work root. |
| `scripts/test_playcover_external_prepare_differential_contract.sh` | Focused negative contract for the external prepare entrypoint: missing/duplicate arguments, relative or CR/LF-bearing paths, stale output paths, checkout-confined outputs, invalid digests/revisions, dirty tracked/index/untracked state, and a commit other than current HEAD must fail before XCTest. |
| `scripts/test_playcover_backend.sh --non-live` | Unified Apple-silicon integration-host gate: upstream audit, fresh workspace CLI/Runtime build and analysis, fixture build, production-linked compositor/PlayChain smoke, vendored and complete CLI Swift tests (including recorded PID reuse), hermetic pinned-prepare differential attestation, and release-installed execution. Because installed execution performs a real fixture launch, the host must be a disposable account with the two explicit safety values, the stable signer initialized by `./ios-use config --mac`, and a launch-capable GUI session. `--live` is the core live aggregate and runs only the pending-launch same-boot crash/restart gate followed by the Runtime protocol/crash stress gate against the committed public fixture. |
| `scripts/test_playcover_cgshw_compositor.sh [--deterministic-only]` | Links the production compositor into deterministic layout, inverse-coordinate, backing-scale, restored 316 x 685 half-physical-pixel geometry, full-edge canvas-only crop, fixed safe-area, and fixed UIKit phone-identity contract tests. Without `--deterministic-only`, it also runs the live CGWindow compositor smoke. |
| `scripts/test_playcover_fixture_live.sh --live` | Optional additive diagnostic that runs the fixture matrix on an unlocked GUI host with exactly one eligible extended non-main display whose backing scale differs from the main display. It preserves one PID/session/generation/window number across exact-window title-bar drags and fixed host scales 0.75 main, 1.0 extended, and 0.875 main, plus canvas-only capture, inverse-scale global mouse, and title-bar miss-hit checks. It is not part of the core `test_playcover_backend.sh --live` or CI live gate. |
| `scripts/test_playcover_runtime_stress_live.sh` | Current-checkout public-fixture gate with fresh build scratch and a temporary logical Home in the explicitly disposable account. It verifies the account-global generation path, fixed UID socket root, Home-local stdio log path, authenticated protocol boundaries, 20 unique-session bare lifecycle cycles on one generation, endpoint loss, fixture-owned self-SIGKILL/stale classification, preserved crash residue, and restart recovery. Its no-clobber attestation binds HEAD and the exact CLI/Runtime/complete fixture App tree/probe digests to every result observation. |
| `scripts/test_playcover_external_app_live.sh --live` | Optional additive generic 20-cycle external-App UI/mouse/lifecycle diagnostic. It requires explicit authorization, a private schema-v1 scenario, an unlocked two-display topology matching `live-matrix-v2.tsv`, and an evidence directory outside the checkout. Global target input is mapped only from Runtime `canvasCGWindowRect` plus `displayScale`, never the outer host frame; its redacted pass attestation is schema v2. It is not part of the core `test_playcover_backend.sh --live` or CI live gate. |
| `scripts/test_playcover_installed_layout.sh [--release-dir <path>]` | Without an argument, package the fresh local CLI/Runtime. With `--release-dir`, consume the exact release-build output. Both paths verify checksums, install a read-only Runtime through `install.sh`, run fixture start/status/stop outside the source tree with a temporary logical Home in the explicitly disposable account, and prove the installed framework is unchanged. |
| `scripts/test_simulator_commands.mjs` | Node-based Simulator command case runner used by full Simulator validation. |
| `scripts/ios_use_test_simulator.js` | Shared helper used by driver unit tests and Simulator command tests to create/boot the fixed `IOSUseTest` Simulator. |

Test standard:

```bash
bash scripts/ci_test.sh
```

The external-App prepare differential is deliberately separate from the
hermetic fixture gate. A reviewed profile and its SHA-256 must be supplied as
two independent arguments, together with the private scenario, complete
Runtime and PlayTools input trees, a fresh work root, a fresh attestation path,
and the exact current checkout commit. The separate characterization command
records source/Runtime/PlayTools identities, producer revisions, and raw
differences with `disposition: diagnostic-only`; it does not generate a
profile, reasons, symbols, or a pass result. The commit must be a clean
committed HEAD; ignored local build output is permitted, but tracked, staged,
or untracked non-ignored changes are not. Its report is observation input for
manual review only and cannot be converted into allowances by either
entrypoint. External report, reviewed profile, and formal attestation use
schema version 2 with scope `external-app-structural-v2`. Characterization
retains its work root for inspection. After manually archiving or explicitly
removing that tree, the operator runs formal execution with the exact same
canonical requested path; formal execution also retains its work root.
Neither entrypoint performs recursive cleanup. `workRootSHA256` is SHA-256
over the path's UTF-8 bytes with no terminator or newline, so evidence binds
the location without publishing the path. CR/LF are rejected before path
canonicalization. Fresh-path and no-overwrite checks remain mandatory for both
executions.

The signed entitlement capability audit consumes an already prepared App and
does not add a public CLI command or produce an attestation:

```bash
bash scripts/test_playcover_entitlement_capabilities.sh \
  --prepared-app "<account-global-cache>/objects/<64hex>/App.app" \
  --playchain-root "<account-application-support>/mac/playchain"
```

Both arguments must be canonical absolute paths beneath the roots derived from
the verified disposable account. The prepared App must be a direct child of a
lowercase 64-hex directory under account-global `objects`; the PlayChain root
must be the account-global owner-only `playchain` directory. The gate also
validates the account-global `homes`/`locks` namespaces and fixed UID socket
root.

The gate verifies the prepared App and its real main executable, signs only a
fresh temporary probe with the exported entitlement plist, re-exports and
compares the two entitlement dictionaries, then executes the signed probe
directly. It creates and retains unique audit directories beneath the fixed UID
socket root and the selected account PlayChain root; denied-path
fixtures stay in the separate owner-only evidence root. It prints
`PCAP-EVIDENCE-ROOT <absolute-path>` for that retained evidence. Only the
exclusive file case unlinks its own file; socket and SQLite evidence are not
recursively cleaned up. Run it only in the explicitly acknowledged disposable
account.

Run the full UI replay only when needed:

```bash
bash scripts/ci_full_simulator.sh --driver-ipa .ios-use/driver-sim.ipa
bash scripts/ci_full_simulator.sh --driver-ipa .ios-use/driver-sim.ipa --case WF-1
```

GitHub CI uses `.github/workflows/ci.yml` for script syntax/packaging metadata,
Swift CLI, and driver unit checks on every matching pull request. Changes to
release workflow paths and release notes trigger that CI. The PlayCover
non-live integration job is explicit-dispatch-only and bound to the provisioned
`[self-hosted, macOS, arm64, playcover-live]` runner because its installed
execution performs a real launch; that host must already have the stable signer
initialized by `./ios-use config --mac`, a launch-capable GUI session, and the
two disposable-account secrets described above. The release workflow uses the
same provisioned runner and secret-backed values for installed execution.

The core PlayCover live gate is an explicit dispatch-only job on that same
runner. It uses only the committed public fixture, needs no operator App,
private scenario/evidence directory, or external-App attestation, and uploads
the runner-temporary `run.log`. The fixture two-display matrix and generic
external-App two-display workflow remain independently runnable additive
diagnostics, not core live completion requirements. The full Simulator UI
replay lives in `.github/workflows/simulator.yml` and is manual-only.

## Install And Benchmark

| Script | Purpose |
| --- | --- |
| `scripts/install.sh` | On Apple Silicon, verify checksums and install the release CLI, driver IPAs, and prebuilt Mac Runtime plus Frida Engine under `<prefix>/share/ios-use/mac/`; both frameworks are signature-verified immutable preparation inputs. Also installs the skill and altsign helper. `--build-from-source` additionally requires full Xcode, Swift, xcodegen, and the pinned Frida build toolchain. Intel macOS is unsupported. |
| `scripts/release_build.sh` | From a clean Git tree, audit all pins/licenses, force fresh Runtime and pinned Frida Engine builds, compare tracked inputs with the exact corresponding-source archive, and stage read-only Mac backend resources, build-manifest, license, provenance, CLI, and driver assets under `release/`; validates `IOS_USE_RELEASE_VERSION` when provided. See [docs/how-to-release.md](../docs/how-to-release.md). |
| `scripts/benchmark.js --bench ios-use --udid <udid> --driver-ipa <path>` | Measure ios-use on a real device and write JSON only. Screenshot cases pass `--no-ocr` to isolate pixel capture. The script never builds, signs, installs, or runs `config`; the device must already be prepared with a driver whose configured `driverVersion` matches the IPA version. |
| `scripts/benchmark.js --bench wda --udid <udid> --wda-bundle-id <id>` | Measure Appium/WebDriverAgent on a real device and write JSON only. This is a separate WDA run, not an implicit ios-use comparison. |

Benchmark quick examples:

```bash
# ios-use read-path benchmark; no build/sign/config happens inside the script.
node scripts/benchmark.js --bench ios-use \
  --udid 00008150-0015309E2EE3401C \
  --driver-ipa .ios-use/driver.ipa \
  --preset read \
  --iterations 5

# WDA read-path benchmark.
node scripts/benchmark.js --bench wda \
  --udid 00008150-0015309E2EE3401C \
  --wda-bundle-id com.example.WebDriverAgentRunner.xctrunner \
  --preset read
```

Use `node scripts/benchmark.js --help` for the complete invocation contract, including presets, case selection, input labels, WDA/Appium options, baseline comparison, and driver identity checks.
Use `node scripts/benchmark.js --list-cases` to print the current case registry. Public benchmark setup and latest summary live in `docs/benchmark.md`.

## Release Artifacts

The GitHub release workflow builds and uploads:

| Asset | Purpose |
| --- | --- |
| `ios-use-darwin-arm64` | Prebuilt Apple Silicon macOS CLI binary. The Runtime and complete release install are Apple-Silicon-only; Intel macOS is unsupported. |
| `driver.ipa` | Real-device XCTest driver IPA. |
| `driver-sim.ipa` | Simulator XCTest driver IPA. |
| `ios-use-mac-resources.tar.gz` | Read-only, prebuilt Runtime, pinned sandbox rules, and pinned arm64 Mac Catalyst Frida Engine installed under `<prefix>/share/ios-use/mac/`. The Engine is copied only for `start --mac --frida`. |
| `ios-use-vX.Y.Z-corresponding-source.tar.gz` | Complete corresponding source for the release, including vendored upstreams, the full pinned Yams Git tree, the Frida GumJS static source closure, build recipes, source commit, and Runtime-input digest. |
| `MAC-BACKEND-BUILD-MANIFEST-vX.Y.Z.txt` | Exact source commit, Yams/Frida evidence, Runtime-input digest, Mac backend resources archive digest, and corresponding-source digest. |
| `FRIDA-STATIC-DEPENDENCY-NOTICES.txt` | Exact license and attribution material for the components statically linked into `IOSUseFridaEngine.framework`; identical to the notice embedded in the framework. |
| `LICENSE`, `*-LICENSE-*`, `THIRD-PARTY-LICENSES.md`, `MAC-BACKEND-PROVENANCE-vX.Y.Z.md` | ios-use and upstream license/provenance materials, including the Yams MIT license, for the Runtime distribution. |
| `CHANGELOG-vX.Y.Z.md` | Focused changes and upgrade notes for that release. |
| `SHA256SUMS` | Checksums for all uploaded content assets. |
