# ios-use v2.1.2

- Restore real-device signing on macOS 27 with AltSign CLI v0.3.2 and its
  Anisette v3 authentication. The installer also includes the iOS device
  registration platform fix and documents provider recovery.
- Check semantic touch geometry before delivering taps, long presses and
  input taps on XCTest targets. Moving targets return a retryable error before
  touch delivery. Improve foreground-App, viewport and gesture routing across
  iPhone Duo displays, reuse display context within an observation, and bind
  permission-alert children by accessibility identity.
- Make `home` return to SpringBoard on iOS 27 Simulators and select compatible
  Simulator runtimes and device types in the test scripts.
- Fix Mac builds with Swift 6.4 and variable code-signature padding. Return
  errors for malformed PlayChain keys, cancel expired DOM traversals between
  accessibility reads, resolve decorated tab labels to their owning controls,
  and recover interrupted launches with `stop`.
- Honor an explicit install `--udid` while a Mac session is active. Add a daily
  update reminder to successful interactive `start` and `status` commands.
- Remove `dom --fresh`: each DOM observation now redetects the foreground App
  on XCTest targets and captures the current tree.

## Upgrade

Update the CLI, Driver and Mac Runtime together. Reconfigure real-device
Drivers with `ios-use config --udid <device-udid>` before starting the new CLI.
Remove `--fresh` from scripts; use `dom --nodiff` when a full tree is required.

Mac compatibility warnings remain on macOS 26 and later. See
[macOS 27 validation](https://github.com/xhzq233/ios-use/blob/v2.1.2/docs/macos27-validation.md)
for tested behavior and remaining coverage. Further Duo expanded-display DOM
and gesture work remains under review in
[PR #38](https://github.com/xhzq233/ios-use/pull/38).

```bash
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/v2.1.2/scripts/install.sh | bash -s -- --version v2.1.2
```
