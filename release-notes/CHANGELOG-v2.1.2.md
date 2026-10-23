# ios-use v2.1.2

- Support macOS 27 and iOS 27, including signing and Simulator Home.
- Improve Duo display routing and semantic touch accuracy.
- Fix Mac DOM, tab selection, startup recovery and explicit-device installation.
- Add update reminders and remove `dom --fresh`; use `--nodiff` for a full tree.

## Upgrade

Update the CLI, Driver and Mac Runtime together. Run
`ios-use config --udid <device-udid>` to update the real-device Driver.

```bash
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/v2.1.2/scripts/install.sh | bash -s -- --version v2.1.2
```
