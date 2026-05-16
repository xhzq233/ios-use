# Scripts Index

Run scripts from the repository root unless noted otherwise.

## Daily Development

| Script | Purpose |
| --- | --- |
| `scripts/runcli.sh ...` | Build the Swift CLI in Debug mode and run it in place. It does not copy anything to `dist/`. |
| `scripts/build_swift_cli.sh [--debug]` | Build the Swift CLI and copy it to `dist/ios-use` and `dist/ios-use-swift`. Release is the default. |
| `scripts/build_driver.sh [--debug] [--simulator-only]` | Generate the Xcode project and build driver IPA artifacts under `assets/`. |
| `scripts/build_all.sh [--debug] [--simulator-only]` | Build the Swift CLI and driver artifacts together. |

## Validation

| Script | Purpose |
| --- | --- |
| `scripts/test_swift_cli.sh` | Run Swift CLI unit tests. |
| `scripts/test_driver_unit.sh` | Run Swift driver unit tests. |
| `scripts/test_all.sh` | Run Swift CLI tests, driver tests, Swift CLI Release build, and Simulator driver build. |
| `scripts/test_full_simulator.sh` | Run the full local Simulator command regression. |
| `scripts/test_simulator_commands.mjs` | Node-based Simulator command case runner used by full Simulator validation. |

## Install And Benchmark

| Script | Purpose |
| --- | --- |
| `scripts/install.sh` | Install the release CLI, driver IPAs, skill, flows, and altsign helper. Use `--build-from-source` to compile locally. |
| `scripts/benchmark_wda.js` | Compare ios-use against Appium/WebDriverAgent on a real device. |
| `scripts/ios_use_test_simulator.js` | Simulator helper used by older local workflows. Prefer `test_simulator_commands.mjs` for current coverage. |

## Release Artifacts

The GitHub release workflow builds and uploads:

| Asset | Purpose |
| --- | --- |
| `ios-use-darwin-arm64` | Prebuilt Apple Silicon macOS CLI binary. Intel Macs use `scripts/install.sh --build-from-source`. |
| `driver.ipa` | Real-device XCTest driver IPA. |
| `driver-sim.ipa` | Simulator XCTest driver IPA. |
| `SHA256SUMS` | Checksums for uploaded release assets. |
