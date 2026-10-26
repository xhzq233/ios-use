# ios-use v2.1.3

- Add explicit `up`, `down`, `left`, and `right` scroll directions and improve container selection for wide layouts.
- Calibrate Mac Duo presets against official Xcode 27.1 device profiles.
- Fix Mac text input through search-bar wrappers and an accessibility crash involving toolbar items.
- Add persistent Mac App volume and mute settings. Mac Apps are muted by default; use `ios-use config --mac --mute off` to enable sound or `ios-use config --mac --volume 25` to adjust volume.

## Upgrade

Update the CLI, Driver and Mac Runtime together. Run
`ios-use config --udid <device-udid>` to update the real-device Driver.

```bash
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/v2.1.3/scripts/install.sh | bash -s -- --version v2.1.3
```
