Device chrome resources packaged in IOSUsePlayRuntime.framework.

The phone, phone4, phone9, phone10, and tablet2 directories contain Apple
DeviceKit PDF artwork and chrome.json layouts, with framebuffer masks from the
matching CoreSimulator device profiles. Apple artwork remains copyright Apple
Inc.; it is not covered by the source-code license of ios-use. The Runtime reads
these bundled files and does not require a local Xcode/DeviceKit installation.

The duo-*.png files are original ios-use preview artwork. Duo screen and bezel
geometry are visual estimates; they do not implement system fold behavior.
