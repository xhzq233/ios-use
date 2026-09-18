#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/message.h>
#import <math.h>
#import "IOSUsePlayDevice.h"

static inline BOOL IOSUsePlayCanvasIsResizable(void) {
    return strcmp(getenv("IOS_USE_MAC_WINDOW_MODE") ?: "fixed", "resizable") == 0;
}

// Screen identity stays fixed. Automation uses the current App scene viewport.
static inline CGSize IOSUsePlayCanvasSize(void) {
    Class bridge = NSClassFromString(@"IOSUsePlayAppKitBridge");
    SEL selector = NSSelectorFromString(@"automationCanvasSize");
    if (IOSUsePlayCanvasIsResizable() && [bridge respondsToSelector:selector]) {
        return ((CGSize (*)(id, SEL))objc_msgSend)(bridge, selector);
    }
    return CGSizeMake(IOSUsePlayDeviceLogicalWidth, IOSUsePlayDeviceLogicalHeight);
}
#define IOSUsePlayCanvasWidth (IOSUsePlayCanvasSize().width)
#define IOSUsePlayCanvasHeight (IOSUsePlayCanvasSize().height)
#define IOSUsePlayCanvasNativeWidth ((size_t)llround(IOSUsePlayCanvasWidth * IOSUsePlayDeviceScale))
#define IOSUsePlayCanvasNativeHeight ((size_t)llround(IOSUsePlayCanvasHeight * IOSUsePlayDeviceScale))
