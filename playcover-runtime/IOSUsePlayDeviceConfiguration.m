#import "IOSUsePlayDeviceConfiguration.h"
#import "IOSUsePlayDevice.h"
#import "IOSUsePlayCanvas.h"
#import "IOSUsePlayDeviceChrome.h"
#import "IOSUsePlayAppKitBridge.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>

NSDictionary *IOSUsePlayDeviceState(void) {
    NSString *variant = @(IOSUsePlayDeviceCurrent()->name);
    BOOL duo = [variant hasPrefix:@"iphone-duo"];
    return @{
        @"preset": duo ? @"iphone-duo" : variant,
        @"expanded": ([variant isEqual:@"iphone-duo-outer"] ? @NO : @YES),
        @"orientation": IOSUsePlayDeviceIsLandscape() ? @"landscape-right" : @"portrait",
        @"chrome": @(getenv("IOS_USE_MAC_CHROME") ?: "on"),
        @"windowMode": IOSUsePlayCanvasIsResizable() ? @"resizable" : @"fixed",
        @"logicalWidth": @(IOSUsePlayDeviceLogicalWidth),
        @"logicalHeight": @(IOSUsePlayDeviceLogicalHeight),
        @"scale": @(IOSUsePlayDeviceScale),
        @"idiom": @(IOSUsePlayDeviceUserInterfaceIdiom),
    };
}

static void updateTraits(UIView *view) {
    if (@available(iOS 17.0, *)) {
        view.traitOverrides.userInterfaceIdiom = (UIUserInterfaceIdiom)IOSUsePlayDeviceUserInterfaceIdiom;
        view.traitOverrides.displayScale = IOSUsePlayDeviceScale;
    }
    [view setNeedsLayout];
}

static NSDictionary *invalidConfiguration(NSError **error) {
    if (error) *error = [NSError errorWithDomain:@"io.ios-use.device" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Invalid Mac device configuration"}];
    return nil;
}

NSDictionary *IOSUsePlayConfigureDevice(NSDictionary *changes, NSError **error) {
    NSCParameterAssert(NSThread.isMainThread);
    NSMutableDictionary *selection = [IOSUsePlayDeviceState() mutableCopy];
    NSSet *keys = [NSSet setWithArray:@[@"preset", @"expanded", @"orientation", @"chrome", @"windowMode"]];
    for (NSString *key in changes) {
        if (![keys containsObject:key]) return invalidConfiguration(error);
        selection[key] = changes[key];
    }
    if (![selection[@"preset"] isKindOfClass:NSString.class] ||
        (![selection[@"preset"] isEqual:@"iphone-duo"] && !IOSUsePlayDevicePresetNamed([selection[@"preset"] UTF8String])) ||
        ![@[@"portrait", @"landscape-right"] containsObject:selection[@"orientation"]] ||
        ![@[@"on", @"off"] containsObject:selection[@"chrome"]] ||
        ![@[@"fixed", @"resizable"] containsObject:selection[@"windowMode"]] ||
        ![selection[@"expanded"] isKindOfClass:NSNumber.class]) return invalidConfiguration(error);
    if ([selection[@"preset"] hasPrefix:@"iphone-duo-"]) {
        selection[@"expanded"] = ([selection[@"preset"] isEqual:@"iphone-duo-outer"] ? @NO : @YES);
        selection[@"preset"] = @"iphone-duo";
    }
    [IOSUsePlayAppKitBridge prepareDeviceConfiguration];
    setenv("IOS_USE_MAC_DEVICE", [selection[@"preset"] UTF8String], 1);
    setenv("IOS_USE_MAC_EXPANDED", [selection[@"expanded"] boolValue] ? "1" : "0", 1);
    setenv("IOS_USE_MAC_ORIENTATION", [selection[@"orientation"] UTF8String], 1);
    setenv("IOS_USE_MAC_CHROME", [selection[@"chrome"] UTF8String], 1);
    setenv("IOS_USE_MAC_WINDOW_MODE", [selection[@"windowMode"] UTF8String], 1);
    IOSUsePlayDeviceChromeReset();
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            updateTraits(window);
            updateTraits(window.rootViewController.view);
            SEL invalidate = NSSelectorFromString(@"_sceneSettingsSafeAreaInsetsDidChange");
            if ([window respondsToSelector:invalidate]) ((void (*)(id, SEL))objc_msgSend)(window, invalidate);
        }
    }
    [IOSUsePlayAppKitBridge configureFixedWindow:NULL];
    [NSNotificationCenter.defaultCenter postNotificationName:UIDeviceOrientationDidChangeNotification object:UIDevice.currentDevice];
    return IOSUsePlayDeviceState();
}
