# Scripts Index

Run scripts from the repository root unless noted otherwise.

## Daily Development

| Script | Purpose |
| --- | --- |
| `scripts/runcli.sh ...` | Build the Swift CLI in Debug mode and run it in place. It does not copy anything to `dist/`. |
| `scripts/build_swift_cli.sh [--debug]` | Build the Swift CLI and copy it to `dist/ios-use` and `dist/ios-use-swift`. Release is the default. |
| `scripts/build_driver.sh [--debug] [--simulator-only]` | Generate the Xcode project and build driver IPA artifacts under `assets/`. |

## Validation

| Script | Purpose |
| --- | --- |
| `scripts/ci_test.sh` | Main CI/local Swift-only gate: Swift CLI tests, driver tests, Swift CLI Release build, and Simulator driver build. |
| `scripts/ci_full_simulator.sh [--case CASES]` | Main full Simulator regression entry. Builds the required artifacts and runs the Node Simulator command matrix. |
| `scripts/test_swift_cli.sh` | Run Swift CLI unit tests. |
| `scripts/test_driver_unit.sh` | Run Swift driver unit tests. |
| `scripts/test_simulator_commands.mjs` | Node-based Simulator command case runner used by full Simulator validation. |
| `scripts/ios_use_test_simulator.js` | Helper used by `test_simulator_commands.mjs` to create/boot the fixed `IOSUseTest` Simulator. |

## Install And Benchmark

| Script | Purpose |
| --- | --- |
| `scripts/install.sh` | Install the release CLI, driver IPAs, skill, flows, and altsign helper. Use `--build-from-source` to compile locally. |
| `scripts/release_build.sh` | Build and stage GitHub Release assets under `release/`. |
| `scripts/benchmark_wda.js` | Compare ios-use against Appium/WebDriverAgent on a real device. |

## Release Artifacts

The GitHub release workflow builds and uploads:

| Asset | Purpose |
| --- | --- |
| `ios-use-darwin-arm64` | Prebuilt Apple Silicon macOS CLI binary. Intel Macs use `scripts/install.sh --build-from-source`. |
| `driver.ipa` | Real-device XCTest driver IPA. |
| `driver-sim.ipa` | Simulator XCTest driver IPA. |
| `SHA256SUMS` | Checksums for uploaded release assets. |
