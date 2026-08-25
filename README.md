# ios-use

> iOS UI automation built for AI agents — deeply optimized DOM tree + target-based command semantics.

[![Release](https://img.shields.io/github/v/release/xhzq233/ios-use?sort=semver)](https://github.com/xhzq233/ios-use/releases)
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL%20v3-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20iOS-lightgrey.svg)](#dependency-matrix)

`ios-use` drives real iPhones and Simulators directly from a Swift CLI. It exposes a structured, noise-free DOM and target-based actions (tap by label, not coordinates), so AI agents can reliably inspect UI state, make decisions, and execute — without vision token overhead or pixel guessing.


https://github.com/user-attachments/assets/50de69c3-dce7-474d-8ec4-008b81cdefde


## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/main/scripts/install.sh | bash -s --

ios-use status
ios-use config --udid <device-udid>
ios-use start <device-udid>
ios-use activateApp com.apple.Preferences
ios-use dom
```

After `start`, screen-driving commands target the selected device. To switch devices, run `ios-use stop`, then `ios-use start <other-udid>`.
`activateApp` returns after the requested app is foreground and one fresh UI snapshot succeeds; add `--dom` to return that same snapshot, or `--no-wait` for host-only launch dispatch.

## Why ios-use

- **Deeply optimized DOM tree**: the accessibility snapshot is restructured for agent consumption: flat, noise-free, with stable labels and semantic grouping. `dom` and `waitFor` are cheap enough for tight observe-act loops.
- **Target-based command semantics**: actions can target label/value text instead of raw coordinates. The driver resolves element frames internally, while coordinate and offset modes remain available for visual-only controls.
- **Single binary, zero infrastructure**: no separate server process, no port forwarding, no extra bridge to maintain.
- **Real device and Simulator support**: real devices connect through usbmuxd; Simulators connect over `localhost`.
- **Logs and proxy capture included**: OSLog, NSLogger, and HTTP/HTTPS proxy capture are first-class CLI workflows; repeatable multi-step recipes can be composed with shell scripts.

## AX-First, Vision-Aware Architecture

Modern multimodal models do not usually allocate tokens linearly with every screenshot pixel. Vision encoders resize, patch, and pool images, which means model providers trade off clarity, scale, latency, and token budget. That tradeoff is still painful for UI automation: small text and dense controls can be misread, coordinate reasoning is slower, and visual prompts consume far more context than structured UI state.

`ios-use` makes AX the primary channel and keeps screenshots as a fallback:

| Channel | What it provides | Best use |
| --- | --- | --- |
| **AX (Accessibility Tree)** | OS-reported text/value, element types, traits, hierarchy, and frames from XCTest snapshots. | Fast semantic state and target resolution. |
| **Screenshot** | Spatial layout, colors, visual-only controls, and custom-rendered UI. | Fallback when AX is incomplete or ambiguous. |

**How they work together:**

1. **DOM-first targeting** - Most actions use label/value text. The driver resolves coordinates internally, so the LLM does not need to guess pixel positions for standard UI.
2. **Vision fallback** - When AX is incomplete (for example, a custom-drawn icon), the LLM can inspect a screenshot and pass raw coordinates.
3. **Offset hybrid** — Combine both: anchor on a known label, then apply a relative offset to hit an adjacent unlabeled control.
4. **Deterministic feedback** - Callers can request a fresh DOM after mutations with `--dom` and use `dom` / `waitFor` to confirm semantic state. Capture explicitly named screenshots when visual context is needed. Failed UI mutations return a stable error code together with actionable targets, candidates, rejection reasons, suggestions, and alert details.

This means:

- **Text models** can drive standard apps using DOM alone, without paying vision latency or visual-token costs on every step.
- **Vision models** can reserve screenshots for the cases where AX does not expose enough information, combining precise DOM text with visual spatial reasoning.
- The framework itself is **model-agnostic**: it exposes a CLI/JSON interface that any agent can call.

## What It Is

`ios-use` is a command-line automation tool for macOS users who want direct iOS UI control — optimized for AI agents and local scripts that call it repeatedly in tight loops.

Driving devices still requires Apple's tooling:

- Real devices require USB. Release usage does not require Xcode CLI tools such as `xctrace` or `devicectl`.
- Simulators require a full Xcode install and the target Simulator runtime.
- Real-device first setup requires Apple ID signing. A free Apple Developer account is enough.

## Installation

### Install The CLI

```bash
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/main/scripts/install.sh | bash -s --
```

The installer verifies `SHA256SUMS`, downloads the prebuilt Apple Silicon macOS
CLI, driver IPAs, and Mac backend resources from the latest GitHub Release, then
installs `ios-use` into a user-writable bin directory. The Mac Runtime is an
immutable resource at `<prefix>/share/ios-use/mac/`, next to the
installed binary prefix rather than in mutable `IOS_USE_HOME`; this remains the
fallback for both the default and custom `IOS_USE_HOME` values. The installed
bundle is treated as a read-only source resource: preparation signs only its
managed copy, and installed execution is tested not to mutate any source
bytes. To install a
specific version:

```bash
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/main/scripts/install.sh | bash -s -- --version v2.0.4
```

Intel Macs are unsupported because the Mac Runtime and converted iPhone Apps
are arm64-only. On Apple Silicon, a source build requires full Xcode,
Swift, and `xcodegen`:

```bash
brew install xcodegen
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/main/scripts/install.sh | bash -s -- --build-from-source
```

### First-Time Setup

Choose the environment you want to drive.

**Real device:**

```bash
ios-use status

# First run: sign with a free Apple Developer account (Personal Team; no paid $99 program).
# Authenticate once directly with AltSign; it reads credentials from stdin.
~/.ios-use/altsign-cli/altsign-cli list --apple-id '<Apple ID>'
ios-use config --udid <device-udid>

# Later runs: AltSign reuses its single cached session.
ios-use config --udid <device-udid>
ios-use start <device-udid>
```

**Simulator:**

```bash
xcrun simctl list devices booted
ios-use config --simulator --udid <simulator-udid>
ios-use start <simulator-udid>
```

When upgrading `ios-use`, run `ios-use status` and `ios-use config --list` after installation. If an entry says `driver update required`, run `ios-use config --udid <device-udid>` again so the on-device driver matches the newly installed CLI.

Free Apple Developer signing expires after about 7 days. `ios-use status` and `ios-use config --list` show the signing state, and `ios-use start` warns during the final day before expiry or after expiry. If an expired driver fails to launch, run `ios-use config --udid <device-udid>` again to re-sign and reinstall it before trusting the developer profile if iOS asks.

## Command Overview

| Command | Use it for |
| --- | --- |
| `status` / `config --list` | Show connected real devices and configured device/Simulator state. |
| `config` | Install or update the on-device driver; use `config --mac` once before the first local Mac-backend start. |
| `start` / `status` / `stop` | Select, inspect, or release the current target. These are the only Mac-backend lifecycle commands; restart Mac with `stop`, then `start --mac`. |
| `activateApp` / `terminateApp` | Open or close an app by bundle ID on a real device or Simulator; activation is UI-ready by default. |
| `dom` | Print the current semantic UI tree. |
| `ui-tree` | Inspect UIKit view classes and layout details for the active Mac App; use `dom` for interaction. |
| `tap` / `longpress` | Act on a label or coordinate. |
| `swipe` | Scroll by direction/distance or toward a target label. |
| `input` | Type into the current keyboard focus, optionally tapping a target first. |
| `rotate` | Set and verify a real-device or Simulator orientation, optionally returning the fresh post-rotation DOM. |
| `screenshot` | Capture a native-resolution JPEG with accurate host OCR and Logical coordinates by default. |
| `capture` | Capture a fixed-rate JPEG sequence plus `manifest.json`, with optional tolerant changed-frame filtering (max 10 FPS). |
| `media import` | Add one local photo or video to the Photos library used by the active backend. |
| `oslog` / `nslog` | Capture system logs or app-side NSLogger output. |
| `proxy` | Capture HTTP/HTTPS traffic through mitmproxy. |
| `open` | Open a URL or custom scheme on a device; on Mac it targets and activates the active App. |

Typical manual loop:

```bash
ios-use activateApp com.apple.Preferences --dom
ios-use waitFor "蓝牙" --timeout 5s
ios-use tap "通用"
ios-use swipe --to "开发者" --from "蓝牙"
ios-use input --tap "搜索" --content "蓝牙"
ios-use rotate --to landscape-right --dom --json
ios-use screenshot --name settings-home
ios-use screenshot --name channels-disagree  # explicit visual evidence when AX is insufficient

# Coordinate fallback for a visual-only control; semantic targets remain preferred.
ios-use tap 67 269

# Short visual sequence; run the interaction separately so the capture primitive stays composable.
ios-use tap "站姿1" && ios-use capture --fps 10 --duration 3 --name pose-sweep
```

Status, App install/list/lifecycle, DOM/screenshot/wait, and UI action commands support
`--json` and emit one versioned envelope suitable for scripts and agents. For example:

```bash
ios-use status --json
ios-use activateApp com.apple.Preferences --dom --json
ios-use tap "通用" --json
```

When a blocking interaction exists, the machine envelope includes a top-level
`interaction` summary and a warning. App-owned alerts must be handled with
`dismissAlert`; external macOS permission prompts are left to the user or
Computer Use. Bare `dismissAlert` accepts only an unambiguous one-button alert;
choose `--label`, `--index`, or `--primary` for a multi-button alert.

Repeatable sequences are ordinary shell scripts, so they can use variables, conditionals, and the same CLI commands without another DSL:

```bash
set -euo pipefail
ios-use waitFor "蓝牙" --timeout 8s
ios-use tap "蓝牙"
ios-use dom
```

For changing labels, wait on a stable substring or use an explicit regex instead of
copying one transient value such as a percentage:

```bash
ios-use waitFor "优化身形线条中" --match contains --gone --timeout 55s
ios-use waitFor '优化身形线条中.*\d+%' --match regex --gone --timeout 55s
```

Time options accept `s` and `ms` suffixes. Bare `waitFor`, `capture`, and log
timeouts are seconds; bare long-press and post-mutation `--dom` durations are
milliseconds.

### Mac Backend

The Mac backend runs a managed copy of an unencrypted
arm64 iPhone App directly on Apple silicon. Its device
contract is compiled into the Runtime and host from one header:
`iPhone16,2`, 430 x 932 logical points, 3x scale, and 1290 x 2796 native
pixels.

The Mac backend is not fully supported on macOS 26 or newer. `start --mac`
prints a warning and continues, but UI interaction can still crash. For
reliable automation, use a validated older macOS release, a real device, or a
Simulator.

```bash
bash scripts/build_swift_cli.sh --debug

./ios-use config --mac
./ios-use start --mac --app /path/to/Source.app
./ios-use status
./ios-use dom
./ios-use tap "A stable label" --dom
./ios-use screenshot
./ios-use stop
```

On Apple Silicon with full Xcode and `xcodegen` available, the local CLI build
also builds the default injected runtime. Before the first Mac-backend start for
your macOS account, run `config --mac`; macOS asks once for authentication
to trust the dedicated signing identity. If you cancel, safely retry the same
command: it resumes that identity instead of creating another one. The signing
identity and installed Apps are shared by the macOS account, while each
`IOS_USE_HOME` keeps its own session and remembers which Bundle ID to reuse.
Both Mac start forms check the existing identity and tell you to run
`config --mac` if setup is missing or trust must be completed.

Each Bundle ID has one installed Mac App. `start --mac --app <source.app>`
checks the source and signing identity, reuses an unchanged installed App, or
updates it when needed. Every Mac App includes the Frida debug Engine, so
`ios-use debug` is always available. Later, `start --mac` launches the current
App remembered by this `IOS_USE_HOME` without requiring its source path.

v2.0.4 does not migrate or auto-launch Mac Apps installed by older versions, and
it never deletes old caches for you. After upgrading, stop any running Mac
session and run `start --mac --app` once for each Bundle you want to keep using.
Run `ios-use du` to see leftover caches you can remove yourself.

The CLI creates one random session ID and connects straight to the injected
Runtime's owner-only Unix socket. `driver.lock` keeps the Mac backend selected until
`ios-use stop`, so session commands cannot fall back to XCTest. `status`,
screenshots, DOM/wait, touch/input, capture, URL delivery, logs, and diagnostics
all use that exact process, executable, and session.
`ui-tree` is a read-only Mac-only diagnostic that relates a fresh semantic DOM
target to its current UIKit view subtree. It does not replace `dom`, does not
act on views, and is unavailable for device and Simulator sessions.
Lifecycle remains host-owned: `activateApp`, `terminateApp`, `home`, and DDI
operations are explicitly unsupported while a Mac session is active.

The Runtime presents the App in an opaque, rectangular Simulator-style host
with the standard AppKit title bar, traffic lights, and shadow. The
scene-owning UIKitMacHelper window is kept instead of adding a second mirror
window. Its content is a fixed 430 x 932 logical-point canvas and the window
is not resizable. Catalyst owns the on-screen presentation size and Retina
backing; ios-use does not wrap or visually scale the content view. There is no
transparent gap or synthetic toolbar. Host decoration is never a target
coordinate or evidence.
Set `IOS_USE_PLAY_ENABLE_3X_BACKING=1` on `ios-use start --mac` to request a
3x scene backing for that launch. When omitted, Catalyst chooses the Retina
backing.
Screenshots capture only the target process's complete canvas compositor
surfaces, including Metal, and always produce a strict 1290 x 2796 frame. The
Runtime never draws synthetic time, battery, Dynamic Island, status glyphs, or
Home Indicator. The path does not use ScreenCaptureKit or request Screen
Recording permission.

## Performance Snapshot

The benchmark below compares `ios-use` against the full `Appium Server -> WebDriverAgent` stack on the same real-device Settings scenario. Lower is better.

| Case | ios-use Avg | Appium+WDA Avg | Reduction |
| --- | ---: | ---: | ---: |
| `start_session` | `1040.0 ms` | `10753.6 ms` | `90.3%` |
| `dom_cached` | `20.7 ms` | `965.7 ms` | `97.9%` |
| `wait_for_present` | `14.0 ms` | `308.7 ms` | `95.5%` |
| `tap_label` | `413.2 ms` | `1076.3 ms` | `61.6%` |
| `scroll_to_visible` | `10799.2 ms` | `17050.9 ms` | `36.7%` |

These are the operations that matter most to AI agents: start a session, refresh UI state, wait for changes, and act. Full benchmark setup and the complete table are in [docs/benchmark.md](docs/benchmark.md).

## Proxy Shell Examples

The three former proxy recipes are available as copyable shell examples. They use the public CLI primitives and are intentionally kept separate from the built-in `proxy` state machine:

```bash
bash examples/proxy/configca.sh
bash examples/proxy/set-wifi-proxy.sh --server 192.168.1.10 --port 8080
bash examples/proxy/clear-wifi-proxy.sh
```

See [examples/proxy/README.md](examples/proxy/README.md) for prerequisites and step-by-step notes.

## Dependency Matrix

| Dependency | Install CLI | Real Device | Simulator / Dev |
| --- | --- | --- | --- |
| `bash`, `curl`, `tar` | required | not needed after install | dev also uses them |
| `swift` | only for `--build-from-source` | not needed after install | required for SwiftPM development |
| `xcrun simctl` | not needed | not needed | required for Simulator config; dev build also uses it |
| `unzip` | not needed | required during `config` | required during Simulator `config` |
| `altsign-cli` | copied by installer if bundled | required for real-device signing | not needed |
| `dns-sd` | not needed | optional for NSLogger Bonjour publish | optional for NSLogger Bonjour publish |
| `mitmproxy` | not needed | proxy capture only | proxy capture only |
| `node` | not needed | benchmark only | benchmark and full Simulator tests |
| `xcodebuild`, `zip`, `mktemp` | not needed | not needed at runtime | required for `scripts/build_driver.sh` |
| `appium`, `lsof` | not needed | not needed at runtime | benchmark only |

## Repository Layout

```text
swift-cli/             Swift CLI, command parsing, config, proxy, logs, and host tools
shared/IOSUseProtocol/ Shared Swift RPC types and Fory frame models
driver/                Swift XCTest driver
playcover-runtime/     Injected Mac Catalyst Runtime plus pinned PlayTools sources
examples/proxy/        Copyable shell recipes for proxy device setup
scripts/               Install, build, test, and benchmark utilities
docs/                  Public documentation
ios-use-skill/         Skill documentation installed for agent usage
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

`bash scripts/build_swift_cli.sh` builds the local workspace CLI to repo-root
`./ios-use`; on Apple Silicon development hosts with full Xcode and `xcodegen`
it also keeps a local development Runtime under `.ios-use/playcover/` up to
date. Release installs instead use the checksummed, read-only prefix share
layout; release CI runs the exact staged archive through an isolated,
non-launching install verification before upload. Use that binary for development
instead of a global `ios-use`.
`bash scripts/build_driver.sh` defaults to Debug and writes development IPAs
under `IOS_USE_HOME`, or cwd `.ios-use/` when unset. `scripts/ci_test.sh` is the
main local unit and build gate. Hosted CI routes script, Swift, Driver, and Mac
Runtime changes to focused workflows. Full Simulator command matrix tests use
`bash scripts/ci_full_simulator.sh --driver-ipa <driver-sim.ipa>`.
See `scripts/README.md` for the script index.

## Acknowledgments

- **[WebDriverAgent](https://github.com/appium/WebDriverAgent)**: This project borrows heavily from the ideas and implementation patterns established by WebDriverAgent. Gesture synthesis, snapshot handling, scrolling behavior, and parts of the driver architecture were shaped by studying WDA's source.
- **[appium-xcuitest-driver](https://github.com/appium/appium-xcuitest-driver)**: The CLI and session behavior were informed by how the Appium XCUITest ecosystem exposes XCTest automation to users.
- **[Appium](https://github.com/appium/appium)**: Appium helped establish the mental model for cross-device automation workflows, including action-oriented commands and reusable sessions.
- **[PlayCover](https://github.com/PlayCover/PlayCover)** and **[PlayTools](https://github.com/PlayCover/PlayTools)**: The Mac backend derives its verified Mach-O conversion, interposition, and UIKit/AppKit bridge approach from these projects.

## License

[GNU AGPL v3.0](https://www.gnu.org/licenses/agpl-3.0.html) - see [LICENSE](LICENSE).
