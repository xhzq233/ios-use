#import "IOSUsePlayRuntimeScreenshot.h"
#import "IOSUsePlayAppKitBridge.h"
#import "IOSUsePlayDevice.h"
#import "IOSUsePlaySystemChrome.h"
#import "IOSUsePlayWindowCompositor.h"

#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <stdatomic.h>
#import <unistd.h>

static const NSTimeInterval IOSUseScreenshotMainThreadTimeoutSeconds = 12;
static const NSUInteger IOSUseScreenshotMaximumJPEGBytes = 11 * 1024 * 1024;
static const NSUInteger IOSUseScreenshotMaximumBase64Bytes =
    15 * 1024 * 1024;
static const CGFloat IOSUseScreenshotGeometryTolerance = 0.01;
static atomic_bool IOSUseScreenshotInFlight = false;
static atomic_ullong IOSUseScreenshotCaptureGeneration = 0;

typedef id (*IOSUseScreenshotSendID)(id, SEL);
typedef BOOL (*IOSUseScreenshotSendBool)(id, SEL);
typedef NSInteger (*IOSUseScreenshotSendInteger)(id, SEL);
typedef CGFloat (*IOSUseScreenshotSendFloat)(id, SEL);
typedef CGRect (*IOSUseScreenshotSendRect)(id, SEL);
typedef int32_t IOSUseCGSConnectionID;
typedef IOSUseCGSConnectionID (*IOSUseCGSMainConnectionID)(void);
typedef CFArrayRef _Nullable (*IOSUseCGSHWCaptureWindowList)(
    IOSUseCGSConnectionID,
    const uint32_t *,
    uint32_t,
    uint32_t
);
typedef CFArrayRef _Nullable (*IOSUseCGWindowListCopyWindowInfo)(
    CGWindowListOption,
    CGWindowID
);

enum {
    IOSUseCGSHWIgnoreGlobalClipShape = 1U << 11,
    IOSUseCGSHWBestResolution = 1U << 8,
    IOSUseCGSHWFullSize = 1U << 19,
};

@interface IOSUseScreenshotNativeWindow : NSObject
@property(nonatomic, strong) id appKitWindow;
@property(nonatomic) uint32_t windowNumber;
@property(nonatomic) CGRect frame;
@property(nonatomic) CGRect cgWindowBounds;
@property(nonatomic) CGRect deviceLogicalRect;
@property(nonatomic) CGFloat backingScale;
@property(nonatomic) NSInteger appKitLevel;
@property(nonatomic) NSInteger cgWindowLayer;
@property(nonatomic) NSUInteger cgFrontToBackIndex;
@property(nonatomic) NSInteger orderedWindowsIndex;
@property(nonatomic) NSInteger parentWindowNumber;
@property(nonatomic) BOOL containsSystemChrome;
@property(nonatomic, strong)
    NSMutableArray<NSDictionary<NSString *, id> *> *uiWindowEvidence;
@end

@implementation IOSUseScreenshotNativeWindow
@end

static void IOSUseScreenshotSetFailure(
    NSString *code,
    NSString *message,
    NSString **failureCode,
    NSString **failureMessage
) {
    if (failureCode != NULL) {
        *failureCode = code;
    }
    if (failureMessage != NULL) {
        *failureMessage = message;
    }
}

static NSDictionary<NSString *, NSNumber *> *IOSUseScreenshotRectJSON(
    CGRect rect
) {
    return @{
        @"x": @(rect.origin.x),
        @"y": @(rect.origin.y),
        @"width": @(rect.size.width),
        @"height": @(rect.size.height),
    };
}

static BOOL IOSUseScreenshotFiniteRect(CGRect rect);

static BOOL IOSUseScreenshotRectFromJSON(id value, CGRect *rect) {
    if (![value isKindOfClass:NSDictionary.class]) {
        return NO;
    }
    NSDictionary *dictionary = value;
    for (NSString *key in @[@"x", @"y", @"width", @"height"]) {
        if (![dictionary[key] isKindOfClass:NSNumber.class]) {
            return NO;
        }
    }
    CGRect result = CGRectMake(
        [dictionary[@"x"] doubleValue],
        [dictionary[@"y"] doubleValue],
        [dictionary[@"width"] doubleValue],
        [dictionary[@"height"] doubleValue]
    );
    if (!IOSUseScreenshotFiniteRect(result)) {
        return NO;
    }
    if (rect != NULL) {
        *rect = result;
    }
    return YES;
}

static BOOL IOSUseScreenshotFiniteRect(CGRect rect) {
    return isfinite(rect.origin.x) &&
        isfinite(rect.origin.y) &&
        isfinite(rect.size.width) &&
        isfinite(rect.size.height) &&
        rect.size.width > 0 &&
        rect.size.height > 0;
}

static BOOL IOSUseScreenshotApproximatelyEqual(
    CGFloat lhs,
    CGFloat rhs
) {
    return fabs(lhs - rhs) <= IOSUseScreenshotGeometryTolerance;
}

static BOOL IOSUseScreenshotRectIsDeviceSize(CGRect rect) {
    return IOSUseScreenshotFiniteRect(rect) &&
        IOSUseScreenshotApproximatelyEqual(
            rect.size.width,
            IOSUsePlayDeviceLogicalWidth
        ) &&
        IOSUseScreenshotApproximatelyEqual(
            rect.size.height,
            IOSUsePlayDeviceLogicalHeight
        );
}

static BOOL IOSUseScreenshotLogicalRectIsInsideDevice(CGRect rect) {
    if (!IOSUseScreenshotFiniteRect(rect)) {
        return NO;
    }
    return CGRectGetMinX(rect) >=
            -IOSUseScreenshotGeometryTolerance &&
        CGRectGetMinY(rect) >=
            -IOSUseScreenshotGeometryTolerance &&
        CGRectGetMaxX(rect) <=
            IOSUsePlayDeviceLogicalWidth +
                IOSUseScreenshotGeometryTolerance &&
        CGRectGetMaxY(rect) <=
            IOSUsePlayDeviceLogicalHeight +
                IOSUseScreenshotGeometryTolerance;
}

static NSArray<UIWindowScene *> *
IOSUseScreenshotForegroundScenes(NSString **failure) {
    NSArray *connectedScenes =
        UIApplication.sharedApplication.connectedScenes.allObjects;
    return IOSUsePlayOrderForegroundScenes(
        connectedScenes,
        ^NSInteger(id candidate) {
            if (![candidate isKindOfClass:UIWindowScene.class]) {
                return -1;
            }
            UISceneActivationState state =
                ((UIWindowScene *)candidate).activationState;
            if (state == UISceneActivationStateForegroundActive) {
                return 0;
            }
            if (state == UISceneActivationStateForegroundInactive) {
                return 1;
            }
            return -1;
        },
        ^NSString *(id candidate) {
            return ((UIWindowScene *)candidate)
                .session.persistentIdentifier;
        },
        failure
    );
}

static UIWindow *IOSUseScreenshotPrimaryUIKitWindow(
    NSArray<UIWindowScene *> *orderedScenes
) {
    return IOSUsePlaySelectPrimaryWindow(
        orderedScenes,
        ^NSArray *(id scene) {
            return ((UIWindowScene *)scene).windows;
        },
        ^BOOL(id window) {
            return ((UIWindow *)window).isKeyWindow;
        }
    );
}

static NSArray<UIWindow *> *IOSUseScreenshotVisibleUIKitWindows(
    NSArray<UIWindowScene *> *orderedScenes
) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIWindowScene *scene in orderedScenes) {
        for (UIWindow *window in scene.windows) {
            if (!window.hidden &&
                window.alpha > 0 &&
                window.bounds.size.width > 0 &&
                window.bounds.size.height > 0) {
                [windows addObject:window];
            }
        }
    }
    return windows;
}

static BOOL IOSUseScreenshotLoadAppKit(void) {
    static void *handle;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handle = dlopen(
            "/System/Library/Frameworks/AppKit.framework/AppKit",
            RTLD_NOW | RTLD_LOCAL
        );
    });
    return handle != NULL;
}

static id IOSUseScreenshotNSApplication(void) {
    if (!IOSUseScreenshotLoadAppKit()) {
        return nil;
    }
    Class applicationClass = NSClassFromString(@"NSApplication");
    SEL sharedSelector = NSSelectorFromString(@"sharedApplication");
    if (applicationClass == Nil ||
        ![(id)applicationClass respondsToSelector:sharedSelector]) {
        return nil;
    }
    return ((IOSUseScreenshotSendID)objc_msgSend)(
        (id)applicationClass,
        sharedSelector
    );
}

static NSArray *IOSUseScreenshotArraySelector(
    id object,
    NSString *selectorName
) {
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) {
        return nil;
    }
    id value = ((IOSUseScreenshotSendID)objc_msgSend)(
        object,
        selector
    );
    return [value isKindOfClass:NSArray.class] ? value : nil;
}

static NSInteger IOSUseScreenshotIntegerSelector(
    id object,
    NSString *selectorName
) {
    SEL selector = NSSelectorFromString(selectorName);
    return [object respondsToSelector:selector]
        ? ((IOSUseScreenshotSendInteger)objc_msgSend)(object, selector)
        : 0;
}

static BOOL IOSUseScreenshotBoolSelector(
    id object,
    NSString *selectorName
) {
    SEL selector = NSSelectorFromString(selectorName);
    return [object respondsToSelector:selector] &&
        ((IOSUseScreenshotSendBool)objc_msgSend)(object, selector);
}

static CGFloat IOSUseScreenshotFloatSelector(
    id object,
    NSString *selectorName
) {
    SEL selector = NSSelectorFromString(selectorName);
    return [object respondsToSelector:selector]
        ? ((IOSUseScreenshotSendFloat)objc_msgSend)(object, selector)
        : 0;
}

static CGRect IOSUseScreenshotRectSelector(
    id object,
    NSString *selectorName
) {
    SEL selector = NSSelectorFromString(selectorName);
    return [object respondsToSelector:selector]
        ? ((IOSUseScreenshotSendRect)objc_msgSend)(object, selector)
        : CGRectZero;
}

static IOSUseScreenshotNativeWindow *
IOSUseScreenshotAddNativeWindow(
    id appKitWindow,
    NSMutableDictionary<NSNumber *, IOSUseScreenshotNativeWindow *> *
        windowsByNumber,
    NSString **failureCode,
    NSString **failureMessage
) {
    NSInteger rawNumber = IOSUseScreenshotIntegerSelector(
        appKitWindow,
        @"windowNumber"
    );
    if (rawNumber <= 0 || rawNumber > UINT32_MAX) {
        IOSUseScreenshotSetFailure(
            @"compositor_window_unavailable",
            @"a visible AppKit window has no valid window number",
            failureCode,
            failureMessage
        );
        return nil;
    }
    NSNumber *key = @((uint32_t)rawNumber);
    IOSUseScreenshotNativeWindow *record = windowsByNumber[key];
    if (record != nil && record.appKitWindow != appKitWindow) {
        IOSUseScreenshotSetFailure(
            @"compositor_window_ambiguous",
            [NSString stringWithFormat:
                @"window number %u identifies more than one AppKit window",
                (uint32_t)rawNumber
            ],
            failureCode,
            failureMessage
        );
        return nil;
    }
    if (record != nil) {
        return record;
    }
    record = [[IOSUseScreenshotNativeWindow alloc] init];
    record.appKitWindow = appKitWindow;
    record.windowNumber = (uint32_t)rawNumber;
    record.frame = IOSUseScreenshotRectSelector(appKitWindow, @"frame");
    record.backingScale = IOSUseScreenshotFloatSelector(
        appKitWindow,
        @"backingScaleFactor"
    );
    record.appKitLevel = IOSUseScreenshotIntegerSelector(
        appKitWindow,
        @"level"
    );
    record.orderedWindowsIndex = -1;
    record.parentWindowNumber = -1;
    record.uiWindowEvidence = [NSMutableArray array];
    windowsByNumber[key] = record;
    return record;
}

static NSDictionary<NSNumber *, NSDictionary<NSString *, id> *> *
IOSUseScreenshotCGWindowMetadata(
    IOSUseCGWindowListCopyWindowInfo copyWindowInfo,
    NSString **failureCode,
    NSString **failureMessage
) {
    if (copyWindowInfo == NULL) {
        IOSUseScreenshotSetFailure(
            @"compositor_z_order_unavailable",
            @"CGWindow order metadata API is unavailable",
            failureCode,
            failureMessage
        );
        return nil;
    }
    CFArrayRef raw = copyWindowInfo(
        kCGWindowListOptionOnScreenOnly,
        kCGNullWindowID
    );
    if (raw == NULL) {
        IOSUseScreenshotSetFailure(
            @"compositor_z_order_unavailable",
            @"CGWindow order metadata returned no on-screen windows",
            failureCode,
            failureMessage
        );
        return nil;
    }
    NSArray *windowInfo = CFBridgingRelease(raw);
    if (![windowInfo isKindOfClass:NSArray.class]) {
        IOSUseScreenshotSetFailure(
            @"compositor_z_order_unavailable",
            @"CGWindow order metadata has an invalid shape",
            failureCode,
            failureMessage
        );
        return nil;
    }
    NSMutableDictionary<
        NSNumber *,
        NSDictionary<NSString *, id> *
    > *result = [NSMutableDictionary dictionary];
    pid_t processID = getpid();
    for (NSUInteger index = 0;
         index < windowInfo.count;
         index += 1) {
        NSDictionary *entry = windowInfo[index];
        if (![entry isKindOfClass:NSDictionary.class]) {
            continue;
        }
        NSNumber *ownerPID =
            entry[(__bridge NSString *)kCGWindowOwnerPID];
        NSNumber *windowNumber =
            entry[(__bridge NSString *)kCGWindowNumber];
        if (![ownerPID isKindOfClass:NSNumber.class] ||
            ownerPID.intValue != processID ||
            ![windowNumber isKindOfClass:NSNumber.class] ||
            windowNumber.unsignedLongLongValue == 0 ||
            windowNumber.unsignedLongLongValue > UINT32_MAX) {
            continue;
        }
        NSNumber *onscreen =
            entry[(__bridge NSString *)kCGWindowIsOnscreen];
        NSNumber *layer =
            entry[(__bridge NSString *)kCGWindowLayer];
        NSDictionary *bounds =
            entry[(__bridge NSString *)kCGWindowBounds];
        CGRect cgBounds = CGRectZero;
        BOOL boundsReady =
            [bounds isKindOfClass:NSDictionary.class] &&
            CGRectMakeWithDictionaryRepresentation(
                (__bridge CFDictionaryRef)bounds,
                &cgBounds
            );
        NSNumber *key = @(windowNumber.unsignedIntValue);
        if (result[key] != nil) {
            IOSUseScreenshotSetFailure(
                @"compositor_z_order_ambiguous",
                [NSString stringWithFormat:
                    @"CGWindow metadata repeated own window %u",
                    windowNumber.unsignedIntValue
                ],
                failureCode,
                failureMessage
            );
            return nil;
        }
        result[key] = @{
            @"frontToBackIndex": @(index),
            @"layer":
                [layer isKindOfClass:NSNumber.class] ? layer : @0,
            @"onscreen": @(
                ![onscreen isKindOfClass:NSNumber.class] ||
                onscreen.boolValue
            ),
            @"bounds": boundsReady
                ? IOSUseScreenshotRectJSON(cgBounds)
                : (id)NSNull.null,
        };
    }
    return result;
}

static BOOL IOSUseScreenshotValidateChildOrder(
    NSArray<IOSUseScreenshotNativeWindow *> *windows,
    NSDictionary<NSNumber *, IOSUseScreenshotNativeWindow *> *
        windowsByNumber,
    NSString **failureCode,
    NSString **failureMessage
) {
    for (IOSUseScreenshotNativeWindow *record in windows) {
        SEL parentSelector = NSSelectorFromString(@"parentWindow");
        id parent = [record.appKitWindow
            respondsToSelector:parentSelector]
            ? ((IOSUseScreenshotSendID)objc_msgSend)(
                record.appKitWindow,
                parentSelector
            )
            : nil;
        NSInteger rawParent = IOSUseScreenshotIntegerSelector(
            parent,
            @"windowNumber"
        );
        record.parentWindowNumber = rawParent > 0 ? rawParent : -1;
        IOSUseScreenshotNativeWindow *parentRecord =
            windowsByNumber[@((uint32_t)rawParent)];
        if (parentRecord != nil &&
            record.cgFrontToBackIndex >=
                parentRecord.cgFrontToBackIndex) {
            IOSUseScreenshotSetFailure(
                @"compositor_z_order_invalid",
                [NSString stringWithFormat:
                    @"child window %u is not in front of parent window %u",
                    record.windowNumber,
                    parentRecord.windowNumber
                ],
                failureCode,
                failureMessage
            );
            return NO;
        }
        NSArray *children = IOSUseScreenshotArraySelector(
            record.appKitWindow,
            @"childWindows"
        );
        for (id child in children ?: @[]) {
            NSInteger rawChild = IOSUseScreenshotIntegerSelector(
                child,
                @"windowNumber"
            );
            IOSUseScreenshotNativeWindow *childRecord =
                windowsByNumber[@((uint32_t)rawChild)];
            if (childRecord != nil &&
                childRecord.cgFrontToBackIndex >=
                    record.cgFrontToBackIndex) {
                IOSUseScreenshotSetFailure(
                    @"compositor_z_order_invalid",
                    [NSString stringWithFormat:
                        @"child window %u is not in front of parent "
                        @"window %u",
                        childRecord.windowNumber,
                        record.windowNumber
                    ],
                    failureCode,
                    failureMessage
                );
                return NO;
            }
        }
    }
    return YES;
}

static NSArray<IOSUseScreenshotNativeWindow *> *
IOSUseScreenshotCollectNativeWindows(
    IOSUseCGWindowListCopyWindowInfo copyWindowInfo,
    uint32_t *baseWindowNumber,
    CGRect *deviceFrame,
    NSUInteger *visibleUIKitWindowCount,
    NSUInteger *mappedUIKitWindowCount,
    BOOL *systemChromeMapped,
    NSString **failureCode,
    NSString **failureMessage
) {
    id application = IOSUseScreenshotNSApplication();
    NSArray *applicationWindows = IOSUseScreenshotArraySelector(
        application,
        @"windows"
    );
    NSArray *orderedWindows = IOSUseScreenshotArraySelector(
        application,
        @"orderedWindows"
    );
    if (application == nil ||
        applicationWindows == nil ||
        orderedWindows == nil) {
        IOSUseScreenshotSetFailure(
            @"compositor_window_unavailable",
            @"NSApplication window inventory is unavailable",
            failureCode,
            failureMessage
        );
        return nil;
    }
    NSString *scenePolicyFailure = nil;
    NSArray<UIWindowScene *> *orderedScenes =
        IOSUseScreenshotForegroundScenes(&scenePolicyFailure);
    if (orderedScenes == nil) {
        IOSUseScreenshotSetFailure(
            @"compositor_scene_policy_invalid",
            scenePolicyFailure ?:
                @"foreground scene order is unavailable",
            failureCode,
            failureMessage
        );
        return nil;
    }
    UIWindow *primaryUIKitWindow =
        IOSUseScreenshotPrimaryUIKitWindow(orderedScenes);
    NSArray<UIWindow *> *uiWindows =
        IOSUseScreenshotVisibleUIKitWindows(orderedScenes);
    if (primaryUIKitWindow != nil &&
        ![uiWindows containsObject:primaryUIKitWindow]) {
        IOSUseScreenshotSetFailure(
            @"compositor_primary_window_unavailable",
            @"the deterministic primary key UIWindow is not visible",
            failureCode,
            failureMessage
        );
        return nil;
    }
    SEL keyWindowSelector = NSSelectorFromString(@"keyWindow");
    id applicationKeyWindow =
        [application respondsToSelector:keyWindowSelector]
        ? ((IOSUseScreenshotSendID)objc_msgSend)(
            application,
            keyWindowSelector
        )
        : nil;
    NSString *primaryMappingSource = nil;
    id primaryAppKitWindow = IOSUsePlayResolveMappedWindow(
        primaryUIKitWindow,
        applicationWindows,
        applicationKeyWindow,
        &primaryMappingSource
    );
    if (primaryAppKitWindow == nil) {
        IOSUseScreenshotSetFailure(
            @"compositor_primary_window_unmapped",
            @"deterministic primary mapping and NSApp.keyWindow "
            @"fallback are unavailable",
            failureCode,
            failureMessage
        );
        return nil;
    }
    if (visibleUIKitWindowCount != NULL) {
        *visibleUIKitWindowCount = uiWindows.count;
    }

    NSMutableArray *mappedNativeWindows = [NSMutableArray array];
    NSMutableArray<NSDictionary<NSString *, id> *> *uiMappings =
        [NSMutableArray arrayWithCapacity:uiWindows.count];
    NSUInteger mappedCount = 0;
    NSUInteger chromeCount = 0;
    for (UIWindow *uiWindow in uiWindows) {
        CGRect logicalFrame = uiWindow.frame;
        if (!IOSUseScreenshotLogicalRectIsInsideDevice(logicalFrame)) {
            IOSUseScreenshotSetFailure(
                @"compositor_uikit_geometry_invalid",
                [NSString stringWithFormat:
                    @"visible UIWindow %@ is outside the fixed logical "
                    @"device",
                    NSStringFromClass(uiWindow.class)
                ],
                failureCode,
                failureMessage
            );
            return nil;
        }
        NSString *mappingSource = nil;
        id appKitWindow = uiWindow == primaryUIKitWindow
            ? primaryAppKitWindow
            : IOSUsePlayResolveMappedWindow(
                uiWindow,
                applicationWindows,
                nil,
                &mappingSource
            );
        if (uiWindow == primaryUIKitWindow) {
            mappingSource = primaryMappingSource;
        }
        if (appKitWindow == nil) {
            IOSUseScreenshotSetFailure(
                @"compositor_uikit_window_unmapped",
                [NSString stringWithFormat:
                    @"visible UIWindow %@ has no AppKit window mapping",
                    NSStringFromClass(uiWindow.class)
                ],
                failureCode,
                failureMessage
            );
            return nil;
        }
        BOOL chrome = [uiWindow.accessibilityIdentifier
            isEqualToString:
                @"io.ios-use.play-runtime.system-chrome"];
        chromeCount += chrome ? 1 : 0;
        NSUInteger sceneWindowIndex =
            [uiWindow.windowScene.windows indexOfObjectIdenticalTo:
                uiWindow];
        NSDictionary<NSString *, id> *evidence = @{
            @"class": NSStringFromClass(uiWindow.class),
            @"identifier":
                uiWindow.accessibilityIdentifier ?: NSNull.null,
            @"sceneIdentifier":
                uiWindow.windowScene.session.persistentIdentifier ?: @"",
            @"sceneWindowIndex": sceneWindowIndex == NSNotFound
                ? @(-1)
                : @(sceneWindowIndex),
            @"windowLevel": @(uiWindow.windowLevel),
            @"key": @(uiWindow.isKeyWindow),
            @"frame": IOSUseScreenshotRectJSON(logicalFrame),
            @"mappingSource": mappingSource ?: @"unknown",
            @"systemChrome": @(chrome),
        };
        [mappedNativeWindows addObject:appKitWindow];
        [uiMappings addObject:@{
            @"uiWindow": uiWindow,
            @"appKitWindow": appKitWindow,
            @"evidence": evidence,
            @"systemChrome": @(chrome),
        }];
        mappedCount += 1;
    }
    if (primaryUIKitWindow == nil) {
        [mappedNativeWindows addObject:primaryAppKitWindow];
    }
    NSString *unionFailure = nil;
    NSArray *captureWindows = IOSUsePlayUnionCaptureWindows(
        mappedNativeWindows,
        applicationWindows,
        ^BOOL(id window) {
            return IOSUseScreenshotBoolSelector(window, @"isVisible");
        },
        ^NSInteger(id window) {
            return IOSUseScreenshotIntegerSelector(
                window,
                @"windowNumber"
            );
        },
        &unionFailure
    );
    if (captureWindows == nil) {
        IOSUseScreenshotSetFailure(
            @"compositor_native_window_union_failed",
            unionFailure ?:
                @"native capture window union is incomplete",
            failureCode,
            failureMessage
        );
        return nil;
    }
    NSMutableDictionary<
        NSNumber *,
        IOSUseScreenshotNativeWindow *
    > *windowsByNumber = [NSMutableDictionary dictionary];
    for (id appKitWindow in captureWindows) {
        IOSUseScreenshotNativeWindow *record =
            IOSUseScreenshotAddNativeWindow(
                appKitWindow,
                windowsByNumber,
                failureCode,
                failureMessage
            );
        if (record == nil) {
            return nil;
        }
    }
    for (NSDictionary<NSString *, id> *mapping in uiMappings) {
        id appKitWindow = mapping[@"appKitWindow"];
        NSInteger rawNumber = IOSUseScreenshotIntegerSelector(
            appKitWindow,
            @"windowNumber"
        );
        IOSUseScreenshotNativeWindow *record =
            windowsByNumber[@((uint32_t)rawNumber)];
        if (record == nil) {
            IOSUseScreenshotSetFailure(
                @"compositor_native_window_union_failed",
                @"mapped UIWindow host is absent from native union",
                failureCode,
                failureMessage
            );
            return nil;
        }
        BOOL chrome = [mapping[@"systemChrome"] boolValue];
        record.containsSystemChrome =
            record.containsSystemChrome || chrome;
        [record.uiWindowEvidence addObject:mapping[@"evidence"]];
    }
    if (mappedUIKitWindowCount != NULL) {
        *mappedUIKitWindowCount = mappedCount;
    }
    NSInteger rawBaseWindowNumber =
        IOSUseScreenshotIntegerSelector(
            primaryAppKitWindow,
            @"windowNumber"
        );
    IOSUseScreenshotNativeWindow *baseRecord =
        windowsByNumber[@((uint32_t)rawBaseWindowNumber)];
    if (baseRecord == nil) {
        IOSUseScreenshotSetFailure(
            @"compositor_primary_window_unmapped",
            @"deterministic primary AppKit window has no native capture",
            failureCode,
            failureMessage
        );
        return nil;
    }
    if (chromeCount != 1) {
        IOSUseScreenshotSetFailure(
            @"compositor_chrome_window_invalid",
            [NSString stringWithFormat:
                @"expected one visible system-chrome UIWindow, found %lu",
                (unsigned long)chromeCount
            ],
            failureCode,
            failureMessage
        );
        return nil;
    }
    if (systemChromeMapped != NULL) {
        *systemChromeMapped = YES;
    }

    CGRect baseFrame = baseRecord.frame;
    if (!IOSUseScreenshotRectIsDeviceSize(baseFrame)) {
        IOSUseScreenshotSetFailure(
            @"compositor_primary_geometry_invalid",
            [NSString stringWithFormat:
                @"primary AppKit window is not the fixed %ldx%ld device",
                (long)IOSUsePlayDeviceLogicalWidth,
                (long)IOSUsePlayDeviceLogicalHeight
            ],
            failureCode,
            failureMessage
        );
        return nil;
    }
    NSDictionary *cgMetadata = IOSUseScreenshotCGWindowMetadata(
        copyWindowInfo,
        failureCode,
        failureMessage
    );
    if (cgMetadata == nil) {
        return nil;
    }
    NSDictionary *baseCGMetadata =
        cgMetadata[@(baseRecord.windowNumber)];
    CGRect baseCGWindowBounds = CGRectZero;
    if (baseCGMetadata == nil ||
        ![baseCGMetadata[@"onscreen"] boolValue] ||
        !IOSUseScreenshotRectFromJSON(
            baseCGMetadata[@"bounds"],
            &baseCGWindowBounds
        )) {
        IOSUseScreenshotSetFailure(
            @"compositor_primary_geometry_invalid",
            @"primary AppKit window has no exact CGWindow bounds",
            failureCode,
            failureMessage
        );
        return nil;
    }
    for (IOSUseScreenshotNativeWindow *record
         in windowsByNumber.allValues) {
        if (!IOSUseScreenshotFiniteRect(record.frame) ||
            !isfinite(record.backingScale) ||
            record.backingScale < 1 ||
            record.backingScale > 4) {
            IOSUseScreenshotSetFailure(
                @"compositor_window_geometry_invalid",
                [NSString stringWithFormat:
                    @"visible AppKit window %u has invalid geometry or "
                    @"backing scale",
                    record.windowNumber
                ],
                failureCode,
                failureMessage
            );
            return nil;
        }
        NSDictionary *metadata =
            cgMetadata[@(record.windowNumber)];
        if (metadata == nil ||
            ![metadata[@"onscreen"] boolValue]) {
            IOSUseScreenshotSetFailure(
                @"compositor_window_not_onscreen",
                [NSString stringWithFormat:
                    @"visible AppKit window %u has no exact own-process "
                    @"CGWindow onscreen metadata",
                    record.windowNumber
                ],
                failureCode,
                failureMessage
            );
            return nil;
        }
        CGRect cgBounds = CGRectZero;
        if (!IOSUseScreenshotRectFromJSON(
                metadata[@"bounds"],
                &cgBounds
            )) {
            IOSUseScreenshotSetFailure(
                @"compositor_window_geometry_invalid",
                [NSString stringWithFormat:
                    @"visible AppKit window %u has no exact CGWindow "
                    @"bounds",
                    record.windowNumber
                ],
                failureCode,
                failureMessage
            );
            return nil;
        }
        CGRect deviceLogicalRect = CGRectZero;
        NSString *relativeFailure = nil;
        if (!IOSUsePlayValidateRelativeWindowGeometry(
                baseFrame,
                baseCGWindowBounds,
                record.frame,
                cgBounds,
                &deviceLogicalRect,
                &relativeFailure
            )) {
            IOSUseScreenshotSetFailure(
                @"compositor_window_geometry_mismatch",
                [NSString stringWithFormat:
                    @"visible AppKit window %u geometry mismatch: %@",
                    record.windowNumber,
                    relativeFailure ?:
                        @"AppKit/CGWindow geometry is inconsistent"
                ],
                failureCode,
                failureMessage
            );
            return nil;
        }
        record.cgWindowBounds = cgBounds;
        record.deviceLogicalRect = deviceLogicalRect;
        record.cgFrontToBackIndex =
            [metadata[@"frontToBackIndex"] unsignedIntegerValue];
        record.cgWindowLayer =
            [metadata[@"layer"] integerValue];
        NSUInteger orderedIndex =
            [orderedWindows indexOfObjectIdenticalTo:
                record.appKitWindow];
        record.orderedWindowsIndex =
            orderedIndex == NSNotFound
                ? -1
                : (NSInteger)orderedIndex;
    }
    NSArray<IOSUseScreenshotNativeWindow *> *records =
        [windowsByNumber.allValues
            sortedArrayUsingComparator:^NSComparisonResult(
                IOSUseScreenshotNativeWindow *left,
                IOSUseScreenshotNativeWindow *right
            ) {
                if (left.cgFrontToBackIndex <
                    right.cgFrontToBackIndex) {
                    return NSOrderedAscending;
                }
                if (left.cgFrontToBackIndex >
                    right.cgFrontToBackIndex) {
                    return NSOrderedDescending;
                }
                if (left.windowNumber < right.windowNumber) {
                    return NSOrderedAscending;
                }
                if (left.windowNumber > right.windowNumber) {
                    return NSOrderedDescending;
                }
                return NSOrderedSame;
            }];
    for (NSUInteger index = 1; index < records.count; index += 1) {
        if (records[index - 1].cgFrontToBackIndex ==
            records[index].cgFrontToBackIndex) {
            IOSUseScreenshotSetFailure(
                @"compositor_z_order_ambiguous",
                @"two own-process windows share one CGWindow order index",
                failureCode,
                failureMessage
            );
            return nil;
        }
    }
    if (!IOSUseScreenshotValidateChildOrder(
            records,
            windowsByNumber,
            failureCode,
            failureMessage
        )) {
        return nil;
    }
    if (baseWindowNumber != NULL) {
        *baseWindowNumber = baseRecord.windowNumber;
    }
    if (deviceFrame != NULL) {
        *deviceFrame = CGRectMake(
            0,
            0,
            IOSUsePlayDeviceLogicalWidth,
            IOSUsePlayDeviceLogicalHeight
        );
    }
    return records;
}

static BOOL IOSUseScreenshotHasUsablePixels(CGImageRef image) {
    if (image == NULL ||
        CGImageGetWidth(image) == 0 ||
        CGImageGetHeight(image) == 0) {
        return NO;
    }
    size_t sampleWidth = 64;
    size_t sampleHeight = 64;
    size_t rowBytes = sampleWidth * 4;
    uint8_t pixels[64 * 64 * 4] = {0};
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (colorSpace == NULL) {
        return NO;
    }
    CGContextRef context = CGBitmapContextCreate(
        pixels,
        sampleWidth,
        sampleHeight,
        8,
        rowBytes,
        colorSpace,
        kCGBitmapByteOrder32Little |
            kCGImageAlphaPremultipliedFirst
    );
    CGColorSpaceRelease(colorSpace);
    if (context == NULL) {
        return NO;
    }
    CGContextDrawImage(
        context,
        CGRectMake(0, 0, sampleWidth, sampleHeight),
        image
    );
    CGContextRelease(context);
    NSUInteger nontransparent = 0;
    for (NSUInteger index = 0;
         index < sampleWidth * sampleHeight;
         index += 1) {
        nontransparent += pixels[index * 4 + 3] > 0 ? 1 : 0;
    }
    // A solid-color app is a valid screenshot. Completeness comes from the
    // per-window proof and system-chrome verification, not color variance.
    return nontransparent > sampleWidth * sampleHeight / 2;
}

static NSDictionary<NSString *, id> *
IOSUseScreenshotCompositorEvidence(
    NSArray<IOSUseScreenshotNativeWindow *> *windows,
    NSArray<NSDictionary<NSString *, id> *> *sourceEvidence,
    uint32_t baseWindowNumber,
    CGRect deviceFrame,
    NSUInteger visibleUIKitWindowCount,
    NSUInteger mappedUIKitWindowCount,
    NSUInteger capturedWindowCount,
    BOOL systemChromeMapped
) {
    NSMutableArray<NSDictionary<NSString *, id> *> *windowEvidence =
        [NSMutableArray arrayWithCapacity:windows.count];
    for (NSUInteger index = 0; index < windows.count; index += 1) {
        IOSUseScreenshotNativeWindow *window = windows[index];
        NSDictionary *geometry = index < sourceEvidence.count
            ? sourceEvidence[index]
            : @{};
        [windowEvidence addObject:@{
            @"windowNumber": @(window.windowNumber),
            @"class": NSStringFromClass(
                [window.appKitWindow class]
            ),
            @"frontToBackIndex": @(index),
            @"cgFrontToBackIndex":
                @(window.cgFrontToBackIndex),
            @"cgWindowLayer": @(window.cgWindowLayer),
            @"appKitLevel": @(window.appKitLevel),
            @"orderedWindowsIndex":
                @(window.orderedWindowsIndex),
            @"parentWindowNumber":
                @(window.parentWindowNumber),
            @"frame": IOSUseScreenshotRectJSON(window.frame),
            @"cgWindowBounds":
                IOSUseScreenshotRectJSON(
                    window.cgWindowBounds
                ),
            @"deviceLogicalRect":
                IOSUseScreenshotRectJSON(
                    window.deviceLogicalRect
                ),
            @"backingScaleFactor": @(window.backingScale),
            @"mappedUIKitWindowCount":
                @(window.uiWindowEvidence.count),
            @"uiWindows": window.uiWindowEvidence,
            @"containsSystemChrome":
                @(window.containsSystemChrome),
            @"captureGeometry": geometry,
        }];
    }
    return @{
        @"source": @"cgshw-own-process-window-list",
        @"complete": @YES,
        @"zOrder":
            @"CGWindowListCopyWindowInfo.front-to-back",
        @"windowCount": @(windows.count),
        @"visibleUIKitWindowCount":
            @(visibleUIKitWindowCount),
        @"mappedUIKitWindowCount":
            @(mappedUIKitWindowCount),
        @"requestedWindowCount": @(windows.count),
        @"capturedWindowCount": @(capturedWindowCount),
        @"baseWindowNumber": @(baseWindowNumber),
        @"deviceFrame": IOSUseScreenshotRectJSON(deviceFrame),
        @"windows": windowEvidence,
        @"completeness": @{
            @"allVisibleUIKitWindowsMapped": @(
                (BOOL)(
                    visibleUIKitWindowCount ==
                        mappedUIKitWindowCount
                )
            ),
            @"allVisibleNativeWindowsOrdered": @YES,
            @"requestedCapturedCountMatch": @(
                (BOOL)(windows.count == capturedWindowCount)
            ),
            @"baseWindowCoversDevice": @YES,
            @"systemChromeMapped": @(systemChromeMapped),
            @"allWindowGeometryInsideDevice": @YES,
            @"appKitCGWindowSizesMatch": @YES,
            @"cgWindowPlacementAuthoritative": @YES,
            @"windowSetStableDuringCapture": @YES,
        },
    };
}

static IOSUsePlayWindowPlanEntry *
IOSUseScreenshotCopyWindowPlan(
    NSArray<IOSUseScreenshotNativeWindow *> *windows
) {
    if (windows.count == 0) {
        return NULL;
    }
    IOSUsePlayWindowPlanEntry *entries = calloc(
        windows.count,
        sizeof(IOSUsePlayWindowPlanEntry)
    );
    if (entries == NULL) {
        return NULL;
    }
    for (NSUInteger index = 0; index < windows.count; index += 1) {
        IOSUseScreenshotNativeWindow *window = windows[index];
        entries[index] = (IOSUsePlayWindowPlanEntry){
            .windowNumber = window.windowNumber,
            .appKitFrame = window.frame,
            .cgWindowBounds = window.cgWindowBounds,
            .backingScale = window.backingScale,
        };
    }
    return entries;
}

static CGImageRef IOSUseScreenshotCaptureFrameOnMain(
    NSDictionary<NSString *, id> **compositorEvidence,
    NSDictionary<NSString *, id> **appKitWindowEvidence,
    NSDictionary<NSString *, id> **systemChromeEvidence,
    unsigned long long *captureGeneration,
    NSString **failureCode,
    NSString **failureMessage
) CF_RETURNS_RETAINED {
    NSCAssert(NSThread.isMainThread, @"screenshot capture is main-only");
    NSError *windowError = nil;
    if (![IOSUsePlayAppKitBridge
            configureFixedWindow:&windowError]) {
        IOSUseScreenshotSetFailure(
            @"window_geometry_unavailable",
            windowError.localizedDescription ?:
                @"AppKit window is not the fixed logical device screen",
            failureCode,
            failureMessage
        );
        return NULL;
    }
    NSDictionary<NSString *, id> *windowEvidence =
        [IOSUsePlayAppKitBridge diagnostics];
    if (![windowEvidence[@"identityTransform"] boolValue] ||
        ![windowEvidence[@"status"]
            isEqualToString:@"configured"]) {
        IOSUseScreenshotSetFailure(
            @"window_geometry_unavailable",
            @"AppKit logical geometry is not capture-ready",
            failureCode,
            failureMessage
        );
        return NULL;
    }
    IOSUsePlaySystemChromeInstall();
    NSDictionary<NSString *, id> *chrome =
        IOSUsePlaySystemChromeDiagnostics();
    BOOL chromeSurfaces =
        [chrome[@"dynamicIslandSurface"] boolValue] &&
        [chrome[@"statusSurface"] boolValue] &&
        [chrome[@"homeIndicatorSurface"] boolValue] &&
        [chrome[@"passthrough"] boolValue] &&
        [chrome[@"safeAreaReady"] boolValue];
    if (!chromeSurfaces) {
        IOSUseScreenshotSetFailure(
            @"system_chrome_unavailable",
            @"independent system-chrome surfaces are not compositor-ready",
            failureCode,
            failureMessage
        );
        return NULL;
    }

    static IOSUseCGSMainConnectionID mainConnection;
    static IOSUseCGSHWCaptureWindowList captureWindows;
    static IOSUseCGWindowListCopyWindowInfo copyWindowInfo;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *skyLight = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_NOW | RTLD_LOCAL
        );
        void *scope = skyLight ?: RTLD_DEFAULT;
        mainConnection = (IOSUseCGSMainConnectionID)dlsym(
            scope,
            "CGSMainConnectionID"
        );
        captureWindows =
            (IOSUseCGSHWCaptureWindowList)dlsym(
                scope,
                "CGSHWCaptureWindowList"
            );
        if (captureWindows == NULL) {
            captureWindows =
                (IOSUseCGSHWCaptureWindowList)dlsym(
                    scope,
                    "SLSHWCaptureWindowList"
                );
        }
        copyWindowInfo =
            (IOSUseCGWindowListCopyWindowInfo)dlsym(
                RTLD_DEFAULT,
                "CGWindowListCopyWindowInfo"
            );
    });
    if (mainConnection == NULL ||
        captureWindows == NULL) {
        IOSUseScreenshotSetFailure(
            @"compositor_api_unavailable",
            @"CGSHW own-window compositor API is unavailable",
            failureCode,
            failureMessage
        );
        return NULL;
    }

    uint32_t baseWindowNumber = 0;
    CGRect deviceFrame = CGRectZero;
    NSUInteger visibleUIKitWindowCount = 0;
    NSUInteger mappedUIKitWindowCount = 0;
    BOOL systemChromeMapped = NO;
    NSArray<IOSUseScreenshotNativeWindow *> *windows =
        IOSUseScreenshotCollectNativeWindows(
            copyWindowInfo,
            &baseWindowNumber,
            &deviceFrame,
            &visibleUIKitWindowCount,
            &mappedUIKitWindowCount,
            &systemChromeMapped,
            failureCode,
            failureMessage
        );
    if (windows == nil || windows.count == 0) {
        if (failureCode != NULL && *failureCode == nil) {
            IOSUseScreenshotSetFailure(
                @"compositor_window_unavailable",
                @"no complete own-process window capture plan exists",
                failureCode,
                failureMessage
            );
        }
        return NULL;
    }
    CGImageRef *capturedImages = calloc(
        windows.count,
        sizeof(CGImageRef)
    );
    if (capturedImages == NULL) {
        IOSUseScreenshotSetFailure(
            @"compositor_capture_failed",
            @"could not allocate own-window capture list",
            failureCode,
            failureMessage
        );
        return NULL;
    }
    NSUInteger capturedCount = 0;
    for (NSUInteger index = 0; index < windows.count; index += 1) {
        uint32_t windowID = windows[index].windowNumber;
        CFArrayRef response = captureWindows(
            mainConnection(),
            &windowID,
            1,
            IOSUseCGSHWIgnoreGlobalClipShape |
                IOSUseCGSHWBestResolution |
                IOSUseCGSHWFullSize
        );
        NSString *captureFailure = nil;
        BOOL countMatches =
            IOSUsePlayValidateCapturedWindowCount(
                1,
                response,
                &captureFailure
            );
        CGImageRef source = countMatches
            ? (CGImageRef)CFArrayGetValueAtIndex(response, 0)
            : NULL;
        if (!countMatches ||
            source == NULL ||
            CFGetTypeID(source) != CGImageGetTypeID()) {
            if (response != NULL) {
                CFRelease(response);
            }
            for (NSUInteger releaseIndex = 0;
                 releaseIndex < capturedCount;
                 releaseIndex += 1) {
                CGImageRelease(capturedImages[releaseIndex]);
            }
            free(capturedImages);
            IOSUseScreenshotSetFailure(
                @"compositor_capture_incomplete",
                [NSString stringWithFormat:
                    @"CGSHW window %u capture failed: %@",
                    windowID,
                    captureFailure ?:
                        @"response is not exactly one CGImage"
                ],
                failureCode,
                failureMessage
            );
            return NULL;
        }
        capturedImages[index] = CGImageRetain(source);
        capturedCount += 1;
        CFRelease(response);
    }
    uint32_t postBaseWindowNumber = 0;
    CGRect postDeviceFrame = CGRectZero;
    NSUInteger postVisibleUIKitWindowCount = 0;
    NSUInteger postMappedUIKitWindowCount = 0;
    BOOL postSystemChromeMapped = NO;
    NSArray<IOSUseScreenshotNativeWindow *> *postWindows =
        IOSUseScreenshotCollectNativeWindows(
            copyWindowInfo,
            &postBaseWindowNumber,
            &postDeviceFrame,
            &postVisibleUIKitWindowCount,
            &postMappedUIKitWindowCount,
            &postSystemChromeMapped,
            failureCode,
            failureMessage
        );
    IOSUsePlayWindowPlanEntry *beforePlan =
        IOSUseScreenshotCopyWindowPlan(windows);
    IOSUsePlayWindowPlanEntry *afterPlan = postWindows == nil
        ? NULL
        : IOSUseScreenshotCopyWindowPlan(postWindows);
    NSString *planFailure = nil;
    BOOL planStable =
        beforePlan != NULL &&
        afterPlan != NULL &&
        postVisibleUIKitWindowCount ==
            visibleUIKitWindowCount &&
        postMappedUIKitWindowCount ==
            mappedUIKitWindowCount &&
        postSystemChromeMapped == systemChromeMapped &&
        IOSUsePlayWindowCapturePlansEqual(
            beforePlan,
            windows.count,
            baseWindowNumber,
            afterPlan,
            postWindows.count,
            postBaseWindowNumber,
            &planFailure
        );
    free(beforePlan);
    free(afterPlan);
    if (!planStable) {
        for (NSUInteger index = 0;
             index < capturedCount;
             index += 1) {
            CGImageRelease(capturedImages[index]);
        }
        free(capturedImages);
        if (postWindows != nil) {
            IOSUseScreenshotSetFailure(
                @"compositor_window_set_changed",
                planFailure ?:
                    @"own-process window set, z-order, AppKit frame, or "
                    @"CGWindow bounds changed during capture",
                failureCode,
                failureMessage
            );
        }
        return NULL;
    }

    IOSUsePlayWindowCapture *captures = calloc(
        windows.count,
        sizeof(IOSUsePlayWindowCapture)
    );
    if (captures == NULL) {
        for (NSUInteger index = 0;
             index < capturedCount;
             index += 1) {
            CGImageRelease(capturedImages[index]);
        }
        free(capturedImages);
        IOSUseScreenshotSetFailure(
            @"compositor_capture_failed",
            @"could not allocate compositor source metadata",
            failureCode,
            failureMessage
        );
        return NULL;
    }
    for (NSUInteger index = 0; index < windows.count; index += 1) {
        IOSUseScreenshotNativeWindow *window = windows[index];
        captures[index] = (IOSUsePlayWindowCapture){
            .image = capturedImages[index],
            .appKitFrame = window.frame,
            .deviceLogicalRect =
                window.deviceLogicalRect,
            .backingScale = window.backingScale,
            .windowNumber = window.windowNumber,
        };
    }
    NSArray<NSDictionary<NSString *, id> *> *sourceEvidence = nil;
    NSString *compositeFailure = nil;
    CGImageRef image = IOSUsePlayCompositeWindowCaptures(
        captures,
        windows.count,
        deviceFrame,
        baseWindowNumber,
        &sourceEvidence,
        &compositeFailure
    );
    free(captures);
    for (NSUInteger index = 0;
         index < capturedCount;
         index += 1) {
        CGImageRelease(capturedImages[index]);
    }
    free(capturedImages);
    if (image == NULL ||
        CGImageGetWidth(image) != IOSUsePlayDeviceNativeWidth ||
        CGImageGetHeight(image) != IOSUsePlayDeviceNativeHeight ||
        !IOSUseScreenshotHasUsablePixels(image)) {
        if (image != NULL) {
            CGImageRelease(image);
        }
        IOSUseScreenshotSetFailure(
            @"invalid_screenshot",
            compositeFailure ?:
                @"own-window compositor pixels are empty or incomplete",
            failureCode,
            failureMessage
        );
        return NULL;
    }
    NSString *chromeFailure = nil;
    if (!IOSUsePlaySystemChromeVerifyImage(
            image,
            &chromeFailure
        )) {
        CGImageRelease(image);
        IOSUseScreenshotSetFailure(
            @"incomplete_compositor",
            chromeFailure ?:
                @"compositor omitted a required system-chrome surface",
            failureCode,
            failureMessage
        );
        return NULL;
    }
    chrome = IOSUsePlaySystemChromeDiagnostics();
    NSDictionary<NSString *, id> *verifiedImageEvidence =
        [chrome[@"lastImageEvidence"]
            isKindOfClass:NSDictionary.class]
            ? chrome[@"lastImageEvidence"]
            : nil;
    if (![verifiedImageEvidence[@"ready"] boolValue]) {
        CGImageRelease(image);
        IOSUseScreenshotSetFailure(
            @"incomplete_compositor",
            @"verified system-chrome evidence is unavailable for the "
            @"captured frame",
            failureCode,
            failureMessage
        );
        return NULL;
    }
    unsigned long long generation =
        atomic_fetch_add(
            &IOSUseScreenshotCaptureGeneration,
            1
        ) + 1;
    if (captureGeneration != NULL) {
        *captureGeneration = generation;
    }
    if (compositorEvidence != NULL) {
        *compositorEvidence =
            IOSUseScreenshotCompositorEvidence(
                windows,
                sourceEvidence ?: @[],
                baseWindowNumber,
                deviceFrame,
                visibleUIKitWindowCount,
                mappedUIKitWindowCount,
                capturedCount,
                systemChromeMapped
            );
    }
    if (appKitWindowEvidence != NULL) {
        *appKitWindowEvidence = windowEvidence;
    }
    if (systemChromeEvidence != NULL) {
        *systemChromeEvidence = chrome;
    }
    return image;
}

static NSDictionary<NSString *, id> *
IOSUseScreenshotPayloadOnMain(
    NSString **failureCode,
    NSString **failureMessage
) {
    NSDictionary<NSString *, id> *compositor = nil;
    NSDictionary<NSString *, id> *windowEvidence = nil;
    NSDictionary<NSString *, id> *chromeEvidence = nil;
    unsigned long long generation = 0;
    CGImageRef image = IOSUseScreenshotCaptureFrameOnMain(
        &compositor,
        &windowEvidence,
        &chromeEvidence,
        &generation,
        failureCode,
        failureMessage
    );
    if (image == NULL) {
        return nil;
    }
    UIImage *uiImage = [UIImage imageWithCGImage:image
                                          scale:IOSUsePlayDeviceScale
                                    orientation:UIImageOrientationUp];
    CGImageRelease(image);
    NSData *jpeg = UIImageJPEGRepresentation(uiImage, 0.9);
    if (jpeg.length == 0 ||
        jpeg.length > IOSUseScreenshotMaximumJPEGBytes) {
        IOSUseScreenshotSetFailure(
            @"screenshot_too_large",
            @"compositor JPEG is empty or exceeds 11 MiB",
            failureCode,
            failureMessage
        );
        return nil;
    }
    NSString *base64 = [jpeg base64EncodedStringWithOptions:0];
    if (base64.length == 0 ||
        [base64 lengthOfBytesUsingEncoding:NSUTF8StringEncoding] >
            IOSUseScreenshotMaximumBase64Bytes) {
        IOSUseScreenshotSetFailure(
            @"screenshot_too_large",
            @"base64 compositor screenshot exceeds 15 MiB",
            failureCode,
            failureMessage
        );
        return nil;
    }
    NSArray *windows = compositor[@"windows"] ?: @[];
    NSMutableArray<NSNumber *> *windowNumbers =
        [NSMutableArray arrayWithCapacity:windows.count];
    NSMutableArray<NSDictionary<NSString *, NSNumber *> *> *sizes =
        [NSMutableArray arrayWithCapacity:windows.count];
    for (NSDictionary *window in windows) {
        NSNumber *number = window[@"windowNumber"];
        NSDictionary *geometry = window[@"captureGeometry"];
        NSNumber *width = geometry[@"sourcePixelWidth"];
        NSNumber *height = geometry[@"sourcePixelHeight"];
        if (number != nil) {
            [windowNumbers addObject:number];
        }
        if (width != nil && height != nil) {
            [sizes addObject:@{
                @"width": width,
                @"height": height,
            }];
        }
    }
    return @{
        @"jpegBase64": base64,
        @"pixelWidth": @(IOSUsePlayDeviceNativeWidth),
        @"pixelHeight": @(IOSUsePlayDeviceNativeHeight),
        @"logicalWidth": @(IOSUsePlayDeviceLogicalWidth),
        @"logicalHeight": @(IOSUsePlayDeviceLogicalHeight),
        @"scale": @(IOSUsePlayDeviceScale),
        @"source": @"window-compositor",
        @"complete": @YES,
        @"captureGeneration": @(generation),
        @"compositorWindowNumbers": windowNumbers,
        @"sourceBackingSizes": sizes,
        @"compositor": compositor ?: @{},
        @"appKitWindowEvidence": windowEvidence ?: @{},
        @"systemChromeEvidence": chromeEvidence ?: @{},
    };
}

static BOOL IOSUseScreenshotTransientCaptureFailure(
    NSString *failureCode
) {
    return [@[
        @"window_geometry_unavailable",
        @"system_chrome_unavailable",
        @"compositor_primary_window_unavailable",
        @"compositor_primary_window_unmapped",
        @"compositor_primary_geometry_invalid",
        @"compositor_window_set_changed",
        @"compositor_capture_incomplete",
        @"incomplete_compositor",
    ] containsObject:failureCode ?: @""];
}

static const NSUInteger IOSUseScreenshotSettlingAttemptLimit = 8;

static void IOSUseScreenshotPumpMainRunLoop(
    NSTimeInterval duration
) {
    CFAbsoluteTime deadline =
        CFAbsoluteTimeGetCurrent() + MAX(0.001, duration);
    do {
        CFRunLoopRunInMode(
            kCFRunLoopDefaultMode,
            MIN(
                0.01,
                MAX(
                    0.001,
                    deadline - CFAbsoluteTimeGetCurrent()
                )
            ),
            true
        );
    } while (CFAbsoluteTimeGetCurrent() < deadline);
}

static NSDictionary<NSString *, id> *
IOSUseScreenshotPayloadWithSettlingOnMain(
    NSString **failureCode,
    NSString **failureMessage
) {
    NSString *lastCode = nil;
    NSString *lastMessage = nil;
    for (
        NSUInteger attempt = 0;
        attempt < IOSUseScreenshotSettlingAttemptLimit;
        attempt += 1
    ) {
        NSString *attemptCode = nil;
        NSString *attemptMessage = nil;
        NSDictionary<NSString *, id> *payload =
            IOSUseScreenshotPayloadOnMain(
                &attemptCode,
                &attemptMessage
            );
        if (payload != nil) {
            return payload;
        }
        lastCode = attemptCode;
        lastMessage = attemptMessage;
        if (attempt + 1 == IOSUseScreenshotSettlingAttemptLimit ||
            !IOSUseScreenshotTransientCaptureFailure(
                attemptCode
            )) {
            break;
        }
        IOSUseScreenshotPumpMainRunLoop(
            0.05 * (attempt + 1)
        );
    }
    IOSUseScreenshotSetFailure(
        lastCode ?: @"screenshot_unavailable",
        lastMessage ?: @"own-window compositor capture failed",
        failureCode,
        failureMessage
    );
    return nil;
}

static NSDictionary<NSString *, id> *
IOSUseScreenshotFingerprintOnMain(
    CGRect logicalRect,
    NSString **failureCode,
    NSString **failureMessage
) {
    if (!IOSUseScreenshotLogicalRectIsInsideDevice(logicalRect)) {
        IOSUseScreenshotSetFailure(
            @"invalid_fingerprint_rect",
            [NSString stringWithFormat:
                @"fingerprint rect must be finite, non-empty, and "
                @"completely inside the %ldx%ld logical device",
                (long)IOSUsePlayDeviceLogicalWidth,
                (long)IOSUsePlayDeviceLogicalHeight
            ],
            failureCode,
            failureMessage
        );
        return nil;
    }
    NSDictionary<NSString *, id> *compositor = nil;
    unsigned long long generation = 0;
    CGImageRef image = IOSUseScreenshotCaptureFrameOnMain(
        &compositor,
        NULL,
        NULL,
        &generation,
        failureCode,
        failureMessage
    );
    if (image == NULL) {
        return nil;
    }
    NSString *fingerprintFailure = nil;
    NSDictionary<NSString *, id> *fingerprint =
        IOSUsePlayFingerprintCompositorImage(
        image,
        logicalRect,
        &fingerprintFailure
    );
    CGImageRelease(image);
    if (fingerprint == nil) {
        IOSUseScreenshotSetFailure(
            @"fingerprint_failed",
            fingerprintFailure ?:
                @"could not fingerprint complete compositor pixels",
            failureCode,
            failureMessage
        );
        return nil;
    }
    NSMutableDictionary<NSString *, id> *result =
        [fingerprint mutableCopy];
    [result addEntriesFromDictionary:@{
        @"captureGeneration": @(generation),
        @"source": @"window-compositor",
        @"complete": @YES,
        @"compositor": compositor ?: @{},
    }];
    return result;
}

static NSDictionary<NSString *, id> *
IOSUseScreenshotFingerprintWithSettlingOnMain(
    CGRect logicalRect,
    NSString **failureCode,
    NSString **failureMessage
) {
    NSString *lastCode = nil;
    NSString *lastMessage = nil;
    for (
        NSUInteger attempt = 0;
        attempt < IOSUseScreenshotSettlingAttemptLimit;
        attempt += 1
    ) {
        NSString *attemptCode = nil;
        NSString *attemptMessage = nil;
        NSDictionary<NSString *, id> *fingerprint =
            IOSUseScreenshotFingerprintOnMain(
                logicalRect,
                &attemptCode,
                &attemptMessage
            );
        if (fingerprint != nil) {
            return fingerprint;
        }
        lastCode = attemptCode;
        lastMessage = attemptMessage;
        if (attempt + 1 == IOSUseScreenshotSettlingAttemptLimit ||
            !IOSUseScreenshotTransientCaptureFailure(
                attemptCode
            )) {
            break;
        }
        IOSUseScreenshotPumpMainRunLoop(
            0.05 * (attempt + 1)
        );
    }
    IOSUseScreenshotSetFailure(
        lastCode ?: @"fingerprint_unavailable",
        lastMessage ?: @"own-window compositor fingerprint failed",
        failureCode,
        failureMessage
    );
    return nil;
}

typedef NSDictionary<NSString *, id> * _Nullable
(^IOSUseScreenshotMainOperation)(
    NSString * _Nullable * _Nullable,
    NSString * _Nullable * _Nullable
);

static NSDictionary<NSString *, id> *
IOSUseScreenshotRunMainOperation(
    IOSUseScreenshotMainOperation operation,
    NSString **failureCode,
    NSString **failureMessage
) {
    if (failureCode != NULL) {
        *failureCode = nil;
    }
    if (failureMessage != NULL) {
        *failureMessage = nil;
    }
    bool expected = false;
    if (!atomic_compare_exchange_strong(
            &IOSUseScreenshotInFlight,
            &expected,
            true
        )) {
        IOSUseScreenshotSetFailure(
            @"screenshot_busy",
            @"another compositor capture is already running",
            failureCode,
            failureMessage
        );
        return nil;
    }
    if (NSThread.isMainThread) {
        NSDictionary *result = nil;
        @try {
            result = operation(
                failureCode,
                failureMessage
            );
        } @catch (NSException *exception) {
            IOSUseScreenshotSetFailure(
                @"screenshot_exception",
                [NSString stringWithFormat:
                    @"compositor capture raised %@",
                    exception.name
                ],
                failureCode,
                failureMessage
            );
        } @finally {
            atomic_store(&IOSUseScreenshotInFlight, false);
        }
        return result;
    }

    __block NSDictionary *result = nil;
    __block NSString *blockCode = nil;
    __block NSString *blockMessage = nil;
    dispatch_semaphore_t completion = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            @try {
                result = operation(
                    &blockCode,
                    &blockMessage
                );
            } @catch (NSException *exception) {
                blockCode = @"screenshot_exception";
                blockMessage = [NSString stringWithFormat:
                    @"compositor capture raised %@",
                    exception.name
                ];
            } @finally {
                atomic_store(&IOSUseScreenshotInFlight, false);
                dispatch_semaphore_signal(completion);
            }
        }
    });
    dispatch_time_t deadline = dispatch_time(
        DISPATCH_TIME_NOW,
        (int64_t)(
            IOSUseScreenshotMainThreadTimeoutSeconds * NSEC_PER_SEC
        )
    );
    if (dispatch_semaphore_wait(completion, deadline) != 0) {
        IOSUseScreenshotSetFailure(
            @"main_thread_timeout",
            @"compositor capture exceeded its main-thread deadline",
            failureCode,
            failureMessage
        );
        return nil;
    }
    if (result == nil) {
        IOSUseScreenshotSetFailure(
            blockCode ?: @"screenshot_unavailable",
            blockMessage ?: @"own-window compositor capture failed",
            failureCode,
            failureMessage
        );
    }
    return result;
}

NSDictionary<NSString *, id> *IOSUsePlayRuntimeScreenshotCommand(
    NSString **failureCode,
    NSString **failureMessage
) {
    return IOSUseScreenshotRunMainOperation(
        ^NSDictionary<NSString *, id> *(
        NSString **blockFailureCode,
        NSString **blockFailureMessage
    ) {
            return IOSUseScreenshotPayloadWithSettlingOnMain(
                blockFailureCode,
                blockFailureMessage
            );
        },
        failureCode,
        failureMessage
    );
}

NSDictionary<NSString *, id> *
IOSUsePlayRuntimeScreenshotFingerprint(
    CGRect logicalRect,
    NSString **failureCode,
    NSString **failureMessage
) {
    return IOSUseScreenshotRunMainOperation(
        ^NSDictionary<NSString *, id> *(
            NSString **blockFailureCode,
            NSString **blockFailureMessage
        ) {
            return IOSUseScreenshotFingerprintWithSettlingOnMain(
                logicalRect,
                blockFailureCode,
                blockFailureMessage
            );
        },
        failureCode,
        failureMessage
    );
}
