# ios-use

> Fast iOS UI automation for agents and scripts.

[![Release](https://img.shields.io/github/v/release/xhzq233/ios-use?sort=semver)](https://github.com/xhzq233/ios-use/releases)
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL%20v3-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20iOS-lightgrey.svg)](#requirements)

`ios-use` drives real iPhones, Simulators, and supported iPhone Apps on Apple
silicon Macs. It exposes a compact accessibility tree, semantic actions, JSON
output, screenshots, logs, proxy capture, and multi-device operation. Linux hosts
can operate iOS Drivers and Apple device services over remote connections.

Application nodes in the DOM provide page context. Element selectors search
their contents, so an App name does not shadow a button with the same label.
On XCTest targets, `dom --fresh` also redetects the foreground App after an external App switch.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/main/scripts/install.sh | bash -s --
```

The CLI and Skill come from the same release, including when installing latest.
Linux users currently need the explicit alpha install below.

By default, the installer links `~/.agents/skills/ios-use` to
`~/.ios-use/skill`. Add `--no-skill` to skip creating the default link; existing
Skill paths are left unchanged. Skill files still update with the CLI, so you
can link them into a project's or another agent's skills directory yourself:

```bash
mkdir -p .agents/skills
ln -s "$HOME/.ios-use/skill" .agents/skills/ios-use
```

Install a specific release or build from source:

```bash
# Opt in to the 2.1.0 alpha pre-release.
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/v2.1.0-alpha.4/scripts/install.sh | bash -s -- --version v2.1.0-alpha.4
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/main/scripts/install.sh | bash -s -- --build-from-source
```

### Linux TCP client

Linux x86_64 is available in `v2.1.0-alpha.4`; use the versioned
installer command above. For a source build, Swift 6.2+ and standard Linux
build tools are required:

```bash
git clone --branch v2.1.0-alpha.4 https://github.com/xhzq233/ios-use.git
cd ios-use
bash scripts/build_swift_cli.sh
./ios-use start -d phone --host <driver-host> --port <forwarded-port>
./ios-use dom -d phone
./ios-use tap "<label>" -d phone --dom
./ios-use screenshot -d phone
./ios-use stop -d phone
```

The Linux release workflow builds an x86_64 binary on Ubuntu 22.04
with the Swift runtime statically linked. Running the binary needs glibc and
libstdc++, without a Swift installation. The device provider handles leases,
signing and transport setup. The Prepare 210 development build also supports
`start --connection` for native XCTest lifecycle, App management, URL opening
and App stdout/stderr on Linux (see below). OCR, capture sequences, local USB,
Simulator, the Mac App backend, system logs and proxy require macOS.
`attach` and `detach` remain compatible entry points for UI-only TCP sessions.

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

`start --host/--port` is available from Alpha 4. `attach` remains supported
with the same endpoint options. Both endpoint options
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
remote targets from Alpha 4; earlier macOS releases default to OCR enabled.

### Remote Apple device services (Prepare 210)

A provider can expose a paired usbmux endpoint and a Driver TCP endpoint.
Save its connection description as `device-connection.json`:

```json
{
  "udid": "DEVICE-UDID",
  "driverBundleID": "com.iosuse.xcuidriver.xctrunner",
  "usbmux": { "host": "127.0.0.1", "port": 27015 },
  "driver": { "host": "127.0.0.1", "port": 18102 }
}
```

Use the provider's actual endpoints. It must install the matching, signed
Driver and prepare paired developer services. This transport is supported on
macOS and Linux x86_64; iOS 18.5 has been tested on real hardware.

```bash
ios-use start -d phone --connection device-connection.json
ios-use apps -d phone
ios-use install /path/to/signed-App.ipa -d phone --json
ios-use activateApp com.example.app --terminateExisting --log -d phone --json
ios-use open 'myapp://page' -d phone --dom
ios-use tap '<label-from-dom>' -d phone --dom
ios-use uninstall com.example.app -d phone --json
ios-use stop -d phone
```

Here ios-use owns XCTest and reports `lifecycleOwner: ios-use`. `stop` closes
XCTest and App log capture, while the provider keeps its lease and transport.
Start again with the same description while that connection remains valid.
The UI path connects directly to the Driver endpoint. Swift uses usbmux,
Lockdown and CoreDevice for App services; no Go runtime is required.
`activateApp --log` returns a background collector PID and log path for
stdout/stderr from the new App process. It does not read sandbox log files.
Signing remains the provider's responsibility; `install` accepts packages
already signed for the device. `status` describes saved ownership; use `dom`
to check current Driver responsiveness.

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

Choose a device preset with `ios-use config --mac --device-model ipad-pro-11`.
This saves the selection in the current `IOS_USE_HOME` and applies on the next
cold launch: stop the App, then run `ios-use start --mac`. A running App keeps
its current model. Setting a preset does not run signing setup.

| Preset | Logical size | Scale |
| --- | --- | --- |
| `iphone-se` | 375 × 667 | 2× |
| `iphone-13` | 390 × 844 | 3× |
| `iphone-15-pro` | 393 × 852 | 3× |
| `iphone-15-pro-max` (default) | 430 × 932 | 3× |
| `ipad-pro-11` | 834 × 1194 | 2× |

The preset controls device identity, phone/tablet layout, portrait screen size,
safe areas and screenshot resolution. `status --json` reports the active
`macDevice` and the pending `configuredMacDevice`. App-specific iPad support
still depends on the App's layouts; this does not emulate hardware or iPadOS.

Background scenes, minimized windows, and windows on another Space do not
automatically block UI commands. Apps can still pause work or rendering in the
background: a successful action or DOM update does not guarantee fresh pixels
from every renderer. Mac UI command entries in `logs/cli.log` include `sceneState`,
`minimized`, and `activeSpace`; failures in those states also include `uiContext`
in JSON output or a context line in text output. Successful commands do not
emit a background warning.

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
