#import <Foundation/Foundation.h>

// Main-thread only. The caller must close the returned temporary NSWindow.
// It hosts the existing App scene without the desktop window's display mask.
id _Nullable IOSUsePlayCreateCanvasCaptureWindow(id _Nonnull sourceWindow);
