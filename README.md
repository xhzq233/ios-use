# ios-use

> iOS UI automation CLI powered by a custom XCTest TCP driver for real devices and Simulators.

`ios-use` connects directly to a lightweight XCTest driver instead of going through an HTTP bridge. The result is a small CLI focused on fast session reuse, direct device control, and a simple flow format.


https://github.com/user-attachments/assets/65155303-5774-4bcb-b68d-5e03f6a3e3ae


## Features

- **Zero external dependencies**: No Appium server, no WDA, no iproxy, no ideviceinstaller — only macOS system tools (`xcrun`, `usbmuxd`) and a free Apple ID.
- **Custom TCP driver**: The CLI talks directly to a lightweight XCTest driver over TCP or usbmuxd, without an HTTP bridge.
- **Free Apple ID signing**: Signs and installs the driver using a regular (free) Apple ID via altsign-cli. No paid developer account required.
- **Auto session reuse**: the first action command starts or reconnects the driver automatically; later commands reuse the saved session state. DOM queries hit `~74 ms`, find hits `~45 ms`.
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
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/main/scripts/install.sh | bash
```

The installer downloads the prebuilt Apple Silicon macOS CLI and driver IPAs from the latest GitHub Release, then installs `ios-use` into a user-writable bin directory. Intel Macs should compile locally instead:

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

## Design & Implementation

### Architecture

```text
Swift CLI
  -> shared Swift protocol / Fory frame model
  -> driver client
  -> Custom XCTest Driver
  -> XCUITest API
```

The default host side is a Swift executable. The device side is a Swift XCTest runner that exposes a compact RPC protocol over TCP. Both sides compile the shared protocol model from `shared/IOSUseProtocol`, so command args, payloads, and frame types stay in one source of truth. For real devices the CLI reaches the driver through usbmuxd; for Simulators it connects to `localhost`.

### Why TCP Instead Of HTTP

- Fewer layers between CLI and XCTest
- No local daemon to keep in sync
- Lower per-command overhead
- Simpler transport for binary payloads such as screenshots

### Session Model

- The first action command prepares the driver and stores local session state under `~/.ios-use/`
- Later commands reuse that session metadata and reconnect directly to the driver
- `ios-use stop` stops the driver process and clears local session state
- Lifecycle mutations such as `activateApp`, `terminateApp`, and session creation invalidate stale snapshots before the next DOM-based command

### Command Surface

The public CLI mirrors the flow action set:

- `devices`
- `config`
- `stop`
- `activateApp`
- `terminateApp`
- `dom`
- `find`
- `tap`
- `longpress`
- `input`
- `swipe`
- `waitFor`
- `screenshot`
- `flow`
- `oslog`
- `nslog`

### Protocol And Runtime Notes

- Transport: TCP on port `8100`
- Framing: 4-byte big-endian length prefix plus Fory binary payload
- Screenshot path: single Fory response frame with `ForyScreenshotPayload.jpeg`
- Coordinates and dimensions use integers
- All XCTest UI work is dispatched onto the main thread inside the driver

## Benchmark

The historical benchmark below compares `ios-use` against the full `Appium Server -> WebDriverAgent` stack on the same app scenario.

Setup summary:

- App: `com.apple.Preferences`
- See `scripts/benchmark_wda.js` for device and OS details
- Custom side: installed `ios-use`
- Baseline: Appium Server + WDA
- Iterations: `3`

| Case | ios-use Avg (ms) | Appium+WDA Avg (ms) | Reduction |
| --- | ---: | ---: | --- |
| `auto_session_activate_app` | 9621.9 | 10371.4 | `7.2%` |
| `dom` | 74.4 | 1642.3 | `95.5%` |
| `find` | 45.8 | 368.3 | `87.6%` |
| `waitFor` | 55.7 | 364.1 | `84.7%` |
| `screenshot` | 94.7 | 175.0 | `45.9%` |
| `tap_coord` | 374.1 | 550.6 | `32.1%` |
| `tap_label` | 366.0 | 1634.1 | `77.6%` |
| `longpress_coord` | 792.2 | 976.1 | `18.8%` |
| `input` | 1508.1 | 2027.3 | `25.6%` |
| `swipe_distance` | 2464.4 | 2797.3 | `11.9%` |
| `scroll_to_visible` | 7615.0 | 18249.1 | `58.3%` |
| `activate_app` | 2676.0 | 2576.4 | `tie` |
| `terminate_app` | 1189.9 | 1106.7 | `tie` |

Why this matters for AI agents:

- `dom` at `74.4 ms` keeps world-state refresh cheap.
- `find` at `45.8 ms` and `waitFor` at `55.7 ms` make polling and retry loops practical.
- `tap_label` at `366.0 ms` keeps common action steps short enough for interactive agent workflows.
- `screenshot` at `94.7 ms` makes visual fallback much cheaper than a typical WDA path.
- `scroll_to_visible` is still expensive in absolute terms, but it saves more than `10 s` versus the baseline in this benchmark.

Numbers vary by device, app state, and whether the target page is already warm, but the shape is stable: `dom`, `find`, `waitFor`, `tap`, and screenshot are the operations that most improve AI-facing responsiveness.

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
scripts/runcli.sh --help
bash scripts/build_swift_cli.sh
bash scripts/build_driver.sh
./dist/ios-use --help
bash scripts/ci_test.sh
```

`scripts/runcli.sh` is the fastest debug loop: it builds the Swift CLI in place and runs it without copying into `dist/`. `scripts/ci_test.sh` is the default CI/local Swift-only validation path. Full Simulator command matrix tests use `bash scripts/ci_full_simulator.sh`. See `scripts/README.md` for the script index.

## Acknowledgments

- **[WebDriverAgent](https://github.com/appium/WebDriverAgent)**: This project borrows heavily from the ideas and implementation patterns established by WebDriverAgent. Gesture synthesis, snapshot handling, scrolling behavior, and parts of the driver architecture were shaped by studying WDA's source.
- **[appium-xcuitest-driver](https://github.com/appium/appium-xcuitest-driver)**: The CLI and session behavior were informed by how the Appium XCUITest ecosystem exposes XCTest automation to users.
- **[Appium](https://github.com/appium/appium)**: Appium helped establish the mental model for cross-device automation workflows, including action-oriented commands and reusable sessions.

## License

[GNU AGPL v3.0](https://www.gnu.org/licenses/agpl-3.0.html) — see [LICENSE](LICENSE).
