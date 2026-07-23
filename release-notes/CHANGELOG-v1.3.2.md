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
- Semantic label swipes now use a 60-second Driver watchdog and a matching
  62-second host read deadline, allowing multi-gesture searches to finish without
  the generic 10-second command timeout. Coordinate and fixed-distance swipes keep
  the shorter deadline.
- Root, `tap`, and `swipe` help now restore the DOM-label-first workflow after
  context compaction and show how to compose stable UI routes with ordinary shell.
  The installed operational playbook carries the same concise recovery guidance.

## Notes

- Default `activateApp` readiness requires a matching active Driver. Start it first,
  or use `--no-wait` when only host launch acknowledgement is needed.
- Loading and animation frames are valid readiness results. Compose `waitFor` for a
  business-screen condition.
- `open --dom` waits for a verified real-device URL handler. If handler lookup is
  unavailable, it reports that dispatch may have applied instead of returning an
  unrelated foreground DOM.
- Activation readiness can return a SpringBoard-owned first-launch alert or sheet
  only while the requested App itself remains foreground; an actual App switch keeps polling.
- CLI and Driver versions must match. Re-run `ios-use config --udid <UDID>` after
  upgrading.
