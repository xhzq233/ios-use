# ios-use v2.1.4

- Preserve each source binary's build SDK version during Mac conversion, including nested frameworks, so UIKit uses the App's intended compatibility behavior.
- Fix Mac device-model switching for Apps with full-screen declarations. Conversion removes those requirements from the prepared Mac App while preserving the source iOS App.
- Fix Mac readiness and trait propagation across multiple windows, including login overlays and model changes. Safe-area checks now follow the selected window, and fixed-window policy is applied after Catalyst layout.
- Parse codesign entitlements and signature metadata from separate output streams, preventing incorrect results with unbuffered output.

## Upgrade

Update the CLI, Driver and Mac Runtime together. Run
`ios-use config --udid <device-udid>` to update the real-device Driver.

For each existing Mac App, stop it and run
`ios-use start --mac --app <source.app>` to rebuild the prepared copy with the
updated conversion behavior. The source App is unchanged.

```bash
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/v2.1.4/scripts/install.sh | bash -s -- --version v2.1.4
```
