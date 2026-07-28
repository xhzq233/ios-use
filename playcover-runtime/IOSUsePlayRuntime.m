//
// IOSUsePlayRuntime
//
// Headless automation Runtime built from the pinned PlayTools implementation.
// Runtime identity is intentionally limited to two launch-environment values;
// device geometry is a compile-time contract in IOSUsePlayDevice.h.
//

#import "IOSUsePlayRuntime.h"
#import "IOSUsePlayAppKitBridge.h"
#import "IOSUsePlayRuntimeSocket.h"
#import "IOSUsePlayDevice.h"

#import <UIKit/UIKit.h>

static NSUInteger IOSUseRuntimeConfigurationAttempt;
static BOOL IOSUseRuntimeSurfaceProbePending;
static NSString *IOSUseRuntimeConfigurationStage = @"loaded";
static NSString *IOSUseRuntimeConfigurationFailure;

static void IOSUseConfigureRuntimeSurface(void);

static NSDictionary<NSString *, id> *IOSUseRuntimeFullFrameEvidence(void) {
    return @{
        @"logicalRect": @{
            @"x": @0,
            @"y": @0,
            @"width": @(IOSUsePlayDeviceLogicalWidth),
            @"height": @(IOSUsePlayDeviceLogicalHeight),
        },
        @"pixelWidth": @(IOSUsePlayDeviceNativeWidth),
        @"pixelHeight": @(IOSUsePlayDeviceNativeHeight),
        @"scale": @(IOSUsePlayDeviceScale),
        @"uncropped": @YES,
        @"safeAreaCropped": @NO,
        @"identityMapping": @YES,
    };
}

static void IOSUseScheduleRuntimeSurfaceProbe(NSTimeInterval delay) {
    NSCAssert(NSThread.isMainThread, @"surface scheduling is main-only");
    if (IOSUseRuntimeSurfaceProbePending) {
        return;
    }
    IOSUseRuntimeSurfaceProbePending = YES;
    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)(delay * NSEC_PER_SEC)
        ),
        dispatch_get_main_queue(),
        ^{
            IOSUseRuntimeSurfaceProbePending = NO;
            IOSUseConfigureRuntimeSurface();
        }
    );
}

static void IOSUseConfigureRuntimeSurface(void) {
    NSCAssert(NSThread.isMainThread, @"surface configuration is main-only");
    IOSUseRuntimeConfigurationAttempt += 1;
    NSError *error = nil;
    BOOL windowReady =
        [IOSUsePlayAppKitBridge configureFixedWindow:&error];
    if (windowReady) {
        IOSUseRuntimeConfigurationStage = @"window-configured";
        IOSUseRuntimeConfigurationFailure = nil;
        return;
    }
    IOSUseRuntimeConfigurationStage = @"waiting-for-window";
    if (error.code == 12) {
        IOSUseRuntimeConfigurationStage = @"waiting-for-safe-area";
    } else if (error.code == 13) {
        IOSUseRuntimeConfigurationStage = @"safe-area-failed";
    }
    IOSUseRuntimeConfigurationFailure =
        error.localizedDescription ?:
        @"fixed iPhone surface is not ready";
    // Keep reconciling scene/window replacement, but do not pretend readiness.
    NSTimeInterval delay =
        IOSUseRuntimeConfigurationAttempt < 240 ? 0.25 : 1.0;
    IOSUseScheduleRuntimeSurfaceProbe(delay);
}

NSDictionary<NSString *, id> *IOSUsePlayRuntimeHookDiagnostics(
    IOSUsePlayRuntimeDiagnosticsScope scope
) {
    BOOL includeFullDiagnostics =
        scope == IOSUsePlayRuntimeDiagnosticsScopeFull;
    NSDictionary<NSString *, id> *window = includeFullDiagnostics
        ? [IOSUsePlayAppKitBridge diagnostics]
        : [IOSUsePlayAppKitBridge readinessDiagnostics];
    NSMutableDictionary<NSString *, id> *diagnostics =
        [@{
            @"configurationStage": IOSUseRuntimeConfigurationStage,
            @"configurationFailure":
                IOSUseRuntimeConfigurationFailure ?: NSNull.null,
            @"window": window,
        } mutableCopy];
    if (!includeFullDiagnostics) {
        return diagnostics;
    }
    NSDictionary<NSString *, id> *safeAreaCompatibility =
        window[@"safeAreaCompatibility"];
    BOOL safeAreaOverride = [
        safeAreaCompatibility[@"safeAreaCompatibilityReady"]
        boolValue
    ] && [
        safeAreaCompatibility[@"safeAreaReady"]
        boolValue
    ];
    [diagnostics addEntriesFromDictionary:@{
        @"implementation": @"pinned-playtools",
        @"playToolsCommit":
            @"d688f695e83bf080be9ad4b7346e914c7c343d96",
        @"configurationAttempts": @(IOSUseRuntimeConfigurationAttempt),
        @"device": @{
            @"productType":
                [NSString stringWithUTF8String:
                    IOSUsePlayDeviceProductType()],
            @"hardwareTarget":
                [NSString stringWithUTF8String:
                    IOSUsePlayDeviceHardwareTarget()],
            @"logical": @{
                @"width": @(IOSUsePlayDeviceLogicalWidth),
                @"height": @(IOSUsePlayDeviceLogicalHeight),
            },
            @"native": @{
                @"width": @(IOSUsePlayDeviceNativeWidth),
                @"height": @(IOSUsePlayDeviceNativeHeight),
            },
            @"scale": @(IOSUsePlayDeviceScale),
        },
        @"rendering": @{
            @"syntheticChrome": @NO,
            @"safeAreaOverride": @(safeAreaOverride),
            @"fullFrame": IOSUseRuntimeFullFrameEvidence(),
        },
    }];
    return diagnostics;
}

void IOSUsePlayRuntimeInitializeAfterStdio(void) {
    @autoreleasepool {
        // UIKitMacHelper chooses its 0.77 iOS-on-Mac compatibility scale
        // before the first scene exists. Install the fixed identity scale
        // before UIApplicationMain creates UINSSceneViewController.
        [IOSUsePlayAppKitBridge installFixedSceneScale:NULL];
        IOSUsePlayRuntimeStartSocket();
        NSNotificationCenter *center =
            NSNotificationCenter.defaultCenter;
        for (NSString *name in @[
            UIApplicationDidBecomeActiveNotification,
            UIWindowDidBecomeKeyNotification,
            UISceneWillEnterForegroundNotification,
            UISceneDidActivateNotification,
            UISceneDidDisconnectNotification,
        ]) {
            [center addObserverForName:name
                               object:nil
                                queue:NSOperationQueue.mainQueue
                           usingBlock:^(
                               __unused NSNotification *notification
                           ) {
                IOSUseConfigureRuntimeSurface();
            }];
        }
        IOSUseScheduleRuntimeSurfaceProbe(0);
        NSLog(
            @"[ios-use-play] Runtime v3 loaded device=%s logical=%dx%d@%dx",
            IOSUsePlayDeviceProductType(),
            IOSUsePlayDeviceLogicalWidth,
            IOSUsePlayDeviceLogicalHeight,
            IOSUsePlayDeviceScale
        );
    }
}
