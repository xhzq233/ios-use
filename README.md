# ios-use

> Fast iOS UI automation for agents and scripts.

[![Release](https://img.shields.io/github/v/release/xhzq233/ios-use?sort=semver)](https://github.com/xhzq233/ios-use/releases)
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL%20v3-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20iOS-lightgrey.svg)](#requirements)

`ios-use` drives real iPhones, Simulators, and supported iPhone Apps on Apple
silicon Macs. It exposes a compact accessibility tree, semantic actions, JSON
output, screenshots, logs, proxy capture, and multi-device operation. Linux hosts
can operate externally managed iOS Drivers through TCP attachments.

Application nodes in the DOM provide page context. Element selectors search
their contents, so an App name does not shadow a button with the same label.
On XCTest targets, `dom --fresh` also redetects the foreground App after an external App switch.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/main/scripts/install.sh | bash -s --
```

The CLI and Skill come from the same release, including when installing latest.
Linux users currently need the explicit alpha install below.

Install a specific release or build from source:

```bash
# Opt in to the 2.1.0 alpha pre-release.
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/v2.1.0-alpha.3/scripts/install.sh | bash -s -- --version v2.1.0-alpha.3
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/main/scripts/install.sh | bash -s -- --build-from-source
```

### Linux TCP client

Linux x86_64 is available starting with `v2.1.0-alpha.3`; use the versioned
installer command above. For a source build, Swift 6.2+ and standard Linux
build tools are required:

```bash
git clone --branch v2.1.0-alpha.3 https://github.com/xhzq233/ios-use.git
cd ios-use
bash scripts/build_swift_cli.sh
./ios-use attach -d phone --host <driver-host> --port <forwarded-port>
./ios-use dom -d phone
./ios-use tap "<label>" -d phone --dom
./ios-use screenshot -d phone
./ios-use detach -d phone
```

The Linux release workflow builds an x86_64 binary on Ubuntu 22.04
with the Swift runtime statically linked. Running the binary needs glibc and
libstdc++, without a Swift installation. The device provider handles leases,
signing, IPA installation, port forwarding and XCTest startup. UI actions,
waits, app activation/termination and JPEG screenshots use the shared protocol.
OCR, capture sequences, local USB, Simulator, Mac, logging and proxy services require
a macOS host. `stop` on Linux detaches and leaves the remote Driver running.
Current source also accepts `start -d phone --host <host> --port <port>` as the
unified session entry point. Alpha 3 uses the compatible `attach` form above.

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

### External TCP driver

When another host or device provider starts the matching ios-use driver and
forwards its TCP port, connect without local USB or signing configuration:

```bash
ios-use start --device remote-phone --host 127.0.0.1 --port 18102
ios-use dom -d remote-phone
ios-use activateApp com.apple.Preferences -d remote-phone --dom
ios-use stop -d remote-phone
```

`start --host/--port` is available in current source; on Alpha 3 use `attach`
with the same endpoint options. `attach` remains supported. Both endpoint options
are required and cannot be mixed with a UDID or local start flags.
The host can be an IP address or hostname. Start checks the Fory protocol before
saving the session. UI commands use this endpoint; installation, URL opening,
media import, logs and proxy remain the provider's responsibility.
`detach` (or `stop` on this target) only removes the local attachment. It also
works offline and never stops the externally managed driver. Restore a lost
endpoint through its provider, then retry; ios-use does not launch a local driver
for a TCP attachment. Use a trusted network or secure tunnel for this plain TCP
connection. `status` reports `attached` and `lifecycleOwner: external`;
local sessions report `lifecycleOwner: ios-use`. This records the binding rather
than continuously probing remote health.

Screenshots default to JPEG output without OCR on both hosts. On macOS, use
`screenshot --ocr` to also recognize text and save an OCR sidecar. `--no-ocr`
remains accepted; Linux has no OCR engine. These defaults apply to local and
remote targets in current source; Alpha 3 on macOS defaults to OCR enabled.

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
These are tool timings, not Agent success/token benchmarks,
and have not been rerun for the current development version. See the
[full results and methodology](docs/benchmark.md).

## Commands

| Command | Purpose |
| --- | --- |
| `status`, `config` | Discover Devices and install or inspect Drivers |
| `start`, `stop` | Start or release a Device Context |
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

- Linux x86_64 for TCP attachments; Apple silicon macOS for local device backends.
- Real devices: iOS 17.4 or newer, USB, and a free or paid Apple Developer
  account for driver signing.
- Simulator and Driver builds: full Xcode, Swift and `xcodegen`. Linux CLI
  builds require Swift 6.2+ and do not need Xcode.
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

## Acknowledgments

The implementation builds on ideas and upstream work from
[WebDriverAgent](https://github.com/appium/WebDriverAgent),
[Appium](https://github.com/appium/appium),
[PlayCover](https://github.com/PlayCover/PlayCover), and
[PlayTools](https://github.com/PlayCover/PlayTools).

## License

[GNU AGPL v3.0](LICENSE)
