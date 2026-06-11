# Scripts Index

Run scripts from the repository root unless noted otherwise.

## Daily Development

| Script | Purpose |
| --- | --- |
| `scripts/build_swift_cli.sh [--debug]` | Build the Swift CLI and copy the single local binary to repo-root `./ios-use`. Release is the default. |
| `scripts/build_driver.sh [--debug\|--release] [--simulator-only]` | Generate the Xcode project and build driver IPA artifacts. Debug is the default and writes `IOS_USE_HOME`, or cwd `.ios-use/` when unset; release writes `driver/build/`. |

Local dev run standard:

```bash
bash scripts/build_swift_cli.sh --debug
./ios-use --help
```

Use `./ios-use`, not global `ios-use`, when validating current workspace changes.

## Validation

| Script | Purpose |
| --- | --- |
| `scripts/ci_test.sh [--skip-builds] [--skip-driver-sim-build]` | Main local Swift-only gate: script syntax checks, Swift CLI tests, driver tests, Swift CLI Release build, and Simulator driver build. Release CI uses `--skip-builds` to avoid duplicate artifact builds. |
| `scripts/ci_full_simulator.sh --driver-ipa <path> [--case CASES]` | Main full Simulator regression entry. Builds the Swift CLI, uses the caller-selected Simulator driver IPA, and runs the Node Simulator command matrix. |
| `scripts/test_swift_cli.sh` | Run Swift CLI unit tests plus installed-style CLI/nslog smoke checks and static driver log/version-stamp guards. |
| `scripts/test_driver_unit.sh` | Run Swift driver unit tests with an isolated default `IOS_USE_HOME` under `~/.ios-use/test-homes/driver-unit`. |
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

GitHub CI uses `.github/workflows/ci.yml` for the default gate and runs script syntax, Swift CLI tests/smoke checks, and driver unit tests in parallel jobs. The full UI replay lives in `.github/workflows/simulator.yml` and is manual-only.

## Install And Benchmark

| Script | Purpose |
| --- | --- |
| `scripts/install.sh` | Install the release CLI, driver IPAs, skill, flows, and altsign helper. Use `--build-from-source` to compile locally. |
| `scripts/release_build.sh` | Build and stage GitHub Release assets under `release/`; validates `IOS_USE_RELEASE_VERSION` when provided. See [docs/how-to-release.md](../docs/how-to-release.md). |
| `scripts/benchmark.js --bench ios-use --udid <udid> --driver-ipa <path>` | Measure ios-use on a real device and write JSON only. The script never builds, signs, installs, or runs `config`; the device must already be prepared with a driver whose configured `driverVersion` matches the IPA version. |
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
| `ios-use-darwin-arm64` | Prebuilt Apple Silicon macOS CLI binary. Intel Macs use `scripts/install.sh --build-from-source`. |
| `driver.ipa` | Real-device XCTest driver IPA. |
| `driver-sim.ipa` | Simulator XCTest driver IPA. |
| `SHA256SUMS` | Checksums for uploaded release assets. |
