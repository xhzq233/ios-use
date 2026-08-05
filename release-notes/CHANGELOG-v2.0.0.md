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
- `ios-use status` now reports Mac Runtime resources, signing readiness, and
  session state even when no Mac App is running.
- Mac semantic swipes can reveal virtualized or initially off-screen targets
  from a visible anchor and now report a classified no-effect/boundary error
  instead of claiming success when content did not move.
- Frida debugging now documents stdin, streaming, JSON, reset, safe Swift
  symbol discovery, and partial-mutation recovery; invalid resolver queries
  and evaluation timeouts have distinct machine-readable errors.
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
- Real-device authentication is now owned by AltSign. Run
  `~/.ios-use/altsign-cli/altsign-cli list --apple-id '<Apple ID>'` once in a
  terminal, with password and two-factor input supplied on standard input, then
  run `ios-use config --udid <UDID>`. `ios-use config` no longer accepts Apple
  ID or password arguments and does not inspect AltSign login state. The
  installer pairs this release with AltSign CLI v0.2.0.
- `ios-use dom` now returns semantic DOM only. Capture named pixel/OCR evidence
  explicitly with `ios-use screenshot --name <evidence>`; use `--no-ocr` when
  OCR is not needed.

## Notes

- The Mac backend supports Apple-silicon Macs and iPhone App bundles.
- System permission prompts outside the App process remain under user or
  computer-use control; ios-use does not request macOS Accessibility access.
