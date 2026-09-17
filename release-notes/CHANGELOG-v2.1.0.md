# ios-use v2.1.0

> Unreleased. This is a version-preparation draft, not a published release.

## Highlights

- Switch the running Mac App's device preset with `config --mac --device-model`:
  iPhone SE, iPhone 13, iPhone 15 Pro/Pro Max, iPad Pro 11-inch and iPhone Duo.
  The native toolbar also selects models, rotates the viewport, and folds or
  expands Duo. CLI configuration persists for future starts; toolbar changes
  affect the current session. Apps that cache device traits at startup may
  still need a restart.
- Bundle the original Simulator device chrome assets in the Runtime framework,
  alongside the Duo preview artwork. A spaced native toolbar keeps controls
  clear of the device frame, including tall iPhone SE bezels.
- Run multiple Devices in one `IOS_USE_HOME`, with separate Driver sessions,
  logs, and artifacts. Use the stable Device IDs shown by `status` with
  `--device` / `-d` when more than one Device is running.
- The installer keeps the Skill at `~/.ios-use/skill` and supports `--no-skill`
  for consumers that create their own discovery links.

## Fixes

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
- After this version is published and installed, refresh configured real-device
  Drivers with `ios-use config --udid <device-udid>` before starting them with
  the new CLI. This preparation does not install or update any Driver.
- No release tag, release assets, or GitHub Release are created by this version
  preparation. Use the latest published release until v2.1.0 is available.
