Device chrome resources packaged in IOSUsePlayRuntime.framework.

The phone, phone4, phone9, phone10, and tablet2 directories contain Apple
DeviceKit PDF artwork and chrome.json layouts, with framebuffer masks from the
matching CoreSimulator device profiles. Apple artwork remains copyright Apple
Inc.; it is not covered by the source-code license of ios-use. The Runtime reads
these bundled files and does not require a local Xcode/DeviceKit installation.

The duo-inner-* and duo-outer-* PNGs are original ios-use preview artwork. Duo screen and bezel
geometry are visual estimates; they do not implement system fold behavior.

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
