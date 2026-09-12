# ios-use

> Fast iOS UI automation for agents and scripts.

[![Release](https://img.shields.io/github/v/release/xhzq233/ios-use?sort=semver)](https://github.com/xhzq233/ios-use/releases)
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL%20v3-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20iOS-lightgrey.svg)](#requirements)

`ios-use` drives real iPhones, Simulators, and supported iPhone Apps on Apple
silicon Macs. It exposes a compact accessibility tree, semantic actions, JSON
output, screenshots, logs, proxy capture, and persistent multi-device MCP tools.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/main/scripts/install.sh | bash -s --
```

The CLI and Skill come from the same release, including when installing latest.

Install a specific release or build from source:

```bash
# v2.1.0 is in preparation; this pinned command is for use after publication.
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/main/scripts/install.sh | bash -s -- --version v2.1.0
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/main/scripts/install.sh | bash -s -- --build-from-source
```

## Quick Start

### Real device

Connect an unlocked iPhone over USB, then run:

```bash
ios-use status

# First setup: authenticate AltSign once, then install the driver.
~/.ios-use/altsign-cli/altsign-cli list --apple-id '<Apple ID>'
ios-use config --udid <device-udid>

ios-use start <device-udid>
ios-use activateApp com.apple.Preferences --dom
ios-use tap "General" --dom
ios-use screenshot --name settings
ios-use stop
```

Release use on a real device does not require Xcode. Free Apple Developer
signing is supported and normally needs renewal every seven days.

### Simulator

```bash
xcrun simctl list devices booted
ios-use config --simulator --udid <simulator-udid>
ios-use start <simulator-udid>
```

### Mac backend

```bash
ios-use config --mac
ios-use start --mac --app /path/to/App.app
ios-use dom
ios-use tap "A stable label" --dom
ios-use stop
```

The Mac backend requires an unencrypted arm64 iPhone App. It is not fully
supported on macOS 26 or newer.

## Multiple Devices

One `IOS_USE_HOME` can keep independent Device Contexts running at the same
time:

```bash
ios-use start <first-device-udid>
ios-use start <second-device-udid>
ios-use status --json

ios-use dom -d <device-id>
ios-use tap "Continue" -d <device-id> --dom
ios-use stop -d <device-id>
```

When exactly one Device is running, `-d` / `--device` may be omitted. With multiple
Devices, use the stable IDs printed by `status`.
Real devices and Simulators use their bare UDID; the Mac Backend uses `mac`.
Per-Device state, logs, and artifacts live under `~/.ios-use/{state,logs,artifacts}/devices/<device-id>/`.
Existing single-Device state is still read and moves to the new layout after its next stop/start.

## MCP automation

Register `ios-use mcp` as a local stdio MCP server. For Codex:

```bash
codex mcp add ios-use -- ios-use mcp
```

Start a new Agent session to discover `js` and `js_reset`. Call `js` with
`{"code":"let device = await cua.getDevice(\"<device-id>\");"}`. Each call returns
its text and image content when the code completes; variables and Device
handles persist across calls. No terminal polling is needed. `timeout_ms`
defaults to 30,000 and can be raised to 300,000 for longer batches.

Use `cua.help()` and `device.help()` for the current API. Common Device methods
include `getAXState`, `getAXSnapshot`, `getScreenshot`, `getAXStateAndScreenshot`, `click`, `drag`,
`longPress`, `scroll`, `scrollTo`, `waitFor`, `setValue`, `selectText`, `typeText`,
`paste`, and `pressKey`. Observations request native quiescence by default;
this does not guarantee that every navigation transition has finished.
`getAXSnapshot()` returns fresh structured AX without text formatting, diffing,
or automatic output; `get()` reads the cached tree without another request.
Use `waitFor(ax => condition, {timeout: 10})` to check a known page transition
inside one call; it returns the matching snapshot or throws on timeout.
`listApps`, `getApp(bundleId)`, and `terminateApp(bundleId)` manage iOS / Simulator
Apps. `getApp` activates the App and returns the same Device handle with its
ready AX; UI methods still operate on the Device's current foreground, not an
independently pinned App. `start()` / `stop()` control configured Drivers; select
an idle Device with `cua.getDevice(id, {observe:false})`. See the
[MCP guide](ios-use-skill/references/mcp.md) for examples.

JavaScript runs in one Node.js child process and calls the Swift Host over
localhost TCP RPC; the Host reuses a separate Driver connection per Device.
Each MCP connection owns its own JavaScript context. `js_reset`, execution
timeout, or cancellation clears that context; disconnection releases its
resources. Drivers and Apps remain running. Device actions already issued may
still finish, so observe before retrying. Device setup, lifecycle, logs and
artifact-producing commands remain available through the native CLI.
The old `ios-use repl` command has been removed.

## Performance Snapshot

Historical real-iPhone Settings benchmark (2026-05-30), comparing the native CLI
with the full Appium Server → WebDriverAgent stack. Lower latency is better.

![Historical ios-use and Appium + WDA latency comparison, with separate scales for short and long operations](docs/benchmark.svg)

| Operation | ios-use (ms) | Appium + WDA (ms) | Latency reduction |
| --- | ---: | ---: | ---: |
| Start session | 1,954.8 | 10,753.6 | 81.8% |
| Cached UI tree | 20.7 | 965.7 | 97.9% |
| Wait for element | 14.0 | 308.7 | 95.5% |
| Screenshot (no OCR) | 81.2 | 179.0 | 54.6% |
| Tap by label | 413.2 | 1,076.3 | 61.6% |
| Scroll to element | 10,799.2 | 17,050.9 | 36.7% |
| Terminate app | 1,195.1 | 1,144.0 | −4.5% |

Command cases are means of three iterations; cold session start is one sample.
These are tool timings, not REPL comparisons or Agent success/token benchmarks,
and have not been rerun for the current development version. See the
[full results and methodology](docs/benchmark.md).

## Commands

| Command | Purpose |
| --- | --- |
| `status`, `config` | Discover Devices and install or inspect Drivers |
| `start`, `stop` | Start or release a Device Context |
| `mcp` | Serve persistent JavaScript tools over stdio MCP |
| `apps`, `install`, `activateApp`, `terminateApp` | Manage Apps |
| `dom`, `waitFor` | Observe and query UI state |
| `tap`, `longpress`, `swipe`, `input`, `rotate` | Interact with the UI |
| `screenshot`, `capture`, `media import` | Capture or import media |
| `oslog`, `nslog`, `proxy` | Capture logs and network traffic |
| `open` | Open a URL or custom scheme |
| `debug`, `ui-tree` | Mac backend diagnostics |

Run `ios-use --help` or `ios-use <command> --help` for the complete contract.
Most automation commands support `--json`.

## Requirements

- Apple silicon macOS.
- Real devices: iOS 17.4 or newer, USB, and a free or paid Apple Developer
  account for driver signing.
- Simulators and source builds: full Xcode; source builds also require Swift
  and `xcodegen`.
- MCP: Node.js 22.18+.
- Proxy capture: `mitmproxy`.

## Development

```bash
git clone https://github.com/xhzq233/ios-use.git
cd ios-use
bash scripts/build_swift_cli.sh --debug
./ios-use --help
bash scripts/ci_test.sh
```

See [scripts/README.md](scripts/README.md) for build and test entry points,
[docs/benchmark.md](docs/benchmark.md) for benchmarks, and
[ios-use Skill](ios-use-skill/SKILL.md) for operational workflows.

For reproducible Agent task comparisons, including the 2.1.0 MCP / 2.0.4 CLI
Settings experiment, see [eval/README.md](eval/README.md).

## Acknowledgments

The implementation builds on ideas and upstream work from
[WebDriverAgent](https://github.com/appium/WebDriverAgent),
[Appium](https://github.com/appium/appium),
[PlayCover](https://github.com/PlayCover/PlayCover), and
[PlayTools](https://github.com/PlayCover/PlayTools).

## License

[GNU AGPL v3.0](LICENSE)
