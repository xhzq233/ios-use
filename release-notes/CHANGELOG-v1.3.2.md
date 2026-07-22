# ios-use v1.3.2

## Highlights

- `activateApp` now returns after the requested App reaches the foreground and one
  fresh Accessibility snapshot succeeds. Use `--no-wait` for the explicit host-only
  launch path.
- Added `activateApp --dom` and `open --dom`. Both reuse the snapshot produced by a
  shared backend-neutral Driver readiness command instead of issuing a second DOM
  request.
- Transient startup snapshot misses are retried by `waitFor`; post-mutation `--dom`
  retries only structured, retryable snapshot failures on the same connection.
- Added a common versioned `--json` envelope for status, App install/list/lifecycle,
  DOM, screenshots, waits, and UI actions. Failed mutations keep structured Driver
  classification and return one evidence-manifest path without dumping duplicate
  evidence into the terminal.
- App install success now reports a typed, device-verified receipt containing bundle
  ID, version, build, installer route, package kind, source path, and elapsed time,
  reusing the existing verification lookup.
- `tap 67 269` is accepted as a coordinate fallback alongside `tap 67,269`; semantic
  label/value targeting remains the preferred interface.

## Notes

- Default `activateApp` readiness requires a matching active Driver. Start it first,
  or use `--no-wait` when only host launch acknowledgement is needed.
- Loading and animation frames are valid readiness results. Compose `waitFor` for a
  business-screen condition.
- `open --dom` waits for a verified real-device URL handler. If handler lookup is
  unavailable, it reports that dispatch may have applied instead of returning an
  unrelated foreground DOM.
- CLI and Driver versions must match. Re-run `ios-use config --udid <UDID>` after
  upgrading.
