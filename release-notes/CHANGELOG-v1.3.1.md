# ios-use v1.3.1

## Highlights

- Added resilient `waitFor` matching with positional targets, `contains`, `exact`,
  and `regex` modes, plus `--gone` and explicit `s`/`ms` durations.
- Added `dom --ocr` for one fresh Accessibility tree accompanied by a screenshot
  and accurate OCR evidence.
- Improved failed-mutation diagnostics with one evidence manifest referencing a
  screenshot, fast OCR, and fresh DOM when available.
- Hardened real-device App termination and lifecycle reporting, including process
  matching and already-not-running behavior.
- Parse failures now include the relevant command help, making malformed invocations
  self-diagnosing.

## Notes

- Short capture output remains JPEG frames plus `manifest.json`, with a maximum of
  10 FPS.
- CLI and Driver versions must match. Re-run `ios-use config --udid <UDID>` after
  upgrading when `ios-use status` reports an older Driver.
