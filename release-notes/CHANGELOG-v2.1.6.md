# ios-use v2.1.6

- Auto-recover `--connection` XCTest sessions once after unexpected runner disconnects while the provider `usbmux` endpoint remains reachable, and fail fast with a transport hint when `usbmux` is unreachable.
- Give provider-aware hints when iOS refuses to launch an app (`CoreDevice` 10002) on remote `--connection` sessions and retain the full `NSUnderlyingError` chain.
- Inline the recent `xctest-holder.log` tail into XCTest holder startup failure errors and pass `ps -ww` when inspecting holder processes so long `--connection` / `--udid` command lines are not truncated.
- Enable `ios-use oslog` (`os_trace_relay`) and `ios-use media import` on Linux x86_64 remote sessions, and run remote recovery/feature unit tests in Linux CI.
- Document `dismissAlert` for system permission dialogs and Linux `oslog` / `media import` / auto-recovery workflows in the Skill.

## Upgrade

Update the CLI, Driver and Mac Runtime together. Run
`ios-use config --udid <device-udid>` to update the real-device Driver.

For each running Mac App, stop it and run
`ios-use start --mac --app <source.app>` to prepare it with the updated Runtime.

```bash
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/v2.1.6/scripts/install.sh | bash -s -- --version v2.1.6
```
