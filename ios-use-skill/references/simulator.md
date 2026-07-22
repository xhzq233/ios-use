---
name: "ios-use Simulator reference"
description: "Simulator-specific setup, lifecycle, and troubleshooting for ios-use."
---

# Simulator Reference

Use this reference only when the target is an iOS Simulator. The main skill flow
is optimized for real devices.

## Requirements

- Simulator use requires Xcode command line tools and a booted Simulator.
- List booted targets with:

```bash
xcrun simctl list devices booted
```

## Setup and start

Simulator setup is separate from real-device signing:

```bash
ios-use config --simulator --udid <sim-udid>
ios-use start <sim-udid>
ios-use dom
```

Use an explicit Simulator UDID with `start`; omitting it selects a connected
real device. Run `ios-use stop` before switching targets.

## Common commands

Once the Simulator target is started, driver-backed commands are the same as on
a real device:

```bash
ios-use dom --fresh
ios-use waitFor "Settings" --timeout 5s
ios-use tap "Settings"
ios-use screenshot
ios-use stop
```

Host-side commands accept an explicit Simulator UDID:

```bash
ios-use open "https://example.com" --udid <sim-udid>
ios-use activateApp com.apple.Preferences --udid <sim-udid>
ios-use terminateApp com.apple.Preferences --udid <sim-udid>
ios-use oslog --udid <sim-udid> --process IOSUseDriver-Runner --timeout 5
```

## Troubleshooting

- If `start` fails, run `xcrun simctl list devices booted` to verify the Simulator is booted, run `ios-use config --list` to inspect target configuration, then stop the target and retry the setup sequence.
- Do not use `ddi-mount` for Simulator; DDI is a real-device requirement.
