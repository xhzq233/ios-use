# ios-use v1.3.4

## Highlights

- Added `ios-use media import <photo-or-video>` for adding one local image or
  video to the connected device Photos library through the active Driver. The
  command preserves the source filename and explicit media type and supports
  the common machine-readable `--json` envelope.
- The first Media Import requests Photos add-only authorization only when its
  current state is not determined. It rejects a pre-existing system alert and
  accepts only the newly triggered, Runner-owned, two-button permission prompt;
  already allowed, denied, and restricted states do not inspect or dismiss UI.
- `dismissAlert` now requires an explicit or unambiguous button selection. Use
  `--label`, `--index`, `--only-button`, or the explicitly heuristic
  `--primary`, together with optional `--scope springboard|app|any` and a
  bounded `--wait`.
- Alert selection no longer treats XCTest query order as visual order. The
  Driver snapshots candidate geometry, uses layout-direction-aware visual
  selection only when requested, and revalidates the alert generation before
  tapping.
- Alert failures now return classified errors and bounded button candidates in
  human, JSON, and failure-manifest output. A one-shot miss is
  `alert_not_found`; an expired positive wait is `alert_wait_timed_out`.
- Proxy CA setup now marks its one-button SpringBoard confirmation explicitly
  with `--only-button`. The preceding two-button Safari download confirmation
  remains a semantic label action.

## Breaking Behavior

- Bare `dismissAlert` now means “require exactly one hittable button.” It no
  longer silently taps the final XCTest query result when several buttons are
  present.
- No-alert and timed-out alert checks now fail with classified errors instead
  of returning a successful “not dismissed” payload.

## Notes

- Visual-primary selection is a reported geometry heuristic, not an OS-provided
  allow/default semantic role. Prefer an exact label or query index when the
  caller knows the intended action.
- Media Import's automatic permission handling contains no localized Photos or
  Allow-button matching table.
- This release changes the CLI/Driver protocol. Re-run
  `ios-use config --udid <UDID>` after upgrading so the installed Driver matches
  the 1.3.4 CLI.
