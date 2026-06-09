---
name: "ios-use Simulator reference"
description: "Simulator-specific setup, lifecycle, and troubleshooting for ios-use."
---

# Simulator Reference

Use this reference only when the target is an iOS Simulator. The main skill flow is optimized for real devices.

## Requirements

- Simulator use requires Xcode command line tools: `xcrun simctl` and `xcodebuild`.
- Use a booted Simulator UDID. List booted targets with:

```bash
ios-use devices --simulator
```

## Setup And Start

Simulator driver setup is unsigned and separate from real-device signing:

```bash
ios-use config --simulator --udid <sim-udid>
ios-use start <sim-udid>
ios-use dom
```

Important boundaries:

- `config --simulator` installs the prebuilt Simulator driver IPA and records config. It does not start the driver or write `driver.lock`.
- `start <sim-udid>` starts the XCTest runner through `xcodebuild test-without-building` and writes `driver.lock`.
- Omitting UDID from `start` selects the first USB real device, not a Simulator. Always pass the Simulator UDID.
- `stop` terminates the Simulator runner and the host-side `xcodebuild` holder recorded in `driver.lock`.

## Common Commands

Once started, driver-backed commands are the same as real device commands:

```bash
ios-use dom --fresh
ios-use find "Settings"
ios-use tap "Settings"
ios-use screenshot
ios-use stop
```

Host-side commands still accept explicit Simulator UDID:

```bash
ios-use open "https://example.com" --udid <sim-udid>
ios-use activateApp com.apple.Preferences --udid <sim-udid>
ios-use terminateApp com.apple.Preferences --udid <sim-udid>
ios-use oslog --udid <sim-udid> --process IOSUseDriver-Runner --timeout 5
```

## Troubleshooting

- If `start` fails, inspect `~/.ios-use/logs/xctest-holder.log`.
- If the driver appears stale, run `ios-use stop`, then rerun `ios-use config --simulator --udid <sim-udid>` and `ios-use start <sim-udid>`.
- Simulator driver artifacts are Xcode-version-sensitive. Rebuild with `bash scripts/build_driver.sh --simulator-only` when the local Xcode or runtime changes.
- Do not use `ddi-mount` for Simulator; DDI is a real-device requirement.
