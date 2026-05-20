# ios-use

> iOS UI automation CLI powered by a custom XCTest TCP driver for real devices and Simulators.

`ios-use` connects directly to a lightweight XCTest driver instead of going through an HTTP bridge. The result is a small CLI focused on fast session reuse, direct device control, and a simple flow format.


https://github.com/user-attachments/assets/65155303-5774-4bcb-b68d-5e03f6a3e3ae


## Features

- **Zero external dependencies**: No Appium server, no WDA, no iproxy, no ideviceinstaller — only macOS system tools (`xcrun`, `usbmuxd`) and a free Apple ID.
- **Custom TCP driver**: The CLI talks directly to a lightweight XCTest driver over TCP or usbmuxd, without an HTTP bridge.
- **Free Apple ID signing**: Signs and installs the driver using a regular (free) Apple ID via altsign-cli. No paid developer account required.
- **Auto session reuse**: the first action command starts or reconnects the driver automatically; later commands reuse the saved session state. DOM queries hit `~13 ms`, find hits `~16 ms`.
- **Real device and Simulator**: Real devices connect through usbmuxd; Simulators connect over `localhost:8100`.
- **Smart DOM tree**: a unified cleaning pipeline trims the raw XCUI snapshot into a concise, readable tree while preserving visible hierarchy and useful traits.
- **Normalized find with traits disambiguation**: contains-match over label/value text with whitespace, punctuation, and case normalization, plus fuzzy fallback and `--traits` filtering.
- **4 scroll modes**: scroll-to-label, point swipe, anchor-based scroll, and fixed-distance swipe. Auto axis detection from visible cell layout.
- **OSLog integration**: Fetch Simulator/device logs from the host side with regex filtering, grouped by bundle ID.
- **Built-in NSLogger receiver**: Capture NSLogger TLS logs from the CLI with Bonjour service discovery.
- **Flow runner**: Describe multi-step automations in YAML using the same command set as the CLI.

## Installation

### 1. Install The CLI

```bash
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/main/scripts/install.sh | bash -s --
```

The installer downloads the prebuilt Apple Silicon macOS CLI and driver IPAs from the latest GitHub Release, then installs `ios-use` into a user-writable bin directory. To install a specific version:

```bash
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/main/scripts/install.sh | bash -s -- --version v1.0.0
```

Intel Macs should compile locally instead:

```bash
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/main/scripts/install.sh | bash -s -- --build-from-source
```

### 2. First-Time Setup

Choose the environment you want to drive:

**Real device:**

- USB connection
- A full Xcode installation that provides `xcrun devicectl` and `xcrun xctrace`
- Apple ID credentials for signing on first install

```bash
# First run: provide Apple ID credentials
ios-use config --udid <device-udid> --apple-id <email> --password '<app-password>'

# Later runs: cached signing session is reused
ios-use config --udid <device-udid>
```

**Simulator:**

- A full Xcode installation that provides `xcrun simctl`
- The specific Simulator runtime you want to boot

```bash
ios-use config --simulator --udid <simulator-udid>
```

`config` signs and installs the driver onto the target. CLI installation alone does not require Xcode, but **driving any real device or Simulator currently depends on a full Xcode installation**.

When upgrading `ios-use`, run `ios-use devices` after installation. If a device line says `driver update required`, run `ios-use config --udid <device-udid>` again so the on-device driver matches the newly installed CLI.

### 3. Select An App

```bash
ios-use devices
ios-use activateApp com.apple.Preferences --udid <device-udid>
```

No manual `session start` is required. The first action command auto-creates a device session; `activateApp` foregrounds the target app when needed.

```bash
ios-use dom --udid <device-udid>
```

### 4. Run Commands

```bash
ios-use dom
ios-use find "蓝牙"
ios-use tap "通用"
ios-use swipe --to "开发者" --from "蓝牙"
ios-use input --label "搜索" --content "蓝牙"
ios-use screenshot --name settings-home
```

### 5. Run A Flow

```bash
ios-use flow flows/test_flow.yaml
```

## Benchmark

The benchmark below compares `ios-use` against the full `Appium Server -> WebDriverAgent` stack on the same app scenario.

Setup summary:

- App: `com.apple.Preferences`
- Device: real iPhone over USB/usbmuxd
- Custom side: Swift CLI + custom XCTest TCP driver
- Baseline: Appium Server + WDA
- Iterations: `3`
- Report date: 2026-05-18

| Case | ios-use Avg (ms) | Appium+WDA Avg (ms) | Reduction |
| --- | ---: | ---: | --- |
| `auto_session_activate_app` | 3257.4 | 9622.1 | `66.1%` |
| `dom` | 13.5 | 984.2 | `98.6%` |
| `find` | 15.7 | 279.8 | `94.4%` |
| `waitFor` | 13.7 | 277.2 | `95.1%` |
| `screenshot` | 45.5 | 215.0 | `78.8%` |
| `tap_coord` | 377.3 | 557.3 | `32.3%` |
| `tap_label` | 542.8 | 1089.5 | `50.2%` |
| `longpress_coord` | 819.9 | 967.4 | `15.2%` |
| `input` | 1534.0 | 1760.8 | `12.9%` |
| `swipe_distance` | 2062.5 | 2595.4 | `20.5%` |
| `scroll_to_visible` | 10717.0 | 17123.0 | `37.4%` |
| `activate_app` | 1213.7 | 2591.1 | `53.2%` |
| `terminate_app` | 1141.4 | 1164.7 | `2.0%` |

Why this matters for AI agents:

- `dom` at `13.5 ms` keeps world-state refresh cheap.
- `find` at `15.7 ms` and `waitFor` at `13.7 ms` make polling and retry loops practical.
- `tap_label` at `542.8 ms` keeps common action steps short enough for interactive agent workflows.
- `screenshot` at `45.5 ms` makes visual fallback much cheaper than a typical WDA path.
- `scroll_to_visible` is still expensive in absolute terms, but it saves more than `6 s` versus the baseline in this benchmark.

Numbers vary by device, app state, and whether the target page is already warm, but the shape is stable: `dom`, `find`, `waitFor`, `tap`, and screenshot are the operations that most improve AI-facing responsiveness.

Note: in this run, the `input` custom average is calculated from two successful iterations; one prepare step failed with a transient driver TCP read error and is tracked separately from the latency comparison.

## Dependency Matrix

| Dependency | Install CLI | Real Device | Simulator / Dev |
| --- | --- | --- | --- |
| `bash`, `curl`, `tar` | required | not needed after install | dev also uses them |
| `swift` | only for `--build-from-source` | not needed after install | required for SwiftPM development |
| `xcrun xctrace` | not needed | required for device discovery | not needed |
| `xcrun devicectl` | not needed | required for install and launch | not needed |
| `xcrun simctl` | not needed | not needed | required for Simulator config; dev build also uses it |
| `unzip` | not needed | required during `config` | required during Simulator `config` |
| `altsign-cli` | copied by installer if bundled | required for real-device signing | not needed |
| `openssl` | not needed | required for real-device `oslog` TLS relay | not needed |
| `dns-sd` | not needed | optional for NSLogger Bonjour publish | optional for NSLogger Bonjour publish |
| `xcodebuild`, `zip`, `mktemp` | not needed | not needed at runtime | required for `scripts/build_driver.sh` |
| `appium`, `lsof` | not needed | not needed at runtime | benchmark only |

## Repository Layout

```text
swift-cli/            Default Swift CLI, session orchestration, config, transport client
shared/IOSUseProtocol/ Shared Swift RPC types and Fory frame models
driver/               Swift XCTest driver
flows/                Example flows
scripts/              Install, build, and benchmark utilities
docs/                 Public documentation
assets/               Prebuilt driver artifacts
```

## Development

```bash
git clone https://github.com/xhzq233/ios-use.git
cd ios-use
bash scripts/build_swift_cli.sh --debug
./ios-use --help
bash scripts/build_driver.sh
bash scripts/ci_test.sh
```

`bash scripts/build_swift_cli.sh` builds the local workspace CLI to repo-root `./ios-use`; use that binary for development instead of a global `ios-use`. `scripts/ci_test.sh` is the default CI/local Swift-only validation path. Full Simulator command matrix tests use `bash scripts/ci_full_simulator.sh`. See `scripts/README.md` for the script index.

## Acknowledgments

- **[WebDriverAgent](https://github.com/appium/WebDriverAgent)**: This project borrows heavily from the ideas and implementation patterns established by WebDriverAgent. Gesture synthesis, snapshot handling, scrolling behavior, and parts of the driver architecture were shaped by studying WDA's source.
- **[appium-xcuitest-driver](https://github.com/appium/appium-xcuitest-driver)**: The CLI and session behavior were informed by how the Appium XCUITest ecosystem exposes XCTest automation to users.
- **[Appium](https://github.com/appium/appium)**: Appium helped establish the mental model for cross-device automation workflows, including action-oriented commands and reusable sessions.

## License

[GNU AGPL v3.0](https://www.gnu.org/licenses/agpl-3.0.html) — see [LICENSE](LICENSE).
