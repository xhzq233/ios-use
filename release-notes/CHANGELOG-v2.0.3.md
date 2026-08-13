# ios-use v2.0.3

## Highlights

- Restores Mac Runtime compatibility for apps such as Feature that could crash
  while entering GPU-backed editors with v2.0.1 or v2.0.2.
- `start --mac` now warns on macOS 26 or newer. It continues to launch, but Mac
  UI interaction on those hosts is not yet fully supported and may crash.
- Real-device and Simulator behavior is unchanged.

## Upgrade Notice

- The v2.0.1 and v2.0.2 binary releases were withdrawn because of the Mac
  Runtime regression. Upgrade affected installations to v2.0.3.
- After upgrading, run `start --mac --app <source.app>` once to rebuild the
  managed App with the v2.0.3 Runtime.
