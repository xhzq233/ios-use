# Scripts Index

Run scripts from the repository root unless noted otherwise.

## Daily Development

| Script | Purpose |
| --- | --- |
| `scripts/build_swift_cli.sh [--debug]` | Build the Swift CLI, copy it to repo-root `./ios-use`, and keep the local PlayCover runtime current on supported Apple silicon/Xcode hosts. Release is the default. |
| `scripts/build_driver.sh [--debug\|--release] [--simulator-only]` | Generate the Xcode project and build driver IPA artifacts. Debug is the default and writes `IOS_USE_HOME`, or cwd `.ios-use/` when unset; release writes `driver/build/`. |
| `scripts/build_playcover_runtime.sh [--output <IOSUsePlayRuntime.framework>] [--replace] [--analyze]` | Build and ad-hoc sign the mixed Objective-C/Swift arm64 Mac Catalyst Runtime containing the pinned PlayTools sources; optionally run Clang static analysis. |

Local dev run standard:

```bash
bash scripts/build_swift_cli.sh --debug
./ios-use --help

./ios-use start --help
```

`build_playcover_runtime.sh` remains available when an explicit Runtime output
is needed for backend development. Normal
`start --playcover --app <source-or-managed-prepared.app>` discovers the
Runtime built by `build_swift_cli.sh`; users do not run a separate PlayCover
prepare command.

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
| `scripts/test_playcover_live_workflow_contract.sh` | Locked-safe live-workflow contract: compiles and exercises the AppKit display/mouse helper without posting events, then runs negative cases proving that the exact three-phase display matrix remains versioned, attestation/run metadata/logs stay under runner-temporary directories outside the checkout, and CI may upload only the redacted `external-app-live-v2.json` file. |
| `scripts/test_playcover_pending_launch_crash_live.sh --live` | Clean-HEAD public-fixture gate that materializes committed HEAD and builds the debug CLI, Runtime, and fixture in fresh owner-only scratch paths outside the checkout. It uses an isolated `/tmp` alias root, `_exit(86)` cuts, independent CLI processes, exact PID/birth/executable/Runtime-socket evidence, and machine-envelope assertions for the post-open, generic pre/post-owner, ready, durable `driver.lock`, and three journal-retirement boundaries, plus the deliberately unresolved pre-open `submissionArmed` state. It proves unresolved-open blocking, exact-owner recovery, generation retention, and a fresh start after safe cleanup for that explicit set. It does not attest production installed-layout callback ordering or independently crash the terminal-failure/source-specific callback branches; their store/ordering semantics remain covered only by focused tests until a real independent-process gate is added. |
| `scripts/test_playcover_prepare_differential.sh` | Run the hermetic pinned Installer-vs-ios-use prepare differential suite in an isolated SwiftPM scratch directory and publish its fixture-only schema-v1 attestation without replacing existing evidence. It binds an embedded 40-file source-closure digest to the loaded XCTest image's exact device/inode and content hash; it does not consume a private live UI scenario. |
| `scripts/test_playcover_runtime_stdio.sh` | Compiles the production early-constructor stdio redirector with a small harness and proves exact device/inode capture plus fail-closed rejection of missing identity, replacement, symlink, broad mode, and multiple-link files. |
| `scripts/test_playcover_external_prepare_differential.sh --profile <path> --profile-sha256 <sha256> --scenario <path> --runtime <path> --playtools <path> --work-root <path> --attestation <path> --commit <sha>` | Run the configured external-App prepare differential against one separately reviewed exact profile. Every input is mandatory; the work root and final owner-only attestation must be fresh absolute paths outside the checkout. The supplied commit must be the clean committed HEAD: tracked working-tree changes, index changes, and untracked non-ignored files are rejected, while ignored build output may remain. The entrypoint runs only the configured XCTest in a cleared environment, verifies the exact external schema, and publishes by hard link without overwrite. It never derives allowances from a raw diagnostic report. |
| `scripts/test_playcover_external_prepare_differential_contract.sh` | Focused negative contract for the external prepare entrypoint: missing/duplicate arguments, relative paths, stale output paths, checkout-confined outputs, invalid digests/revisions, dirty tracked/index/untracked state, and a commit other than current HEAD must fail before XCTest. |
| `scripts/test_playcover_backend.sh --non-live` | Unified Apple-silicon hosted gate: upstream audit, fresh workspace CLI/Runtime build and analysis, fixture build, production-linked compositor/PlayChain smoke, vendored and complete CLI Swift tests (including recorded PID reuse), hermetic pinned-prepare differential attestation, and release-installed execution. `--live` first runs the independent pending-launch CLI crash/restart matrix and records the lock-independent Runtime stress evidence, then requires the unlocked public fixture matrix and configured generic external-App live gate; missing private runner inputs still fail the complete gate. |
| `scripts/test_playcover_cgshw_compositor.sh [--deterministic-only]` | Links the production compositor into deterministic layout, inverse-coordinate, backing-scale, restored 316 x 685 half-physical-pixel geometry, and full-edge canvas-only crop tests. Without `--deterministic-only`, it also runs the live CGWindow compositor smoke. |
| `scripts/test_playcover_fixture_live.sh --live` | Runs the fixture matrix on an unlocked GUI host with exactly one eligible extended non-main display whose backing scale differs from the main display. It preserves one PID/session/generation/window number across exact-window title-bar drags and fixed host scales 0.75 main, 1.0 extended, and 0.875 main, plus canvas-only capture, inverse-scale global mouse, and title-bar miss-hit checks. |
| `scripts/test_playcover_runtime_stress_live.sh` | Lock-independent isolated current-checkout public-fixture gate. It requires a clean unchanged HEAD, refuses fixture overrides, and freshly rebuilds the Runtime plus a CLI in new SwiftPM scratch and a fixture in new DerivedData before proving the raw authenticated `hello` contains exactly the minimal readiness AppKit field set, covering zero/oversized/exact-limit/malformed/truncated Runtime frames, continued listener health, 20 unique-session bare lifecycle cycles on one generation, scene replacement, exact endpoint-loss handling, fixture-owned self-SIGKILL/stale classification, preserved crash residue, and restart recovery. Its no-clobber schema-v2 attestation binds HEAD and the exact CLI/Runtime/complete fixture App tree/probe/timing-filter digests to every result observation, embeds all 20 warm bare-start timing samples with recomputable median/MAD summaries, and retains raw crash-residue stat snapshots separately. |
| `scripts/test_playcover_timing_stats.sh` | Pure contract gate for exact warm bare-start timing parsing, sample identity, minimum count, median/MAD calculations, skipped Runtime-ping accounting, and exact summary recomputation through `scripts/playcover_timing_stats.jq`. |
| `scripts/test_playcover_external_app_live.sh --live` | Generic 20-cycle external-App UI/mouse/lifecycle gate. It requires explicit authorization, a private schema-v1 scenario, an unlocked two-display topology matching `live-matrix-v2.tsv`, and an evidence directory outside the checkout. Global target input is mapped only from Runtime `canvasCGWindowRect` plus `displayScale`, never the outer host frame; its redacted pass attestation is schema v2. |
| `scripts/test_playcover_installed_layout.sh [--release-dir <path>]` | Without an argument, package the fresh local CLI/Runtime. With `--release-dir`, consume the exact release-build output. Both paths verify checksums, install a read-only Runtime through `install.sh`, run fixture start/status/stop outside the source tree with a separate `IOS_USE_HOME`, and prove the installed framework is unchanged. |
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
and the exact current checkout commit. There is no pass-producing
characterization or profile-generation mode. The commit must be a clean
committed HEAD; ignored local build output is permitted, but tracked, staged,
or untracked non-ignored changes are not. Raw difference inventories remain
diagnostic evidence only and cannot be converted into allowances by this
entrypoint.

Run the full UI replay only when needed:

```bash
bash scripts/ci_full_simulator.sh --driver-ipa .ios-use/driver-sim.ipa
bash scripts/ci_full_simulator.sh --driver-ipa .ios-use/driver-sim.ipa --case WF-1
```

GitHub CI uses `.github/workflows/ci.yml` for script syntax/packaging metadata,
Swift CLI, driver unit, and hosted PlayCover non-live gates in parallel. Changes
to release workflow paths and release notes trigger that CI. The external-App
live/stress gate is an explicit dispatch-only schema-v2 entry on an
operator-provided, unlocked GUI runner; raw scenario/evidence stay
runner-private. Its attestation, run metadata, and log remain outside the
checkout under runner-temporary directories, and CI uploads only the redacted
`external-app-live-v2.json`. Hosted CI does not assume that private runner is
reachable. The full Simulator UI replay lives in `.github/workflows/simulator.yml`
and is manual-only.

## Install And Benchmark

| Script | Purpose |
| --- | --- |
| `scripts/install.sh` | On Apple Silicon, verify checksums and install the release CLI, driver IPAs, and prebuilt PlayCover Runtime under `<prefix>/share/ios-use/playcover/`; the Runtime is signature-verified and used only as an immutable source for managed prepare copies. Also installs the skill and altsign helper. `--build-from-source` additionally requires full Xcode, Swift, and xcodegen. Intel macOS is unsupported. |
| `scripts/release_build.sh` | From a clean Git tree, audit all pins/licenses, force a fresh Runtime, compare its tracked input digest with the exact corresponding-source archive (including complete pinned Yams source), and stage read-only Runtime, build-manifest, license, provenance, CLI, and driver assets under `release/`; validates `IOS_USE_RELEASE_VERSION` when provided. See [docs/how-to-release.md](../docs/how-to-release.md). |
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
| `ios-use-playcover-runtime.tar.gz` | Read-only, prebuilt Runtime installed at `<prefix>/share/ios-use/playcover/`. |
| `ios-use-vX.Y.Z-corresponding-source.tar.gz` | Complete corresponding source for the release, including vendored upstreams, the full pinned Yams Git tree, build recipes, source commit, and Runtime-input digest. |
| `PLAYCOVER-BUILD-MANIFEST-vX.Y.Z.txt` | Exact source commit, Yams commit, Runtime-input digest, Runtime archive digest, and corresponding-source digest. |
| `LICENSE`, `*-LICENSE-*`, `THIRD-PARTY-LICENSES.md`, `PLAYCOVER-PROVENANCE-vX.Y.Z.md` | ios-use and upstream license/provenance materials, including the Yams MIT license, for the Runtime distribution. |
| `CHANGELOG-vX.Y.Z.md` | Focused changes and upgrade notes for that release. |
| `SHA256SUMS` | Checksums for all uploaded content assets. |
