# ios-use v2.1.0

> Unreleased. This is a version-preparation draft, not a published release.

## Highlights

- Run multiple Devices in one `IOS_USE_HOME`, with separate Driver sessions,
  logs, and artifacts. Use the stable Device IDs shown by `status` with
  `--device` / `-d` when more than one Device is running.
- Use `ios-use mcp` for persistent JavaScript automation through `js` and
  `js_reset` tools. Each call returns text and image content on completion;
  Device handles, AX observations, and Driver connections are reused.
- Batch repeated UI work into helpers and loops, checking intermediate page
  state inside the script instead of returning to the model after every action.
- AX and screenshot observations wait for animation-idle by default. Read full
  parent/child relationships from `device.get()`; combined AX and screenshot
  calls retain the AX indices and return image bytes directly.
- Add touch multi-clicks, coordinate dragging, literal text selection with
  prefix/suffix disambiguation, verified whole-value replacement, and iOS
  keyboard chords. Mac inputs preserve the current selection.
- Scroll by positive fractional pages, such as
  `device.scroll(target, "down", 0.5)`, using the observed scroll viewport and
  requested direction. Fractional amounts are no longer rounded to whole swipes.
- Install only the ios-use Skill on a remote Agent without installing the Mac
  binary or configuring a device host. The full installer also supports
  `IOS_USE_INSTALL_SKILL=0` for consumers that manage Skill discovery themselves.

## Fixes

- Improve scroll targeting for sectioned lists and visibility-aware container
  selection.
- Clean up JavaScript on timeout, cancellation, reset, or MCP disconnection.
- Preserve UTF-8 across RPC chunks and complete MCP messages under stdout
  backpressure, including large images with concurrent replies.
- Avoid false AX diffs caused by JSON property order, preserve editable Unicode
  values, and keep numeric-looking labels distinct from coordinates.
- Treat placeholder-only fields as empty during verified replacement and clear;
  never estimate deletion counts from a displayed or masked value.
- Fix IPA metadata inspection for App installation and Driver version checks.
- Keep the installed Skill and CLI on the same release, including default
  latest installs. Both installers accept `--version <tag>`.

## Compatibility and Upgrade Notes

- MCP requires Node.js 22.18+; native CLI commands do not. The old `ios-use repl`
  entry point is removed; register `ios-use mcp` with your Agent client instead.
- Rich-text paste, secondary accessibility actions, and secure-field replacement
  or selection remain unavailable. iOS clicks are touch-only; Mac currently
  supports single clicks and Return/Enter keys.
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
