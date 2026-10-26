# Mac Duo device profile

The Mac `iphone-duo` preset uses the DeviceKit/CoreSimulator profile installed
with Xcode 27.1 (27A9275), replacing the earlier screenshot-canvas estimates and
preview PNG shell. It keeps the existing CLI model names and fold/rotate controls.

| Property | Inner display | Outer display |
| --- | --- | --- |
| DeviceKit chrome | phone14 | phone15 |
| Portrait logical size | 669 × 951 | 466 × 678 |
| Native size | 2007 × 2853 | 1398 × 2034 |
| Scale | 3 | 3 |
| Corner radii | 55pt | left 8pt, right 59pt |

Both profiles report `iPhone19,4` / `A3447`. Artwork, button positions and frame
padding come from the original PDFs and `chrome.json`. Screen cutouts use the
matching Simulator framebuffer masks. Assets are bundled, so users do not need
a local Xcode installation for Mac decoration. See the resource README for
provenance and the retained camera/status-overlay limitations.

## Layout calibration

Measured with the public UIKit fixture on the iOS 27.1 Duo Simulator, reading
`UIWindow.safeAreaInsets`, interface orientation and window size classes from
the App's `Documents/geometry.json`. Device Hub controls physical posture and
rotation; screen orientation changes when the hinge opens without rotating the
device. CLI `rotate --to` likewise names physical orientation.

| Display / UIKit interface orientation | Insets: top, left, bottom, right |
| --- | --- |
| Inner portrait and portrait upside down (1 / 2) | 82, 0, 34, 0 |
| Inner landscape, both orientations (3 / 4) | 0, 0, 34, 84 |
| Outer portrait (1) | 0, 0, 34, 84 |
| Outer landscape left (3) | 0, 84, 34, 0 |
| Outer landscape right (4) | 0, 0, 34, 84 |

Inner size classes are regular/regular. Outer portrait is compact/regular;
outer landscape is compact/compact. The old preset omitted the 34pt bottom
inset, used 32pt instead of 82pt for inner portrait top, and inferred side-band
placement from artwork rotation. The Duo shell now rotates opposite to the
UIKit interface coordinate transform, keeping the camera and side band on the
same side in landscape. Outer upside-down behavior is not calibrated:
the tested Simulator App does not accept that interface orientation.

For repeatable acceptance, build the public fixture for Simulator and iPhoneOS,
run the two variants in isolated test state, and compare their App-owned geometry
for each supported pose. On Mac, also verify a DOM-coordinate tab tap changes the
actual selected page, a semantic tab tap returns, and screenshots have the
expected logical dimensions at 3x. Include a live toolbar fold/unfold round trip
without restarting the App, and inspect the shell corners at desktop scale.

This is a calibrated Mac layout preview. It uses the host's Catalyst/UIKit
implementation; native iOS status bars, system fold lifecycle and arbitrary
third-party App compatibility are outside this profile. In particular, matching
safe areas does not establish matching statusBarManager frames: the Simulator
and the Mac's decorative status layer report different geometry. Older macOS
hosts have not been revalidated for this update.
