//
// IOSUsePlayRuntime
//
// Headless automation Runtime built from the pinned PlayTools implementation.
// Runtime identity and device geometry remain fixed contracts. Optional host
// presentation choices are captured before private launch values are hidden.
//

#import "IOSUsePlayRuntime.h"
#import "IOSUsePlayAppKitBridge.h"
#import "IOSUsePlayHookRegistry.h"
#import "IOSUsePlayRuntimeSocket.h"
#import "IOSUsePlaySafeAreaCompatibility.h"
#import "IOSUsePlayDevice.h"

#import <Photos/Photos.h>
#import <UIKit/UIKit.h>
#import <mach/mach_time.h>
#import <objc/runtime.h>
#import <os/lock.h>

static NSUInteger IOSUseRuntimeConfigurationAttempt;
static BOOL IOSUseRuntimeSurfaceProbePending;
static BOOL IOSUseRuntimeRequiredSafeAreaHookInstalled;
static NSString *IOSUseRuntimeRequiredHookFailure;
static NSString *IOSUseRuntimeConfigurationStage = @"loaded";
static NSString *IOSUseRuntimeConfigurationFailure;
static os_unfair_lock IOSUsePhotosAuthorizationLock =
    OS_UNFAIR_LOCK_INIT;
static uint64_t IOSUsePhotosAuthorizationSequence;
static uint64_t IOSUsePhotosAuthorizationStateVersion;
static uint64_t IOSUsePhotosAuthorizationCompletionSequence;
static NSUInteger IOSUsePhotosAuthorizationOutstandingCount;
static uint64_t
    IOSUsePhotosAuthorizationRequestMonotonicMicroseconds;
static NSInteger IOSUsePhotosAuthorizationAccessLevel;
static BOOL IOSUsePhotosAuthorizationHasAccessLevel;
static NSInteger IOSUsePhotosAuthorizationStatus;
static BOOL IOSUsePhotosAuthorizationHasCompletion;
static BOOL IOSUsePhotosAuthorizationHookInstalled;
static NSString *IOSUsePhotosAuthorizationLastAPI;
static NSMutableDictionary<
    NSNumber *,
    NSDictionary<NSString *, id> *
> *IOSUsePhotosAuthorizationOutstandingRequests;
static IMP IOSUsePhotosAuthorizationOriginal;

static void IOSUseConfigureRuntimeSurface(void);

typedef void (^IOSUsePhotosAuthorizationHandler)(
    PHAuthorizationStatus status
);

static uint64_t IOSUseMonotonicMicroseconds(void) {
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mach_timebase_info(&timebase);
    });
    __uint128_t nanoseconds =
        (__uint128_t)mach_continuous_time() *
        timebase.numer /
        timebase.denom;
    return (uint64_t)(nanoseconds / 1000);
}

static uint64_t IOSUsePhotosAuthorizationBegin(
    NSString *api,
    BOOL hasAccessLevel,
    NSInteger accessLevel
) {
    os_unfair_lock_lock(
        &IOSUsePhotosAuthorizationLock
    );
    IOSUsePhotosAuthorizationStateVersion += 1;
    IOSUsePhotosAuthorizationSequence += 1;
    uint64_t sequence =
        IOSUsePhotosAuthorizationSequence;
    uint64_t requestMonotonicMicroseconds =
        IOSUseMonotonicMicroseconds();
    IOSUsePhotosAuthorizationRequestMonotonicMicroseconds =
        requestMonotonicMicroseconds;
    IOSUsePhotosAuthorizationLastAPI = api;
    IOSUsePhotosAuthorizationHasAccessLevel =
        hasAccessLevel;
    IOSUsePhotosAuthorizationAccessLevel =
        accessLevel;
    if (IOSUsePhotosAuthorizationOutstandingRequests == nil) {
        IOSUsePhotosAuthorizationOutstandingRequests =
            [NSMutableDictionary dictionary];
    }
    IOSUsePhotosAuthorizationOutstandingRequests[@(sequence)] = @{
        @"sequence": @(sequence),
        @"requestMonotonicMicroseconds":
            @(requestMonotonicMicroseconds),
        @"api": api,
        @"accessLevel": hasAccessLevel
            ? @(accessLevel)
            : (id)NSNull.null,
    };
    IOSUsePhotosAuthorizationOutstandingCount =
        IOSUsePhotosAuthorizationOutstandingRequests.count;
    os_unfair_lock_unlock(
        &IOSUsePhotosAuthorizationLock
    );
    return sequence;
}

static void IOSUsePhotosAuthorizationComplete(
    uint64_t sequence,
    PHAuthorizationStatus status
) {
    os_unfair_lock_lock(
        &IOSUsePhotosAuthorizationLock
    );
    IOSUsePhotosAuthorizationStateVersion += 1;
    [IOSUsePhotosAuthorizationOutstandingRequests
        removeObjectForKey:@(sequence)];
    IOSUsePhotosAuthorizationOutstandingCount =
        IOSUsePhotosAuthorizationOutstandingRequests.count;
    if (!IOSUsePhotosAuthorizationHasCompletion ||
        sequence >=
            IOSUsePhotosAuthorizationCompletionSequence) {
        IOSUsePhotosAuthorizationCompletionSequence =
            sequence;
        IOSUsePhotosAuthorizationStatus = status;
        IOSUsePhotosAuthorizationHasCompletion = YES;
    }
    os_unfair_lock_unlock(
        &IOSUsePhotosAuthorizationLock
    );
}

static void IOSUsePhotosRequestAuthorization(
    id receiver,
    SEL selector,
    NSInteger accessLevel,
    BOOL supportsLimited,
    IOSUsePhotosAuthorizationHandler handler
) {
    IOSUsePlayHookRegistryRecordInvocation(
        @"photos.authorization.request"
    );
    uint64_t sequence =
        IOSUsePhotosAuthorizationBegin(
            @"_requestAuthorizationForAccessLevel:"
                @"supportsLimited:handler:",
            YES,
            accessLevel
        );
    IOSUsePhotosAuthorizationHandler wrapped =
        ^(PHAuthorizationStatus status) {
            IOSUsePhotosAuthorizationComplete(
                sequence,
                status
            );
            if (handler != nil) {
                handler(status);
            }
        };
    ((void (*)(
        id,
        SEL,
        NSInteger,
        BOOL,
        IOSUsePhotosAuthorizationHandler
    ))IOSUsePhotosAuthorizationOriginal)(
        receiver,
        selector,
        accessLevel,
        supportsLimited,
        wrapped
    );
}

static void IOSUseInstallPhotosAuthorizationHooks(void) {
    if (!IOSUsePhotosAuthorizationHookInstalled) {
        const char *argumentTypes[] = {
            @encode(NSInteger),
            @encode(BOOL),
            @encode(IOSUsePhotosAuthorizationHandler),
        };
        IOSUsePhotosAuthorizationHookInstalled =
            IOSUsePlayHookRegistryInstallFunction(
                @"photos.authorization.request",
                NO,
                @"pre-main",
                PHPhotoLibrary.class,
                YES,
                NSSelectorFromString(
                    @"_requestAuthorizationForAccessLevel:"
                     @"supportsLimited:handler:"
                ),
                @encode(void),
                argumentTypes,
                3,
                YES,
                NO,
                (IMP)IOSUsePhotosRequestAuthorization,
                &IOSUsePhotosAuthorizationOriginal,
                NULL
            );
    }
}

static NSDictionary<NSString *, id> *
IOSUsePhotosAuthorizationDiagnosticsLocked(void) {
    uint64_t observation =
        IOSUseMonotonicMicroseconds();
    NSArray<NSNumber *> *pendingSequences =
        [IOSUsePhotosAuthorizationOutstandingRequests.allKeys
            sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray<NSDictionary<NSString *, id> *> *pendingRequests =
        [NSMutableArray arrayWithCapacity:pendingSequences.count];
    for (NSNumber *pendingSequence in pendingSequences) {
        NSDictionary<NSString *, id> *pending =
            IOSUsePhotosAuthorizationOutstandingRequests[
                pendingSequence
            ];
        uint64_t requestedAt = [
            pending[@"requestMonotonicMicroseconds"]
            unsignedLongLongValue
        ];
        [pendingRequests addObject:@{
            @"sequence": pending[@"sequence"],
            @"requestMonotonicMicroseconds":
                pending[@"requestMonotonicMicroseconds"],
            @"ageMicroseconds": @(
                observation >= requestedAt
                    ? observation - requestedAt
                    : 0
            ),
            @"api": pending[@"api"],
            @"accessLevel": pending[@"accessLevel"],
        }];
    }
    NSDictionary<NSString *, id> *result = @{
        @"hookInstalled": @(IOSUsePhotosAuthorizationHookInstalled),
        @"sequence": @(IOSUsePhotosAuthorizationSequence),
        @"stateVersion": @(
            IOSUsePhotosAuthorizationStateVersion
        ),
        @"outstandingCount": @(
            IOSUsePhotosAuthorizationOutstandingCount
        ),
        @"pendingRequests": pendingRequests,
        @"requestMonotonicMicroseconds":
            IOSUsePhotosAuthorizationSequence == 0
                ? (id)NSNull.null
                : @(
                    IOSUsePhotosAuthorizationRequestMonotonicMicroseconds
                ),
        @"observationMonotonicMicroseconds":
            @(observation),
        @"ageMicroseconds":
            IOSUsePhotosAuthorizationSequence == 0
                ? (id)NSNull.null
                : @(
                    observation -
                    IOSUsePhotosAuthorizationRequestMonotonicMicroseconds
                ),
        @"lastAPI":
            IOSUsePhotosAuthorizationLastAPI ?: NSNull.null,
        @"accessLevel":
            IOSUsePhotosAuthorizationHasAccessLevel
                ? @(IOSUsePhotosAuthorizationAccessLevel)
                : (id)NSNull.null,
        @"completionSequence":
            IOSUsePhotosAuthorizationHasCompletion
                ? @(IOSUsePhotosAuthorizationCompletionSequence)
                : (id)NSNull.null,
        @"authorizationStatus":
            IOSUsePhotosAuthorizationHasCompletion
                ? @(IOSUsePhotosAuthorizationStatus)
                : (id)NSNull.null,
    };
    return result;
}

NSDictionary<NSString *, id> *
IOSUsePlayRuntimePhotosAuthorizationDiagnostics(void) {
    os_unfair_lock_lock(
        &IOSUsePhotosAuthorizationLock
    );
    NSDictionary<NSString *, id> *result =
        IOSUsePhotosAuthorizationDiagnosticsLocked();
    os_unfair_lock_unlock(
        &IOSUsePhotosAuthorizationLock
    );
    return result;
}

BOOL IOSUsePlayRuntimeTryLinearizePhotosMutation(
    uint64_t expectedStateVersion,
    NSDictionary<NSString *, id> **blockingDiagnostics
) {
    os_unfair_lock_lock(
        &IOSUsePhotosAuthorizationLock
    );
    uint64_t observedStateVersion =
        IOSUsePhotosAuthorizationStateVersion;
    NSUInteger outstandingCount =
        IOSUsePhotosAuthorizationOutstandingCount;
    BOOL stateChanged =
        observedStateVersion != expectedStateVersion;
    BOOL unchangedAndClear =
        !stateChanged && outstandingCount == 0;
    BOOL settledAfterChange =
        stateChanged && outstandingCount == 0;
    BOOL allowed = unchangedAndClear || settledAfterChange;
    NSDictionary<NSString *, id> *capturedBlockingDiagnostics =
        allowed
            ? nil
            : IOSUsePhotosAuthorizationDiagnosticsLocked();
    os_unfair_lock_unlock(
        &IOSUsePhotosAuthorizationLock
    );
    if (allowed) {
        // The locked comparison is the mutation's linearization point
        // relative to PhotoKit Begin/Complete transitions. A later Begin is
        // ordered after this mutation. A changed version whose outstanding
        // set is already empty no longer blocks interaction.
        return YES;
    }
    if (blockingDiagnostics != NULL) {
        *blockingDiagnostics = capturedBlockingDiagnostics;
    }
    return NO;
}

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
        @"nativeCanvas": @YES,
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
    if (!IOSUseRuntimeRequiredSafeAreaHookInstalled) {
        IOSUseRuntimeConfigurationStage = @"required-hook-failed";
        if (IOSUseRuntimeConfigurationFailure == nil) {
            IOSUseRuntimeConfigurationFailure =
                @"required safe-area provider hook did not install "
                 "before UIApplicationMain";
        }
        IOSUsePlayRuntimePublishUIReadiness();
        return;
    }
    NSError *error = nil;
    BOOL windowReady =
        [IOSUsePlayAppKitBridge configureFixedWindow:&error];
    if (windowReady) {
        IOSUseRuntimeConfigurationStage = @"window-configured";
        IOSUseRuntimeConfigurationFailure = nil;
        IOSUsePlayRuntimePublishUIReadiness();
        return;
    }
    IOSUseRuntimeConfigurationStage = @"waiting-for-window";
    if (error.code == 12) {
        IOSUseRuntimeConfigurationStage = @"waiting-for-safe-area";
    } else if (error.code == 13) {
        IOSUseRuntimeConfigurationStage = @"safe-area-failed";
    } else {
        NSString *windowStatus = [
            IOSUsePlayAppKitBridge readinessDiagnostics
        ][@"status"];
        if ([windowStatus isEqualToString:@"scene-geometry-failed"]) {
            IOSUseRuntimeConfigurationStage = @"scene-geometry-failed";
        } else if ([windowStatus isEqualToString:@"failed"]) {
            IOSUseRuntimeConfigurationStage = @"window-configuration-failed";
        }
    }
    IOSUseRuntimeConfigurationFailure =
        error.localizedDescription ?:
        @"fixed iPhone surface is not ready";
    IOSUsePlayRuntimePublishUIReadiness();
    if ([IOSUseRuntimeConfigurationStage hasSuffix:@"-failed"]) {
        return;
    }
    // Keep reconciling scene/window replacement, but do not pretend readiness.
    NSTimeInterval delay =
        IOSUseRuntimeConfigurationAttempt < 240 ? 0.25 : 1.0;
    IOSUseScheduleRuntimeSurfaceProbe(delay);
}

BOOL IOSUsePlayRuntimeRequiredHooksReady(void) {
    return IOSUseRuntimeRequiredSafeAreaHookInstalled;
}

NSString *IOSUsePlayRuntimeRequiredHooksFailure(void) {
    return IOSUseRuntimeRequiredHookFailure;
}

NSDictionary<NSString *, id> *IOSUsePlayRuntimeHookDiagnostics(
    IOSUsePlayRuntimeDiagnosticsScope scope,
    NSDictionary<NSString *, id> *nativeAlertSnapshot,
    NSDictionary<NSString *, id> *photosAuthorizationDiagnostics
) {
    BOOL includeFullDiagnostics =
        scope == IOSUsePlayRuntimeDiagnosticsScopeFull;
    NSDictionary<NSString *, id> *window = includeFullDiagnostics
        ? nativeAlertSnapshot == nil
            ? [IOSUsePlayAppKitBridge diagnostics]
            : [IOSUsePlayAppKitBridge
                diagnosticsWithNativeAlertSnapshot:
                    nativeAlertSnapshot]
        : [IOSUsePlayAppKitBridge readinessDiagnostics];
    IOSUsePlaySafeAreaCompatibilityBridgeHookRegistry();
    NSDictionary<NSString *, id> *hookRegistry =
        IOSUsePlayHookRegistryDiagnostics();
    NSMutableDictionary<NSString *, id> *diagnostics =
        [@{
            @"configurationStage": IOSUseRuntimeConfigurationStage,
            @"configurationFailure":
                IOSUseRuntimeConfigurationFailure ?: NSNull.null,
            @"window": window,
            @"hookRegistry": hookRegistry,
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
        @"photosAuthorization":
            photosAuthorizationDiagnostics ?:
                IOSUsePlayRuntimePhotosAuthorizationDiagnostics(),
    }];
    return diagnostics;
}

void IOSUsePlayRuntimeInitializeAfterStdio(void) {
    @autoreleasepool {
        [IOSUsePlayAppKitBridge captureSceneBackingLaunchEnvironment];
        // Required API hooks must be installed synchronously before
        // UIApplicationMain permits App/SDK first reads. Scene/window
        // reconciliation remains a later, main-thread lifecycle operation.
        NSError *safeAreaInstallError = nil;
        IOSUseRuntimeRequiredSafeAreaHookInstalled =
            IOSUsePlaySafeAreaCompatibilityInstallBeforeUIApplicationMain(
                &safeAreaInstallError
            );
        IOSUsePlaySafeAreaCompatibilityBridgeHookRegistry();
        if (!IOSUseRuntimeRequiredSafeAreaHookInstalled) {
            IOSUseRuntimeConfigurationStage =
                @"required-hook-failed";
            IOSUseRuntimeConfigurationFailure =
                safeAreaInstallError.localizedDescription ?:
                    @"required safe-area provider hook did not install "
                     "before UIApplicationMain";
            IOSUseRuntimeRequiredHookFailure =
                IOSUseRuntimeConfigurationFailure;
        }
        IOSUsePlayRuntimeSetUIReadiness(
            IOSUseRuntimeRequiredSafeAreaHookInstalled
                ? @"initializing"
                : @"failed",
            IOSUseRuntimeRequiredSafeAreaHookInstalled
                ? @"waiting-for-application-main"
                : @"required-hook-failed",
            IOSUseRuntimeRequiredHookFailure
        );
        IOSUseInstallPhotosAuthorizationHooks();
        NSNotificationCenter *center =
            NSNotificationCenter.defaultCenter;
        for (NSString *name in @[
            UIApplicationDidBecomeActiveNotification,
            UIApplicationWillResignActiveNotification,
            UIApplicationDidEnterBackgroundNotification,
            UIWindowDidBecomeKeyNotification,
            UISceneWillEnterForegroundNotification,
            UISceneDidActivateNotification,
            UISceneWillDeactivateNotification,
            UISceneDidEnterBackgroundNotification,
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
        IOSUsePlayRuntimeStartCommandLoop();
        NSLog(
            @"[ios-use-play] Runtime loaded device=%s logical=%dx%d@%dx",
            IOSUsePlayDeviceProductType(),
            IOSUsePlayDeviceLogicalWidth,
            IOSUsePlayDeviceLogicalHeight,
            IOSUsePlayDeviceScale
        );
    }
}
