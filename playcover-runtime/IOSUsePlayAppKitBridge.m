#import "IOSUsePlayAppKitBridge.h"
#import "IOSUsePlayDevice.h"
#import "IOSUsePlayHookRegistry.h"
#import "IOSUsePlaySafeAreaCompatibility.h"
#import "IOSUsePlayWindowCompositor.h"

#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

static const CGFloat IOSUseBridgeDeviceLogicalWidth =
    (CGFloat)IOSUsePlayDeviceLogicalWidth;
static const CGFloat IOSUseBridgeDeviceLogicalHeight =
    (CGFloat)IOSUsePlayDeviceLogicalHeight;

typedef id (*IOSUseBridgeSendID)(id, SEL);
typedef id (*IOSUseBridgeSendIDInteger)(id, SEL, NSInteger);
typedef BOOL (*IOSUseBridgeSendBool)(id, SEL);
typedef NSInteger (*IOSUseBridgeSendInteger)(id, SEL);
typedef CGFloat (*IOSUseBridgeSendFloat)(id, SEL);
typedef CGPoint (*IOSUseBridgeSendPoint)(id, SEL);
typedef CGPoint (*IOSUseBridgeSendPointPointID)(id, SEL, CGPoint, id);
typedef CGRect (*IOSUseBridgeSendRect)(id, SEL);
typedef CGRect (*IOSUseBridgeSendRectRect)(id, SEL, CGRect);
typedef CGRect (*IOSUseBridgeSendRectRectID)(id, SEL, CGRect, id);
typedef CGSize (*IOSUseBridgeSendSize)(id, SEL);
typedef CGSize (*IOSUseBridgeSendProposedSize)(
    id,
    SEL,
    CGSize,
    NSUInteger
);
typedef NSUInteger (*IOSUseBridgeSendResizableEdges)(
    id,
    SEL,
    NSUInteger *,
    NSUInteger *
);
typedef SEL (*IOSUseBridgeSendSelector)(id, SEL);
typedef CGEventRef _Nullable (*IOSUseBridgeSendCGEvent)(id, SEL);
typedef id (*IOSUseBridgeSendIDRect)(id, SEL, CGRect);
typedef BOOL (*IOSUseBridgeSendAction)(
    id,
    SEL,
    SEL,
    id,
    id
);
typedef void (*IOSUseBridgeSendBoolArgument)(id, SEL, BOOL);
typedef void (*IOSUseBridgeSendVoid)(id, SEL);
typedef void (*IOSUseBridgeSendIDArgument)(id, SEL, id);
typedef void (*IOSUseBridgeSendIntegerArgument)(id, SEL, NSInteger);
typedef void (*IOSUseBridgeSendUnsignedIntegerArgument)(
    id,
    SEL,
    NSUInteger
);
typedef void (*IOSUseBridgeSendRectArgument)(id, SEL, CGRect);
typedef void (*IOSUseBridgeSendSizeArgument)(id, SEL, CGSize);
typedef id (*IOSUseBridgeSendIDUnsignedIntegerID)(
    id,
    SEL,
    NSUInteger,
    id
);
typedef CFArrayRef _Nullable (*IOSUseBridgeCGWindowListCopyWindowInfo)(
    CGWindowListOption,
    CGWindowID
);

#if defined(IOS_USE_PLAY_APPKIT_BRIDGE_TESTING)
typedef NSArray * _Nullable
    (*IOSUseBridgeNativeAlertWindowsProvider)(void);
static IOSUseBridgeCGWindowListCopyWindowInfo
    IOSUseBridgeCGWindowListCopyWindowInfoForTesting;
static IOSUseBridgeNativeAlertWindowsProvider
    IOSUseBridgeNativeAlertWindowsProviderForTesting;

void IOSUsePlayAppKitBridgeSetCGWindowListCopyWindowInfoForTesting(
    IOSUseBridgeCGWindowListCopyWindowInfo copyWindowInfo
);
void IOSUsePlayAppKitBridgeSetNativeAlertWindowsProviderForTesting(
    IOSUseBridgeNativeAlertWindowsProvider windowsProvider
);
NSDictionary<NSNumber *, NSDictionary<NSString *, id> *> * _Nullable
IOSUsePlayAppKitBridgeCopyOwnOnscreenCGWindowMetadataForTesting(void);
NSDictionary<NSString *, id> * _Nullable
IOSUsePlayAppKitBridgeSelectVisibleNativeAlertForTesting(
    NSArray * _Nullable windows,
    NSDictionary<
        NSNumber *,
        NSDictionary<NSString *, id> *
    > * _Nullable cgMetadata
);
#endif

static NSString *const IOSUsePlayWindowErrorDomain =
    @"io.ios-use.play-runtime.window";
static NSString *const IOSUsePlayNativeAlertErrorDomain =
    @"io.ios-use.play-runtime.native-alert";
static NSString *const IOSUsePlayAccessibilityBridgeErrorDomain =
    @"io.ios-use.play-runtime.appkit-accessibility";
static NSString *IOSUsePlayWindowStatus = @"not-configured";
static NSString *IOSUsePlayWindowFailure;
static NSUInteger IOSUsePlayWindowAttemptCount;
static NSString *IOSUsePlaySceneScaleStatus = @"not-configured";
static NSString *IOSUsePlaySceneScaleFailure;
static CGFloat IOSUsePlayObservedIdiomScale;
static CGFloat IOSUsePlayObservedWindowScale;
static BOOL IOSUsePlayObservedDownscale;
static BOOL IOSUsePlaySceneScaleBootstrapAttempted;
static BOOL IOSUsePlaySceneScaleBootstrapReady;
static NSDictionary<NSString *, id> *
    IOSUsePlayLastTextInputTransientDismissal;
static id IOSUsePlayMouseLocalMonitor;
static NSDictionary<NSString *, id> *IOSUsePlayLastMouseDelivery;
static NSDictionary<NSString *, id> *IOSUsePlayLastMouseDownDelivery;
static NSDictionary<NSString *, id> *IOSUsePlayLastMouseUpDelivery;
static NSUInteger IOSUsePlayMouseDeliveryCount;
static id IOSUsePlayHostWindow;
static id IOSUsePlayHostContentView;
static id IOSUsePlayScaleView;
static id IOSUsePlayCanvasView;
static IOSUsePlayHostCanvasLayout IOSUsePlayCurrentHostCanvasLayout;
static BOOL IOSUsePlayHostCanvasLayoutReady;
static BOOL IOSUsePlayHostCanvasLayoutUpdateScheduled;
static id IOSUsePlayBootstrapContentWindow;
static BOOL IOSUsePlayBootstrapContentReady;
static BOOL IOSUsePlayBootstrapContentNormalizationScheduled;
static NSUInteger IOSUsePlayBootstrapContentNormalizationAttempts;
static NSUInteger IOSUsePlayHostContentGeneration;
static Class IOSUsePlayResizableEdgesHookClass;
static Class IOSUsePlayResizeHookClass;
static IOSUseBridgeSendProposedSize IOSUsePlayOriginalProposedSize;
static NSString *IOSUsePlayHostTitle;
typedef NS_ENUM(NSUInteger, IOSUseBridgeSceneGeometryState) {
    IOSUseBridgeSceneGeometryStateNotRequested,
    IOSUseBridgeSceneGeometryStatePending,
    IOSUseBridgeSceneGeometryStateReady,
    IOSUseBridgeSceneGeometryStateFailed,
};
static UIWindowScene *IOSUsePlaySceneGeometryScene;
static IOSUseBridgeSceneGeometryState IOSUsePlaySceneGeometryState =
    IOSUseBridgeSceneGeometryStateNotRequested;
static NSString *IOSUsePlaySceneGeometryFailure;

static BOOL IOSUseBridgeUpdateHostCanvasLayout(
    id window,
    NSString **failure
);
static void IOSUseBridgeScheduleHostCanvasLayoutUpdate(void);
static UIWindow *IOSUseBridgeAutomationUIKitWindow(void);

static BOOL IOSUseBridgeLoadAppKit(void) {
    static void *appKitHandle;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        appKitHandle = dlopen(
            "/System/Library/Frameworks/AppKit.framework/AppKit",
            RTLD_NOW | RTLD_LOCAL
        );
    });
    return appKitHandle != NULL;
}

static UIWindow *IOSUseBridgeKeyUIKitWindow(void) {
    NSMutableArray<UIWindowScene *> *scenes =
        [NSMutableArray array];
    for (UIScene *scene in
         UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            (scene.activationState !=
                UISceneActivationStateForegroundActive &&
             scene.activationState !=
                UISceneActivationStateForegroundInactive)) {
            continue;
        }
        [scenes addObject:(UIWindowScene *)scene];
    }
    [scenes sortUsingComparator:^NSComparisonResult(
        UIWindowScene *left,
        UIWindowScene *right
    ) {
        if (left.activationState != right.activationState) {
            return left.activationState ==
                    UISceneActivationStateForegroundActive
                ? NSOrderedAscending
                : NSOrderedDescending;
        }
        NSString *leftIdentifier =
            left.session.persistentIdentifier ?: @"";
        NSString *rightIdentifier =
            right.session.persistentIdentifier ?: @"";
        return [leftIdentifier compare:rightIdentifier];
    }];
    for (UIWindowScene *scene in scenes) {
        for (UIWindow *window in scene.windows) {
            if (window.isKeyWindow) {
                return window;
            }
        }
    }
    return nil;
}

static id IOSUseBridgeApplication(void) {
    if (!IOSUseBridgeLoadAppKit()) {
        return nil;
    }
    Class applicationClass = NSClassFromString(@"NSApplication");
    SEL sharedSelector = NSSelectorFromString(@"sharedApplication");
    if (applicationClass == Nil ||
        ![(id)applicationClass respondsToSelector:sharedSelector]) {
        return nil;
    }
    return ((IOSUseBridgeSendID)objc_msgSend)(
        (id)applicationClass,
        sharedSelector
    );
}

static id IOSUseBridgeWindowForUIKitWindow(
    UIWindow *uiWindow,
    BOOL allowApplicationKeyWindowFallback
) {
    // Preserve pinned PlayTools' UIWindow.nsWindow lookup semantics: map the
    // UIKit window through NSApplication.windows[i].uiWindows first.  The
    // private `-[UIWindow nsWindow]` shortcut can return the inner
    // UINSFullScreenWindow (the 0.77 compatibility canvas) instead of the
    // visible host window.
    id application = IOSUseBridgeApplication();
    SEL windowsSelector = NSSelectorFromString(@"windows");
    SEL uiWindowsSelector = NSSelectorFromString(@"uiWindows");
    if (uiWindow != nil &&
        [application respondsToSelector:windowsSelector]) {
        id windows = ((IOSUseBridgeSendID)objc_msgSend)(
            application,
            windowsSelector
        );
        for (id candidate in
             [windows isKindOfClass:NSArray.class] ? windows : @[]) {
            if (![candidate respondsToSelector:uiWindowsSelector]) {
                continue;
            }
            id uiWindows = ((IOSUseBridgeSendID)objc_msgSend)(
                candidate,
                uiWindowsSelector
            );
            if ([uiWindows isKindOfClass:NSArray.class] &&
                [(NSArray *)uiWindows containsObject:uiWindow]) {
                return candidate;
            }
        }
    }
    SEL nsWindowSelector = NSSelectorFromString(@"nsWindow");
    if ([uiWindow respondsToSelector:nsWindowSelector]) {
        id window = ((IOSUseBridgeSendID)objc_msgSend)(
            uiWindow,
            nsWindowSelector
        );
        if (window != nil) {
            return window;
        }
    }
    if (!allowApplicationKeyWindowFallback) {
        return nil;
    }
    SEL keyWindowSelector = NSSelectorFromString(@"keyWindow");
    return [application respondsToSelector:keyWindowSelector]
        ? ((IOSUseBridgeSendID)objc_msgSend)(
            application,
            keyWindowSelector
        )
        : nil;
}

static id IOSUseBridgeSelectedWindow(void) {
    return IOSUseBridgeWindowForUIKitWindow(
        IOSUseBridgeAutomationUIKitWindow(),
        NO
    );
}

static CGRect IOSUseBridgeRect(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    return [object respondsToSelector:selector]
        ? ((IOSUseBridgeSendRect)objc_msgSend)(object, selector)
        : CGRectZero;
}

static BOOL IOSUseBridgeSetBool(
    id object,
    NSString *selectorName,
    BOOL value
) {
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) {
        return NO;
    }
    ((IOSUseBridgeSendBoolArgument)objc_msgSend)(
        object,
        selector,
        value
    );
    return YES;
}

static BOOL IOSUseBridgeSetInteger(
    id object,
    NSString *selectorName,
    NSInteger value
) {
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) {
        return NO;
    }
    ((IOSUseBridgeSendIntegerArgument)objc_msgSend)(
        object,
        selector,
        value
    );
    return YES;
}

static BOOL IOSUseBridgeSetUnsignedInteger(
    id object,
    NSString *selectorName,
    NSUInteger value
) {
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) {
        return NO;
    }
    ((IOSUseBridgeSendUnsignedIntegerArgument)objc_msgSend)(
        object,
        selector,
        value
    );
    return YES;
}

static BOOL IOSUseBridgeSetRect(
    id object,
    NSString *selectorName,
    CGRect value
) {
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) {
        return NO;
    }
    ((IOSUseBridgeSendRectArgument)objc_msgSend)(
        object,
        selector,
        value
    );
    return YES;
}

static BOOL IOSUseBridgeBool(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    return [object respondsToSelector:selector] &&
        ((IOSUseBridgeSendBool)objc_msgSend)(object, selector);
}

static NSInteger IOSUseBridgeInteger(
    id object,
    NSString *selectorName
) {
    SEL selector = NSSelectorFromString(selectorName);
    return [object respondsToSelector:selector]
        ? ((IOSUseBridgeSendInteger)objc_msgSend)(object, selector)
        : 0;
}

static CGDirectDisplayID IOSUseBridgeDisplayIDForScreen(id screen) {
    SEL deviceDescriptionSelector =
        NSSelectorFromString(@"deviceDescription");
    if (screen == nil ||
        ![screen respondsToSelector:deviceDescriptionSelector]) {
        return kCGNullDirectDisplay;
    }
    id rawDescription = ((IOSUseBridgeSendID)objc_msgSend)(
        screen,
        deviceDescriptionSelector
    );
    if (![rawDescription isKindOfClass:NSDictionary.class]) {
        return kCGNullDirectDisplay;
    }
    id rawDisplayID =
        ((NSDictionary *)rawDescription)[@"NSScreenNumber"];
    if (![rawDisplayID isKindOfClass:NSNumber.class] ||
        [rawDisplayID unsignedLongLongValue] == 0 ||
        [rawDisplayID unsignedLongLongValue] > UINT32_MAX) {
        return kCGNullDirectDisplay;
    }
    return (CGDirectDisplayID)[rawDisplayID unsignedIntValue];
}

static NSDictionary<
    NSNumber *,
    NSDictionary<NSString *, id> *
> *IOSUseBridgeOwnOnscreenCGWindowMetadata(void) {
    IOSUseBridgeCGWindowListCopyWindowInfo copyWindowInfo = NULL;
#if defined(IOS_USE_PLAY_APPKIT_BRIDGE_TESTING)
    copyWindowInfo =
        IOSUseBridgeCGWindowListCopyWindowInfoForTesting;
#endif
    static IOSUseBridgeCGWindowListCopyWindowInfo
        systemCopyWindowInfo;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        systemCopyWindowInfo =
            (IOSUseBridgeCGWindowListCopyWindowInfo)dlsym(
                RTLD_DEFAULT,
                "CGWindowListCopyWindowInfo"
            );
    });
    if (copyWindowInfo == NULL) {
        copyWindowInfo = systemCopyWindowInfo;
    }
    if (copyWindowInfo == NULL) {
        return nil;
    }
    CFArrayRef raw = copyWindowInfo(
        kCGWindowListOptionOnScreenOnly,
        kCGNullWindowID
    );
    if (raw == NULL ||
        CFGetTypeID(raw) != CFArrayGetTypeID()) {
        if (raw != NULL) {
            CFRelease(raw);
        }
        return nil;
    }
    NSArray *entries = CFBridgingRelease(raw);
    pid_t processID = getpid();
    NSMutableDictionary<
        NSNumber *,
        NSDictionary<NSString *, id> *
    > *metadata = [NSMutableDictionary dictionary];
    for (NSUInteger index = 0; index < entries.count; index += 1) {
        id candidate = entries[index];
        if (![candidate isKindOfClass:NSDictionary.class]) {
            continue;
        }
        NSDictionary *entry = candidate;
        NSNumber *owner =
            entry[(__bridge NSString *)kCGWindowOwnerPID];
        NSNumber *number =
            entry[(__bridge NSString *)kCGWindowNumber];
        NSNumber *onscreen =
            entry[(__bridge NSString *)kCGWindowIsOnscreen];
        if (![owner isKindOfClass:NSNumber.class] ||
            owner.intValue != processID ||
            ![number isKindOfClass:NSNumber.class] ||
            number.unsignedLongLongValue == 0 ||
            number.unsignedLongLongValue > UINT32_MAX ||
            ([onscreen isKindOfClass:NSNumber.class] &&
             !onscreen.boolValue)) {
            continue;
        }
        id rawBounds =
            entry[(__bridge NSString *)kCGWindowBounds];
        CGRect candidateBounds = CGRectZero;
        if (![rawBounds isKindOfClass:NSDictionary.class] ||
            !CGRectMakeWithDictionaryRepresentation(
                (__bridge CFDictionaryRef)rawBounds,
                &candidateBounds
            ) ||
            !isfinite(candidateBounds.origin.x) ||
            !isfinite(candidateBounds.origin.y) ||
            !isfinite(candidateBounds.size.width) ||
            !isfinite(candidateBounds.size.height) ||
            candidateBounds.size.width <= 0 ||
            candidateBounds.size.height <= 0) {
            return nil;
        }
        NSNumber *key = @(number.unsignedIntValue);
        if (metadata[key] != nil) {
            return nil;
        }
        metadata[key] = @{
            @"boundsValue":
                [NSValue valueWithCGRect:candidateBounds],
            @"frontToBackIndex": @(index),
        };
    }
    return metadata;
}

#if defined(IOS_USE_PLAY_APPKIT_BRIDGE_TESTING)
void IOSUsePlayAppKitBridgeSetCGWindowListCopyWindowInfoForTesting(
    IOSUseBridgeCGWindowListCopyWindowInfo copyWindowInfo
) {
    IOSUseBridgeCGWindowListCopyWindowInfoForTesting =
        copyWindowInfo;
}

NSDictionary<NSNumber *, NSDictionary<NSString *, id> *> * _Nullable
IOSUsePlayAppKitBridgeCopyOwnOnscreenCGWindowMetadataForTesting(void) {
    return IOSUseBridgeOwnOnscreenCGWindowMetadata();
}
#endif

static NSDictionary<NSString *, id> *
IOSUseBridgeExactOnscreenCGWindowMetadata(
    id window,
    NSDictionary<
        NSNumber *,
        NSDictionary<NSString *, id> *
    > *metadata
) {
    NSInteger rawWindowNumber = IOSUseBridgeInteger(
        window,
        @"windowNumber"
    );
    if (rawWindowNumber <= 0 ||
        (uint64_t)rawWindowNumber > UINT32_MAX ||
        metadata == nil) {
        return nil;
    }
    return metadata[@((uint32_t)rawWindowNumber)];
}

static BOOL IOSUseBridgeSetSize(
    id object,
    NSString *selectorName,
    CGSize value
) {
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) {
        return NO;
    }
    ((IOSUseBridgeSendSizeArgument)objc_msgSend)(
        object,
        selector,
        value
    );
    return YES;
}

static CGSize IOSUseBridgeSize(
    id object,
    NSString *selectorName
) {
    SEL selector = NSSelectorFromString(selectorName);
    return [object respondsToSelector:selector]
        ? ((IOSUseBridgeSendSize)objc_msgSend)(object, selector)
        : CGSizeZero;
}

static BOOL IOSUseBridgeClassScaleMethodMatches(
    Class scaleClass,
    NSString *selectorName,
    BOOL setter
) {
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getClassMethod(scaleClass, selector);
    if (method == NULL ||
        method_getNumberOfArguments(method) != (setter ? 3 : 2)) {
        return NO;
    }
    char *returnType = method_copyReturnType(method);
    char *argumentType = setter
        ? method_copyArgumentType(method, 2)
        : NULL;
    BOOL matches =
        returnType != NULL &&
        strcmp(
            returnType,
            setter ? @encode(void) : @encode(CGFloat)
        ) == 0 &&
        (!setter ||
            (argumentType != NULL &&
             strcmp(argumentType, @encode(CGFloat)) == 0));
    free(returnType);
    free(argumentType);
    return matches;
}

static BOOL IOSUseBridgeClassBoolMethodMatches(
    Class scaleClass,
    NSString *selectorName,
    BOOL setter
) {
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getClassMethod(scaleClass, selector);
    if (method == NULL ||
        method_getNumberOfArguments(method) != (setter ? 3 : 2)) {
        return NO;
    }
    char *returnType = method_copyReturnType(method);
    char *argumentType = setter
        ? method_copyArgumentType(method, 2)
        : NULL;
    BOOL matches =
        returnType != NULL &&
        strcmp(
            returnType,
            setter ? @encode(void) : @encode(BOOL)
        ) == 0 &&
        (!setter ||
            (argumentType != NULL &&
             strcmp(argumentType, @encode(BOOL)) == 0));
    free(returnType);
    free(argumentType);
    return matches;
}

static BOOL IOSUseBridgeApproximatelyEqual(CGFloat lhs, CGFloat rhs) {
    return fabs(lhs - rhs) <= 0.01;
}

static BOOL IOSUseBridgeRectApproximatelyEqual(CGRect lhs, CGRect rhs) {
    return IOSUseBridgeApproximatelyEqual(lhs.origin.x, rhs.origin.x) &&
        IOSUseBridgeApproximatelyEqual(lhs.origin.y, rhs.origin.y) &&
        IOSUseBridgeApproximatelyEqual(
            lhs.size.width,
            rhs.size.width
        ) &&
        IOSUseBridgeApproximatelyEqual(
            lhs.size.height,
            rhs.size.height
        );
}

static BOOL IOSUseBridgeRectApproximatelyEqualWithTolerance(
    CGRect lhs,
    CGRect rhs,
    CGFloat tolerance
) {
    return isfinite(tolerance) && tolerance >= 0 &&
        fabs(lhs.origin.x - rhs.origin.x) <= tolerance &&
        fabs(lhs.origin.y - rhs.origin.y) <= tolerance &&
        fabs(lhs.size.width - rhs.size.width) <= tolerance &&
        fabs(lhs.size.height - rhs.size.height) <= tolerance;
}

static CGFloat IOSUseBridgeBackingScaleFactor(id window) {
    if (window == nil || ![window respondsToSelector:
        NSSelectorFromString(@"backingScaleFactor")]) {
        return 0;
    }
    CGFloat backingScaleFactor =
        ((IOSUseBridgeSendFloat)objc_msgSend)(
            window,
            NSSelectorFromString(@"backingScaleFactor")
        );
    return isfinite(backingScaleFactor) &&
        backingScaleFactor > 0 &&
        backingScaleFactor <= 4
        ? backingScaleFactor
        : 0;
}

static CGSize IOSUseBridgeHostMinimumContentSize(void) {
    return CGSizeMake(
        IOSUseBridgeDeviceLogicalWidth *
            IOSUsePlayHostCanvasMinimumDisplayScale,
        IOSUseBridgeDeviceLogicalHeight *
            IOSUsePlayHostCanvasMinimumDisplayScale
    );
}

static NSString *IOSUseBridgeHostTitle(void) {
    if (IOSUsePlayHostTitle != nil) {
        return IOSUsePlayHostTitle;
    }
    NSBundle *bundle = NSBundle.mainBundle;
    for (NSString *key in @[
        @"CFBundleDisplayName",
        @"CFBundleName",
    ]) {
        id value = [bundle objectForInfoDictionaryKey:key];
        if ([value isKindOfClass:NSString.class] &&
            [(NSString *)value length] > 0) {
            IOSUsePlayHostTitle = value;
            return IOSUsePlayHostTitle;
        }
    }
    IOSUsePlayHostTitle = bundle.bundleIdentifier.length > 0
        ? bundle.bundleIdentifier
        : @"iPhone App";
    return IOSUsePlayHostTitle;
}

static BOOL IOSUseBridgeResizableEdgesMethodMatches(Method method) {
    if (method == NULL || method_getNumberOfArguments(method) != 4) {
        return NO;
    }
    char *returnType = method_copyReturnType(method);
    char *growingType = method_copyArgumentType(method, 2);
    char *shrinkingType = method_copyArgumentType(method, 3);
    BOOL matches =
        returnType != NULL &&
            strcmp(returnType, @encode(NSUInteger)) == 0 &&
        growingType != NULL &&
            strcmp(growingType, @encode(NSUInteger *)) == 0 &&
        shrinkingType != NULL &&
            strcmp(shrinkingType, @encode(NSUInteger *)) == 0;
    free(returnType);
    free(growingType);
    free(shrinkingType);
    return matches;
}

static NSUInteger IOSUseBridgeResizableEdges(
    id window,
    NSUInteger *growing,
    NSUInteger *shrinking
) {
    if (growing != NULL) {
        *growing = 0;
    }
    if (shrinking != NULL) {
        *shrinking = 0;
    }
    SEL selector = NSSelectorFromString(
        @"_resizableEdgesForGrowing:shrinking:"
    );
    Method method = class_getInstanceMethod([window class], selector);
    if (!IOSUseBridgeResizableEdgesMethodMatches(method)) {
        return 0;
    }
    return ((IOSUseBridgeSendResizableEdges)objc_msgSend)(
        window,
        selector,
        growing,
        shrinking
    );
}

static BOOL IOSUseBridgeWindowPolicyIsHost(id window) {
    const NSInteger titled = 1 << 0;
    const NSInteger resizable = 1 << 3;
    const NSUInteger allEdges = 0x0f;
    NSInteger styleMask = IOSUseBridgeInteger(window, @"styleMask");
    CGSize aspect = IOSUseBridgeSize(window, @"contentAspectRatio");
    NSUInteger growing = 0;
    NSUInteger shrinking = 0;
    NSUInteger resizeEdges = IOSUseBridgeResizableEdges(
        window,
        &growing,
        &shrinking
    );
    return (styleMask & titled) != 0 &&
        (styleMask & resizable) != 0 &&
        (resizeEdges & allEdges) == allEdges &&
        (growing & allEdges) == allEdges &&
        (shrinking & allEdges) == allEdges &&
        IOSUseBridgeBool(window, @"isOpaque") &&
        IOSUseBridgeBool(window, @"isMovable") &&
        !IOSUseBridgeBool(window, @"ignoresMouseEvents") &&
        isfinite(aspect.width) && isfinite(aspect.height) &&
        aspect.width > 0 && aspect.height > 0 &&
        IOSUseBridgeApproximatelyEqual(
            aspect.width / aspect.height,
            (CGFloat)IOSUsePlayDeviceLogicalWidth /
                (CGFloat)IOSUsePlayDeviceLogicalHeight
        );
}

static NSDictionary<NSString *, NSNumber *> *IOSUseBridgeRectJSON(
    CGRect rect
) {
    return @{
        @"x": @(rect.origin.x),
        @"y": @(rect.origin.y),
        @"width": @(rect.size.width),
        @"height": @(rect.size.height),
    };
}

static NSDictionary<NSString *, NSNumber *> *IOSUseBridgeSizeJSON(
    CGSize size
) {
    return @{
        @"width": @(size.width),
        @"height": @(size.height),
    };
}

static NSArray<NSDictionary<NSString *, id> *> *
IOSUseBridgeViewInventory(id view, NSUInteger depth) {
    if (view == nil) {
        return @[];
    }
    NSMutableDictionary<NSString *, id> *entry = [@{
        @"class": NSStringFromClass([view class]),
        @"frame": IOSUseBridgeRectJSON(
            IOSUseBridgeRect(view, @"frame")
        ),
        @"bounds": IOSUseBridgeRectJSON(
            IOSUseBridgeRect(view, @"bounds")
        ),
    } mutableCopy];
    SEL subviewsSelector = NSSelectorFromString(@"subviews");
    id subviews = [view respondsToSelector:subviewsSelector]
        ? ((IOSUseBridgeSendID)objc_msgSend)(
            view,
            subviewsSelector
        )
        : nil;
    if (depth > 0 && [subviews isKindOfClass:NSArray.class]) {
        NSMutableArray<NSDictionary<NSString *, id> *> *children =
            [NSMutableArray array];
        for (id child in (NSArray *)subviews) {
            [children addObjectsFromArray:
                IOSUseBridgeViewInventory(child, depth - 1)];
        }
        entry[@"subviews"] = children;
    }
    return @[entry];
}

static NSArray<NSDictionary<NSString *, id> *> *
IOSUseBridgeSceneInventory(void) {
    NSMutableArray<NSDictionary<NSString *, id> *> *result =
        [NSMutableArray array];
    for (UIScene *candidate in
         UIApplication.sharedApplication.connectedScenes) {
        if (![candidate isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        UIWindowScene *scene = (UIWindowScene *)candidate;
        NSMutableArray<NSDictionary<NSString *, id> *> *windows =
            [NSMutableArray arrayWithCapacity:scene.windows.count];
        for (UIWindow *window in scene.windows) {
            [windows addObject:@{
                @"class": NSStringFromClass(window.class) ?: @"",
                @"key": @(window.isKeyWindow),
                @"hidden": @(window.hidden),
                @"alpha": @(window.alpha),
                @"level": @(window.windowLevel),
                @"frame": IOSUseBridgeRectJSON(window.frame),
            }];
        }
        [result addObject:@{
            @"identifier":
                scene.session.persistentIdentifier ?: @"",
            @"activationState": @(scene.activationState),
            @"windows": windows,
        }];
    }
    return result;
}

static BOOL IOSUseBridgeRectIsDeviceScreen(CGRect rect) {
    return IOSUseBridgeApproximatelyEqual(rect.origin.x, 0) &&
        IOSUseBridgeApproximatelyEqual(rect.origin.y, 0) &&
        IOSUseBridgeApproximatelyEqual(
            rect.size.width,
            IOSUsePlayDeviceLogicalWidth
        ) &&
        IOSUseBridgeApproximatelyEqual(
            rect.size.height,
            IOSUsePlayDeviceLogicalHeight
        );
}

static BOOL IOSUseBridgeUIKitWindowCanBootstrapActivation(
    UIWindow *window,
    UIWindowScene *scene
) {
    return window != nil &&
        window.windowScene == scene &&
        [scene.windows containsObject:window] &&
        !window.hidden &&
        window.alpha > 0.01 &&
        window.rootViewController != nil &&
        IOSUseBridgeApproximatelyEqual(
            window.windowLevel,
            UIWindowLevelNormal
        ) &&
        IOSUseBridgeRectIsDeviceScreen(window.bounds);
}

static NSInteger IOSUseBridgeWindowActivationSceneRank(
    UIWindowScene *scene
) {
    switch (scene.activationState) {
        case UISceneActivationStateForegroundActive:
            return 0;
        case UISceneActivationStateForegroundInactive:
            return 1;
        case UISceneActivationStateBackground:
            return 2;
        case UISceneActivationStateUnattached:
            return -1;
    }
    return -1;
}

static UIWindow *IOSUseBridgeAutomationUIKitWindow(void) {
    NSMutableArray<UIWindowScene *> *scenes =
        [NSMutableArray array];
    NSMutableSet<NSString *> *identifiers =
        [NSMutableSet set];
    for (UIScene *candidate in
         UIApplication.sharedApplication.connectedScenes) {
        if (![candidate isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        UIWindowScene *scene = (UIWindowScene *)candidate;
        if (IOSUseBridgeWindowActivationSceneRank(scene) < 0 ||
            ![scene.session.role
                isEqualToString:
                    UIWindowSceneSessionRoleApplication]) {
            continue;
        }
        NSString *identifier =
            scene.session.persistentIdentifier ?: @"";
        if (identifier.length == 0 ||
            [identifiers containsObject:identifier]) {
            return nil;
        }
        [identifiers addObject:identifier];
        [scenes addObject:scene];
    }
    [scenes sortUsingComparator:^NSComparisonResult(
        UIWindowScene *left,
        UIWindowScene *right
    ) {
        NSInteger leftRank =
            IOSUseBridgeWindowActivationSceneRank(left);
        NSInteger rightRank =
            IOSUseBridgeWindowActivationSceneRank(right);
        if (leftRank < rightRank) {
            return NSOrderedAscending;
        }
        if (leftRank > rightRank) {
            return NSOrderedDescending;
        }
        return [left.session.persistentIdentifier
            compare:right.session.persistentIdentifier];
    }];
    for (UIWindowScene *scene in scenes) {
        for (UIWindow *window in scene.windows) {
            if (window.isKeyWindow &&
                IOSUseBridgeUIKitWindowCanBootstrapActivation(
                    window,
                    scene
                )) {
                return window;
            }
        }
        id delegate = scene.delegate;
        SEL windowSelector = NSSelectorFromString(@"window");
        UIWindow *delegateWindow =
            [delegate respondsToSelector:windowSelector]
                ? ((IOSUseBridgeSendID)objc_msgSend)(
                    delegate,
                    windowSelector
                )
                : nil;
        if (IOSUseBridgeUIKitWindowCanBootstrapActivation(
                delegateWindow,
                scene
            )) {
            return delegateWindow;
        }
        NSMutableArray<UIWindow *> *candidates =
            [NSMutableArray array];
        for (UIWindow *window in scene.windows) {
            if (IOSUseBridgeUIKitWindowCanBootstrapActivation(
                    window,
                    scene
                )) {
                [candidates addObject:window];
            }
        }
        if (candidates.count == 1) {
            return candidates.firstObject;
        }
        if (candidates.count > 1) {
            return nil;
        }
    }
    return nil;
}

static NSError *IOSUseBridgeAccessibilityError(
    NSInteger code,
    NSString *message
) {
    return [NSError
        errorWithDomain:IOSUsePlayAccessibilityBridgeErrorDomain
                   code:code
               userInfo:@{
        NSLocalizedDescriptionKey: message,
    }];
}

static BOOL IOSUseBridgeAccessibilityFiniteRect(CGRect rect) {
    return !CGRectIsNull(rect) &&
        !CGRectIsInfinite(rect) &&
        isfinite(rect.origin.x) &&
        isfinite(rect.origin.y) &&
        isfinite(rect.size.width) &&
        isfinite(rect.size.height) &&
        rect.size.width > 0 &&
        rect.size.height > 0;
}

static BOOL IOSUseBridgeAppKitScreenRectToCGWindowRect(
    CGRect appKitScreenRect,
    CGRect *cgWindowRect
) {
    if (!IOSUseBridgeAccessibilityFiniteRect(appKitScreenRect)) {
        return NO;
    }
    // CGWindow bounds use the global top-left coordinate system rooted at
    // the main display, not the current window's screen. That remains stable
    // for vertically arranged or differently sized displays.
    CGRect mainDisplayBounds = CGDisplayBounds(CGMainDisplayID());
    if (!IOSUseBridgeAccessibilityFiniteRect(mainDisplayBounds)) {
        return NO;
    }
    return IOSUsePlayResolveAppKitScreenRectInCGWindowCoordinates(
        appKitScreenRect,
        mainDisplayBounds,
        cgWindowRect,
        NULL
    );
}

/// Single inverse-transform route for AppKit AX and native-alert controls.
/// It starts from an AppKit global screen rect, enters the fixed-canvas host's
/// content coordinate system, clips to the visible fixed canvas, then maps
/// to the device's fixed top-left logical coordinates using the current
/// display scale.
static CGRect IOSUseBridgeAppKitScreenRectToCanvasLogicalRect(
    CGRect appKitScreenRect,
    id window,
    NSError * _Nullable __autoreleasing *error
) {
    if (window == nil || window != IOSUsePlayHostWindow ||
        IOSUsePlayHostContentView == nil) {
        if (error != NULL) {
            *error = IOSUseBridgeAccessibilityError(
                13,
                @"AppKit host is unavailable for geometry conversion"
            );
        }
        return CGRectNull;
    }
    NSString *layoutFailure = nil;
    if (!IOSUseBridgeUpdateHostCanvasLayout(window, &layoutFailure)) {
        if (error != NULL) {
            *error = IOSUseBridgeAccessibilityError(
                13,
                layoutFailure ?: @"fixed host canvas layout is unavailable"
            );
        }
        return CGRectNull;
    }
    SEL fromScreenSelector = NSSelectorFromString(@"convertRectFromScreen:");
    SEL fromViewSelector = NSSelectorFromString(@"convertRect:fromView:");
    if (![window respondsToSelector:fromScreenSelector] ||
        ![IOSUsePlayHostContentView respondsToSelector:fromViewSelector]) {
        if (error != NULL) {
            *error = IOSUseBridgeAccessibilityError(
                13,
                @"AppKit host cannot convert screen geometry into canvas coordinates"
            );
        }
        return CGRectNull;
    }
    @try {
        CGRect windowLocal = ((IOSUseBridgeSendRectRect)objc_msgSend)(
            window,
            fromScreenSelector,
            appKitScreenRect
        );
        CGRect hostContentRect = ((IOSUseBridgeSendRectRectID)objc_msgSend)(
            IOSUsePlayHostContentView,
            fromViewSelector,
            windowLocal,
            nil
        );
        CGRect visibleHostRect = CGRectIntersection(
            hostContentRect,
            IOSUsePlayCurrentHostCanvasLayout.canvasRect
        );
        if (!IOSUseBridgeAccessibilityFiniteRect(visibleHostRect)) {
            return CGRectNull;
        }
        CGRect logicalRect = CGRectNull;
        NSString *transformFailure = nil;
        if (!IOSUsePlayMapHostContentRectToCanvas(
                IOSUsePlayCurrentHostCanvasLayout,
                visibleHostRect,
                &logicalRect,
                &transformFailure
            )) {
            if (error != NULL) {
                *error = IOSUseBridgeAccessibilityError(
                    14,
                    transformFailure ?: @"canvas inverse transform failed"
                );
            }
            return CGRectNull;
        }
        return logicalRect;
    } @catch (NSException *exception) {
        if (error != NULL) {
            *error = IOSUseBridgeAccessibilityError(
                14,
                [NSString stringWithFormat:
                    @"AppKit canvas geometry conversion raised %@",
                    exception.name]
            );
        }
        return CGRectNull;
    }
}

static BOOL IOSUseBridgeScreenCanFit(id window) {
    SEL screenSelector = NSSelectorFromString(@"screen");
    id screen = [window respondsToSelector:screenSelector]
        ? ((IOSUseBridgeSendID)objc_msgSend)(window, screenSelector)
        : nil;
    CGRect visibleFrame = IOSUseBridgeRect(screen, @"visibleFrame");
    CGSize minimumContent = IOSUseBridgeHostMinimumContentSize();
    CGRect minimumFrame = [window respondsToSelector:
        NSSelectorFromString(@"frameRectForContentRect:")]
        ? ((IOSUseBridgeSendRectRect)objc_msgSend)(
            window,
            NSSelectorFromString(@"frameRectForContentRect:"),
            CGRectMake(
                0,
                0,
                minimumContent.width,
                minimumContent.height
            )
        )
        : CGRectMake(
            0,
            0,
            minimumContent.width,
            minimumContent.height
        );
    return !CGRectIsEmpty(visibleFrame) &&
        !CGRectIsEmpty(minimumFrame) &&
        visibleFrame.size.width >= minimumFrame.size.width &&
        visibleFrame.size.height >= minimumFrame.size.height;
}

static CGRect IOSUseBridgeVisibleFrameInCGCoordinates(id window) {
    SEL screenSelector = NSSelectorFromString(@"screen");
    id screen = [window respondsToSelector:screenSelector]
        ? ((IOSUseBridgeSendID)objc_msgSend)(window, screenSelector)
        : nil;
    CGRect visibleFrame = IOSUseBridgeRect(screen, @"visibleFrame");
    CGRect cgVisibleFrame = CGRectNull;
    return IOSUseBridgeAppKitScreenRectToCGWindowRect(
        visibleFrame,
        &cgVisibleFrame
    ) ? cgVisibleFrame : CGRectNull;
}

static NSString *IOSUseBridgeSceneGeometryStateName(
    IOSUseBridgeSceneGeometryState state
) {
    switch (state) {
        case IOSUseBridgeSceneGeometryStateNotRequested:
            return @"not-requested";
        case IOSUseBridgeSceneGeometryStatePending:
            return @"pending";
        case IOSUseBridgeSceneGeometryStateReady:
            return @"configured";
        case IOSUseBridgeSceneGeometryStateFailed:
            return @"failed";
    }
    return @"unknown";
}

static CGSize IOSUseBridgeFixedSceneCanvasSize(void) {
    return CGSizeMake(
        IOSUsePlayDeviceLogicalWidth,
        IOSUsePlayDeviceLogicalHeight
    );
}

static BOOL IOSUseBridgeSceneHasFixedCanvas(
    UIWindowScene *scene,
    UIWindow *uiWindow
) {
    return scene != nil &&
        uiWindow != nil &&
        uiWindow.windowScene == scene &&
        IOSUseBridgeRectIsDeviceScreen(uiWindow.bounds);
}

static IOSUseBridgeSceneGeometryState
IOSUseBridgeLockSceneToFixedCanvas(UIWindow *uiWindow) {
    UIWindowScene *scene = uiWindow.windowScene;
    if (scene == nil || scene.sizeRestrictions == nil) {
        IOSUsePlaySceneGeometryState = IOSUseBridgeSceneGeometryStateFailed;
        IOSUsePlaySceneGeometryFailure =
            @"UIKit scene size restrictions are unavailable";
        return IOSUsePlaySceneGeometryState;
    }
    CGSize fixed = IOSUseBridgeFixedSceneCanvasSize();
    // The AppKit wrapper may resize, but UIKit's scene remains the fixed
    // device canvas and is only display-scaled inside that wrapper.
    scene.sizeRestrictions.minimumSize = fixed;
    scene.sizeRestrictions.maximumSize = fixed;
    if (scene != IOSUsePlaySceneGeometryScene) {
        IOSUsePlaySceneGeometryScene = scene;
        IOSUsePlaySceneGeometryState =
            IOSUseBridgeSceneGeometryStateNotRequested;
        IOSUsePlaySceneGeometryFailure = nil;
    }
    if (@available(macCatalyst 16.0, *)) {
        scene.sizeRestrictions.allowsFullScreen = NO;
    }
    if (IOSUseBridgeSceneHasFixedCanvas(scene, uiWindow)) {
        IOSUsePlaySceneGeometryState =
            IOSUseBridgeSceneGeometryStateReady;
        IOSUsePlaySceneGeometryFailure = nil;
    } else {
        // `effectiveGeometry.systemFrame` is the public AppKit window frame,
        // including its title bar. It is deliberately taller than the fixed
        // UIKit canvas and must not be forced to 430 x 932. The size
        // restrictions and observed UIWindow bounds are the authoritative
        // fixed-canvas proof; Runtime's periodic main-queue probe retries
        // while UIKit applies them.
        IOSUsePlaySceneGeometryState =
            IOSUseBridgeSceneGeometryStatePending;
        IOSUsePlaySceneGeometryFailure =
            @"waiting for UIWindowScene size restrictions to settle to the "
             "fixed 430 x 932 UIKit canvas";
    }
    return IOSUsePlaySceneGeometryState;
}

static id IOSUseBridgeNewViewWithFrame(CGRect frame) {
    Class viewClass = NSClassFromString(@"NSView");
    if (viewClass == Nil) {
        return nil;
    }
    id allocated = ((IOSUseBridgeSendID)objc_msgSend)(
        (id)viewClass,
        NSSelectorFromString(@"alloc")
    );
    return allocated == nil ? nil :
        ((IOSUseBridgeSendIDRect)objc_msgSend)(
            allocated,
            NSSelectorFromString(@"initWithFrame:"),
            frame
        );
}

static CGSize IOSUseBridgeAcceptProposedWindowSize(
    id window,
    SEL selector,
    CGSize proposed,
    NSUInteger resizeEdges
) {
    if (isfinite(proposed.width) && isfinite(proposed.height) &&
        proposed.width > 0 && proposed.height > 0) {
        return proposed;
    }
    return IOSUsePlayOriginalProposedSize == NULL
        ? proposed
        : IOSUsePlayOriginalProposedSize(
            window,
            selector,
            proposed,
            resizeEdges
        );
}

static NSUInteger IOSUseBridgeEnableAllResizableEdges(
    __unused id window,
    __unused SEL selector,
    NSUInteger *growing,
    NSUInteger *shrinking
) {
    const NSUInteger allEdges = 0x0f;
    if (growing != NULL) {
        *growing = allEdges;
    }
    if (shrinking != NULL) {
        *shrinking = allEdges;
    }
    return allEdges;
}

static BOOL IOSUseBridgeInstallAllResizableEdgesHook(id window) {
    Class windowClass = [window class];
    Class standardWindowClass = NSClassFromString(@"NSWindow");
    // UIKitMacHelper currently uses UINSWindow rather than the older
    // UINSFullScreenWindow on some macOS releases. Limit the compatibility
    // override to the exact UIKit-owned host class; never mutate NSWindow or
    // an unrelated AppKit subclass.
    if (windowClass == standardWindowClass ||
        ![NSStringFromClass(windowClass) hasPrefix:@"UINS"]) {
        IOSUsePlayHookRegistryRecordState(
            @"uikitmac.resize.edges",
            YES,
            @"first-window",
            windowClass == Nil
                ? @"unavailable"
                : NSStringFromClass(windowClass),
            @"_resizableEdgesForGrowing:shrinking:",
            @"NSUInteger(id,SEL,NSUInteger *,NSUInteger *)",
            NO,
            NO,
            @"UIKit host is not an exact UINS window class"
        );
        return NO;
    }
    if (IOSUsePlayResizableEdgesHookClass == windowClass) {
        return IOSUsePlayHookRegistryEntryReady(
            @"uikitmac.resize.edges"
        );
    }
    if (IOSUsePlayResizableEdgesHookClass != Nil &&
        IOSUsePlayResizableEdgesHookClass != windowClass) {
        return NO;
    }
    SEL selector = NSSelectorFromString(
        @"_resizableEdgesForGrowing:shrinking:"
    );
    const char *argumentTypes[] = {
        @encode(NSUInteger *),
        @encode(NSUInteger *),
    };
    BOOL installed = IOSUsePlayHookRegistryInstallFunction(
        @"uikitmac.resize.edges",
        YES,
        @"first-window",
        windowClass,
        NO,
        selector,
        @encode(NSUInteger),
        argumentTypes,
        2,
        NO,
        NO,
        (IMP)IOSUseBridgeEnableAllResizableEdges,
        NULL,
        NULL
    );
    if (installed) {
        IOSUsePlayResizableEdgesHookClass = windowClass;
    }
    return installed;
}

static BOOL IOSUseBridgeInstallSimulatorScaleResizeHook(id window) {
    Class windowClass = [window class];
    if (!IOSUseBridgeInstallAllResizableEdgesHook(window)) {
        return NO;
    }
    if (![NSStringFromClass(windowClass) hasPrefix:@"UINS"]) {
        return NO;
    }
    if (IOSUsePlayResizeHookClass == windowClass &&
        IOSUsePlayOriginalProposedSize != NULL) {
        return IOSUsePlayHookRegistryEntryReady(
            @"uikitmac.resize.proposed-size"
        );
    }
    if (IOSUsePlayResizeHookClass != Nil &&
        IOSUsePlayResizeHookClass != windowClass) {
        return NO;
    }
    SEL selector = NSSelectorFromString(
        @"_sizeForProposedSize:resizeEdges:"
    );
    const char *argumentTypes[] = {
        @encode(CGSize),
        @encode(NSUInteger),
    };
    IMP original = NULL;
    BOOL installed = IOSUsePlayHookRegistryInstallFunction(
        @"uikitmac.resize.proposed-size",
        YES,
        @"first-window",
        windowClass,
        NO,
        selector,
        @encode(CGSize),
        argumentTypes,
        2,
        NO,
        NO,
        (IMP)IOSUseBridgeAcceptProposedWindowSize,
        &original,
        NULL
    );
    if (!installed ||
        original == NULL ||
        original == (IMP)IOSUseBridgeAcceptProposedWindowSize) {
        return NO;
    }
    IOSUsePlayResizeHookClass = windowClass;
    IOSUsePlayOriginalProposedSize =
        (IOSUseBridgeSendProposedSize)original;
    return YES;
}

static BOOL IOSUseBridgeApplyWindowPolicy(id window) {
    // Preserve UIKitMacHelper's ordinary titled window. The host owns only
    // public resize policy; UIKit keeps its fixed 430 x 932 logical scene.
    const NSInteger resizable = 1 << 3;
    // UIKitMacHelper may override both AppKit's resizable-edge hit testing
    // and proposed-size path. The compatibility hook is restricted to the
    // exact UINS host class, and four-edge availability remains part of the
    // launch contract.
    if (!IOSUseBridgeInstallSimulatorScaleResizeHook(window)) {
        return NO;
    }
    NSInteger styleMask = IOSUseBridgeInteger(window, @"styleMask");
    if ((styleMask & resizable) == 0) {
        IOSUseBridgeSetInteger(
            window,
            @"setStyleMask:",
            styleMask | resizable
        );
    }
    CGSize fixedAspect = CGSizeMake(
        IOSUsePlayDeviceLogicalWidth,
        IOSUsePlayDeviceLogicalHeight
    );
    CGSize currentAspect = IOSUseBridgeSize(
        window,
        @"contentAspectRatio"
    );
    if (!IOSUseBridgeApproximatelyEqual(
            currentAspect.width / currentAspect.height,
            fixedAspect.width / fixedAspect.height
        )) {
        IOSUseBridgeSetSize(
            window,
            @"setContentAspectRatio:",
            fixedAspect
        );
    }
    CGSize minimumContent = IOSUseBridgeHostMinimumContentSize();
    CGSize currentMinimum = IOSUseBridgeSize(window, @"contentMinSize");
    if (!IOSUseBridgeApproximatelyEqual(
            currentMinimum.width,
            minimumContent.width
        ) ||
        !IOSUseBridgeApproximatelyEqual(
            currentMinimum.height,
            minimumContent.height
        )) {
        IOSUseBridgeSetSize(
            window,
            @"setContentMinSize:",
            minimumContent
        );
    }
    return IOSUseBridgeWindowPolicyIsHost(window);
}

static BOOL IOSUseBridgeInstallHostCanvas(id window) {
    SEL contentViewSelector = NSSelectorFromString(@"contentView");
    id currentContent = [window respondsToSelector:contentViewSelector]
        ? ((IOSUseBridgeSendID)objc_msgSend)(
            window,
            contentViewSelector
        )
        : nil;
    if (window == IOSUsePlayHostWindow &&
        currentContent == IOSUsePlayHostContentView &&
        IOSUsePlayScaleView != nil &&
        IOSUsePlayCanvasView != nil) {
        return YES;
    }
    if (currentContent == nil ||
        currentContent == IOSUsePlayHostContentView) {
        return NO;
    }
    CGRect contentBounds = IOSUseBridgeRect(currentContent, @"bounds");
    if (CGRectIsEmpty(contentBounds)) {
        contentBounds = CGRectMake(
            0,
            0,
            IOSUsePlayDeviceLogicalWidth,
            IOSUsePlayDeviceLogicalHeight
        );
    }
    id hostContent = IOSUseBridgeNewViewWithFrame(contentBounds);
    id scaleView = IOSUseBridgeNewViewWithFrame(contentBounds);
    SEL setContentViewSelector = NSSelectorFromString(@"setContentView:");
    SEL addSubviewSelector = NSSelectorFromString(@"addSubview:");
    if (hostContent == nil ||
        scaleView == nil ||
        ![window respondsToSelector:setContentViewSelector] ||
        ![hostContent respondsToSelector:addSubviewSelector] ||
        ![scaleView respondsToSelector:addSubviewSelector]) {
        return NO;
    }
    IOSUseBridgeSetUnsignedInteger(
        currentContent,
        @"setAutoresizingMask:",
        0
    );
    IOSUseBridgeSetUnsignedInteger(
        scaleView,
        @"setAutoresizingMask:",
        0
    );
    ((IOSUseBridgeSendIDArgument)objc_msgSend)(
        window,
        setContentViewSelector,
        hostContent
    );
    ((IOSUseBridgeSendIDArgument)objc_msgSend)(
        hostContent,
        addSubviewSelector,
        scaleView
    );
    ((IOSUseBridgeSendIDArgument)objc_msgSend)(
        scaleView,
        addSubviewSelector,
        currentContent
    );
    IOSUsePlayHostWindow = window;
    IOSUsePlayHostContentView = hostContent;
    IOSUsePlayScaleView = scaleView;
    IOSUsePlayCanvasView = currentContent;
    IOSUsePlayHostCanvasLayoutReady = NO;
    IOSUsePlayBootstrapContentWindow = window;
    IOSUsePlayBootstrapContentReady = NO;
    IOSUsePlayBootstrapContentNormalizationScheduled = NO;
    IOSUsePlayBootstrapContentNormalizationAttempts = 0;
    IOSUsePlayHostContentGeneration += 1;
    return YES;
}

static id IOSUseBridgeUniqueDirectSubview(
    id parent,
    NSString *className
) {
    id subviews = [parent respondsToSelector:
        NSSelectorFromString(@"subviews")]
        ? ((IOSUseBridgeSendID)objc_msgSend)(
            parent,
            NSSelectorFromString(@"subviews")
        )
        : nil;
    if (![subviews isKindOfClass:NSArray.class]) {
        return nil;
    }
    id match = nil;
    for (id child in (NSArray *)subviews) {
        NSString *name = NSStringFromClass([child class]);
        if (![name isEqualToString:className]) {
            continue;
        }
        if (match != nil) {
            return nil;
        }
        match = child;
    }
    return match;
}

static id IOSUseBridgeSceneRenderView(id canvasView) {
    return IOSUseBridgeUniqueDirectSubview(
        canvasView,
        @"UINSSceneView"
    );
}

static id IOSUseBridgeInputRenderView(id sceneView) {
    return IOSUseBridgeUniqueDirectSubview(
        sceneView,
        @"UINSInputView"
    );
}

static void IOSUseBridgeLayoutIfNeeded(id view) {
    for (NSString *selectorName in @[
        @"layoutSubtreeIfNeeded",
        @"layoutIfNeeded",
    ]) {
        SEL selector = NSSelectorFromString(selectorName);
        if ([view respondsToSelector:selector]) {
            ((IOSUseBridgeSendVoid)objc_msgSend)(view, selector);
        }
    }
}

static BOOL IOSUseBridgeNormalizeLogicalRenderView(
    id view,
    CGRect logicalFrame
) {
    if (view == nil) {
        return NO;
    }
    CGRect frame = IOSUseBridgeRect(view, @"frame");
    BOOL frameReady =
        IOSUseBridgeRectApproximatelyEqual(frame, logicalFrame) ||
        IOSUseBridgeSetRect(view, @"setFrame:", logicalFrame);
    CGRect bounds = IOSUseBridgeRect(view, @"bounds");
    BOOL boundsReady =
        IOSUseBridgeRectApproximatelyEqual(bounds, logicalFrame) ||
        IOSUseBridgeSetRect(view, @"setBounds:", logicalFrame);
    return frameReady && boundsReady;
}

static BOOL IOSUseBridgeReassertIdentitySceneScale(
    NSString **failure
) {
    Class scaleClass = NSClassFromString(
        @"UINSSceneViewController"
    );
    if (!IOSUsePlaySceneScaleBootstrapReady ||
        scaleClass == Nil) {
        if (failure != NULL) {
            *failure =
                @"UIKitMacHelper identity scene scale is unavailable";
        }
        return NO;
    }
    SEL idiomGetter =
        NSSelectorFromString(@"defaultUIScaleFactorForIdiom");
    SEL idiomSetter =
        NSSelectorFromString(@"setDefaultUIScaleFactorForIdiom:");
    SEL windowsGetter =
        NSSelectorFromString(@"defaultUIScaleFactorForWindows");
    SEL windowsSetter =
        NSSelectorFromString(@"setDefaultUIScaleFactorForWindows:");
    SEL downscaleGetter =
        NSSelectorFromString(@"downscaleWindowIfNecessary");
    SEL downscaleSetter =
        NSSelectorFromString(@"setDownscaleWindowIfNecessary:");
    CGFloat idiom = ((CGFloat (*)(id, SEL))objc_msgSend)(
        (id)scaleClass,
        idiomGetter
    );
    if (!IOSUseBridgeApproximatelyEqual(idiom, 1.0)) {
        ((void (*)(id, SEL, CGFloat))objc_msgSend)(
            (id)scaleClass,
            idiomSetter,
            1.0
        );
    }
    CGFloat windows = ((CGFloat (*)(id, SEL))objc_msgSend)(
        (id)scaleClass,
        windowsGetter
    );
    if (!IOSUseBridgeApproximatelyEqual(windows, 1.0)) {
        ((void (*)(id, SEL, CGFloat))objc_msgSend)(
            (id)scaleClass,
            windowsSetter,
            1.0
        );
    }
    BOOL downscale = ((BOOL (*)(id, SEL))objc_msgSend)(
        (id)scaleClass,
        downscaleGetter
    );
    if (downscale) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(
            (id)scaleClass,
            downscaleSetter,
            NO
        );
    }
    IOSUsePlayObservedIdiomScale =
        ((CGFloat (*)(id, SEL))objc_msgSend)(
            (id)scaleClass,
            idiomGetter
        );
    IOSUsePlayObservedWindowScale =
        ((CGFloat (*)(id, SEL))objc_msgSend)(
            (id)scaleClass,
            windowsGetter
        );
    IOSUsePlayObservedDownscale =
        ((BOOL (*)(id, SEL))objc_msgSend)(
            (id)scaleClass,
            downscaleGetter
        );
    BOOL ready =
        IOSUseBridgeApproximatelyEqual(
            IOSUsePlayObservedIdiomScale,
            1.0
        ) &&
        IOSUseBridgeApproximatelyEqual(
            IOSUsePlayObservedWindowScale,
            1.0
        ) &&
        !IOSUsePlayObservedDownscale;
    IOSUsePlaySceneScaleStatus =
        ready ? @"configured" : @"rejected";
    IOSUsePlaySceneScaleFailure = ready
        ? nil
        : @"UIKitMacHelper rejected the identity scene scale";
    if (!ready && failure != NULL) {
        *failure = IOSUsePlaySceneScaleFailure;
    }
    return ready;
}

static BOOL IOSUseBridgeNormalizeBootstrapContentAspect(
    id window,
    NSString **failure
) {
    if (failure != NULL) {
        *failure = nil;
    }
    if (window != IOSUsePlayBootstrapContentWindow) {
        if (failure != NULL) {
            *failure =
                @"bootstrap content normalization lost its exact host";
        }
        return NO;
    }
    if (IOSUsePlayBootstrapContentReady) {
        return YES;
    }
    CGRect contentBounds = IOSUseBridgeRect(
        IOSUsePlayHostContentView,
        @"bounds"
    );
    IOSUsePlayHostCanvasLayout layout;
    NSString *layoutFailure = nil;
    if (!IOSUsePlayResolveHostCanvasLayout(
            contentBounds,
            IOSUseBridgeBackingScaleFactor(window),
            &layout,
            &layoutFailure
        )) {
        if (failure != NULL) {
            *failure = layoutFailure;
        }
        return NO;
    }
    if (IOSUsePlayHostCanvasFitsPixelQuantizedContent(
            layout,
            NULL
        )) {
        IOSUsePlayBootstrapContentReady = YES;
        return YES;
    }

    // UIKitMacHelper can publish an initial integral-point content size that
    // predates contentAspectRatio. Snap only that new host to the already
    // resolved aspect-fit size. Subsequent user resize stays entirely under
    // normal AppKit aspect-ratio handling.
    SEL setContentSize = NSSelectorFromString(@"setContentSize:");
    if (![window respondsToSelector:setContentSize]) {
        if (failure != NULL) {
            *failure =
                @"AppKit host cannot normalize its bootstrap content aspect";
        }
        return NO;
    }
    if (IOSUsePlayBootstrapContentNormalizationScheduled) {
        if (failure != NULL) {
            *failure =
                @"waiting for bootstrap content aspect normalization";
        }
        return NO;
    }
    if (IOSUsePlayBootstrapContentNormalizationAttempts >= 3) {
        if (failure != NULL) {
            *failure =
                @"AppKit host did not settle to its bootstrap content aspect";
        }
        return NO;
    }
    IOSUsePlayBootstrapContentNormalizationScheduled = YES;
    CGSize normalizedSize = layout.canvasRect.size;
    CGRect bootstrapContentBounds = contentBounds;
    id bootstrapContentView = IOSUsePlayHostContentView;
    NSUInteger bootstrapGeneration =
        IOSUsePlayHostContentGeneration;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (bootstrapGeneration !=
                IOSUsePlayHostContentGeneration ||
            window != IOSUsePlayBootstrapContentWindow ||
            bootstrapContentView != IOSUsePlayHostContentView) {
            return;
        }
        IOSUsePlayBootstrapContentNormalizationScheduled = NO;
        if (window != IOSUsePlayHostWindow) {
            return;
        }
        CGRect currentContentBounds = IOSUseBridgeRect(
            IOSUsePlayHostContentView,
            @"bounds"
        );
        if (IOSUseBridgeBool(window, @"inLiveResize") ||
            !IOSUseBridgeRectApproximatelyEqual(
                currentContentBounds,
                bootstrapContentBounds
            )) {
            return;
        }
        IOSUsePlayBootstrapContentNormalizationAttempts += 1;
        IOSUseBridgeSetSize(
            window,
            @"setContentSize:",
            normalizedSize
        );
    });
    if (failure != NULL) {
        *failure =
            @"waiting for bootstrap content aspect normalization";
    }
    return NO;
}

static BOOL IOSUseBridgeUpdateHostCanvasLayout(
    id window,
    NSString **failure
) {
    if (failure != NULL) {
        *failure = nil;
    }
    if (window != IOSUsePlayHostWindow ||
        IOSUsePlayHostContentView == nil ||
        IOSUsePlayScaleView == nil ||
        IOSUsePlayCanvasView == nil) {
        if (failure != NULL) {
            *failure = @"AppKit host canvas is not installed";
        }
        return NO;
    }
    CGRect contentBounds = IOSUseBridgeRect(
        IOSUsePlayHostContentView,
        @"bounds"
    );
    IOSUsePlayHostCanvasLayout layout;
    NSString *layoutFailure = nil;
    if (!IOSUsePlayResolveHostCanvasLayout(
            contentBounds,
            IOSUseBridgeBackingScaleFactor(window),
            &layout,
            &layoutFailure
        )) {
        IOSUsePlayHostCanvasLayoutReady = NO;
        if (failure != NULL) {
            *failure = layoutFailure;
        }
        return NO;
    }
    NSString *sceneScaleFailure = nil;
    BOOL sceneScaleReady =
        IOSUseBridgeReassertIdentitySceneScale(
            &sceneScaleFailure
        );
    CGRect requiredBounds = CGRectMake(
        0,
        0,
        IOSUsePlayDeviceLogicalWidth,
        IOSUsePlayDeviceLogicalHeight
    );
    CGRect currentFrame = IOSUseBridgeRect(
        IOSUsePlayScaleView,
        @"frame"
    );
    BOOL frameReady =
        IOSUseBridgeRectApproximatelyEqualWithTolerance(
            currentFrame,
            layout.canvasRect,
            layout.halfPixelTolerance
        ) ||
        IOSUseBridgeSetRect(
            IOSUsePlayScaleView,
            @"setFrame:",
            layout.canvasRect
        );
    // Our ordinary NSView wrapper is the single display-scale boundary: its
    // frame is the physical host canvas while its bounds remain the fixed
    // logical device. The UIKit-owned scene container stays entirely at
    // 430 x 932 inside it, so AppKit applies one uniform transform to every
    // UIKit surface and automatically inverse-maps native mouse input.
    // Never publish the host displayScale into UIKitMacHelper's class-global
    // window scale after scene creation; only the identity invariant above is
    // reasserted because late non-identity changes split independently hosted
    // UIKit layers across different scales.
    CGRect currentBounds = IOSUseBridgeRect(
        IOSUsePlayScaleView,
        @"bounds"
    );
    BOOL boundsReady =
        IOSUseBridgeRectApproximatelyEqual(
            currentBounds,
            requiredBounds
        ) ||
        IOSUseBridgeSetRect(
            IOSUsePlayScaleView,
            @"setBounds:",
            requiredBounds
        );
    CGRect currentCanvasFrame = IOSUseBridgeRect(
        IOSUsePlayCanvasView,
        @"frame"
    );
    BOOL canvasFrameReady =
        IOSUseBridgeRectApproximatelyEqual(
            currentCanvasFrame,
            requiredBounds
        ) ||
        IOSUseBridgeSetRect(
            IOSUsePlayCanvasView,
            @"setFrame:",
            requiredBounds
        );
    CGRect currentCanvasBounds = IOSUseBridgeRect(
        IOSUsePlayCanvasView,
        @"bounds"
    );
    BOOL canvasBoundsReady =
        IOSUseBridgeRectApproximatelyEqual(
            currentCanvasBounds,
            requiredBounds
        ) ||
        IOSUseBridgeSetRect(
            IOSUsePlayCanvasView,
            @"setBounds:",
            requiredBounds
        );
    if (frameReady && boundsReady &&
        canvasFrameReady && canvasBoundsReady) {
        IOSUseBridgeLayoutIfNeeded(IOSUsePlayHostContentView);
        IOSUseBridgeLayoutIfNeeded(IOSUsePlayScaleView);
        IOSUseBridgeLayoutIfNeeded(IOSUsePlayCanvasView);
    }
    CGRect resolvedFrame = IOSUseBridgeRect(
        IOSUsePlayScaleView,
        @"frame"
    );
    CGRect resolvedBounds = IOSUseBridgeRect(
        IOSUsePlayScaleView,
        @"bounds"
    );
    CGRect resolvedCanvasFrame = IOSUseBridgeRect(
        IOSUsePlayCanvasView,
        @"frame"
    );
    CGRect resolvedCanvasBounds = IOSUseBridgeRect(
        IOSUsePlayCanvasView,
        @"bounds"
    );
    id sceneRenderView =
        IOSUseBridgeSceneRenderView(IOSUsePlayCanvasView);
    BOOL sceneRenderViewReady =
        IOSUseBridgeNormalizeLogicalRenderView(
            sceneRenderView,
            requiredBounds
        );
    id inputRenderView =
        IOSUseBridgeInputRenderView(sceneRenderView);
    BOOL inputRenderViewReady =
        IOSUseBridgeNormalizeLogicalRenderView(
            inputRenderView,
            requiredBounds
        );
    CGRect resolvedSceneFrame =
        IOSUseBridgeRect(sceneRenderView, @"frame");
    CGRect resolvedSceneBounds =
        IOSUseBridgeRect(sceneRenderView, @"bounds");
    CGRect resolvedInputFrame =
        IOSUseBridgeRect(inputRenderView, @"frame");
    CGRect resolvedInputBounds =
        IOSUseBridgeRect(inputRenderView, @"bounds");
    BOOL renderTreeReady =
        sceneRenderViewReady &&
        inputRenderViewReady &&
        IOSUseBridgeRectIsDeviceScreen(resolvedSceneFrame) &&
        IOSUseBridgeRectIsDeviceScreen(resolvedSceneBounds) &&
        IOSUseBridgeRectIsDeviceScreen(resolvedInputFrame) &&
        IOSUseBridgeRectIsDeviceScreen(resolvedInputBounds);
    if (!sceneScaleReady ||
        !boundsReady || !frameReady ||
        !canvasFrameReady || !canvasBoundsReady ||
        !renderTreeReady ||
        !IOSUseBridgeRectApproximatelyEqualWithTolerance(
            resolvedFrame,
            layout.canvasRect,
            layout.halfPixelTolerance
        ) ||
        !IOSUseBridgeRectApproximatelyEqual(
            resolvedBounds,
            requiredBounds
        ) ||
        !IOSUseBridgeRectApproximatelyEqual(
            resolvedCanvasFrame,
            requiredBounds
        ) ||
        !IOSUseBridgeRectApproximatelyEqual(
            resolvedCanvasBounds,
            requiredBounds
        )) {
        IOSUsePlayHostCanvasLayoutReady = NO;
        if (failure != NULL) {
            *failure = sceneScaleFailure ?:
                [NSString stringWithFormat:
                @"UIKit render tree is not the fixed logical canvas "
                 @"(scale=%@/%@ canvas=%@/%@ scene=%@/%@ input=%@/%@)",
                NSStringFromCGRect(resolvedFrame),
                NSStringFromCGRect(resolvedBounds),
                NSStringFromCGRect(resolvedCanvasFrame),
                NSStringFromCGRect(resolvedCanvasBounds),
                NSStringFromCGRect(resolvedSceneFrame),
                NSStringFromCGRect(resolvedSceneBounds),
                NSStringFromCGRect(resolvedInputFrame),
                NSStringFromCGRect(resolvedInputBounds)
            ];
        }
        return NO;
    }
    IOSUsePlayCurrentHostCanvasLayout = layout;
    IOSUsePlayHostCanvasLayoutReady = YES;
    return YES;
}

static void IOSUseBridgeScheduleHostCanvasLayoutUpdate(void) {
    NSCAssert(NSThread.isMainThread, @"host layout scheduling must be main-thread");
    if (IOSUsePlayHostCanvasLayoutUpdateScheduled) {
        return;
    }
    IOSUsePlayHostCanvasLayoutUpdateScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        IOSUsePlayHostCanvasLayoutUpdateScheduled = NO;
        if (IOSUsePlayHostWindow != nil) {
            IOSUseBridgeUpdateHostCanvasLayout(
                IOSUsePlayHostWindow,
                NULL
            );
        }
    });
}

static NSArray<NSDictionary<NSString *, id> *> *
IOSUseBridgeWindowInventory(void) {
    id application = IOSUseBridgeApplication();
    SEL windowsSelector = NSSelectorFromString(@"windows");
    id windows = [application respondsToSelector:windowsSelector]
        ? ((IOSUseBridgeSendID)objc_msgSend)(
            application,
            windowsSelector
        )
        : nil;
    if (![windows isKindOfClass:NSArray.class]) {
        return @[];
    }
    UIWindow *keyUIKitWindow = IOSUseBridgeKeyUIKitWindow();
    NSMutableArray<NSDictionary<NSString *, id> *> *result =
        [NSMutableArray array];
    for (id candidate in (NSArray *)windows) {
        SEL uiWindowsSelector = NSSelectorFromString(@"uiWindows");
        id uiWindows = [candidate respondsToSelector:uiWindowsSelector]
            ? ((IOSUseBridgeSendID)objc_msgSend)(
                candidate,
                uiWindowsSelector
            )
            : nil;
        SEL parentSelector = NSSelectorFromString(@"parentWindow");
        id parent = [candidate respondsToSelector:parentSelector]
            ? ((IOSUseBridgeSendID)objc_msgSend)(
                candidate,
                parentSelector
            )
            : nil;
        SEL contentViewSelector = NSSelectorFromString(@"contentView");
        id contentView = [candidate respondsToSelector:
            contentViewSelector]
            ? ((IOSUseBridgeSendID)objc_msgSend)(
                candidate,
                contentViewSelector
            )
            : nil;
        [result addObject:@{
            @"class": NSStringFromClass([candidate class]),
            @"contentClass": contentView == nil
                ? NSNull.null
                : NSStringFromClass([contentView class]),
            @"windowNumber": @(
                IOSUseBridgeInteger(candidate, @"windowNumber")
            ),
            @"level": @(
                IOSUseBridgeInteger(candidate, @"level")
            ),
            @"visible": @(
                IOSUseBridgeBool(candidate, @"isVisible")
            ),
            @"frame": IOSUseBridgeRectJSON(
                IOSUseBridgeRect(candidate, @"frame")
            ),
            @"content": IOSUseBridgeRectJSON(
                IOSUseBridgeRect(candidate, @"contentLayoutRect")
            ),
            @"uiWindowCount":
                [uiWindows isKindOfClass:NSArray.class]
                    ? @([(NSArray *)uiWindows count])
                    : @0,
            @"containsKeyUIKitWindow": @(
                [uiWindows isKindOfClass:NSArray.class] &&
                [(NSArray *)uiWindows containsObject:keyUIKitWindow]
            ),
            @"parentClass": parent == nil
                ? NSNull.null
                : NSStringFromClass([parent class]),
            @"parentFrame": IOSUseBridgeRectJSON(
                IOSUseBridgeRect(parent, @"frame")
            ),
        }];
    }
    return result;
}

static NSArray *IOSUseBridgeNativeAlertWindows(void) {
#if defined(IOS_USE_PLAY_APPKIT_BRIDGE_TESTING)
    if (IOSUseBridgeNativeAlertWindowsProviderForTesting != NULL) {
        return IOSUseBridgeNativeAlertWindowsProviderForTesting();
    }
#endif
    id application = IOSUseBridgeApplication();
    id windows = [application respondsToSelector:
        NSSelectorFromString(@"windows")]
        ? ((IOSUseBridgeSendID)objc_msgSend)(
            application,
            NSSelectorFromString(@"windows")
        )
        : nil;
    return [windows isKindOfClass:NSArray.class]
        ? windows
        : nil;
}

static BOOL IOSUseBridgeWindowLooksLikeNativeAlertCandidate(
    id window
) {
    if (!IOSUseBridgeBool(window, @"isVisible") ||
        IOSUseBridgeInteger(window, @"windowNumber") <= 0) {
        return NO;
    }
    id contentView = [window respondsToSelector:
        NSSelectorFromString(@"contentView")]
        ? ((IOSUseBridgeSendID)objc_msgSend)(
            window,
            NSSelectorFromString(@"contentView")
        )
        : nil;
    NSString *windowClass =
        NSStringFromClass([window class]) ?: @"";
    NSString *contentClass =
        NSStringFromClass([contentView class]) ?: @"";
    return [windowClass containsString:@"AlertPanel"] &&
        [contentClass containsString:@"AlertContent"];
}

static BOOL IOSUseBridgeHasVisibleNativeAlertCandidateInWindows(
    NSArray *windows
) {
    if (![windows isKindOfClass:NSArray.class]) {
        return NO;
    }
    for (id window in windows) {
        if (IOSUseBridgeWindowLooksLikeNativeAlertCandidate(window)) {
            return YES;
        }
    }
    return NO;
}

static NSDictionary<NSString *, id> *
IOSUseBridgeVisibleNativeAlertSelectionFromWindows(
    NSArray *windows,
    NSDictionary<
        NSNumber *,
        NSDictionary<NSString *, id> *
    > *cgMetadata
) {
    if (![windows isKindOfClass:NSArray.class] ||
        cgMetadata == nil) {
        return nil;
    }
    NSMutableArray<NSDictionary<NSString *, id> *> *candidates =
        [NSMutableArray array];
    NSMutableSet<NSNumber *> *windowNumbers =
        [NSMutableSet set];
    for (id window in (NSArray *)windows) {
        if (!IOSUseBridgeWindowLooksLikeNativeAlertCandidate(
                window
            )) {
            continue;
        }
        NSDictionary<NSString *, id> *exactMetadata =
            IOSUseBridgeExactOnscreenCGWindowMetadata(
                window,
                cgMetadata
            );
        NSInteger rawWindowNumber = IOSUseBridgeInteger(
            window,
            @"windowNumber"
        );
        NSNumber *windowNumber = @((uint32_t)rawWindowNumber);
        if (exactMetadata == nil) {
            // A visible-looking AppKit object without the exact own-process
            // onscreen CGWindow identity is a stale/phantom alert panel.
            continue;
        }
        if ([windowNumbers containsObject:windowNumber]) {
            // Do not guess when AppKit exposes two objects for one native
            // identity.
            return nil;
        }
        [windowNumbers addObject:windowNumber];
        [candidates addObject:@{
            @"window": window,
            @"windowNumber": windowNumber,
            @"frontToBackIndex":
                exactMetadata[@"frontToBackIndex"],
            @"cgMetadata": cgMetadata,
        }];
    }
    [candidates sortUsingComparator:^NSComparisonResult(
        NSDictionary<NSString *, id> *left,
        NSDictionary<NSString *, id> *right
    ) {
        NSUInteger leftIndex =
            [left[@"frontToBackIndex"] unsignedIntegerValue];
        NSUInteger rightIndex =
            [right[@"frontToBackIndex"] unsignedIntegerValue];
        if (leftIndex < rightIndex) {
            return NSOrderedAscending;
        }
        if (leftIndex > rightIndex) {
            return NSOrderedDescending;
        }
        return NSOrderedSame;
    }];
    return candidates.firstObject;
}

static NSDictionary<NSString *, id> *
IOSUseBridgeVisibleNativeAlertSelectionWithCGWindowMetadata(
    NSDictionary<
        NSNumber *,
        NSDictionary<NSString *, id> *
    > *cgMetadata
) {
    return IOSUseBridgeVisibleNativeAlertSelectionFromWindows(
        IOSUseBridgeNativeAlertWindows(),
        cgMetadata
    );
}

static NSDictionary<NSString *, id> *
IOSUseBridgeVisibleNativeAlertSelection(void) {
    NSArray *windows = IOSUseBridgeNativeAlertWindows();
    NSDictionary<
        NSNumber *,
        NSDictionary<NSString *, id> *
    > *cgMetadata = IOSUseBridgeOwnOnscreenCGWindowMetadata();
    return IOSUseBridgeVisibleNativeAlertSelectionFromWindows(
        windows,
        cgMetadata
    );
}

#if defined(IOS_USE_PLAY_APPKIT_BRIDGE_TESTING)
void IOSUsePlayAppKitBridgeSetNativeAlertWindowsProviderForTesting(
    IOSUseBridgeNativeAlertWindowsProvider windowsProvider
) {
    IOSUseBridgeNativeAlertWindowsProviderForTesting =
        windowsProvider;
}

NSDictionary<NSString *, id> * _Nullable
IOSUsePlayAppKitBridgeSelectVisibleNativeAlertForTesting(
    NSArray * _Nullable windows,
    NSDictionary<
        NSNumber *,
        NSDictionary<NSString *, id> *
    > * _Nullable cgMetadata
) {
    return IOSUseBridgeVisibleNativeAlertSelectionFromWindows(
        windows,
        cgMetadata
    );
}

BOOL IOSUsePlayAppKitBridgeHasVisibleNativeAlertCandidateForTesting(
    NSArray * _Nullable windows
) {
    return IOSUseBridgeHasVisibleNativeAlertCandidateInWindows(
        windows
    );
}
#endif

/// A launch-time system panel can legitimately appear before UIKit has
/// connected its first scene.  It cannot participate in target automation:
/// there is neither a fixed canvas nor an exact CGWindow/canvas mapping yet.
/// Keep it separate from IOSUseBridgeVisibleNativeAlertSelection, whose
/// strict identity policy protects normal in-canvas native-alert routing.
static NSDictionary<NSString *, id> *
IOSUseBridgeBootstrapNativeAlertSelection(void) {
    if (IOSUsePlayHostWindow != nil ||
        IOSUseBridgeKeyUIKitWindow() != nil) {
        return nil;
    }
    id application = IOSUseBridgeApplication();
    id windows = [application respondsToSelector:
        NSSelectorFromString(@"windows")]
        ? ((IOSUseBridgeSendID)objc_msgSend)(
            application,
            NSSelectorFromString(@"windows")
        )
        : nil;
    if (![windows isKindOfClass:NSArray.class]) {
        return nil;
    }
    NSMutableArray<NSDictionary<NSString *, id> *> *candidates =
        [NSMutableArray array];
    for (id window in (NSArray *)windows) {
        if (!IOSUseBridgeBool(window, @"isVisible") ||
            !IOSUseBridgeBool(window, @"isKeyWindow")) {
            continue;
        }
        NSInteger rawWindowNumber = IOSUseBridgeInteger(
            window,
            @"windowNumber"
        );
        if (rawWindowNumber <= 0 ||
            (uint64_t)rawWindowNumber > UINT32_MAX) {
            continue;
        }
        id contentView = [window respondsToSelector:
            NSSelectorFromString(@"contentView")]
            ? ((IOSUseBridgeSendID)objc_msgSend)(
                window,
                NSSelectorFromString(@"contentView")
            )
            : nil;
        NSString *windowClass =
            NSStringFromClass([window class]) ?: @"";
        NSString *contentClass =
            NSStringFromClass([contentView class]) ?: @"";
        if (![windowClass containsString:@"AlertPanel"] ||
            ![contentClass containsString:@"AlertContent"]) {
            continue;
        }
        [candidates addObject:@{
            @"window": window,
            @"contentView": contentView,
            @"windowNumber": @((uint32_t)rawWindowNumber),
            @"class": windowClass,
            @"contentClass": contentClass,
        }];
    }
    // Never guess between more than one launch-time panel.
    return candidates.count == 1 ? candidates.firstObject : nil;
}

static void IOSUseBridgeCollectAlertButtons(
    id view,
    NSMutableArray *buttons,
    NSUInteger *visited
) {
    if (view == nil || *visited >= 512) {
        return;
    }
    *visited += 1;
    Class buttonClass = NSClassFromString(@"NSButton");
    if (buttonClass != Nil &&
        [view isKindOfClass:buttonClass] &&
        !IOSUseBridgeBool(view, @"isHidden") &&
        IOSUseBridgeBool(view, @"isEnabled")) {
        [buttons addObject:view];
    }
    id subviews = [view respondsToSelector:
        NSSelectorFromString(@"subviews")]
        ? ((IOSUseBridgeSendID)objc_msgSend)(
            view,
            NSSelectorFromString(@"subviews")
        )
        : nil;
    if (![subviews isKindOfClass:NSArray.class]) {
        return;
    }
    for (id child in (NSArray *)subviews) {
        IOSUseBridgeCollectAlertButtons(child, buttons, visited);
    }
}

static void IOSUseBridgeCollectAlertTextFields(
    id view,
    NSMutableArray *textFields,
    NSUInteger *visited
) {
    if (view == nil || *visited >= 512) {
        return;
    }
    *visited += 1;
    Class textFieldClass = NSClassFromString(@"NSTextField");
    if (textFieldClass != Nil &&
        [view isKindOfClass:textFieldClass] &&
        !IOSUseBridgeBool(view, @"isHidden")) {
        id value = [view respondsToSelector:
            NSSelectorFromString(@"stringValue")]
            ? ((IOSUseBridgeSendID)objc_msgSend)(
                view,
                NSSelectorFromString(@"stringValue")
            )
            : nil;
        if ([value isKindOfClass:NSString.class]) {
            NSString *text = [(NSString *)value
                stringByTrimmingCharactersInSet:
                    NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (text.length > 0 && text.length <= 4096) {
                [textFields addObject:view];
            }
        }
    }
    id subviews = [view respondsToSelector:
        NSSelectorFromString(@"subviews")]
        ? ((IOSUseBridgeSendID)objc_msgSend)(
            view,
            NSSelectorFromString(@"subviews")
        )
        : nil;
    if (![subviews isKindOfClass:NSArray.class]) {
        return;
    }
    for (id child in (NSArray *)subviews) {
        IOSUseBridgeCollectAlertTextFields(
            child,
            textFields,
            visited
        );
    }
}

/// This is deliberately text-only evidence for the pre-scene launch panel.
/// It does not assign canvas coordinates or expose an action delivery path.
static NSString *IOSUseBridgeBootstrapNativeAlertText(id contentView) {
    NSMutableArray *textFields = [NSMutableArray array];
    NSUInteger visited = 0;
    IOSUseBridgeCollectAlertTextFields(
        contentView,
        textFields,
        &visited
    );
    NSMutableOrderedSet<NSString *> *lines =
        [NSMutableOrderedSet orderedSet];
    for (id textField in textFields) {
        id value = [textField respondsToSelector:
            NSSelectorFromString(@"stringValue")]
            ? ((IOSUseBridgeSendID)objc_msgSend)(
                textField,
                NSSelectorFromString(@"stringValue")
            )
            : nil;
        if (![value isKindOfClass:NSString.class]) {
            continue;
        }
        NSString *line = [(NSString *)value
            stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (line.length > 0 && line.length <= 4096) {
            [lines addObject:line];
        }
    }
    return [[lines array] componentsJoinedByString:@"\n"];
}

static NSArray<NSString *> *IOSUseBridgeBootstrapNativeAlertActions(
    id contentView
) {
    NSMutableArray *buttons = [NSMutableArray array];
    NSUInteger visited = 0;
    IOSUseBridgeCollectAlertButtons(contentView, buttons, &visited);
    NSMutableOrderedSet<NSString *> *labels =
        [NSMutableOrderedSet orderedSet];
    for (id button in buttons) {
        id title = [button respondsToSelector:
            NSSelectorFromString(@"title")]
            ? ((IOSUseBridgeSendID)objc_msgSend)(
                button,
                NSSelectorFromString(@"title")
            )
            : nil;
        if (![title isKindOfClass:NSString.class]) {
            continue;
        }
        NSString *label = [(NSString *)title
            stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (label.length > 0 && label.length <= 4096) {
            [labels addObject:label];
        }
    }
    return [labels array];
}

static NSDictionary<NSString *, id> *
IOSUseBridgeBootstrapNativeAlertDiagnostics(void) {
    NSDictionary<NSString *, id> *selection =
        IOSUseBridgeBootstrapNativeAlertSelection();
    if (selection == nil) {
        return @{
            @"visible": @NO,
            @"preSceneOwnProcess": @NO,
            @"geometryAvailable": @NO,
            @"windowNumber": @0,
            @"class": NSNull.null,
            @"contentClass": NSNull.null,
            @"text": @"",
            @"actions": @[],
        };
    }
    return @{
        @"visible": @YES,
        @"preSceneOwnProcess": @YES,
        @"geometryAvailable": @NO,
        @"windowNumber": selection[@"windowNumber"],
        @"class": selection[@"class"],
        @"contentClass": selection[@"contentClass"],
        @"text": IOSUseBridgeBootstrapNativeAlertText(
            selection[@"contentView"]
        ),
        @"actions": IOSUseBridgeBootstrapNativeAlertActions(
            selection[@"contentView"]
        ),
    };
}

static CGRect IOSUseBridgeAlertButtonLogicalFrame(
    id button,
    id alertWindow
) {
    CGRect bounds = IOSUseBridgeRect(button, @"bounds");
    SEL convertSelector = NSSelectorFromString(@"convertRect:toView:");
    SEL toScreenSelector = NSSelectorFromString(@"convertRectToScreen:");
    if (![button respondsToSelector:convertSelector] ||
        ![alertWindow respondsToSelector:toScreenSelector]) {
        return CGRectNull;
    }
    CGRect windowLocalRect =
        ((IOSUseBridgeSendRectRectID)objc_msgSend)(
            button,
            convertSelector,
            bounds,
            nil
        );
    CGRect appKitScreenRect = ((IOSUseBridgeSendRectRect)objc_msgSend)(
        alertWindow,
        toScreenSelector,
        windowLocalRect
    );
    return IOSUseBridgeAppKitScreenRectToCanvasLogicalRect(
        appKitScreenRect,
        IOSUsePlayHostWindow,
        NULL
    );
}

static BOOL IOSUseBridgeHostContentCGWindowRect(
    id window,
    id contentView,
    CGRect *contentCGWindowRect
) {
    SEL convertRectSelector = NSSelectorFromString(@"convertRect:toView:");
    SEL convertToScreenSelector = NSSelectorFromString(@"convertRectToScreen:");
    if (window == nil || contentView == nil ||
        ![contentView respondsToSelector:convertRectSelector] ||
        ![window respondsToSelector:convertToScreenSelector]) {
        return NO;
    }
    CGRect contentBounds = IOSUseBridgeRect(contentView, @"bounds");
    if (CGRectIsEmpty(contentBounds)) {
        return NO;
    }
    CGRect windowLocal = ((IOSUseBridgeSendRectRectID)objc_msgSend)(
        contentView,
        convertRectSelector,
        contentBounds,
        nil
    );
    CGRect screenRect = ((IOSUseBridgeSendRectRect)objc_msgSend)(
        window,
        convertToScreenSelector,
        windowLocal
    );
    CGRect resolved = CGRectNull;
    CGFloat backingScaleFactor =
        IOSUseBridgeBackingScaleFactor(window);
    CGFloat geometryTolerance = backingScaleFactor > 0
        ? 0.5 / backingScaleFactor
        : 0;
    if (!IOSUseBridgeAppKitScreenRectToCGWindowRect(
            screenRect,
            &resolved
        ) ||
        geometryTolerance <= 0 ||
        fabs(
            resolved.size.width - contentBounds.size.width
        ) > geometryTolerance ||
        fabs(
            resolved.size.height - contentBounds.size.height
        ) > geometryTolerance) {
        return NO;
    }
    if (contentCGWindowRect != NULL) {
        *contentCGWindowRect = resolved;
    }
    return YES;
}

static NSDictionary<NSString *, id> *
IOSUseBridgeHostCanvasCaptureGeometry(
    id window,
    NSDictionary<
        NSNumber *,
        NSDictionary<NSString *, id> *
    > *cgMetadata,
    NSError **error
) {
    if (window == nil || window != IOSUsePlayHostWindow ||
        !IOSUsePlayHostCanvasLayoutReady) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:IOSUsePlayWindowErrorDomain
                                         code:7
                                     userInfo:@{
                NSLocalizedDescriptionKey:
                    @"AppKit host canvas is not ready for capture",
            }];
        }
        return nil;
    }
    NSDictionary<NSString *, id> *hostMetadata =
        IOSUseBridgeExactOnscreenCGWindowMetadata(window, cgMetadata);
    CGRect hostCGWindowBounds = hostMetadata == nil
        ? CGRectNull
        : [hostMetadata[@"boundsValue"] CGRectValue];
    CGRect contentCGWindowRect = CGRectNull;
    CGRect canvasCGWindowRect = CGRectNull;
    NSString *canvasFailure = nil;
    BOOL contentReady = IOSUseBridgeHostContentCGWindowRect(
        window,
        IOSUsePlayHostContentView,
        &contentCGWindowRect
    );
    BOOL canvasReady = contentReady &&
        IOSUsePlayResolveCanvasCGWindowRect(
            contentCGWindowRect,
            IOSUsePlayCurrentHostCanvasLayout,
            &canvasCGWindowRect,
            &canvasFailure
        );
    CGFloat geometryTolerance =
        IOSUsePlayCurrentHostCanvasLayout.halfPixelTolerance;
    if (hostMetadata == nil || CGRectIsNull(hostCGWindowBounds) ||
        !canvasReady ||
        CGRectGetMinX(canvasCGWindowRect) <
            CGRectGetMinX(hostCGWindowBounds) - geometryTolerance ||
        CGRectGetMinY(canvasCGWindowRect) <
            CGRectGetMinY(hostCGWindowBounds) - geometryTolerance ||
        CGRectGetMaxX(canvasCGWindowRect) >
            CGRectGetMaxX(hostCGWindowBounds) + geometryTolerance ||
        CGRectGetMaxY(canvasCGWindowRect) >
            CGRectGetMaxY(hostCGWindowBounds) + geometryTolerance) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:IOSUsePlayWindowErrorDomain
                                         code:8
                                     userInfo:@{
                NSLocalizedDescriptionKey: canvasFailure ?:
                    @"could not resolve the fixed canvas inside the host CGWindow",
            }];
        }
        return nil;
    }
    return @{
        @"hostFrame": IOSUseBridgeRectJSON(
            IOSUseBridgeRect(window, @"frame")
        ),
        @"hostContentBounds": IOSUseBridgeRectJSON(
            IOSUsePlayCurrentHostCanvasLayout.hostContentBounds
        ),
        @"hostContentCGWindowRect": IOSUseBridgeRectJSON(
            contentCGWindowRect
        ),
        @"hostCGWindowBounds": IOSUseBridgeRectJSON(hostCGWindowBounds),
        @"canvasRect": IOSUseBridgeRectJSON(
            IOSUsePlayCurrentHostCanvasLayout.canvasRect
        ),
        @"backingPixelCanvasRect": IOSUseBridgeRectJSON(
            IOSUsePlayCurrentHostCanvasLayout.backingPixelCanvasRect
        ),
        @"canvasCGWindowRect": IOSUseBridgeRectJSON(canvasCGWindowRect),
        @"displayScale": @(IOSUsePlayCurrentHostCanvasLayout.displayScale),
        @"inverseDisplayScale": @(
            IOSUsePlayCurrentHostCanvasLayout.inverseDisplayScale
        ),
        @"backingScaleFactor": @(
            IOSUsePlayCurrentHostCanvasLayout.backingScaleFactor
        ),
        @"halfPixelTolerance": @(
            IOSUsePlayCurrentHostCanvasLayout.halfPixelTolerance
        ),
        @"hostWindowNumber": @(
            IOSUseBridgeInteger(window, @"windowNumber")
        ),
        @"title": IOSUseBridgeHostTitle(),
    };
}

static CGRect IOSUseBridgeWindowLogicalFrame(
    id window,
    NSDictionary<
        NSNumber *,
        NSDictionary<NSString *, id> *
    > *cgMetadata
) {
    id hostWindow = IOSUsePlayHostWindow;
    NSDictionary<NSString *, id> *windowMetadata =
        IOSUseBridgeExactOnscreenCGWindowMetadata(window, cgMetadata);
    NSError *canvasError = nil;
    NSDictionary<NSString *, id> *canvasGeometry =
        IOSUseBridgeHostCanvasCaptureGeometry(
            hostWindow,
            cgMetadata,
            &canvasError
        );
    if (window == nil || windowMetadata == nil ||
        canvasGeometry == nil || canvasError != nil) {
        return CGRectNull;
    }
    NSDictionary<NSString *, id> *rawCanvas =
        canvasGeometry[@"canvasCGWindowRect"];
    CGRect canvasCGWindowRect = CGRectNull;
    if (![rawCanvas isKindOfClass:NSDictionary.class] ||
        ![rawCanvas[@"x"] isKindOfClass:NSNumber.class] ||
        ![rawCanvas[@"y"] isKindOfClass:NSNumber.class] ||
        ![rawCanvas[@"width"] isKindOfClass:NSNumber.class] ||
        ![rawCanvas[@"height"] isKindOfClass:NSNumber.class]) {
        return CGRectNull;
    }
    canvasCGWindowRect = CGRectMake(
        [rawCanvas[@"x"] doubleValue],
        [rawCanvas[@"y"] doubleValue],
        [rawCanvas[@"width"] doubleValue],
        [rawCanvas[@"height"] doubleValue]
    );
    if (!IOSUseBridgeAccessibilityFiniteRect(canvasCGWindowRect)) {
        return CGRectNull;
    }
    CGRect logicalRect = CGRectNull;
    if (!IOSUsePlayResolveCGWindowRectInCanvas(
            [windowMetadata[@"boundsValue"] CGRectValue],
            canvasCGWindowRect,
            [canvasGeometry[@"displayScale"] doubleValue],
            [canvasGeometry[@"backingScaleFactor"] doubleValue],
            &logicalRect,
            NULL
        )) {
        return CGRectNull;
    }
    return logicalRect;
}

static BOOL IOSUseBridgeInstallMouseLocalMonitor(void) {
    NSCAssert(NSThread.isMainThread, @"mouse monitor is main-only");
    if (IOSUsePlayMouseLocalMonitor != nil) {
        return IOSUsePlayHookRegistryEntryReady(
            @"appkit.mouse-monitor.selector"
        ) && IOSUsePlayHookRegistryEntryReady(
            @"appkit.mouse-monitor.token"
        );
    }
    Class eventClass = NSClassFromString(@"NSEvent");
    SEL addMonitorSelector = NSSelectorFromString(
        @"addLocalMonitorForEventsMatchingMask:handler:"
    );
    const char *monitorArguments[] = {
        @encode(NSUInteger),
        "@?",
    };
    NSError *preflightError = nil;
    if (!IOSUsePlayHookRegistryObserveMethod(
            @"appkit.mouse-monitor.selector",
            YES,
            @"first-scene",
            eventClass,
            YES,
            addMonitorSelector,
            @encode(id),
            monitorArguments,
            2,
            YES,
            NO,
            &preflightError
        )) {
        IOSUsePlayHookRegistryRecordState(
            @"appkit.mouse-monitor.token",
            YES,
            @"first-scene",
            @"NSEvent",
            @"local-monitor-token",
            @"id",
            NO,
            NO,
            preflightError.localizedDescription ?:
                @"mouse monitor selector preflight failed"
        );
        return NO;
    }
    // NSEventTypeLeftMouseDown == 1 and LeftMouseUp == 2. NSEventMask is
    // defined as one shifted by NSEventType in pinned PlayTools/AppKit.
    NSUInteger mask = ((NSUInteger)1 << 1) | ((NSUInteger)1 << 2);
    id handler = ^id(id event) {
        CGEventRef cgEvent = [event respondsToSelector:
            NSSelectorFromString(@"CGEvent")]
            ? ((IOSUseBridgeSendCGEvent)objc_msgSend)(
                event,
                NSSelectorFromString(@"CGEvent")
            )
            : NULL;
        int64_t token = cgEvent == NULL
            ? 0
            : CGEventGetIntegerValueField(
                cgEvent,
                kCGEventSourceUserData
            );
        if (token == 0) {
            return event;
        }
        id eventWindow = [event respondsToSelector:
            NSSelectorFromString(@"window")]
            ? ((IOSUseBridgeSendID)objc_msgSend)(
                event,
                NSSelectorFromString(@"window")
            )
            : nil;
        NSInteger windowNumber =
            IOSUseBridgeInteger(eventWindow, @"windowNumber");
        CGPoint localPoint = [event respondsToSelector:
            NSSelectorFromString(@"locationInWindow")]
            ? ((IOSUseBridgeSendPoint)objc_msgSend)(
                event,
                NSSelectorFromString(@"locationInWindow")
            )
            : CGPointMake(NAN, NAN);
        CGPoint hostContentPoint = CGPointMake(NAN, NAN);
        CGPoint logicalPoint = CGPointMake(NAN, NAN);
        NSString *layoutFailure = nil;
        BOOL hostCanvasReady = eventWindow == IOSUsePlayHostWindow &&
            IOSUseBridgeUpdateHostCanvasLayout(
                IOSUsePlayHostWindow,
                &layoutFailure
            );
        if (hostCanvasReady &&
            [IOSUsePlayHostContentView respondsToSelector:
                NSSelectorFromString(@"convertPoint:fromView:")]) {
            hostContentPoint =
                ((IOSUseBridgeSendPointPointID)objc_msgSend)(
                    IOSUsePlayHostContentView,
                    NSSelectorFromString(@"convertPoint:fromView:"),
                    localPoint,
                    nil
                );
        }
        NSString *inverseFailure = nil;
        BOOL targetHitTest = hostCanvasReady &&
            IOSUsePlayMapHostContentPointToCanvas(
                IOSUsePlayCurrentHostCanvasLayout,
                hostContentPoint,
                &logicalPoint,
                &inverseFailure
            );
        BOOL geometryReady = hostCanvasReady &&
            isfinite(localPoint.x) &&
            isfinite(localPoint.y) &&
            isfinite(hostContentPoint.x) &&
            isfinite(hostContentPoint.y);
        int64_t sourcePID = cgEvent == NULL
            ? 0
            : CGEventGetIntegerValueField(
                cgEvent,
                kCGEventSourceUnixProcessID
            );
        NSInteger eventType = IOSUseBridgeInteger(event, @"type");
        NSString *phase = eventType == 1
            ? @"down"
            : eventType == 2 ? @"up" : @"unknown";
        IOSUsePlayMouseDeliveryCount += 1;
        NSDictionary<NSString *, id> *delivery = @{
            @"token": @(token),
            @"sourcePID": @(sourcePID),
            @"targetPID": @(getpid()),
            @"windowNumber": @(windowNumber),
            @"phase": phase,
            @"sequence": @(IOSUsePlayMouseDeliveryCount),
            @"localPoint": @{
                @"x": @(localPoint.x),
                @"y": @(localPoint.y),
            },
            @"hostContentPoint": @{
                @"x": @(hostContentPoint.x),
                @"y": @(hostContentPoint.y),
            },
            @"logicalPoint": targetHitTest
                ? @{ @"x": @(logicalPoint.x), @"y": @(logicalPoint.y) }
                : (id)NSNull.null,
            @"canvasRect": hostCanvasReady
                ? IOSUseBridgeRectJSON(
                    IOSUsePlayCurrentHostCanvasLayout.canvasRect
                )
                : (id)NSNull.null,
            @"displayScale": hostCanvasReady
                ? @(IOSUsePlayCurrentHostCanvasLayout.displayScale)
                : (id)NSNull.null,
            @"inverseDisplayScale": hostCanvasReady
                ? @(IOSUsePlayCurrentHostCanvasLayout.inverseDisplayScale)
                : (id)NSNull.null,
            @"targetHitTest": @(targetHitTest),
            @"transformFailure": layoutFailure ?: inverseFailure ?:
                (id)NSNull.null,
            @"geometryReady": @(geometryReady),
        };
        IOSUsePlayLastMouseDelivery = delivery;
        if (eventType == 1) {
            IOSUsePlayLastMouseDownDelivery = delivery;
        } else if (eventType == 2) {
            IOSUsePlayLastMouseUpDelivery = delivery;
        }
        return event;
    };
    IOSUsePlayMouseLocalMonitor = (
        (IOSUseBridgeSendIDUnsignedIntegerID)objc_msgSend
    )(
        (id)eventClass,
        addMonitorSelector,
        mask,
        handler
    );
    IOSUsePlayHookRegistryRecordInvocation(
        @"appkit.mouse-monitor.selector"
    );
    BOOL installed = IOSUsePlayMouseLocalMonitor != nil;
    IOSUsePlayHookRegistryRecordState(
        @"appkit.mouse-monitor.token",
        YES,
        @"first-scene",
        @"NSEvent",
        @"local-monitor-token",
        @"id",
        NO,
        installed,
        installed ? nil : @"NSEvent returned no local monitor token"
    );
    return installed;
}

static NSArray<NSDictionary<NSString *, id> *> *
IOSUseBridgeNativeAlertActionInventory(id alertWindow) {
    if (alertWindow == nil) {
        return @[];
    }
    id contentView = [alertWindow respondsToSelector:
        NSSelectorFromString(@"contentView")]
        ? ((IOSUseBridgeSendID)objc_msgSend)(
            alertWindow,
            NSSelectorFromString(@"contentView")
        )
        : nil;
    NSMutableArray *buttons = [NSMutableArray array];
    NSUInteger visited = 0;
    IOSUseBridgeCollectAlertButtons(contentView, buttons, &visited);
    NSMutableArray<NSDictionary<NSString *, id> *> *buttonDescriptors =
        [NSMutableArray arrayWithCapacity:buttons.count];
    for (id button in buttons) {
        CGRect frame = IOSUseBridgeAlertButtonLogicalFrame(
            button,
            alertWindow
        );
        if (CGRectIsNull(frame) || CGRectIsEmpty(frame)) {
            return @[];
        }
        [buttonDescriptors addObject:@{
            @"button": button,
            @"frameValue": [NSValue valueWithCGRect:frame],
        }];
    }
    [buttonDescriptors
        sortUsingComparator:^NSComparisonResult(
            NSDictionary<NSString *, id> *left,
            NSDictionary<NSString *, id> *right
        ) {
        CGRect leftFrame =
            [left[@"frameValue"] CGRectValue];
        CGRect rightFrame =
            [right[@"frameValue"] CGRectValue];
        if (CGRectGetMinY(leftFrame) < CGRectGetMinY(rightFrame)) {
            return NSOrderedAscending;
        }
        if (CGRectGetMinY(leftFrame) > CGRectGetMinY(rightFrame)) {
            return NSOrderedDescending;
        }
        if (CGRectGetMinX(leftFrame) < CGRectGetMinX(rightFrame)) {
            return NSOrderedAscending;
        }
        if (CGRectGetMinX(leftFrame) > CGRectGetMinX(rightFrame)) {
            return NSOrderedDescending;
        }
        return NSOrderedSame;
    }];
    NSMutableArray<NSDictionary<NSString *, id> *> *result =
        [NSMutableArray arrayWithCapacity:buttonDescriptors.count];
    for (NSUInteger index = 0;
         index < buttonDescriptors.count;
         index += 1) {
        NSDictionary<NSString *, id> *descriptor =
            buttonDescriptors[index];
        id button = descriptor[@"button"];
        CGRect frame = [descriptor[@"frameValue"] CGRectValue];
        id title = [button respondsToSelector:
            NSSelectorFromString(@"title")]
            ? ((IOSUseBridgeSendID)objc_msgSend)(
                button,
                NSSelectorFromString(@"title")
            )
            : nil;
        NSString *label = [title isKindOfClass:NSString.class]
            ? title
            : @"";
        if (label.length == 0) {
            continue;
        }
        [result addObject:@{
            @"index": @(index),
            @"label": label,
            @"frame": IOSUseBridgeRectJSON(frame),
            @"button": button,
        }];
    }
    return result;
}

static NSArray<NSDictionary<NSString *, id> *> *
IOSUseBridgePublicNativeAlertActions(id alertWindow) {
    NSArray<NSDictionary<NSString *, id> *> *inventory =
        IOSUseBridgeNativeAlertActionInventory(alertWindow);
    NSMutableArray<NSDictionary<NSString *, id> *> *publicInventory =
        [NSMutableArray arrayWithCapacity:inventory.count];
    for (NSDictionary<NSString *, id> *entry in inventory) {
        [publicInventory addObject:@{
            @"index": entry[@"index"],
            @"label": entry[@"label"],
            @"frame": entry[@"frame"],
        }];
    }
    return publicInventory;
}

static NSString *IOSUseBridgeNativeAlertText(id alertWindow) {
    if (alertWindow == nil) {
        return @"";
    }
    id contentView = [alertWindow respondsToSelector:
        NSSelectorFromString(@"contentView")]
        ? ((IOSUseBridgeSendID)objc_msgSend)(
            alertWindow,
            NSSelectorFromString(@"contentView")
        )
        : nil;
    NSMutableArray *textFields = [NSMutableArray array];
    NSUInteger visited = 0;
    IOSUseBridgeCollectAlertTextFields(
        contentView,
        textFields,
        &visited
    );
    NSMutableArray<NSDictionary<NSString *, id> *> *textDescriptors =
        [NSMutableArray arrayWithCapacity:textFields.count];
    for (id textField in textFields) {
        CGRect frame = IOSUseBridgeAlertButtonLogicalFrame(
            textField,
            alertWindow
        );
        if (CGRectIsNull(frame) || CGRectIsEmpty(frame)) {
            return @"";
        }
        [textDescriptors addObject:@{
            @"textField": textField,
            @"frameValue": [NSValue valueWithCGRect:frame],
        }];
    }
    [textDescriptors sortUsingComparator:^NSComparisonResult(
        NSDictionary<NSString *, id> *left,
        NSDictionary<NSString *, id> *right
    ) {
        CGRect leftFrame =
            [left[@"frameValue"] CGRectValue];
        CGRect rightFrame =
            [right[@"frameValue"] CGRectValue];
        if (CGRectGetMinY(leftFrame) < CGRectGetMinY(rightFrame)) {
            return NSOrderedAscending;
        }
        if (CGRectGetMinY(leftFrame) > CGRectGetMinY(rightFrame)) {
            return NSOrderedDescending;
        }
        if (CGRectGetMinX(leftFrame) < CGRectGetMinX(rightFrame)) {
            return NSOrderedAscending;
        }
        if (CGRectGetMinX(leftFrame) > CGRectGetMinX(rightFrame)) {
            return NSOrderedDescending;
        }
        return NSOrderedSame;
    }];
    NSMutableOrderedSet<NSString *> *lines =
        [NSMutableOrderedSet orderedSet];
    for (NSDictionary<NSString *, id> *descriptor
         in textDescriptors) {
        id textField = descriptor[@"textField"];
        id value = ((IOSUseBridgeSendID)objc_msgSend)(
            textField,
            NSSelectorFromString(@"stringValue")
        );
        NSString *line = [(NSString *)value
            stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (line.length > 0) {
            [lines addObject:line];
        }
    }
    return [[lines array] componentsJoinedByString:@"\n"];
}

@interface IOSUsePlayAppKitBridge ()

+ (NSDictionary<NSString *, id> *)diagnosticsIncludingStatusOnlyFields:
    (BOOL)includeStatusOnlyFields
    nativeAlertSnapshot:
        (NSDictionary<NSString *, id> * _Nullable)
            nativeAlertSnapshot;

@end

@implementation IOSUsePlayAppKitBridge

+ (BOOL)installFixedSceneScale:(NSError **)error {
    if (IOSUsePlaySceneScaleBootstrapAttempted) {
        if (!IOSUsePlaySceneScaleBootstrapReady && error != NULL) {
            *error = [NSError
                errorWithDomain:IOSUsePlayWindowErrorDomain
                           code:3
                       userInfo:@{
                NSLocalizedDescriptionKey:
                    IOSUsePlaySceneScaleFailure ?:
                        @"UIKitMacHelper scene scale bootstrap failed",
            }];
        }
        return IOSUsePlaySceneScaleBootstrapReady;
    }
    IOSUsePlaySceneScaleBootstrapAttempted = YES;
    IOSUsePlaySceneScaleBootstrapReady = NO;
    IOSUsePlaySceneScaleFailure = nil;
    Class scaleClass = NSClassFromString(
        @"UINSSceneViewController"
    );
    NSArray<NSString *> *setters = @[
        @"setDefaultUIScaleFactorForIdiom:",
        @"setDefaultUIScaleFactorForWindows:",
    ];
    NSArray<NSString *> *getters = @[
        @"defaultUIScaleFactorForIdiom",
        @"defaultUIScaleFactorForWindows",
    ];
    NSArray<NSString *> *setterIdentifiers = @[
        @"uikitmac.scale.idiom-setter",
        @"uikitmac.scale.windows-setter",
    ];
    NSArray<NSString *> *getterIdentifiers = @[
        @"uikitmac.scale.idiom-getter",
        @"uikitmac.scale.windows-getter",
    ];
    if (scaleClass == Nil) {
        IOSUsePlaySceneScaleStatus = @"unavailable";
        IOSUsePlaySceneScaleFailure =
            @"UIKitMacHelper scene scale controller is unavailable";
    } else {
        const char *scaleArgumentTypes[] = {
            @encode(CGFloat),
        };
        for (NSUInteger index = 0;
             index < setters.count;
             index += 1) {
            NSString *selectorName = setters[index];
            NSError *registryError = nil;
            BOOL registered =
                IOSUsePlayHookRegistryObserveMethod(
                    setterIdentifiers[index],
                    YES,
                    @"pre-main",
                    scaleClass,
                    YES,
                    NSSelectorFromString(selectorName),
                    @encode(void),
                    scaleArgumentTypes,
                    1,
                    NO,
                    NO,
                    &registryError
                );
            if ((!IOSUseBridgeClassScaleMethodMatches(
                    scaleClass,
                    selectorName,
                    YES
                ) ||
                 !registered) &&
                IOSUsePlaySceneScaleFailure == nil) {
                IOSUsePlaySceneScaleStatus = @"abi-mismatch";
                IOSUsePlaySceneScaleFailure =
                    registryError.localizedDescription ?:
                    [NSString stringWithFormat:
                        @"UIKitMacHelper selector %@ has an unsupported ABI",
                        selectorName
                    ];
            }
        }
        for (NSUInteger index = 0;
             index < getters.count;
             index += 1) {
            NSString *selectorName = getters[index];
            NSError *registryError = nil;
            BOOL registered =
                IOSUsePlayHookRegistryObserveMethod(
                    getterIdentifiers[index],
                    YES,
                    @"pre-main",
                    scaleClass,
                    YES,
                    NSSelectorFromString(selectorName),
                    @encode(CGFloat),
                    NULL,
                    0,
                    NO,
                    NO,
                    &registryError
                );
            if ((!IOSUseBridgeClassScaleMethodMatches(
                        scaleClass,
                        selectorName,
                        NO
                    ) ||
                 !registered) &&
                IOSUsePlaySceneScaleFailure == nil) {
                IOSUsePlaySceneScaleStatus = @"abi-mismatch";
                IOSUsePlaySceneScaleFailure =
                    registryError.localizedDescription ?:
                    [NSString stringWithFormat:
                        @"UIKitMacHelper selector %@ has an unsupported ABI",
                        selectorName
                    ];
            }
        }
        const char *boolArgumentTypes[] = {
            @encode(BOOL),
        };
        NSError *downscaleSetterError = nil;
        BOOL downscaleSetterRegistered =
            IOSUsePlayHookRegistryObserveMethod(
                @"uikitmac.scale.downscale-setter",
                YES,
                @"pre-main",
                scaleClass,
                YES,
                NSSelectorFromString(
                    @"setDownscaleWindowIfNecessary:"
                ),
                @encode(void),
                boolArgumentTypes,
                1,
                NO,
                NO,
                &downscaleSetterError
            );
        NSError *downscaleGetterError = nil;
        BOOL downscaleGetterRegistered =
            IOSUsePlayHookRegistryObserveMethod(
                @"uikitmac.scale.downscale-getter",
                YES,
                @"pre-main",
                scaleClass,
                YES,
                NSSelectorFromString(
                    @"downscaleWindowIfNecessary"
                ),
                @encode(BOOL),
                NULL,
                0,
                NO,
                NO,
                &downscaleGetterError
            );
        if ((!IOSUseBridgeClassBoolMethodMatches(
                    scaleClass,
                    @"setDownscaleWindowIfNecessary:",
                    YES
                ) ||
             !IOSUseBridgeClassBoolMethodMatches(
                    scaleClass,
                    @"downscaleWindowIfNecessary",
                    NO
                ) ||
             !downscaleSetterRegistered ||
             !downscaleGetterRegistered) &&
            IOSUsePlaySceneScaleFailure == nil) {
            IOSUsePlaySceneScaleStatus = @"abi-mismatch";
            IOSUsePlaySceneScaleFailure =
                downscaleSetterError.localizedDescription ?:
                downscaleGetterError.localizedDescription ?:
                    @"UIKitMacHelper downscale policy has an unsupported ABI";
        }
    }
    if (IOSUsePlaySceneScaleFailure == nil) {
        // UIKitMacHelper reads these before it creates
        // UINSSceneViewController. Keep its scene identity-scaled for the
        // process lifetime; the outer scene-container frame/bounds mapping is
        // the only display transform.
        for (NSString *selectorName in setters) {
            ((void (*)(id, SEL, CGFloat))objc_msgSend)(
                (id)scaleClass,
                NSSelectorFromString(selectorName),
                1.0
            );
        }
        IOSUsePlayHookRegistryRecordInvocation(
            @"uikitmac.scale.idiom-setter"
        );
        IOSUsePlayHookRegistryRecordInvocation(
            @"uikitmac.scale.windows-setter"
        );
        ((void (*)(id, SEL, BOOL))objc_msgSend)(
            (id)scaleClass,
            NSSelectorFromString(
                @"setDownscaleWindowIfNecessary:"
            ),
            NO
        );
        IOSUsePlayHookRegistryRecordInvocation(
            @"uikitmac.scale.downscale-setter"
        );
        IOSUsePlayObservedIdiomScale =
            ((CGFloat (*)(id, SEL))objc_msgSend)(
                (id)scaleClass,
                NSSelectorFromString(getters[0])
            );
        IOSUsePlayHookRegistryRecordInvocation(
            @"uikitmac.scale.idiom-getter"
        );
        IOSUsePlayObservedWindowScale =
            ((CGFloat (*)(id, SEL))objc_msgSend)(
                (id)scaleClass,
                NSSelectorFromString(getters[1])
            );
        IOSUsePlayHookRegistryRecordInvocation(
            @"uikitmac.scale.windows-getter"
        );
        IOSUsePlayObservedDownscale =
            ((BOOL (*)(id, SEL))objc_msgSend)(
                (id)scaleClass,
                NSSelectorFromString(
                    @"downscaleWindowIfNecessary"
                )
            );
        IOSUsePlayHookRegistryRecordInvocation(
            @"uikitmac.scale.downscale-getter"
        );
        BOOL exact =
            IOSUseBridgeApproximatelyEqual(
                IOSUsePlayObservedIdiomScale,
                1.0
            ) &&
            IOSUseBridgeApproximatelyEqual(
                IOSUsePlayObservedWindowScale,
                1.0
            ) &&
            !IOSUsePlayObservedDownscale;
        IOSUsePlaySceneScaleStatus =
            exact ? @"configured" : @"rejected";
        IOSUsePlaySceneScaleFailure = exact
            ? nil
            : @"UIKitMacHelper rejected the identity scale bootstrap";
        IOSUsePlaySceneScaleBootstrapReady = exact;
    }
    if (IOSUsePlaySceneScaleFailure != nil && error != NULL) {
        *error = [NSError errorWithDomain:IOSUsePlayWindowErrorDomain
                                     code:3
                                 userInfo:@{
            NSLocalizedDescriptionKey:
                IOSUsePlaySceneScaleFailure,
        }];
    }
    return IOSUsePlaySceneScaleBootstrapReady;
}

+ (void)scheduleFixedWindowConfiguration {
    NSParameterAssert(NSThread.isMainThread);
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSNotificationCenter *center =
            NSNotificationCenter.defaultCenter;
        for (NSString *name in @[
            @"NSWindowDidBecomeKeyNotification",
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
                [self configureFixedWindow:NULL];
            }];
        }
        for (NSString *name in @[
            @"NSWindowDidResizeNotification",
            @"NSWindowDidMoveNotification",
            @"NSWindowDidChangeBackingPropertiesNotification",
            @"NSWindowDidChangeScreenNotification",
        ]) {
            [center addObserverForName:name
                               object:nil
                                queue:NSOperationQueue.mainQueue
                           usingBlock:^(
                               NSNotification *notification
                           ) {
                // Once installed, outer-window notifications must not reapply
                // style/titlebar/size policy while AppKit is consuming the
                // same frame transition. Only the fixed inner canvas needs
                // reconciliation.
                if (notification.object == IOSUsePlayHostWindow) {
                    IOSUseBridgeScheduleHostCanvasLayoutUpdate();
                }
            }];
        }
    });
    // PlayLoader invokes this from a constructor before UIApplicationMain.
    // Do not instantiate NSApplication or configure a window here; the
    // notifications above and Runtime's first main-queue probe reconcile the
    // surface after UIKit has created the scene.
}

+ (BOOL)configureFixedWindow:(NSError **)error {
    NSParameterAssert(NSThread.isMainThread);
    IOSUsePlayWindowAttemptCount += 1;
    if (!IOSUsePlaySceneScaleBootstrapReady) {
        IOSUsePlayWindowStatus = @"failed";
        IOSUsePlayWindowFailure = IOSUsePlaySceneScaleFailure ?:
            @"UIKitMacHelper scene scale was not bootstrapped before "
             "scene creation";
        if (error != NULL) {
            *error = [NSError
                errorWithDomain:IOSUsePlayWindowErrorDomain
                           code:3
                       userInfo:@{
                NSLocalizedDescriptionKey:
                    IOSUsePlayWindowFailure,
            }];
        }
        return NO;
    }
    UIWindow *uiWindow = IOSUseBridgeAutomationUIKitWindow();
    id window = uiWindow == nil
        ? nil
        : IOSUseBridgeWindowForUIKitWindow(uiWindow, NO);
    NSError *safeAreaError = nil;
    BOOL safeAreaReconciled =
        IOSUsePlaySafeAreaCompatibilityReconcile(&safeAreaError);
    if (uiWindow == nil || window == nil) {
        IOSUsePlayWindowStatus = @"waiting-for-window";
        IOSUsePlayWindowFailure = @"UIKit/AppKit window bridge is unavailable";
        return NO;
    }
    IOSUseBridgeSceneGeometryState sceneGeometryState =
        IOSUseBridgeLockSceneToFixedCanvas(uiWindow);
    if (sceneGeometryState != IOSUseBridgeSceneGeometryStateReady) {
        BOOL pending = sceneGeometryState ==
            IOSUseBridgeSceneGeometryStatePending;
        IOSUsePlayWindowStatus = pending
            ? @"waiting-for-scene-geometry"
            : @"scene-geometry-failed";
        IOSUsePlayWindowFailure = pending
            ? IOSUsePlaySceneGeometryFailure ?:
                @"waiting for the fixed UIKit canvas before installing the "
                 "AppKit host"
            : IOSUsePlaySceneGeometryFailure ?:
                @"fixed scene geometry is unavailable";
        if (error != NULL) {
            *error = [NSError errorWithDomain:IOSUsePlayWindowErrorDomain
                                         code:9
                                     userInfo:@{
                NSLocalizedDescriptionKey: IOSUsePlayWindowFailure,
            }];
        }
        return NO;
    }
    if (!IOSUseBridgeApplyWindowPolicy(window)) {
        IOSUsePlayWindowStatus = @"failed";
        IOSUsePlayWindowFailure =
            @"could not install the simulator-scale NSWindow policy";
        if (error != NULL) {
            *error = [NSError errorWithDomain:IOSUsePlayWindowErrorDomain
                                         code:10
                                     userInfo:@{
                NSLocalizedDescriptionKey: IOSUsePlayWindowFailure,
            }];
        }
        return NO;
    }
    if (!IOSUseBridgeScreenCanFit(window)) {
        IOSUsePlayWindowStatus = @"failed";
        IOSUsePlayWindowFailure = [NSString stringWithFormat:
            @"Mac display cannot fit the minimum host %.0f x %.0f",
            IOSUseBridgeHostMinimumContentSize().width,
            IOSUseBridgeHostMinimumContentSize().height];
        if (error != NULL) {
            *error = [NSError errorWithDomain:IOSUsePlayWindowErrorDomain
                                         code:1
                                     userInfo:@{
                NSLocalizedDescriptionKey: IOSUsePlayWindowFailure,
            }];
        }
        return NO;
    }
    if (!IOSUseBridgeInstallHostCanvas(window)) {
        IOSUsePlayWindowStatus = @"failed";
        IOSUsePlayWindowFailure =
            @"could not install the fixed-canvas AppKit host";
        if (error != NULL) {
            *error = [NSError errorWithDomain:IOSUsePlayWindowErrorDomain
                                         code:5
                                     userInfo:@{
                NSLocalizedDescriptionKey: IOSUsePlayWindowFailure,
            }];
        }
        return NO;
    }
    NSString *layoutFailure = nil;
    if (!IOSUseBridgeNormalizeBootstrapContentAspect(
            window,
            &layoutFailure
        )) {
        IOSUsePlayWindowStatus = @"geometry-mismatch";
        IOSUsePlayWindowFailure = layoutFailure ?:
            @"could not normalize the initial host content aspect";
        if (error != NULL) {
            *error = [NSError errorWithDomain:IOSUsePlayWindowErrorDomain
                                         code:11
                                     userInfo:@{
                NSLocalizedDescriptionKey: IOSUsePlayWindowFailure,
            }];
        }
        return NO;
    }
    if (!IOSUseBridgeUpdateHostCanvasLayout(window, &layoutFailure)) {
        IOSUsePlayWindowStatus = @"geometry-mismatch";
        IOSUsePlayWindowFailure = layoutFailure ?:
            @"could not resolve the fixed host canvas layout";
        if (error != NULL) {
            *error = [NSError errorWithDomain:IOSUsePlayWindowErrorDomain
                                         code:6
                                     userInfo:@{
                NSLocalizedDescriptionKey: IOSUsePlayWindowFailure,
            }];
        }
        return NO;
    }
    BOOL mouseMonitorReady =
        IOSUseBridgeInstallMouseLocalMonitor();

    CGRect canvasFrame = IOSUseBridgeRect(
        IOSUsePlayScaleView,
        @"frame"
    );
    UISceneSizeRestrictions *restrictions = uiWindow.windowScene.sizeRestrictions;
    CGSize fixed = CGSizeMake(
        IOSUsePlayDeviceLogicalWidth,
        IOSUsePlayDeviceLogicalHeight
    );
    BOOL sceneFixed = restrictions != nil &&
        IOSUseBridgeApproximatelyEqual(
            restrictions.minimumSize.width,
            fixed.width
        ) &&
        IOSUseBridgeApproximatelyEqual(
            restrictions.minimumSize.height,
            fixed.height
        ) &&
        IOSUseBridgeApproximatelyEqual(
            restrictions.maximumSize.width,
            fixed.width
        ) &&
        IOSUseBridgeApproximatelyEqual(
            restrictions.maximumSize.height,
            fixed.height
        );
    // This is a one-time proof that UIKit has honored the fixed scene size
    // restrictions before the host wrapper is installed. A later public
    // AppKit resize changes only the outer window and display scale.
    BOOL sceneGeometryBootstrapped =
        IOSUsePlaySceneGeometryState ==
            IOSUseBridgeSceneGeometryStateReady &&
        IOSUsePlaySceneGeometryScene == uiWindow.windowScene;
    BOOL canvasMatchesLayout =
        IOSUseBridgeRectApproximatelyEqualWithTolerance(
            canvasFrame,
            IOSUsePlayCurrentHostCanvasLayout.canvasRect,
            IOSUsePlayCurrentHostCanvasLayout.halfPixelTolerance
        );
    BOOL geometryExact = IOSUseBridgeWindowPolicyIsHost(window) &&
        sceneFixed &&
        sceneGeometryBootstrapped &&
        IOSUsePlayHostCanvasLayoutReady &&
        canvasMatchesLayout &&
        mouseMonitorReady &&
        IOSUseBridgeRectIsDeviceScreen(uiWindow.bounds);
    BOOL safeAreaReady =
        safeAreaReconciled &&
        IOSUsePlaySafeAreaCompatibilityIsReadyForWindow(uiWindow);
    BOOL exact = geometryExact && safeAreaReady;
    if (geometryExact && !safeAreaReady) {
        NSDictionary<NSString *, id> *safeAreaDiagnostics =
            IOSUsePlaySafeAreaCompatibilityDiagnostics();
        BOOL failed = [
            safeAreaDiagnostics[@"stage"] isEqual:@"failed"
        ];
        id diagnosticsFailure =
            safeAreaDiagnostics[@"failure"];
        NSString *diagnosticsFailureDescription =
            [diagnosticsFailure isKindOfClass:NSString.class]
                ? diagnosticsFailure
                : nil;
        IOSUsePlayWindowStatus = failed
            ? @"safe-area-failed"
            : @"waiting-for-safe-area";
        IOSUsePlayWindowFailure =
            safeAreaError.localizedDescription ?:
            diagnosticsFailureDescription ?:
            @"fixed iPhone safe-area layout is not ready";
        if (error != NULL) {
            *error = [
                NSError
                errorWithDomain:IOSUsePlayWindowErrorDomain
                           code:failed ? 13 : 12
                       userInfo:@{
                NSLocalizedDescriptionKey:
                    IOSUsePlayWindowFailure,
            }];
        }
        return NO;
    }
    IOSUsePlayWindowStatus = exact ? @"configured" : @"geometry-mismatch";
    IOSUsePlayWindowFailure = exact
        ? nil
        : sceneGeometryBootstrapped
            ? @"AppKit host or fixed logical canvas geometry is not ready"
            : IOSUsePlaySceneGeometryFailure ?:
                @"fixed UIKit scene geometry is not ready";
    if (!exact && error != NULL) {
        *error = [NSError errorWithDomain:IOSUsePlayWindowErrorDomain
                                     code:2
                                 userInfo:@{
            NSLocalizedDescriptionKey: IOSUsePlayWindowFailure,
        }];
    }
    return exact;
}

+ (NSInteger)screenCount {
    Class screenClass = NSClassFromString(@"NSScreen");
    id screens = ((IOSUseBridgeSendID)objc_msgSend)(
        (id)screenClass,
        NSSelectorFromString(@"screens")
    );
    return [screens isKindOfClass:NSArray.class]
        ? (NSInteger)[(NSArray *)screens count]
        : 0;
}

+ (CGPoint)mousePoint {
    id window = IOSUsePlayHostWindow;
    SEL selector = NSSelectorFromString(
        @"mouseLocationOutsideOfEventStream"
    );
    CGPoint local = [window respondsToSelector:selector]
        ? ((IOSUseBridgeSendPoint)objc_msgSend)(window, selector)
        : CGPointMake(NAN, NAN);
    NSString *layoutFailure = nil;
    if (!IOSUseBridgeUpdateHostCanvasLayout(window, &layoutFailure) ||
        ![IOSUsePlayHostContentView respondsToSelector:
            NSSelectorFromString(@"convertPoint:fromView:")]) {
        return CGPointZero;
    }
    CGPoint content = ((IOSUseBridgeSendPointPointID)objc_msgSend)(
        IOSUsePlayHostContentView,
        NSSelectorFromString(@"convertPoint:fromView:"),
        local,
        nil
    );
    CGPoint logical = CGPointZero;
    return IOSUsePlayMapHostContentPointToCanvas(
        IOSUsePlayCurrentHostCanvasLayout,
        content,
        &logical,
        NULL
    ) ? logical : CGPointZero;
}

+ (CGRect)windowFrame {
    return IOSUseBridgeRect(IOSUsePlayHostWindow, @"frame");
}

+ (CGRect)mainScreenFrame {
    Class screenClass = NSClassFromString(@"NSScreen");
    id screen = ((IOSUseBridgeSendID)objc_msgSend)(
        (id)screenClass,
        NSSelectorFromString(@"mainScreen")
    );
    return IOSUseBridgeRect(screen, @"frame");
}

+ (BOOL)isMainScreenEqualToFirst {
    Class screenClass = NSClassFromString(@"NSScreen");
    id mainScreen = ((IOSUseBridgeSendID)objc_msgSend)(
        (id)screenClass,
        NSSelectorFromString(@"mainScreen")
    );
    id screens = ((IOSUseBridgeSendID)objc_msgSend)(
        (id)screenClass,
        NSSelectorFromString(@"screens")
    );
    return [screens isKindOfClass:NSArray.class] &&
        [(NSArray *)screens count] > 0 &&
        mainScreen == [(NSArray *)screens firstObject];
}

+ (BOOL)isFullscreen {
    id window = IOSUseBridgeSelectedWindow();
    SEL selector = NSSelectorFromString(@"styleMask");
    NSInteger style = [window respondsToSelector:selector]
        ? ((IOSUseBridgeSendInteger)objc_msgSend)(
            window,
            selector
        )
        : 0;
    return (style & ((NSInteger)1 << 14)) != 0;
}

+ (void)setMenuBarVisible:(BOOL)visible {
    Class menuClass = NSClassFromString(@"NSMenu");
    IOSUseBridgeSetBool(
        (id)menuClass,
        @"setMenuBarVisible:",
        visible
    );
}

+ (BOOL)hasVisibleNativeAlertCandidate {
    NSParameterAssert(NSThread.isMainThread);
    return IOSUseBridgeHasVisibleNativeAlertCandidateInWindows(
        IOSUseBridgeNativeAlertWindows()
    );
}

+ (BOOL)hasVisibleNativeAlert {
    NSParameterAssert(NSThread.isMainThread);
    return IOSUseBridgeVisibleNativeAlertSelection() != nil;
}

+ (NSDictionary<NSString *, id> *)nativeAlertSnapshot {
    NSParameterAssert(NSThread.isMainThread);
    NSArray *windows = IOSUseBridgeNativeAlertWindows();
    BOOL candidateVisible =
        IOSUseBridgeHasVisibleNativeAlertCandidateInWindows(
            windows
        );
    if (!candidateVisible) {
        return @{
            @"candidateVisible": @NO,
            @"visible": @NO,
            @"actionableByIOSUse": @NO,
        };
    }

    NSDictionary<
        NSNumber *,
        NSDictionary<NSString *, id> *
    > *cgMetadata = IOSUseBridgeOwnOnscreenCGWindowMetadata();
    NSDictionary<NSString *, id> *selection =
        IOSUseBridgeVisibleNativeAlertSelectionFromWindows(
            windows,
            cgMetadata
        );
    id alertWindow = selection[@"window"];
    if (selection == nil || alertWindow == nil) {
        return @{
            @"candidateVisible": @YES,
            @"visible": @YES,
            @"actionableByIOSUse": @NO,
            @"source": @"appkitNativeUnresolved",
            @"text": @"",
            @"actions": @[],
            @"_cgWindowMetadata":
                cgMetadata ?: (id)NSNull.null,
        };
    }

    CGRect frame = IOSUseBridgeWindowLogicalFrame(
        alertWindow,
        selection[@"cgMetadata"]
    );
    NSArray<NSDictionary<NSString *, id> *> *actions =
        IOSUseBridgePublicNativeAlertActions(alertWindow);
    return @{
        @"candidateVisible": @YES,
        @"visible": @YES,
        @"actionableByIOSUse":
            actions.count > 0 ? @YES : @NO,
        @"source": @"appkitNative",
        @"windowClass":
            NSStringFromClass([alertWindow class]) ?: @"",
        @"windowNumber": @(
            IOSUseBridgeInteger(alertWindow, @"windowNumber")
        ),
        @"frame": CGRectIsNull(frame)
            ? (id)NSNull.null
            : IOSUseBridgeRectJSON(frame),
        @"text": IOSUseBridgeNativeAlertText(alertWindow),
        @"actions": actions,
        @"_cgWindowMetadata": cgMetadata,
    };
}

+ (NSDictionary<NSString *, id> *)
    canvasCaptureGeometryWithError:(NSError **)error {
    NSParameterAssert(NSThread.isMainThread);
    NSString *layoutFailure = nil;
    if (!IOSUseBridgeUpdateHostCanvasLayout(
            IOSUsePlayHostWindow,
            &layoutFailure
        )) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:IOSUsePlayWindowErrorDomain
                                         code:9
                                     userInfo:@{
                NSLocalizedDescriptionKey: layoutFailure ?:
                    @"AppKit host canvas layout is unavailable",
            }];
        }
        return nil;
    }
    NSDictionary<
        NSNumber *,
        NSDictionary<NSString *, id> *
    > *metadata = IOSUseBridgeOwnOnscreenCGWindowMetadata();
    return IOSUseBridgeHostCanvasCaptureGeometry(
        IOSUsePlayHostWindow,
        metadata,
        error
    );
}

+ (NSDictionary<NSString *, id> *)
    dismissTransientTextInputWindows:(NSError **)error {
    NSParameterAssert(NSThread.isMainThread);
    id application = IOSUseBridgeApplication();
    SEL windowsSelector = NSSelectorFromString(@"windows");
    id rawWindows =
        [application respondsToSelector:windowsSelector]
        ? ((IOSUseBridgeSendID)objc_msgSend)(
            application,
            windowsSelector
        )
        : nil;
    NSArray *windows = [rawWindows isKindOfClass:NSArray.class]
        ? rawWindows
        : nil;
    if (windows == nil) {
        if (error != NULL) {
            *error = [NSError
                errorWithDomain:IOSUsePlayWindowErrorDomain
                           code:4
                       userInfo:@{
                NSLocalizedDescriptionKey:
                    @"AppKit window inventory is unavailable while dismissing text input UI",
            }];
        }
        return nil;
    }
    NSMutableArray<NSNumber *> *dismissedWindowNumbers =
        [NSMutableArray array];
    for (id window in windows) {
        NSString *className =
            NSStringFromClass([window class]) ?: @"";
        if (![className isEqualToString:@"SPRoundedWindow"] ||
            !IOSUseBridgeBool(window, @"isVisible")) {
            continue;
        }
        id uiWindows = [window respondsToSelector:
            NSSelectorFromString(@"uiWindows")]
            ? ((IOSUseBridgeSendID)objc_msgSend)(
                window,
                NSSelectorFromString(@"uiWindows")
            )
            : nil;
        if ([uiWindows isKindOfClass:NSArray.class] &&
            [(NSArray *)uiWindows count] > 0) {
            continue;
        }
        NSInteger windowNumber =
            IOSUseBridgeInteger(window, @"windowNumber");
        SEL orderOutSelector = NSSelectorFromString(@"orderOut:");
        if (![window respondsToSelector:orderOutSelector]) {
            if (error != NULL) {
                *error = [NSError
                    errorWithDomain:IOSUsePlayWindowErrorDomain
                               code:5
                           userInfo:@{
                    NSLocalizedDescriptionKey:
                        @"SPRoundedWindow does not expose orderOut:",
                }];
            }
            return nil;
        }
        ((IOSUseBridgeSendIDArgument)objc_msgSend)(
            window,
            orderOutSelector,
            nil
        );
        if (IOSUseBridgeBool(window, @"isVisible")) {
            if (error != NULL) {
                *error = [NSError
                    errorWithDomain:IOSUsePlayWindowErrorDomain
                               code:6
                           userInfo:@{
                    NSLocalizedDescriptionKey:
                        @"SPRoundedWindow remained visible after orderOut:",
                }];
            }
            return nil;
        }
        if (windowNumber > 0) {
            [dismissedWindowNumbers addObject:@(windowNumber)];
        }
    }
    NSDictionary<NSString *, id> *evidence = @{
        @"backend": @"appkit-text-input-transient-order-out",
        @"class": @"SPRoundedWindow",
        @"dismissedCount": @(dismissedWindowNumbers.count),
        @"windowNumbers": dismissedWindowNumbers,
    };
    IOSUsePlayLastTextInputTransientDismissal = evidence;
    return evidence;
}

+ (CGRect)nativeAlertFrame {
    NSParameterAssert(NSThread.isMainThread);
    NSDictionary<NSString *, id> *selection =
        IOSUseBridgeVisibleNativeAlertSelection();
    return IOSUseBridgeWindowLogicalFrame(
        selection[@"window"],
        selection[@"cgMetadata"]
    );
}

+ (NSString *)nativeAlertText {
    NSParameterAssert(NSThread.isMainThread);
    NSDictionary<NSString *, id> *selection =
        IOSUseBridgeVisibleNativeAlertSelection();
    return IOSUseBridgeNativeAlertText(selection[@"window"]);
}

+ (NSArray<NSDictionary<NSString *, id> *> *)nativeAlertActions {
    NSParameterAssert(NSThread.isMainThread);
    NSDictionary<NSString *, id> *selection =
        IOSUseBridgeVisibleNativeAlertSelection();
    return IOSUseBridgePublicNativeAlertActions(
        selection[@"window"]
    );
}

+ (NSDictionary<NSString *, id> *)
    performNativeAlertActionWithLabel:(NSString *)label
                                error:(NSError **)error {
    NSParameterAssert(NSThread.isMainThread);
    NSDictionary<NSString *, id> *selection =
        IOSUseBridgeVisibleNativeAlertSelection();
    id alertWindow = selection[@"window"];
    NSArray<NSDictionary<NSString *, id> *> *inventory =
        IOSUseBridgeNativeAlertActionInventory(alertWindow);
    NSMutableArray<NSDictionary<NSString *, id> *> *matches =
        [NSMutableArray array];
    for (NSDictionary<NSString *, id> *entry in inventory) {
        if ([entry[@"label"] isEqualToString:label]) {
            [matches addObject:entry];
        }
    }
    if (alertWindow == nil || matches.count != 1) {
        if (error != NULL) {
            NSString *message = alertWindow == nil
                ? @"no visible native alert panel"
                : @"native alert action label is missing or ambiguous";
            *error = [NSError
                errorWithDomain:IOSUsePlayNativeAlertErrorDomain
                           code:matches.count > 1 ? 2 : 1
                       userInfo:@{
                NSLocalizedDescriptionKey: message,
                @"label": label ?: @"",
                @"candidateCount": @(matches.count),
            }];
        }
        return nil;
    }
    NSDictionary<NSString *, id> *entry = matches.firstObject;
    id button = entry[@"button"];
    SEL actionSelector = NSSelectorFromString(@"action");
    SEL targetSelector = NSSelectorFromString(@"target");
    id application = IOSUseBridgeApplication();
    SEL sendActionSelector =
        NSSelectorFromString(@"sendAction:to:from:");
    if (![button respondsToSelector:actionSelector] ||
        ![button respondsToSelector:targetSelector] ||
        ![application respondsToSelector:sendActionSelector]) {
        if (error != NULL) {
            *error = [NSError
                errorWithDomain:IOSUsePlayNativeAlertErrorDomain
                           code:3
                       userInfo:@{
                NSLocalizedDescriptionKey:
                    @"native alert action cannot enter AppKit target/action routing",
                @"label": label ?: @"",
            }];
        }
        return nil;
    }
    SEL action = ((IOSUseBridgeSendSelector)objc_msgSend)(
        button,
        actionSelector
    );
    id target = ((IOSUseBridgeSendID)objc_msgSend)(
        button,
        targetSelector
    );
    BOOL delivered =
        action != NULL &&
        ((IOSUseBridgeSendAction)objc_msgSend)(
            application,
            sendActionSelector,
            action,
            target,
            button
        );
    if (!delivered) {
        if (error != NULL) {
            *error = [NSError
                errorWithDomain:IOSUsePlayNativeAlertErrorDomain
                           code:4
                       userInfo:@{
                NSLocalizedDescriptionKey:
                    @"AppKit rejected the native alert target/action",
                @"label": label ?: @"",
                @"action": action == NULL
                    ? @""
                    : NSStringFromSelector(action),
                @"targetClass": target == nil
                    ? @""
                    : NSStringFromClass([target class]),
            }];
        }
        return nil;
    }
    return @{
        @"label": entry[@"label"],
        @"index": entry[@"index"],
        @"frame": entry[@"frame"],
        @"backend": @"appkit-native-alert-target-action",
        @"action": NSStringFromSelector(action),
        @"targetClass": target == nil
            ? @""
            : NSStringFromClass([target class]),
    };
}

+ (NSDictionary<NSString *, id> *)diagnosticsIncludingStatusOnlyFields:
    (BOOL)includeStatusOnlyFields
    nativeAlertSnapshot:
        (NSDictionary<NSString *, id> *)nativeAlertSnapshot {
    // Keep diagnostics anchored to the strict foreground UIKit selection when
    // the host has not yet been installed; after installation the selected
    // host is the authoritative visible surface.
    id selectedWindow =
        includeStatusOnlyFields || IOSUsePlayHostWindow == nil
            ? IOSUseBridgeSelectedWindow()
            : nil;
    id window = IOSUsePlayHostWindow ?: selectedWindow;
    id capturedCGWindowMetadata =
        nativeAlertSnapshot[@"_cgWindowMetadata"];
    BOOL hasCapturedCGWindowMetadata =
        capturedCGWindowMetadata != nil;
    NSDictionary<
        NSNumber *,
        NSDictionary<NSString *, id> *
    > *cgWindowMetadata = nil;
    if (hasCapturedCGWindowMetadata) {
        cgWindowMetadata =
            [capturedCGWindowMetadata
                isKindOfClass:NSDictionary.class]
                ? capturedCGWindowMetadata
                : nil;
    } else {
        cgWindowMetadata =
            IOSUseBridgeOwnOnscreenCGWindowMetadata();
    }
    NSDictionary<NSString *, id> *baseCGWindow =
        includeStatusOnlyFields
            ? IOSUseBridgeExactOnscreenCGWindowMetadata(
                window,
                cgWindowMetadata
            )
            : nil;
    CGRect frame = IOSUseBridgeRect(window, @"frame");
    CGRect content = includeStatusOnlyFields
        ? IOSUseBridgeRect(window, @"contentLayoutRect")
        : CGRectNull;
    id contentView = IOSUsePlayHostContentView;
    if (contentView == nil && [window respondsToSelector:
        NSSelectorFromString(@"contentView")]) {
        contentView = ((IOSUseBridgeSendID)objc_msgSend)(
            window,
            NSSelectorFromString(@"contentView")
        );
    }
    CGRect bounds = IOSUseBridgeRect(contentView, @"bounds");
    CGRect contentViewFrame = includeStatusOnlyFields
        ? IOSUseBridgeRect(contentView, @"frame")
        : CGRectNull;
    UIWindow *uiWindow = IOSUseBridgeAutomationUIKitWindow();
    // This is the observed UIKit logical canvas. Do not synthesize the fixed
    // contract here: Runtime readiness must fail if a host drag causes
    // UIKitMacHelper to relayout the scene.
    CGRect canvasBounds =
        uiWindow == nil ? CGRectZero : uiWindow.bounds;
    CGRect canvasFrame = IOSUseBridgeRect(
        IOSUsePlayScaleView,
        @"frame"
    );
    CGRect renderViewBounds = IOSUseBridgeRect(
        IOSUsePlayCanvasView,
        @"bounds"
    );
    id sceneRenderView =
        IOSUseBridgeSceneRenderView(IOSUsePlayCanvasView);
    CGRect sceneRenderViewFrame = IOSUseBridgeRect(
        sceneRenderView,
        @"frame"
    );
    CGRect sceneRenderViewBounds = IOSUseBridgeRect(
        sceneRenderView,
        @"bounds"
    );
    id inputRenderView =
        IOSUseBridgeInputRenderView(sceneRenderView);
    CGRect inputRenderViewFrame = IOSUseBridgeRect(
        inputRenderView,
        @"frame"
    );
    CGRect inputRenderViewBounds = IOSUseBridgeRect(
        inputRenderView,
        @"bounds"
    );
    id windowScreen =
        includeStatusOnlyFields &&
            [window respondsToSelector:NSSelectorFromString(@"screen")]
            ? ((IOSUseBridgeSendID)objc_msgSend)(
                window,
                NSSelectorFromString(@"screen")
            )
            : nil;
    CGDirectDisplayID screenDisplayID = includeStatusOnlyFields
        ? IOSUseBridgeDisplayIDForScreen(windowScreen)
        : kCGNullDirectDisplay;
    BOOL screenIsMain =
        screenDisplayID != kCGNullDirectDisplay &&
        CGDisplayIsMain(screenDisplayID) != 0;
    UISceneSizeRestrictions *restrictions =
        includeStatusOnlyFields
            ? uiWindow.windowScene.sizeRestrictions
            : nil;
    CGFloat backingScale = [window respondsToSelector:
        NSSelectorFromString(@"backingScaleFactor")]
        ? ((IOSUseBridgeSendFloat)objc_msgSend)(
            window,
            NSSelectorFromString(@"backingScaleFactor")
        )
        : 0;
    CGRect expectedCGWindowBounds = CGRectNull;
    if (includeStatusOnlyFields) {
        (void)IOSUseBridgeAppKitScreenRectToCGWindowRect(
            frame,
            &expectedCGWindowBounds
        );
    }
    // Keep one diagnostics response on one fresh alert selection. Public
    // automation accessors intentionally continue to re-select so a later
    // action never trusts this observational snapshot.
    NSDictionary<NSString *, id> *nativeAlertSelection =
        includeStatusOnlyFields &&
            nativeAlertSnapshot == nil
            ? IOSUseBridgeVisibleNativeAlertSelectionWithCGWindowMetadata(
                cgWindowMetadata
            )
            : nil;
    id nativeAlertWindow = nativeAlertSelection[@"window"];
    CGRect nativeAlertFrame = nativeAlertSelection == nil
        ? CGRectNull
        : IOSUseBridgeWindowLogicalFrame(
            nativeAlertWindow,
            nativeAlertSelection[@"cgMetadata"]
        );
    BOOL nativeAlertVisible = nativeAlertSnapshot != nil
        ? [nativeAlertSnapshot[@"visible"] boolValue]
        : nativeAlertSelection != nil;
    id nativeAlertFrameJSON = nativeAlertSnapshot != nil
        ? nativeAlertSnapshot[@"frame"] ?: NSNull.null
        : CGRectIsNull(nativeAlertFrame)
            ? (id)NSNull.null
            : IOSUseBridgeRectJSON(nativeAlertFrame);
    NSString *nativeAlertText = nativeAlertSnapshot != nil
        ? nativeAlertSnapshot[@"text"] ?: @""
        : includeStatusOnlyFields
            ? IOSUseBridgeNativeAlertText(nativeAlertWindow)
            : @"";
    NSArray<NSDictionary<NSString *, id> *> *nativeAlertActions =
        nativeAlertSnapshot != nil
            ? nativeAlertSnapshot[@"actions"] ?: @[]
            : includeStatusOnlyFields
            ? IOSUseBridgePublicNativeAlertActions(nativeAlertWindow)
            : @[];
    NSDictionary<NSString *, id> *bootstrapNativeAlert =
        includeStatusOnlyFields
            ? IOSUseBridgeBootstrapNativeAlertDiagnostics()
            : @{};
    NSUInteger growingResizeEdges = 0;
    NSUInteger shrinkingResizeEdges = 0;
    NSUInteger resizeEdges = includeStatusOnlyFields
        ? IOSUseBridgeResizableEdges(
            window,
            &growingResizeEdges,
            &shrinkingResizeEdges
        )
        : 0;
    NSError *canvasError = nil;
    NSDictionary<NSString *, id> *canvasCapture =
        IOSUseBridgeHostCanvasCaptureGeometry(
            window,
            cgWindowMetadata,
            &canvasError
        );
    id rawWindowTitle = [window respondsToSelector:
        NSSelectorFromString(@"title")]
        ? ((IOSUseBridgeSendID)objc_msgSend)(
            window,
            NSSelectorFromString(@"title")
        )
        : nil;
    NSString *windowTitle = [rawWindowTitle isKindOfClass:NSString.class]
        ? rawWindowTitle
        : @"";
    if (!includeStatusOnlyFields) {
        // Runtime hello consumes only the exact inputs to
        // IOSUseHostGeometryReady plus failures that explain a not-ready
        // surface. Keep this dictionary observational: every value above was
        // captured in the same main-thread turn, including the exact owned
        // CGWindow used by canvasCapture.
        return @{
            @"status": IOSUsePlayWindowStatus,
            @"failure": IOSUsePlayWindowFailure ?: NSNull.null,
            @"frame": IOSUseBridgeRectJSON(frame),
            @"hostFrame": IOSUseBridgeRectJSON(frame),
            @"hostContentBounds": IOSUseBridgeRectJSON(bounds),
            @"canvasRect": IOSUseBridgeRectJSON(canvasFrame),
            @"backingPixelCanvasRect":
                IOSUsePlayHostCanvasLayoutReady
                    ? IOSUseBridgeRectJSON(
                        IOSUsePlayCurrentHostCanvasLayout
                            .backingPixelCanvasRect
                    )
                    : (id)NSNull.null,
            @"canvasBounds": IOSUseBridgeRectJSON(canvasBounds),
            @"renderViewBounds": IOSUseBridgeRectJSON(renderViewBounds),
            @"sceneRenderViewFrame":
                IOSUseBridgeRectJSON(sceneRenderViewFrame),
            @"sceneRenderViewBounds":
                IOSUseBridgeRectJSON(sceneRenderViewBounds),
            @"inputRenderViewFrame":
                IOSUseBridgeRectJSON(inputRenderViewFrame),
            @"inputRenderViewBounds":
                IOSUseBridgeRectJSON(inputRenderViewBounds),
            @"displayScale": IOSUsePlayHostCanvasLayoutReady
                ? @(IOSUsePlayCurrentHostCanvasLayout.displayScale)
                : (id)NSNull.null,
            @"inverseDisplayScale": IOSUsePlayHostCanvasLayoutReady
                ? @(IOSUsePlayCurrentHostCanvasLayout.inverseDisplayScale)
                : (id)NSNull.null,
            @"halfPixelTolerance": IOSUsePlayHostCanvasLayoutReady
                ? @(IOSUsePlayCurrentHostCanvasLayout.halfPixelTolerance)
                : (id)NSNull.null,
            @"canvasCapture": canvasCapture ?: (id)@{
                @"error":
                    canvasError.localizedDescription ?: @"unavailable",
            },
            @"sceneGeometry": @{
                @"failure":
                    IOSUsePlaySceneGeometryFailure ?: NSNull.null,
            },
            @"backingScaleFactor": @(backingScale),
            @"opaque": @(IOSUseBridgeBool(window, @"isOpaque")),
            @"publicTitleBar": @(
                (BOOL)((IOSUseBridgeInteger(window, @"styleMask") & 1) != 0)
            ),
            @"title": windowTitle,
            @"titleExpected": IOSUseBridgeHostTitle(),
            @"titleVisible": @(
                IOSUseBridgeInteger(window, @"titleVisibility") == 0
            ),
            @"resizable": @(
                (BOOL)((IOSUseBridgeInteger(window, @"styleMask") &
                    ((NSInteger)1 << 3)) != 0)
            ),
            @"hostPolicy": @(
                IOSUseBridgeWindowPolicyIsHost(window)
            ),
            @"sceneScale": @{
                @"failure":
                    IOSUsePlaySceneScaleFailure ?: NSNull.null,
                @"idiom": @(IOSUsePlayObservedIdiomScale),
                @"windows": @(IOSUsePlayObservedWindowScale),
                @"downscaleWindowIfNecessary":
                    @(IOSUsePlayObservedDownscale),
            },
        };
    }
    return @{
        @"status": IOSUsePlayWindowStatus,
        @"failure": IOSUsePlayWindowFailure ?: NSNull.null,
        @"attempts": @(IOSUsePlayWindowAttemptCount),
        @"frame": IOSUseBridgeRectJSON(frame),
        @"hostFrame": IOSUseBridgeRectJSON(frame),
        @"hostContentBounds": IOSUseBridgeRectJSON(bounds),
        @"canvasRect": IOSUseBridgeRectJSON(canvasFrame),
        @"backingPixelCanvasRect":
            IOSUsePlayHostCanvasLayoutReady
                ? IOSUseBridgeRectJSON(
                    IOSUsePlayCurrentHostCanvasLayout
                        .backingPixelCanvasRect
                )
                : (id)NSNull.null,
        @"canvasBounds": IOSUseBridgeRectJSON(canvasBounds),
        @"renderViewBounds": IOSUseBridgeRectJSON(renderViewBounds),
        @"sceneRenderViewFrame":
            IOSUseBridgeRectJSON(sceneRenderViewFrame),
        @"sceneRenderViewBounds":
            IOSUseBridgeRectJSON(sceneRenderViewBounds),
        @"inputRenderViewFrame":
            IOSUseBridgeRectJSON(inputRenderViewFrame),
        @"inputRenderViewBounds":
            IOSUseBridgeRectJSON(inputRenderViewBounds),
        @"displayScale": IOSUsePlayHostCanvasLayoutReady
            ? @(IOSUsePlayCurrentHostCanvasLayout.displayScale)
            : (id)NSNull.null,
        @"inverseDisplayScale": IOSUsePlayHostCanvasLayoutReady
            ? @(IOSUsePlayCurrentHostCanvasLayout.inverseDisplayScale)
            : (id)NSNull.null,
        @"halfPixelTolerance": IOSUsePlayHostCanvasLayoutReady
            ? @(IOSUsePlayCurrentHostCanvasLayout.halfPixelTolerance)
            : (id)NSNull.null,
        @"canvasCapture": canvasCapture ?: (id)@{
            @"error": canvasError.localizedDescription ?: @"unavailable",
        },
        @"contentLayoutRect": IOSUseBridgeRectJSON(content),
        @"contentViewFrame": IOSUseBridgeRectJSON(contentViewFrame),
        @"contentViewBounds": IOSUseBridgeRectJSON(bounds),
        @"screenFrame": IOSUseBridgeRectJSON(
            IOSUseBridgeRect(windowScreen, @"frame")
        ),
        @"screenVisibleFrame": IOSUseBridgeRectJSON(
            IOSUseBridgeRect(windowScreen, @"visibleFrame")
        ),
        @"screenDisplayID": @(screenDisplayID),
        @"screenIsMain": @(screenIsMain),
        @"cgVisibleFrame": IOSUseBridgeRectJSON(
            IOSUseBridgeVisibleFrameInCGCoordinates(window)
        ),
        @"expectedCGWindowBoundsFromAppKit":
            CGRectIsNull(expectedCGWindowBounds)
                ? (id)NSNull.null
                : IOSUseBridgeRectJSON(expectedCGWindowBounds),
        @"applicationActive": @(
            IOSUseBridgeBool(
                IOSUseBridgeApplication(),
                @"isActive"
            )
        ),
        @"applicationActivationPolicy": @(
            IOSUseBridgeInteger(
                IOSUseBridgeApplication(),
                @"activationPolicy"
            )
        ),
        @"windowKey": @(IOSUseBridgeBool(window, @"isKeyWindow")),
        @"windowCanBecomeKey": @(
            IOSUseBridgeBool(window, @"canBecomeKeyWindow")
        ),
        @"scenes": IOSUseBridgeSceneInventory(),
        @"contentViewTree": IOSUseBridgeViewInventory(contentView, 3),
        @"windowClass": window == nil
            ? NSNull.null
            : NSStringFromClass([window class]),
        @"windowNumber": @(
            IOSUseBridgeInteger(window, @"windowNumber")
        ),
        @"cgWindowBounds": baseCGWindow == nil
            ? (id)NSNull.null
            : IOSUseBridgeRectJSON(
                [baseCGWindow[@"boundsValue"] CGRectValue]
            ),
        @"minSize": IOSUseBridgeSizeJSON(
            IOSUseBridgeSize(window, @"minSize")
        ),
        @"maxSize": IOSUseBridgeSizeJSON(
            IOSUseBridgeSize(window, @"maxSize")
        ),
        @"contentMinSize": IOSUseBridgeSizeJSON(
            IOSUseBridgeSize(window, @"contentMinSize")
        ),
        @"contentMaxSize": IOSUseBridgeSizeJSON(
            IOSUseBridgeSize(window, @"contentMaxSize")
        ),
        @"sceneMinimumSize": IOSUseBridgeSizeJSON(
            restrictions.minimumSize
        ),
        @"sceneMaximumSize": IOSUseBridgeSizeJSON(
            restrictions.maximumSize
        ),
        @"sceneGeometry": @{
            @"status": IOSUseBridgeSceneGeometryStateName(
                IOSUsePlaySceneGeometryState
            ),
            @"failure": IOSUsePlaySceneGeometryFailure ?: NSNull.null,
            @"bootstrapVerified": @(
                IOSUsePlaySceneGeometryState ==
                    IOSUseBridgeSceneGeometryStateReady &&
                IOSUsePlaySceneGeometryScene == uiWindow.windowScene
            ),
            @"fixedCanvas": @(
                IOSUseBridgeSceneHasFixedCanvas(
                    uiWindow.windowScene,
                    uiWindow
                )
            ),
        },
        @"allWindows": IOSUseBridgeWindowInventory(),
        @"nativeAlert": @{
            @"visible": @(nativeAlertVisible),
            @"frame": nativeAlertFrameJSON,
            @"text": nativeAlertText,
            @"actions": nativeAlertActions,
        },
        @"bootstrapNativeAlert": bootstrapNativeAlert,
        @"backingScaleFactor": @(backingScale),
        @"borderless": @NO,
        @"opaque": @(IOSUseBridgeBool(window, @"isOpaque")),
        @"publicTitleBar": @(
            (BOOL)((IOSUseBridgeInteger(window, @"styleMask") & 1) != 0)
        ),
        @"title": windowTitle,
        @"titleExpected": IOSUseBridgeHostTitle(),
        @"titleVisible": @(
            IOSUseBridgeInteger(window, @"titleVisibility") == 0
        ),
        @"resizable": @(
            (BOOL)((IOSUseBridgeInteger(window, @"styleMask") &
                ((NSInteger)1 << 3)) != 0)
        ),
        @"resizeEdges": @{
            @"available": @(resizeEdges),
            @"growing": @(growingResizeEdges),
            @"shrinking": @(shrinkingResizeEdges),
        },
        @"styleMask": @(
            IOSUseBridgeInteger(window, @"styleMask")
        ),
        @"hasShadow": @(
            IOSUseBridgeBool(window, @"hasShadow")
        ),
        @"movable": @(
            IOSUseBridgeBool(window, @"isMovable")
        ),
        @"ignoresMouseEvents": @(
            IOSUseBridgeBool(window, @"ignoresMouseEvents")
        ),
        @"acceptsMouseMovedEvents": @(
            IOSUseBridgeBool(window, @"acceptsMouseMovedEvents")
        ),
        @"hostPolicy": @(
            IOSUseBridgeWindowPolicyIsHost(window)
        ),
        @"safeAreaCompatibility":
            IOSUsePlaySafeAreaCompatibilityDiagnostics(),
        @"lastTextInputTransientDismissal":
            IOSUsePlayLastTextInputTransientDismissal ?:
                (id)NSNull.null,
        @"sceneScale": @{
            @"status": IOSUsePlaySceneScaleStatus,
            @"failure": IOSUsePlaySceneScaleFailure ?: NSNull.null,
            @"idiom": @(IOSUsePlayObservedIdiomScale),
            @"windows": @(IOSUsePlayObservedWindowScale),
            @"downscaleWindowIfNecessary":
                @(IOSUsePlayObservedDownscale),
        },
        @"identityTransform": @(
            IOSUsePlayHostCanvasLayoutReady
        ),
        @"mouseMonitorReady":
            @((BOOL)(IOSUsePlayMouseLocalMonitor != nil)),
        @"lastMouseDelivery":
            IOSUsePlayLastMouseDelivery ?: (id)NSNull.null,
        @"lastMouseDownDelivery":
            IOSUsePlayLastMouseDownDelivery ?: (id)NSNull.null,
        @"lastMouseUpDelivery":
            IOSUsePlayLastMouseUpDelivery ?: (id)NSNull.null,
        @"mouseDeliveryCount": @(IOSUsePlayMouseDeliveryCount),
    };
}

+ (NSDictionary<NSString *, id> *)readinessDiagnostics {
    return [self
        diagnosticsIncludingStatusOnlyFields:NO
        nativeAlertSnapshot:nil];
}

+ (NSDictionary<NSString *, id> *)uiAutomationAvailability {
    NSParameterAssert(NSThread.isMainThread);
    UIWindow *uiWindow = IOSUseBridgeAutomationUIKitWindow();
    if (uiWindow == nil) {
        BOOL hasBackgroundScene = NO;
        BOOL hasDisconnectedScene = NO;
        for (UIScene *candidate in
             UIApplication.sharedApplication.connectedScenes) {
            if (![candidate isKindOfClass:UIWindowScene.class] ||
                ![candidate.session.role
                    isEqualToString:
                        UIWindowSceneSessionRoleApplication]) {
                continue;
            }
            hasBackgroundScene = hasBackgroundScene ||
                candidate.activationState ==
                    UISceneActivationStateBackground;
            hasDisconnectedScene = hasDisconnectedScene ||
                candidate.activationState ==
                    UISceneActivationStateUnattached;
        }
        return @{
            @"available": @NO,
            @"reason": hasBackgroundScene
                ? @"scene-backgrounded"
                : hasDisconnectedScene || IOSUsePlayHostWindow != nil
                    ? @"scene-disconnected"
                    : @"window-unavailable",
        };
    }
    UISceneActivationState activationState =
        uiWindow.windowScene.activationState;
    if (activationState == UISceneActivationStateBackground ||
        activationState == UISceneActivationStateUnattached) {
        return @{
            @"available": @NO,
            @"reason": activationState ==
                    UISceneActivationStateBackground
                ? @"scene-backgrounded"
                : @"scene-disconnected",
        };
    }
    id window = IOSUseBridgeWindowForUIKitWindow(uiWindow, NO);
    if (window == nil) {
        return @{
            @"available": @NO,
            @"reason": @"window-unavailable",
        };
    }
    if (IOSUseBridgeBool(window, @"isMiniaturized")) {
        return @{
            @"available": @NO,
            @"reason": @"minimized",
        };
    }
    if (uiWindow.hidden || uiWindow.alpha <= 0.01 ||
        !IOSUseBridgeBool(window, @"isVisible")) {
        return @{
            @"available": @NO,
            @"reason": @"hidden",
        };
    }
    SEL activeSpaceSelector = NSSelectorFromString(@"isOnActiveSpace");
    if (![window respondsToSelector:activeSpaceSelector] ||
        !((IOSUseBridgeSendBool)objc_msgSend)(
            window,
            activeSpaceSelector
        )) {
        return @{
            @"available": @NO,
            @"reason": @"inactive-space",
        };
    }
    SEL screenSelector = NSSelectorFromString(@"screen");
    id screen = [window respondsToSelector:screenSelector]
        ? ((IOSUseBridgeSendID)objc_msgSend)(window, screenSelector)
        : nil;
    if (screen == nil || [self screenCount] == 0) {
        return @{
            @"available": @NO,
            @"reason": @"display-unavailable",
        };
    }
    return @{
        @"available": @YES,
        @"reason": NSNull.null,
    };
}

+ (NSDictionary<NSString *, id> *)diagnostics {
    return [self
        diagnosticsIncludingStatusOnlyFields:YES
        nativeAlertSnapshot:nil];
}

+ (NSDictionary<NSString *, id> *)diagnosticsWithNativeAlertSnapshot:
    (NSDictionary<NSString *, id> *)nativeAlertSnapshot {
    return [self
        diagnosticsIncludingStatusOnlyFields:YES
        nativeAlertSnapshot:nativeAlertSnapshot];
}

@end
