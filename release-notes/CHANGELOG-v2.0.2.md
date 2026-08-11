# ios-use v2.0.2

## Highlights

- Mac starts now reuse an unchanged source App automatically. Pass `--app`
  after a rebuild, or omit it to launch the current App for this Home.
- Mac App slots now use the stable ASCII path `App.app`, independent of the
  App's localized display name.
- Mac URL opening now uses the system lifecycle for the active App, including
  normal App Delegate or Scene Delegate delivery and window activation.
- UI command failures report actionable targets, candidates, rejection
  reasons, suggestions, and alert details directly instead of writing an
  automatic failure evidence bundle.
- The default Mac readiness timeout is 60 seconds; an explicit positive
  `--timeout` may be longer.
- Hosted CI now routes Swift, Driver, Mac Runtime, and script checks only when
  their relevant inputs change.

## Breaking Behavior

- Removed `start --mac --reuse`. Use `start --mac` for the current slot or
  `start --mac --app <source.app>` for automatic source-aware reuse/update.
- Mac slots created by 2.0.1 are not migrated. Run one explicit
  `start --mac --app <source.app>` to rebuild each slot as `App.app`.
- JSON failures no longer contain `evidenceManifest`, and UI failures no
  longer create `*-failure-*` artifact directories.

## Notes

- Existing explicit `dom`, `screenshot`, and `capture` commands are unchanged.
- Device and Simulator URL opening behavior is unchanged.
