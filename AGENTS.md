# ios-use

`ios-use` is a Swift CLI for automating real iOS devices and Simulators. The
host CLI handles arguments, device and session state, logs, proxying, and local
artifacts. The XCTest driver handles UI actions, DOM snapshots, Fory encoding,
and its TCP server.

## Repository map

- `swift-cli/`: host CLI, state, services, and Swift Package tests.
- `shared/IOSUseProtocol/`: commands, Fory frames, and payloads shared by host and driver.
- `driver/tcp/` and `driver/ui/`: driver transport and XCTest UI behavior; driver tests are in `driver/tests/`.
- `scripts/`: build, install, test, Simulator, and benchmark entry points.
- `ios-use-skill/`: user-facing command workflows and recovery guidance.

Read relevant source and owning tests for current behavior. README and command
help describe the public CLI. Design notes are useful for historical intent,
but may describe earlier versions. Keep implementation context in this repo;
keep the installed skill focused on actions a CLI user can take.

## Working approach

Favor focused changes and real end-to-end checks on the affected platform. Add
unit tests where they catch a meaningful protocol, algorithm, state, or error
boundary; avoid tests that only compare wording or repeat the implementation.
Do not add hashes, frozen contracts, baselines, or new gates without a concrete
need. Keep planning and handoff notes proportional to the work.

When CLI behavior changes, update command help or the smallest relevant public
document. Update `ios-use-skill/` when command choice, order, or a user-executable
recovery path changes; it does not need internal schemas or test matrices.

## Build and validation

Run from the repository root. See [`scripts/README.md`](scripts/README.md) for
script details.

```bash
bash scripts/build_swift_cli.sh --debug   # local CLI at ./ios-use
./ios-use --help
bash scripts/build_driver.sh
bash scripts/test_swift_cli.sh
bash scripts/test_driver_unit.sh
bash scripts/ci_test.sh
bash scripts/ci_full_simulator.sh --driver-ipa .ios-use/driver-sim.ipa
```

Use the workspace's `./ios-use` when validating CLI changes. Choose the owning
test script for code changes and a real device or Simulator check when behavior
depends on the platform. UI commands sharing page state run serially. Test
state belongs in an isolated `IOS_USE_HOME`; tests and new scripts should not
overwrite a user's device, signing, proxy, Apple ID, or artifact state.

`driver/project.yml` is the XcodeGen source of truth, not the generated Xcode
project. The driver uses Swift 5.9 and targets iOS 17.0. Simulator driver
artifacts depend on the local Xcode and runtime and may need rebuilding after
either changes.

## Implementation notes

- Argument parsing and strict numeric validation live in `CLIParser.swift`; `IOSUseCLI.swift` dispatches commands.
- Socket, usbmux, and Fory transport live in `DriverClient.swift` and the shared protocol layer.
- `IOSUsePaths` owns state, logs, and artifacts under `~/.ios-use/` or `IOS_USE_HOME`; avoid another temporary-path convention.
- Driver logs use `NSLog()` with the existing `[driver]`, `[session]`, and `[source]` prefixes.
- Real devices use USB and iOS 17.4 or later; Simulator use needs Xcode and a booted runtime. For DDI issues, use the current `ddi-mount` resolver and a matching image.
- Driver artifacts are `driver.ipa` and `driver-sim.ipa`. Debug builds read them from `IOS_USE_HOME` or `.ios-use/`; release packaging stages them under `release/`.

Do not commit credentials, `.env` files, signing material, private docs, logs,
real UDIDs, or build output. Apple ID and developer passwords belong in secure
interactive prompts, never command arguments or fixtures.

## Release

Follow [`docs/how-to-release.md`](docs/how-to-release.md) for builds, version
stamping, checksums, and publishing. Keep code, help, user docs, examples, and
release notes aligned; check the package for private local context.
