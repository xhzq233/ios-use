# ios-use v2.1.1

- Compact semantic DOM output, with diff enabled by default for `dom`, `-D` and
  `--dom`. Use `--nodiff` for a full observation and `--json` for structured
  details, including element geometry. Driver observations retain diff history;
  UI actions and full observations capture fresh trees instead of reusing the
  old cross-command snapshot cache.
- Separate direct drags from scroll-to-label searches:
  `swipe --from <label|x,y> --to <label|x,y>` drags between visible endpoints;
  `swipe --from <label|x,y> --find <label>` searches the anchor's scroll container.
  Fix container selection, nested scroll axes and gestures outside the viewport.
  Already-visible search targets return without scrolling.
- `activateApp <bundleId>` now confirms foreground without taking a snapshot.
  Add `-D` to observe the resulting page. Remove `--no-wait` and the duplicate
  snapshot before post-action DOM capture; startup stdout/stderr logging remains
  available. Same-device tests measured mean activation time of 517 → 249 ms.
- Bound XCTest idle waits and prevent input after a command deadline. Resolve
  semantic touch targets after idle waiting so coordinates are fresh at injection.
- Fix Mac scene resize/rotation ordering and preserve previously captured trait
  collections. Serialize overlapping device transitions and refresh safe areas
  with the new window geometry. Cross-model switching remains a layout preview;
  Apps may require a cold start after changing device identity.
- Refresh the user-facing Skill and publish separate USB/Mac benchmark results.

## Upgrade

Update CLI, Driver and Mac Runtime together. Reconfigure real-device Drivers
with `ios-use config --udid <device-udid>` before starting the new CLI.
Migrate scroll-to-label scripts from `--to` to `--find`, keeping a visible
`--from` anchor. Use `--nodiff` if a consumer requires every observation in full.

Foreground confirmation and native idle do not guarantee stable layout.
Cold-launch list reordering can still cause semantic taps to hit the wrong row;
this remains tracked in [#29](https://github.com/xhzq233/ios-use/issues/29).

```bash
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/v2.1.1/scripts/install.sh | bash -s -- --version v2.1.1
```
