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
| `scripts/test_playcover_backend.sh --non-live` | Unified Apple-silicon hosted gate: upstream audit, fresh workspace CLI/Runtime build and analysis, fixture build, non-GUI transparent-host contract, compositor/PlayChain smoke, vendored Swift tests, and release-installed execution. `--live` adds the public fixture matrix, isolated Runtime protocol/crash stress, and configured generic external-App live gate; it requires the private runner inputs. |
| `scripts/test_playcover_fixture_live.sh [--static\|--live]` | `--static` verifies the public Simulator-style transparent-host/fixed-canvas contract without launching an App or requiring a GUI. `--live` runs the fixture matrix in an unlocked GUI session, including title bar, 8pt transparent gap, two host resizes, canvas-only capture, inverse-scale global mouse, and decoration miss-hit checks. |
| `scripts/test_playcover_runtime_stress_live.sh` | Isolated public-fixture live gate for oversized/malformed Runtime frames, continued listener health, exact Runtime-endpoint loss handling, App crash/stale classification, and safe host-only cleanup. |
| `scripts/test_playcover_external_app_live.sh [--static\|--live]` | `--static` verifies the same host source contract without private inputs or a GUI. `--live` is the generic 20-cycle external-App UI/mouse/lifecycle gate; it requires explicit authorization, a private schema-v1 scenario, and an evidence directory outside the checkout. Global target input is mapped only from Runtime `canvasCGWindowRect` plus `displayScale`, never the outer host frame. |
| `playcover-fixtures/test_transparent_host_contract.sh --static` | Hermetic source contract for the public AppKit title bar, transparent 8pt spacer, resizable fixed canvas, canonical Runtime geometry, canvas-only crop, and live-gate mode/mapping policy. |
| `scripts/test_playcover_installed_layout.sh [--release-dir <path>]` | Without an argument, package the fresh local CLI/Runtime. With `--release-dir`, consume the exact release-build output. Both paths verify checksums, install a read-only Runtime through `install.sh`, run fixture start/status/stop outside the source tree with a separate `IOS_USE_HOME`, and prove the installed framework is unchanged. |
| `scripts/test_simulator_commands.mjs` | Node-based Simulator command case runner used by full Simulator validation. |
| `scripts/ios_use_test_simulator.js` | Shared helper used by driver unit tests and Simulator command tests to create/boot the fixed `IOSUseTest` Simulator. |

Test standard:

```bash
bash scripts/ci_test.sh
```

Run the full UI replay only when needed:

```bash
bash scripts/ci_full_simulator.sh --driver-ipa .ios-use/driver-sim.ipa
bash scripts/ci_full_simulator.sh --driver-ipa .ios-use/driver-sim.ipa --case WF-1
```

GitHub CI uses `.github/workflows/ci.yml` for script syntax/packaging metadata,
Swift CLI, driver unit, and hosted PlayCover non-live gates in parallel. Changes
to release workflow paths and release notes trigger that CI. The external-App
live/stress gate is an explicit dispatch-only schema-v1 entry on an
operator-provided, unlocked GUI runner; raw scenario/evidence stay
runner-private and CI uploads only the redacted attestation. Hosted CI does not
assume that private runner is reachable. The full Simulator UI replay lives in
`.github/workflows/simulator.yml` and is manual-only.

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
