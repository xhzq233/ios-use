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
| `scripts/test_swift_cli.sh` | Run Swift CLI unit tests. |
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
bash scripts/ci_full_simulator.sh --driver-ipa .ios-use/driver-sim.ipa --case FIND-1B
```

GitHub CI uses `.github/workflows/ci.yml` for the default gate and runs script syntax, Swift CLI tests, driver unit tests, and artifact builds in parallel jobs. The full UI replay lives in `.github/workflows/simulator.yml` and is manual-only.

## Install And Benchmark

| Script | Purpose |
| --- | --- |
| `scripts/install.sh` | Install the release CLI, driver IPAs, skill, flows, and altsign helper. Use `--build-from-source` to compile locally. |
| `scripts/release_build.sh` | Build and stage GitHub Release assets under `release/`; validates `IOS_USE_RELEASE_VERSION` when provided. |
| `scripts/benchmark_wda.js --driver-ipa <path>` | Compare ios-use against Appium/WebDriverAgent on a real device; the caller chooses the custom driver IPA and the script records the copied IPA path plus configured `driverVersion`. `--custom-only` skips Appium/WDA. `--custom-simulator` is only valid with `--custom-only` for local Simulator runs. |

## Release Artifacts

The GitHub release workflow builds and uploads:

| Asset | Purpose |
| --- | --- |
| `ios-use-darwin-arm64` | Prebuilt Apple Silicon macOS CLI binary. Intel Macs use `scripts/install.sh --build-from-source`. |
| `driver.ipa` | Real-device XCTest driver IPA. |
| `driver-sim.ipa` | Simulator XCTest driver IPA. |
| `SHA256SUMS` | Checksums for uploaded release assets. |
