Device chrome resources packaged in IOSUsePlayRuntime.framework.

The phone, phone4, phone9, phone10, phone14, phone15, and tablet2 directories contain Apple
DeviceKit PDF artwork and chrome.json layouts, with framebuffer masks from the
matching CoreSimulator device profiles. Apple artwork remains copyright Apple
Inc.; it is not covered by the source-code license of ios-use. The Runtime reads
these bundled files and does not require a local Xcode/DeviceKit installation.

Duo uses Xcode 27.1 (27A9275) DeviceKit phone14 (inner) and phone15
(outer) PDF artwork and chrome.json, replacing the original preview PNGs.
The matching iPhone Duo.simdevicetype provides the two framebuffer masks,
iPhone19,4 / A3447 identity, 3x scale, and per-corner radii (inner 55pt;
outer left 8pt/right 59pt). Source resources are in the installed
/Library/Developer/DeviceKit/Chrome and CoreSimulator/Profiles/DeviceTypes
directories. Screen dimensions are 669x951 and 466x678 logical points.
These resources do not implement system fold behavior. The status items below
remain drawn previews, separate from the official device shell. DeviceKit
does not bundle the compositor camera overlay with the shell; the existing
34pt outer-camera cutout is retained as a vector, without the old PNG.

duo-status-black.pdf and duo-status-white.pdf contain the original eight filled
Bezier paths in the Ring group of Apple's iOS 27 UI Kit (copyright Apple Inc.,
not the ios-use source license):
https://www.sketch.com/s/04c24d8b-38fb-4afb-8836-36617e022f02
https://developer.apple.com/design/resources/

Source symbols: Status Bars/iPhone Duo/{Light,Dark} Background/Vertical.
The paths retain the original point/control-point coordinates, layer transforms
and 46x46pt bounds. They have no embedded bitmap or video compression artifacts.
The Runtime rasterizes them at the native window's current backing size.

The full status component is 48x86pt: Ring is at (1,35), and Time is at (0,11)
with SF Pro Rounded Bold 16. The Tab Bar example anchors the component at
(width-72,72) on the portrait outer display and (width-72,24) on the landscape
inner display, within an 84pt side inset. This keeps the center 48pt from the
outer edge. The Toolbar inner-display example uses y=27 instead; these are
design examples, not a claim that all native App layouts have identical spacing.
