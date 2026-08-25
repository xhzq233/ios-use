# ios-use v2.0.4

## Highlights

- Mac Apps now render through UIKitMacHelper's original Catalyst content view.
  The Runtime no longer wraps it in a resizable display-scale canvas or forces
  the UIKitMacHelper scene scale to 1x, improving Retina rendering for images,
  rounded corners, and other curved edges.
- Mac pointer hover is disabled by default. Mouse movement, enter, exit, and
  cursor-update events are filtered before they reach the target App, while
  ordinary mouse clicks and ios-use automation remain available.
- Set `IOS_USE_PLAY_ENABLE_3X_BACKING=1` on `ios-use start --mac` to request a
  3x scene backing for that launch. When omitted, Catalyst chooses the native
  Retina backing.
- The iPhone 15 Pro Max model remains fixed at 430 x 932 logical points, and
  screenshots remain full-frame 1290 x 2796 images.
- Real-device and Simulator behavior is unchanged.

## Breaking Behavior

- The Mac host window is no longer resizable. Arbitrary host-window scaling and
  the associated outer canvas transform have been removed.
- A Mac App slot prepared by v2.0.3 still embeds the v2.0.3 Runtime. After
  upgrading, run one explicit `start --mac --app <source.app>` for each App you
  want to use so the slot is rebuilt with the v2.0.4 Runtime.

## Upgrade Notice

```bash
ios-use stop
curl -fsSL https://raw.githubusercontent.com/xhzq233/ios-use/main/scripts/install.sh | bash -s -- --version v2.0.4
ios-use start --mac --app /path/to/Your.app
```

## Notes

- Omit `IOS_USE_PLAY_ENABLE_3X_BACKING` for the default Catalyst-managed scene
  backing. Only the exact value `1` enables the 3x request.
- DOM, input, screenshots, and automation coordinates continue to use the fixed
  iPhone logical model regardless of the Mac display backing.
