# PlayCover acceptance fixture

`IOSUsePlayFixture` is the cross-stack UI and compositor fixture for the
PlayCover backend. It deliberately combines:

- UIKit controls, a native modal alert, an in-window UIKit popup, text input,
  and four safe-area edge probes;
- SwiftUI controls and text input;
- a `WKWebView` with accessible controls;
- an animated `MTKView` underneath a UIKit overlay;
- a bottom `UITabBarController` whose items exercise the home-indicator region;
- the `iosusefixture://` URL scheme with an accessible
  `fixture.url.status` postcondition.

Build the iPhoneOS source App consumed by PlayCover:

```bash
./playcover-fixtures/build.sh
```

Build a Simulator oracle without sharing generated state with ios-use:

```bash
./playcover-fixtures/build.sh --sdk iphonesimulator
```

`Release` is the default configuration. Pass
`--configuration Debug` when a debug-dylib/nested-code fixture is required.
Generated projects and build products stay untracked under this directory.

The native `UIAlertController` and the custom popup are separate gates.
On Catalyst the alert intentionally exercises the native AppKit panel. The
popup is instead added directly to the fixture `UIWindow`, bounded by its
top and bottom safe area, and exposes stable identifier/label pairs:
`fixture.uikit.popup.open` / `Open UIKit Popup`,
`fixture.uikit.popup` / `UIKit In-Window Popup`,
`fixture.uikit.popup.confirm` / `Confirm and Close`, and
`fixture.uikit.popup.result` / `UIKit Popup Result`. Confirming it removes
the visible dimmed/card surface and advances the result's accessibility
value to `confirmed N`.

Run the hermetic popup source contract with:

```bash
bash playcover-fixtures/test_uikit_popup_contract.sh
```

A freshly active fixture session can additionally prove that Runtime touch
and a real global AppKit mouse event activate the same confirmation button:

```bash
IOS_USE_HOME=/path/to/isolated-fixture-home \
  bash playcover-fixtures/test_uikit_popup_contract.sh --live
```

Live mode consumes the active session without starting or stopping it. It
requires Accessibility/PostEvent permission for the invoking terminal and
uses the popup button's fresh DOM frame plus the exact AppKit window bounds
to derive the global mouse point. Set `IOS_USE_POPUP_EVIDENCE_DIR` to a new
path when the JSON responses and mouse-event record must be retained instead
of using an automatically removed temporary directory.

On an iPhone 15 Pro Max (`iPhone16,2`) the fixture writes
`Documents/geometry.json` and exposes the same value as
`fixture.uikit.geometry`. The required portrait oracle is:

```text
logical 430x932 scale 3 native 1290x2796 safe 59,0,34,0
```

The fixture pins light appearance so the reference surfaces and status glyph
contrast do not change with the macOS automatic day/night appearance.

The empty `UILaunchScreen` declaration is intentional. Removing it puts a
freshly built App into the legacy 320x480 compatibility mode and must be
rejected by the PlayCover Runtime rather than hidden by screenshot resizing.

This fixture is only one part of the unified backend gate. A passing mock DOM
or UIKit-only image is insufficient: the final PlayCover path must also prove
real touch/input, Metal plus UIKit composition, system chrome, signing,
session identity, and the configured external-App live workflow.

`runtime_socket_probe.swift` is intentionally a bounded negative-test client,
not an automation API. The unified live gate uses it only against a fixture
session in a freshly created `IOS_USE_HOME` to prove exact protocol errors for
oversized, malformed-JSON, and invalid-UTF-8 frames while the Runtime listener
remains healthy. The same isolated stress gate also proves Runtime-endpoint
loss and App-crash cleanup without exposing a production kill or unlink
command.
