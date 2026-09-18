# ios-use v2.1.0-alpha.5

This prerelease adds native remote device services and Mac device/window previews. It includes macOS arm64 and Linux x86_64 clients; MCP/REPL remains separate.

## Remote devices

- `start --connection <file>` uses a provider-maintained device connection. ios-use owns XCTest startup/shutdown and supports UI commands, App management, URL opening, and `activateApp --log` stdout/stderr capture. The provider owns leasing, signing, and maintaining the device transport.
- Removed the old UI-only `attach` and `start --host/--port` interfaces. Update providers to the connection-file interface before upgrading.
- Remote service TLS uses the connected device socket directly. Shutdown no longer lets stale proxy workers close reused file descriptors; log writers append without overwriting each other.
- `open <url> --bundle-id <id>` selects the handler on supported device/Simulator paths. On Mac it validates the current App; it cannot route to another Mac-hosted App.

## Mac windows

- Seven cold-start presets: iPhone SE, 13, 15 Pro, 15 Pro Max, iPad Pro 11-inch, and Duo inner/outer layout previews.
- Native device decoration follows the original App window and stays out of App screenshots. Native window controls remain accessible above the bezel. Supported local DeviceKit artwork is loaded when available; only original fallback/Duo artwork is distributed.
- `config --mac --device-chrome on|off` selects decoration for the next cold start.
- `config --mac --window-mode fixed|resizable` separates screen identity from the current App viewport. Resizable mode preserves App scene size preferences and native window safe areas, hides the device shell, and updates DOM, input and screenshots to the actual window dimensions. Catalyst can impose additional limits; phone-only compatibility Apps may remain fixed.
- Disable the native titlebar separator so it no longer adds a dark line to the top of the captured canvas.
- Background state no longer blocks every UI command. Failures include background context, and command logs record scene, minimization and Space state. Fresh pixels from paused background renderers remain under investigation in #16.

These are App layout previews, not hardware/iPadOS window-manager emulation. Duo retains a supported iPhone identity and estimated chrome geometry; folding and iOS 27 system reserved regions are not emulated.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/v2.1.0-alpha.5/scripts/install.sh | bash -s -- --version v2.1.0-alpha.5
```

Use the matching CLI and Driver artifacts. The six assets are `ios-use-darwin-arm64`, `ios-use-linux-x86_64`, `driver.ipa`, `driver-sim.ipa`, `ios-use-mac-resources.tar.gz` and `SHA256SUMS`. Default latest installation continues to select the stable channel.

## Validation

Mac Fixture validation covers seven preset cold starts, semantic input and uncropped screenshot dimensions, native decoration, and a resizable universal App. The scene's requested minimum/maximum sizes remain intact while the viewport changes. Native remote lifecycle, App management, targeted URL opening and launch stdout/stderr collection were exercised on macOS and native Linux x86_64 real-device sessions during development. Host/Driver unit tests and own-process UIKit/Metal compositor checks accompany this release.

Linux requires a remote device transport; it does not provide local USB, Simulator, the Mac App backend or Vision OCR. `activateApp --log` captures the launched process's stdout/stderr, not arbitrary private log files or a guarantee of all unified OS log messages.
