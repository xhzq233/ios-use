# ios-use v1.3.3

## Highlights

- Semantic tap, long press, input focus, and swipe gestures now use one bounded
  interaction frame. A valid XCTest `visibleFrame` is clipped to the foreground
  App frame before pointer coordinates are calculated.
- When XCTest does not provide a usable `visibleFrame`, ios-use falls back to the
  raw frame only for a visible element without an effectively invisible ancestor.
  This preserves controls such as Toolbar buttons while rejecting offscreen
  descendants such as the `配置代理` row before it is scrolled into view.
- Scroll-container selection and gesture geometry now use the same interaction
  frame. Oversized or negative-origin horizontal collections no longer place the
  drag start beneath an adjacent overlay merely because their raw layout frame
  extends beyond the visible App area.
- Failed semantic lookups can classify candidates blocked by an invisible ancestor
  as `ancestor_invisible`, making offscreen and non-actionable targets easier to
  distinguish.

## Notes

- DOM and response evidence continue to report raw layout frames. The bounded
  interaction frame is used only for element filtering and pointer actions.
- This release changes the Driver implementation and version. Re-run
  `ios-use config --udid <UDID>` after upgrading so the CLI and Driver remain
  aligned.
