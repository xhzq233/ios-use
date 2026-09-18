# ios-use v2.1.0

## Highlights

- Support Linux x86_64 alongside macOS arm64. With `start --connection`,
  ios-use owns remote XCTest start/stop, App installation and management,
  `activateApp --log` stdout/stderr capture, URL opening and UI commands;
  a provider maintains the paired device connection and supplies signed Apps.
- Select an iOS URL handler with `open --bundle-id`. On Mac this targets the
  active App and rejects a different bundle ID.
- Switch the running Mac App's device preset with `config --mac --device-model`:
  iPhone SE, iPhone 13, iPhone 15 Pro/Pro Max, iPad Pro 11-inch and iPhone Duo.
  The native toolbar also selects models, rotates the viewport, and folds or
  expands Duo. CLI configuration persists for future starts; toolbar changes
  affect the current session. Apps that cache device traits at startup may
  still need a restart.
- Bundle the original Simulator device chrome assets in the Runtime framework,
  alongside the Duo preview artwork. A spaced native toolbar keeps controls
  clear of the device frame, including tall iPhone SE bezels.
- Rotate from the CLI or toolbar; show optional status-bar overlays outside
  CLI screenshots. Screenshots capture the current App window with transparent
  corners filled black, without device chrome or status overlays.
- Default screenshot OCR off; request it explicitly with `--ocr`.
- Allow Mac UI commands in background states and attach scene/window context
  to failures. Fresh rendering while locked/backgrounded remains under investigation.
- Run multiple Devices in one `IOS_USE_HOME`, with separate Driver sessions,
  logs, and artifacts. Use the stable Device IDs shown by `status` with
  `--device` / `-d` when more than one Device is running.
- The installer keeps the Skill at `~/.ios-use/skill` and supports `--no-skill`
  for consumers that create their own discovery links.

## Fixes

- Reject duplicate Remote sessions for one physical device and mismatched
  explicit UDIDs. Report Remote holder/endpoint health instead of assuming a
  saved session is running; reuse health checks within each status command.
- Compute CoreDevice TCP checksums without repeatedly copying packet buffers.
- Clip each DeviceKit PDF tile to its drawing bounds, fixing repeated iPad bezel
  segments. Keep iPad safe areas at the top and bottom when rotating.
- Preserve Duo's physical hinge orientation when opening or closing, and update
  the inner/outer display's size classes and preview safe-area profile. The
  Duo profile is a layout preview running on the host's UIKit runtime.
- Keep Catalyst's native scene orientation in resizable mode so a landscape
  device preset does not transpose a non-square App window's UIKit bounds.
- Release old snapshot trees after repeated observations while retaining the
  ancestor context needed by scrolling and interaction results.
- Read only the selected Device's session for explicit Device operations.
- Keep DOM and App-readiness identifiers tied to the App that produced the
  snapshot, including when the foreground changes during observation.
- Improve scroll targeting for sectioned lists and visibility-aware container
  selection.
- Fix IPA metadata inspection for App installation and Driver version checks.
- Keep the installed Skill and CLI on the same release, including default
  latest installs. The installer accepts `--version <tag>`.

## Compatibility and Upgrade Notes

- Remove UI-only `attach` and `start --host/--port`. Remote sessions use
  `start --connection` and native device services.
- Remove `nslog` and its NSLogger receiver, daemon, state and bundled TLS
  credentials. Use `activateApp <bundleId> --terminateExisting --log` for App
  stdout/stderr, `start --mac --log` on Mac, or `oslog` for unified logging.
- `open --json` returns the observed DOM once at `data.dom`; `data.readiness`
  contains readiness metadata without a duplicate DOM.
- Native quiescence can return during iOS navigation animations. Check the
  expected page/container before collecting results; it is not a universal
  readiness guarantee.
- The Skill is now named `ios-use`. Source selection follows the release version;
  the separate `IOS_USE_REF` override has been removed. Link the installed
  `~/.ios-use/skill` directory into any additional agent skills directory.
- Real-device and Simulator IDs are bare UDIDs; the Mac Backend uses `mac`.
  With exactly one running Device, the selector remains optional.
- Existing single-Device state remains readable and moves to the per-Device
  layout after its next stop/start.
- After installing, refresh configured real-device Drivers with
  `ios-use config --udid <device-udid>` before starting them with the new CLI.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/v2.1.0/scripts/install.sh | bash -s -- --version v2.1.0
```
