#import "IOSUsePlayDeviceConfiguration.h"
#import "IOSUsePlayDevice.h"
#import "IOSUsePlayCanvas.h"
#import "IOSUsePlayDeviceChrome.h"
#import "IOSUsePlayAppKitBridge.h"
#import "IOSUsePlayRuntimeSocket.h"
#import <UIKit/UIKit.h>

NSDictionary *IOSUsePlayDeviceState(void) {
    NSString *variant = @(IOSUsePlayDeviceCurrent()->name);
    BOOL duo = [variant hasPrefix:@"iphone-duo"];
    return @{
        @"preset": duo ? @"iphone-duo" : variant,
        @"expanded": ([variant isEqual:@"iphone-duo-outer"] ? @NO : @YES),
        @"orientation": @(IOSUsePlayDeviceInterfaceName(IOSUsePlayDeviceQuarterTurns())),
        @"physicalOrientation": @(IOSUsePlayDevicePhysicalName(IOSUsePlayDevicePhysicalQuarterTurns())),
        @"safeAreaProfile": IOSUsePlayCanvasIsResizable() ? @"native-window" :
            (duo ? @"duo-preview" : (IOSUsePlayDeviceUserInterfaceIdiom == 1 ? @"ipados-26" : @"device-preset")),
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
        // Override the environment, not UITraitCollection getters: retained
        // previous collections must keep their old idiom after model changes.
        id<UITraitOverrides> traits = view.traitOverrides;
        // Reading an unset UITraitOverrides value raises an exception. Setters
        // already coalesce unchanged overrides; do not use it as a collection.
        traits.userInterfaceIdiom = (UIUserInterfaceIdiom)IOSUsePlayDeviceUserInterfaceIdiom;
        traits.displayScale = IOSUsePlayDeviceScale;
        // Native Catalyst width heuristics do not describe Duo's two displays.
        // Full-screen iPad and the inner display stay regular in both axes.
        if (!IOSUsePlayCanvasIsResizable() && (IOSUsePlayDeviceUserInterfaceIdiom == 1 || IOSUsePlayDeviceIsDuo())) {
            BOOL regular = IOSUsePlayDeviceUserInterfaceIdiom == 1 || IOSUsePlayDeviceIsDuoInner();
            UIUserInterfaceSizeClass horizontal = regular ? UIUserInterfaceSizeClassRegular : UIUserInterfaceSizeClassCompact;
            UIUserInterfaceSizeClass vertical = regular || !IOSUsePlayDeviceIsLandscape()
                ? UIUserInterfaceSizeClassRegular : UIUserInterfaceSizeClassCompact;
            traits.horizontalSizeClass = horizontal;
            traits.verticalSizeClass = vertical;
        } else {
            [traits removeTrait:UITraitHorizontalSizeClass.class];
            [traits removeTrait:UITraitVerticalSizeClass.class];
        }
    }
}

void IOSUsePlayRefreshDeviceTraits(UIWindow *window) {
    updateTraits(window);
    updateTraits(window.rootViewController.view);
}

static NSDictionary *invalidConfiguration(NSError **error) {
    if (error) *error = [NSError errorWithDomain:@"io.ios-use.device" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Invalid Mac device configuration"}];
    return nil;
}

static NSDictionary *applyDeviceConfiguration(NSDictionary *changes, NSError **error) {
    NSCParameterAssert(NSThread.isMainThread);
    NSMutableDictionary *selection = [IOSUsePlayDeviceState() mutableCopy];
    NSSet *keys = [NSSet setWithArray:@[@"preset", @"expanded", @"orientation", @"physicalOrientation", @"chrome", @"windowMode"]];
    for (NSString *key in changes) {
        if (![keys containsObject:key]) return invalidConfiguration(error);
        selection[key] = changes[key];
    }
    if (![selection[@"preset"] isKindOfClass:NSString.class] ||
        (![selection[@"preset"] isEqual:@"iphone-duo"] && !IOSUsePlayDevicePresetNamed([selection[@"preset"] UTF8String])) ||
        ![@[@"portrait", @"portrait-upside-down", @"landscape-left", @"landscape-right"] containsObject:selection[@"orientation"]] ||
        ![@[@"portrait", @"portrait-upside-down", @"landscape-left", @"landscape-right"] containsObject:selection[@"physicalOrientation"]] ||
        (changes[@"orientation"] && changes[@"physicalOrientation"]) ||
        ![@[@"on", @"off"] containsObject:selection[@"chrome"]] ||
        ![@[@"fixed", @"resizable"] containsObject:selection[@"windowMode"]] ||
        ![selection[@"expanded"] isKindOfClass:NSNumber.class]) return invalidConfiguration(error);
    if ([selection[@"preset"] hasPrefix:@"iphone-duo-"]) {
        selection[@"expanded"] = ([selection[@"preset"] isEqual:@"iphone-duo-outer"] ? @NO : @YES);
        selection[@"preset"] = @"iphone-duo";
    }
    if (changes[@"physicalOrientation"] && [selection[@"windowMode"] isEqual:@"resizable"]) {
        if (error) *error = [NSError errorWithDomain:@"io.ios-use.device" code:2 userInfo:@{NSLocalizedDescriptionKey:
            @"Rotate requires a fixed device canvas. Use config --mac --window-mode fixed first."}];
        return nil;
    }
    if (changes[@"physicalOrientation"] ||
        ((changes[@"preset"] || changes[@"expanded"]) && !changes[@"orientation"])) {
        int physicalTurns = IOSUsePlayDevicePhysicalQuarterTurns();
        if (changes[@"physicalOrientation"]) {
            for (int i = 0; i < 4; i++)
                if ([changes[@"physicalOrientation"] isEqual:@(IOSUsePlayDevicePhysicalName(i))]) physicalTurns = i;
        }
        BOOL inner = [selection[@"preset"] isEqual:@"iphone-duo"] && [selection[@"expanded"] boolValue];
        selection[@"orientation"] = @(IOSUsePlayDeviceInterfaceName((physicalTurns + (inner ? 1 : 0)) % 4));
    }
    setenv("IOS_USE_MAC_DEVICE", [selection[@"preset"] UTF8String], 1);
    setenv("IOS_USE_MAC_EXPANDED", [selection[@"expanded"] boolValue] ? "1" : "0", 1);
    setenv("IOS_USE_MAC_ORIENTATION", [selection[@"orientation"] UTF8String], 1);
    setenv("IOS_USE_MAC_CHROME", [selection[@"chrome"] UTF8String], 1);
    setenv("IOS_USE_MAC_WINDOW_MODE", [selection[@"windowMode"] UTF8String], 1);
    IOSUsePlayDeviceChromeReset();
    // Ask Catalyst for the native size transition. Trait/safe-area propagation
    // must wait for that geometry; even unforced overrides can flush too early.
    [IOSUsePlayAppKitBridge configureFixedWindow:NULL];
    return IOSUsePlayDeviceState();
}

@interface IOSUsePlayDeviceTransition : NSObject
@property(nonatomic, copy) void (^completion)(NSDictionary *, NSError *);
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic) NSTimeInterval deadline;
@property(nonatomic) int previousOrientation;
@property(nonatomic) BOOL traitsApplied;
- (void)check;
@end

static IOSUsePlayDeviceTransition *activeTransition;

BOOL IOSUsePlayDeviceConfigurationInProgress(void) {
    NSCParameterAssert(NSThread.isMainThread);
    return activeTransition != nil;
}

void IOSUsePlayDeviceGeometryWillLayout(UIWindow *window) {
    if (!activeTransition || activeTransition.traitsApplied || activeTransition.window != window) return;
    CGSize target = CGSizeMake(IOSUsePlayDeviceLogicalWidth, IOSUsePlayDeviceLogicalHeight);
    if (!IOSUsePlayCanvasIsResizable() && !CGSizeEqualToSize(window.bounds.size, target)) return;
    activeTransition.traitsApplied = YES;
    IOSUsePlayRefreshDeviceTraits(window);
}

@implementation IOSUsePlayDeviceTransition
- (void)finish:(NSError *)error {
    activeTransition = nil;
    [IOSUsePlayAppKitBridge finishDeviceConfiguration];
    IOSUsePlayDeviceChromeSetConfigurationPending(NO);
    IOSUsePlayRuntimePublishUIReadiness();
    self.completion(error ? nil : IOSUsePlayDeviceState(), error);
}

- (void)check {
    // UIKit clears the active coordinator after native completion callbacks.
    // Also inspect presented controllers, whose transition can outlive the root.
    BOOL transitioning = NO;
    for (UIViewController *vc = self.window.rootViewController; vc; vc = vc.presentedViewController) {
        transitioning |= vc.transitionCoordinator != nil;
    }
    BOOL ready = [IOSUsePlayAppKitBridge configureFixedWindow:NULL];
    if (ready && !transitioning) {
        // Geometry-only changes (including folding and replacing a model) keep
        // the physical pose. A device notification is not a resize callback.
        if (self.previousOrientation != IOSUsePlayDevicePhysicalOrientation()) {
            self.previousOrientation = IOSUsePlayDevicePhysicalOrientation();
            [NSNotificationCenter.defaultCenter postNotificationName:UIDeviceOrientationDidChangeNotification object:UIDevice.currentDevice];
            // Let notification-driven App layout run before reporting done.
            dispatch_async(dispatch_get_main_queue(), ^{ [self check]; });
            return;
        }
        BOOL uiReady = IOSUsePlayRuntimePublishUIReadiness();
        if (uiReady) {
            [self finish:nil];
            return;
        }
    }
    if (NSProcessInfo.processInfo.systemUptime >= self.deadline) {
        [self finish:[NSError errorWithDomain:@"io.ios-use.device" code:4 userInfo:@{NSLocalizedDescriptionKey:
            @"Device selection changed, but the App's native size transition has not completed"}]];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self check]; });
}
@end

void IOSUsePlayConfigureDevice(NSDictionary *changes, void (^completion)(NSDictionary *, NSError *)) {
    NSCParameterAssert(NSThread.isMainThread);
    if (activeTransition) {
        completion(nil, [NSError errorWithDomain:@"io.ios-use.device" code:3 userInfo:@{NSLocalizedDescriptionKey:
            @"A Mac device transition is still in progress; retry after it completes"}]);
        return;
    }
    IOSUsePlayDeviceTransition *transition = [IOSUsePlayDeviceTransition new];
    transition.completion = completion;
    transition.previousOrientation = IOSUsePlayDevicePhysicalOrientation();
    transition.window = [IOSUsePlayAppKitBridge prepareDeviceConfiguration];
    transition.deadline = NSProcessInfo.processInfo.systemUptime + 5;
    activeTransition = transition;
    IOSUsePlayDeviceChromeSetConfigurationPending(YES);
    NSError *error = nil;
    if (!applyDeviceConfiguration(changes, &error)) {
        [transition finish:error];
        return;
    }
    IOSUsePlayRuntimePublishUIReadiness();
    dispatch_async(dispatch_get_main_queue(), ^{ [transition check]; });
}
