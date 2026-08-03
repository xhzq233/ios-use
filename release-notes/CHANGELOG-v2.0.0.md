# ios-use v2.0.0

## Highlights

- Added a Mac backend for running locally built iPhone Apps on Apple silicon:
  `ios-use start --mac --app <path-to-app>` starts the App, and subsequent
  screenshot, DOM, wait, and input commands use that active session until
  `ios-use stop`.
- Added reusable prepared-App storage shared across `IOS_USE_HOME` instances,
  while sessions, logs, and artifacts remain Home-local.
- Added `ios-use du` to report ios-use storage by category, size, and latest
  update time without deleting data.
- Mac releases now include the Runtime and optional Frida Engine resources
  required by the backend, the Engine's static-dependency notices, and the
  complete pinned Frida source closure in the corresponding-source archive.

## Breaking Behavior

- The Mac backend lifecycle is intentionally limited to `start`, `status`, and
  `stop`; App lifecycle commands are not routed through an active Mac session.
- Mac UI commands require the App to remain visible in the foreground or
  foreground-inactive. Hidden, minimized, off-Space, or otherwise backgrounded
  UI returns a classified error instead of silently activating the App.
- This release changes the CLI/Driver protocol. Re-run
  `ios-use config --udid <UDID>` after upgrading before using a real device.

## Notes

- The Mac backend supports Apple-silicon Macs and iPhone App bundles.
- System permission prompts outside the App process remain under user or
  computer-use control; ios-use does not request macOS Accessibility access.
