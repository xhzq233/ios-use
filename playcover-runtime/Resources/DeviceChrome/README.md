Device chrome resources packaged in IOSUsePlayRuntime.framework.

The phone, phone4, phone9, phone10, and tablet2 directories contain Apple
DeviceKit PDF artwork and chrome.json layouts, with framebuffer masks from the
matching CoreSimulator device profiles. Apple artwork remains copyright Apple
Inc.; it is not covered by the source-code license of ios-use. The Runtime reads
these bundled files and does not require a local Xcode/DeviceKit installation.

The duo-inner-* and duo-outer-* PNGs are original ios-use preview artwork. Duo screen and bezel
geometry are visual estimates; they do not implement system fold behavior.

duo-status-black.png and duo-status-white.png are raster extracts from Apple's
"Design for iPhone Duo" video (copyright Apple Inc., not the ios-use source license):
https://developer.apple.com/videos/play/tech-talks/111466/

The 1920x1080 HD video frames at 6:57 (black) and 7:12 (white) are cropped at
x=1150, y=268, width=56, height=56, without scaling, sharpening or redrawing.
All crop pixels are monochrome. The black asset uses alpha=255-sourceGray;
the white asset uses alpha=sourceGray. Compositing each over its original white
or black background reproduces every source pixel exactly, including video
compression artifacts. Other background colors and display scaling necessarily
change the output pixels. These low-resolution video extracts are not native
Duo runtime assets and do not establish pixel parity with a physical device.
