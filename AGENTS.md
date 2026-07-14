# ios-use

## 1. Project overview

`ios-use` is a Swift CLI for automating iOS real devices and Simulators. The
host CLI owns argument parsing, device/session state, logs, proxying, and local
artifacts. The XCTest driver owns UI actions, DOM snapshots, Fory encoding, and
the TCP server.

Key paths:

- `swift-cli/`: host CLI, parsers, sessions, device/config state, logs, proxy, and host services.
- `shared/IOSUseProtocol/`: command, Fory frame, and payload types shared by host and driver.
- `driver/tcp/`: TCP server and Fory codec.
- `driver/ui/`: XCTest UI actions, DOM, element lookup, waits, screenshots, and driver-side commands.
- `scripts/`: build, install, test, Simulator matrix, and benchmark entry points.
- `swift-cli/Tests/` and `driver/tests/`: host and driver unit tests.
- `ios-use-skill/`: user-facing CLI usage guidance. Keep leaf implementation context in this repository, cross-project coordination context in ContextShell, and the installed skill strictly user-facing.

The current implementation and internal behavior are defined by source and
tests. Use this evidence order:

1. Read the relevant source under `swift-cli/`, `driver/`, and `shared/IOSUseProtocol/`.
2. Read the owning unit tests and validation scripts for acceptance behavior.
3. Use README and command help for the public CLI contract. Use `ios-use-skill/`
   only for operational workflows and recovery guidance.
4. Use design and historical documents to understand boundaries and historical intent; do not copy early-version instructions as current behavior.

## 2. Documentation rules

- Pure internal refactors and test-only changes usually do not require design updates.
- User-visible CLI arguments, defaults, output, errors, or state side effects require a focused update to command help or the smallest owning public document, plus tests.
- Shared protocol or driver lifecycle changes require updates to the shared models and owning tests. Update a design note only when a durable cross-file invariant changes.
- Test cases and case IDs belong in the owning executable tests or scripts, not in a parallel Markdown matrix. Update verification guidance only when gate selection changes.
- Keep `ios-use-skill/SKILL.md` and its references strictly actionable for CLI users. Update them only when command choice, invocation order, or a user-executable recovery path changes. Do not mirror schemas, implementation details, benchmarks, test matrices, or release notes there.
- Record completed code-change work in the coordinating ContextShell history when the task spans repositories. Do not commit or push unless the user asks.

## 3. Development commands

Run commands from the repository root. Detailed script contracts live in
[`scripts/README.md`](scripts/README.md).

```bash
bash scripts/build_swift_cli.sh --debug   # build the local CLI at ./ios-use
./ios-use --help

bash scripts/build_driver.sh               # build the device driver
bash scripts/build_driver.sh --release

bash scripts/ci_test.sh                    # Swift CLI + driver unit gate
bash scripts/ci_test.sh --skip-builds      # fast local gate
bash scripts/ci_full_simulator.sh --driver-ipa .ios-use/driver-sim.ipa
```

`driver/project.yml` is the XcodeGen source of truth; do not edit generated
`driver/IOSUseDriver.xcodeproj` files. Use `./ios-use` or the local build script
when validating workspace changes, never an unrelated globally installed binary.
The driver uses Swift 5.9 and an iOS 17.0 deployment target. Keep test state in
an isolated `IOS_USE_HOME`; do not write real device, signing, proxy, or user
artifact state from tests.

For Simulator development, use a booted Simulator UDID and the repository's
Simulator scripts. Simulator driver artifacts are Xcode-version-sensitive and
must be rebuilt when the local Xcode/runtime changes. For real-device DDI
issues, use the current `ddi-mount` resolver and a matching `Restore/`,
`iOS_DDI/`, or `.dmg` path. If the local cache has no matching image, keep the
user-facing fallback download documented in `ios-use-skill/SKILL.md`; the CLI
does not silently download or mount an unverified image.

## 4. Code style

- Keep strict argument validation in the CLI parser (`parseIntStrict`, `parseDoubleStrict`, and related helpers).
- Keep command parsing in `swift-cli/Sources/IOSUseCLI/CLI/CLIParser.swift` and keep `swift-cli/Sources/IOSUseCLI/CLI/IOSUseCLI.swift` as a clear execution dispatcher.
- Keep socket, usbmux, and Fory protocol logic in `swift-cli/Sources/IOSUseCLI/Services/DriverRuntime/DriverClient.swift` and the shared protocol layer.
- Resolve state, logs, and artifacts through `IOSUsePaths` under `~/.ios-use/`; do not add a new `/tmp/ios-use` or `/tmp/WebDriverAgent` path convention.
- Driver logs use `NSLog()`, not `print()`; preserve the existing `[driver]`, `[session]`, and `[source]` prefixes.

## 5. Testing requirements

- Host tests use Swift Package XCTest under `swift-cli/Tests/`; driver tests live under `driver/tests/`.
- After Swift CLI, shared protocol, or driver changes, run `bash scripts/ci_test.sh` or the owning test script explicitly. Run the full Simulator matrix for UI-facing changes when practical.
- Cover boundary and error behavior, not only happy paths. Driver-side changes need an algorithm, protocol, error, or state-boundary test under `driver/tests/`.
- Tests must use temporary HOME/artifact/state directories and restore injected fakes or global overrides after each test.
- UI commands that depend on page state are serialized. Only independent read-only observations may run concurrently; on TCP or page-state races, return to a serial reproduction.
- New scripts must not overwrite real Apple ID, signing, device session, proxy, or artifact state.

## 6. Security and configuration

- Never commit `.env` files, signing artifacts, private docs, logs, credentials, UDIDs, certificates, or build output. Check tracked content and history before public release.
- Apple ID and developer-account passwords must be entered through the secure interactive prompt. Do not put real passwords in command arguments, logs, docs, or fixtures.
- Real devices require USB and iOS 17.4 or later. Simulator use requires Xcode and a booted runtime.
- The local CLI binary is `./ios-use`; the local host directory is `~/.ios-use/` (or `IOS_USE_HOME` when set), containing config, session state, logs, and artifacts.
- Real-device and Simulator driver artifacts are `driver.ipa` and `driver-sim.ipa`. Debug builds read them from `IOS_USE_HOME` or `.ios-use/`; release packaging stages them under `release/`, while installed releases use their installed artifact location.

## 7. Release

Follow [`docs/how-to-release.md`](docs/how-to-release.md) for release builds,
version stamping, checksums, and publishing. Before release, synchronize code,
tests, user docs, examples, and release notes. Audit the skill for stale workflows,
but change it only when operational guidance changed. Verify that no private local
context is included.
