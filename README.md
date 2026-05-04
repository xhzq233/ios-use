# ios-use

> iOS UI automation CLI powered by a custom XCTest TCP driver for real devices and Simulators.

`ios-use` connects directly to a lightweight XCTest driver instead of going through an HTTP bridge. The result is a small CLI focused on fast session reuse, direct device control, and a simple flow format.

https://github.com/xhzq233/ios-use/releases/download/v1.0.0/demo.mp4

## Features

- **Zero external dependencies**: No Appium server, no WDA, no iproxy, no ideviceinstaller — only macOS system tools (`xcrun`, `usbmuxd`) and a free Apple ID.
- **Custom TCP driver**: The CLI talks directly to a lightweight XCTest driver over TCP or usbmuxd, without an HTTP bridge.
- **Free Apple ID signing**: Signs and installs the driver using a regular (free) Apple ID via altsign-cli. No paid developer account required.
- **Fast session reuse**: `session start` prepares the driver once; later commands reconnect automatically. DOM queries hit `~74 ms`, find hits `~45 ms`.
- **Real device and Simulator**: Real devices connect through usbmuxd; Simulators connect over `localhost:8100`.
- **Smart DOM tree**: 7-rule cleaning pipeline trims the raw XCUI snapshot into a concise, readable tree. SpringBoard gets dedicated rendering (Home icons, Dock, Spotlight, status bar).
- **Fuzzy find with context disambiguation**: exact match → Levenshtein fuzzy fallback → `ancestorType`/`ancestorLabel` filtering. On failure, returns ambiguous matches and suggestions.
- **4 scroll modes**: scroll-to-label, point swipe, anchor-based scroll, and fixed-distance swipe. Auto axis detection from visible cell layout.
- **OSLog integration**: Fetch device-side `OSLogStore` entries with regex filtering, grouped by bundle ID.
- **Built-in NSLogger receiver**: Capture device logs from the CLI, with optional TLS and Bonjour service discovery.
- **Flow runner**: Describe multi-step automations in YAML using the same command set as the CLI.

## Installation

### 1. Install The CLI

```bash
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/main/scripts/install.sh | bash
```

The installer compiles the current CLI locally with Bun and installs `ios-use` into a user-writable bin directory.

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

### 3. Start A Session

```bash
ios-use session start --udid <device-udid> --bundle-id com.apple.Preferences
```

Or create a device session without binding an app:

```bash
ios-use session start --udid <device-udid>
```

### 4. Run Commands

```bash
ios-use dom
ios-use find "蓝牙"
ios-use tap --label "通用"
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
CLI (Bun)
  -> session orchestration
  -> driver client
  -> Custom XCTest Driver
  -> XCUITest API
```

The host side is implemented in TypeScript and Bun. The device side is a Swift XCTest runner that exposes a compact RPC protocol over TCP. For real devices the CLI reaches the driver through usbmuxd; for Simulators it connects to `localhost`.

### Why TCP Instead Of HTTP

- Fewer layers between CLI and XCTest
- No local daemon to keep in sync
- Lower per-command overhead
- Simpler transport for binary payloads such as screenshots

### Session Model

- `session start` prepares the driver and stores local session state under `~/.ios-use/`
- Later commands reuse that session and reconnect directly to the driver
- Lifecycle mutations such as `activateApp`, `terminateApp`, and session creation invalidate stale snapshots before the next DOM-based command

### Command Surface

The public CLI mirrors the flow action set:

- `device`
- `config`
- `session start|stop|status`
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
- Framing: 4-byte big-endian length prefix plus JSON payload
- Screenshot path: JSON header plus raw JPEG binary
- Coordinates and dimensions use integers
- All XCTest UI work is dispatched onto the main thread inside the driver

## Benchmark

Latest benchmark compares `ios-use` against the full `Appium Server -> WebDriverAgent` stack on the same app scenario.

Setup summary:

- App: `com.apple.Preferences`
- See `scripts/benchmark_wda.js` for device and OS details
- Custom side: installed `ios-use`
- Baseline: Appium Server + WDA
- Iterations: `3`

| Case | ios-use Avg (ms) | Appium+WDA Avg (ms) | Reduction |
| --- | ---: | ---: | --- |
| `session_start_app` | 9621.9 | 10371.4 | `7.2%` |
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
| `bash`, `curl`, `tar`, `bun` | required | not needed after install | dev also uses `bun` |
| `xcrun xctrace` | not needed | required for device discovery | not needed |
| `xcrun devicectl` | not needed | required for install and launch | not needed |
| `xcrun simctl` | not needed | not needed | required for Simulator config; dev build also uses it |
| `unzip` | not needed | required during `config` | required during Simulator `config` |
| `altsign-cli` | copied by installer if bundled | required for real-device signing | not needed |
| `openssl` | not needed | optional for `nslog --ssl` | optional for `nslog --ssl` |
| `dns-sd` | not needed | optional for NSLogger Bonjour publish | optional for NSLogger Bonjour publish |
| `xcodebuild`, `zip`, `mktemp` | not needed | not needed at runtime | required for `scripts/build_host_app.sh` |
| `appium`, `lsof` | not needed | not needed at runtime | benchmark only |

## Repository Layout

```text
src/                  CLI, session orchestration, config, transport client
src/driver-protocol/  Shared RPC types and frames
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
bun install
bash scripts/build_host_app.sh
bun run src/cli.ts --help
```

## Acknowledgments

- **[WebDriverAgent](https://github.com/appium/WebDriverAgent)**: This project borrows heavily from the ideas and implementation patterns established by WebDriverAgent. Gesture synthesis, snapshot handling, scrolling behavior, and parts of the driver architecture were shaped by studying WDA's source.
- **[appium-xcuitest-driver](https://github.com/appium/appium-xcuitest-driver)**: The CLI and session behavior were informed by how the Appium XCUITest ecosystem exposes XCTest automation to users.
- **[Appium](https://github.com/appium/appium)**: Appium helped establish the mental model for cross-device automation workflows, including action-oriented commands and reusable sessions.

## License

[GNU AGPL v3.0](https://www.gnu.org/licenses/agpl-3.0.html) — see [LICENSE](LICENSE).
