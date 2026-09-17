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
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/v2.1.0-alpha.5/scripts/install.sh | bash -s -- --version v2.1.0-alpha.5
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/main/scripts/install.sh | bash -s -- --build-from-source
```

### Linux remote client

Version `v2.1.0-alpha.5` supports native remote XCTest and Apple device
services on Linux x86_64. Install the alpha with the command above, or build
the development branch with Swift 6.2+ and standard Linux build tools:

```bash
git clone --branch codex/prepare-210 https://github.com/xhzq233/ios-use.git
cd ios-use
bash scripts/build_swift_cli.sh
./ios-use start -d phone --connection device-connection.json
./ios-use dom -d phone
./ios-use tap "<label>" -d phone --dom
./ios-use screenshot -d phone
./ios-use stop -d phone
```

The Linux release workflow builds an x86_64 binary on Ubuntu 22.04 with the
Swift runtime statically linked. Running it needs glibc and libstdc++, without
a Swift installation. The provider handles leases, signing and transport.
ios-use owns XCTest, App management, URL opening and App stdout/stderr.
OCR, capture sequences, local USB, Simulator, the Mac App backend, system
logs and proxy require macOS.

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
ios-use open 'myapp://page' -d phone --bundle-id com.example.app --dom
ios-use tap '<label-from-dom>' -d phone --dom
ios-use uninstall com.example.app -d phone --json
ios-use stop -d phone
```

Here ios-use owns XCTest and reports `lifecycleOwner: ios-use`. `stop` closes
XCTest and App log capture, while the provider keeps its lease and transport.
Start again with the same description while that connection remains valid.
The UI path connects directly to the Driver endpoint. Swift uses usbmux,
Lockdown and CoreDevice for App services; no Go runtime is required. TLS wraps
the existing device socket directly, with no additional localhost relay.
`activateApp --log` captures stdout/stderr from the new App process on the CLI
host, under `$IOS_USE_HOME/logs/devices/<device-id>/` (default home: `~/.ios-use`).
`--json` returns `data.logFile` and `data.logCapturePid`; use `tail -f <logFile>`
to follow output. Stopping capture retains the file. Sandbox log files are not read.
The adjacent `cli.log` records tunnel, stdio, App service and launch stages for
capture startup diagnosis.
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
This changes the running Mac App and saves the selection in the current
`IOS_USE_HOME` for future starts. Setting a preset does not run signing setup.

| Preset | Logical size | Scale |
| --- | --- | --- |
| `iphone-se` | 375 × 667 | 2× |
| `iphone-13` | 390 × 844 | 3× |
| `iphone-15-pro` | 393 × 852 | 3× |
| `iphone-15-pro-max` (default) | 430 × 932 | 3× |
| `ipad-pro-11` | 834 × 1194 | 2× |
| `iphone-duo` (preview) | 669 × 951 expanded; 466 × 678 collapsed | 3× |

The preset controls device identity, phone/tablet layout, portrait screen size,
and fixed-window safe areas and screenshot resolution. `status --json` reports the active
`macDevice` and the saved `configuredMacDevice`. App-specific iPad support
still depends on the App's layouts; this does not emulate hardware or iPadOS.

Device chrome is enabled by default and ships inside the Runtime framework;
Xcode is not needed to load the bundled device artwork. The shell follows the
native window, leaves App input intact, and is excluded from screenshots.
The native title bar provides a device selector and Rotate; iPhone Duo also
has an Expand/Collapse button. These controls change the current App in place.

`ios-use config --mac --device-model iphone-duo` switches a running Mac App
immediately and saves the selection for future starts. The same applies to
`--device-chrome on|off` and `--window-mode fixed|resizable`. With no running Mac
session, config saves the choice for the next start. Toolbar changes affect the
current session; use config to save it. The legacy Duo inner/outer names remain
accepted, but selecting `iphone-duo` and using Expand/Collapse is sufficient.

A live switch updates the Runtime's screen identity, viewport, traits, safe areas,
and capture scale while preserving the App process and navigation. Apps that
cache device-dependent layouts in their own startup code may still need a restart.

For adaptive App layouts, use `ios-use config --mac --device-model ipad-pro-11 --window-mode resizable`.
The device screen identity stays fixed while DOM coordinates and screenshots
follow the actual App window. The App's scene minimum/maximum size preferences
are preserved, with Catalyst applying its own limits. Phone-only or full-screen
compatibility Apps may still restrict resizing. Resizable mode hides the device
shell and uses native window safe areas. It previews App layout; it does not
implement the iPadOS window manager, Stage Manager or Split View. Restore the
full device canvas with `--window-mode fixed`. These options also apply to the current Mac session.
See Apple's [scene size restrictions](https://developer.apple.com/documentation/uikit/uiscenesizerestrictions)
and [full-screen compatibility migration](https://developer.apple.com/documentation/technotes/tn3192-migrating-your-app-from-the-deprecated-uirequiresfullscreen-key).

Duo presets are layout previews. They use Apple's [App Store screenshot
canvases](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications)
(inner 2007 × 2853, outer 1398 × 2034) with an assumed 3× logical scale.
These differ from the inner panel's physical pixel dimensions. Until the Duo
SDK/runtime is available for validation, the previews retain the existing
iPhone runtime identity and use zero synthetic safe-area insets. They do not
emulate folding, the iOS 27 side controls, or claim exact Duo hardware metrics.


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

- Linux x86_64 for remote device connections; Apple silicon macOS for local device backends.
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
