# ios-use v2.1.0

> Unreleased. This is a version-preparation draft, not a published release.

## Highlights

- Run multiple Devices in one `IOS_USE_HOME`, with separate Driver sessions,
  logs, and artifacts. Use the stable Device IDs shown by `status` with
  `--device` / `-d` when more than one Device is running.
- Install only the ios-use Skill on a remote Agent without installing the Mac
  binary or configuring a device host. The full installer also supports
  `--no-skill` for consumers that manage Skill discovery themselves.

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
  latest installs. Both installers accept `--version <tag>`.

## Compatibility and Upgrade Notes

- Native quiescence can return during iOS navigation animations. Check the
  expected page/container before collecting results; it is not a universal
  readiness guarantee.
- The Skill is now named `ios-use`. Source selection follows the release version;
  the separate `IOS_USE_REF` override has been removed. Local Skill development
  still uses `bash scripts/install_skill.sh` from a checkout.
- Real-device and Simulator IDs are bare UDIDs; the Mac Backend uses `mac`.
  With exactly one running Device, the selector remains optional.
- Existing single-Device state remains readable and moves to the per-Device
  layout after its next stop/start.
- After this version is published and installed, refresh configured real-device
  Drivers with `ios-use config --udid <device-udid>` before starting them with
  the new CLI. This preparation does not install or update any Driver.
- No release tag, release assets, or GitHub Release are created by this version
  preparation. Use the latest published release until v2.1.0 is available.
