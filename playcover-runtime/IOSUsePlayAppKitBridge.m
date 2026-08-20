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

#ifndef IOS_USE_PLAY_ENABLE_HOVER
#define IOS_USE_PLAY_ENABLE_HOVER 0
#endif

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
typedef SEL (*IOSUseBridgeSendSelector)(id, SEL);
typedef CGEventRef _Nullable (*IOSUseBridgeSendCGEvent)(id, SEL);
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
static NSString *IOSUsePlaySceneBackingStatus = @"not-observed";
static NSString *IOSUsePlaySceneBackingFailure;
static CGFloat IOSUsePlayObservedFixedBackingScale;
static CGFloat IOSUsePlayObservedRasterizationScale;
static BOOL IOSUsePlayRequest3XBacking;
static NSDictionary<NSString *, id> *
    IOSUsePlayLastTextInputTransientDismissal;
static id IOSUsePlayMouseLocalMonitor;
static NSDictionary<NSString *, id> *IOSUsePlayLastMouseDelivery;
static NSDictionary<NSString *, id> *IOSUsePlayLastMouseDownDelivery;
static NSDictionary<NSString *, id> *IOSUsePlayLastMouseUpDelivery;
static NSUInteger IOSUsePlayMouseDeliveryCount;
static id IOSUsePlayHostWindow;
static id IOSUsePlayHostContentView;
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

static CGSize IOSUseBridgeSize(
    id object,
    NSString *selectorName
) {
    SEL selector = NSSelectorFromString(selectorName);
    return [object respondsToSelector:selector]
        ? ((IOSUseBridgeSendSize)objc_msgSend)(object, selector)
        : CGSizeZero;
}

static BOOL IOSUseBridgeInstanceFloatMethodMatches(
    id object,
    NSString *selectorName,
    BOOL setter
) {
    SEL selector = NSSelectorFromString(selectorName);
    Method method = object == nil
        ? NULL
        : class_getInstanceMethod([object class], selector);
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

static BOOL IOSUseBridgeApproximatelyEqual(CGFloat lhs, CGFloat rhs) {
    return fabs(lhs - rhs) <= 0.01;
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

static BOOL IOSUseBridgeWindowPolicyIsHost(id window) {
    const NSInteger titled = 1 << 0;
    const NSInteger resizable = 1 << 3;
    NSInteger styleMask = IOSUseBridgeInteger(window, @"styleMask");
    return (styleMask & titled) != 0 &&
        (styleMask & resizable) == 0 &&
        IOSUseBridgeBool(window, @"isOpaque") &&
        IOSUseBridgeBool(window, @"isMovable") &&
        !IOSUseBridgeBool(window, @"ignoresMouseEvents");
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

/// Maps an AppKit AX/native-alert rectangle from the native Catalyst content
/// view into the fixed iPhone logical coordinate space. This is evidence
/// normalization only; the AppKit display hierarchy is never transformed.
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
        CGRect contentBounds = IOSUseBridgeRect(
            IOSUsePlayHostContentView,
            @"bounds"
        );
        CGRect visibleHostRect = CGRectIntersection(
            hostContentRect,
            contentBounds
        );
        if (!IOSUseBridgeAccessibilityFiniteRect(visibleHostRect)) {
            return CGRectNull;
        }
        CGRect logicalRect = CGRectNull;
        NSString *transformFailure = nil;
        if (!IOSUsePlayMapHostContentRectToDevice(
                contentBounds,
                visibleHostRect,
                &logicalRect,
                &transformFailure
            )) {
            if (error != NULL) {
                *error = IOSUseBridgeAccessibilityError(
                    14,
                    transformFailure ?:
                        @"native content geometry normalization failed"
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
                    @"AppKit content geometry conversion raised %@",
                    exception.name]
            );
        }
        return CGRectNull;
    }
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
    // The iPhone model remains fixed in UIKit. Catalyst owns how that logical
    // scene is presented in its native, non-resizable AppKit window.
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

static BOOL IOSUseBridgeApplyWindowPolicy(id window) {
    // Preserve UIKitMacHelper's native titled window and disable only public
    // resizing. Catalyst remains the sole owner of content size and scene
    // presentation scale.
    const NSInteger resizable = 1 << 3;
    NSInteger styleMask = IOSUseBridgeInteger(window, @"styleMask");
    if ((styleMask & resizable) != 0) {
        IOSUseBridgeSetInteger(
            window,
            @"setStyleMask:",
            styleMask & ~resizable
        );
    }
    return IOSUseBridgeWindowPolicyIsHost(window);
}

static BOOL IOSUseBridgeCaptureNativeHost(id window) {
    SEL contentViewSelector = NSSelectorFromString(@"contentView");
    id currentContent = [window respondsToSelector:contentViewSelector]
        ? ((IOSUseBridgeSendID)objc_msgSend)(
            window,
            contentViewSelector
        )
        : nil;
    if (currentContent == nil ||
        CGRectIsEmpty(IOSUseBridgeRect(currentContent, @"bounds"))) {
        return NO;
    }
    IOSUsePlayHostWindow = window;
    IOSUsePlayHostContentView = currentContent;
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

static BOOL IOSUseBridgeReconcileSceneBacking(
    id sceneView,
    NSString **failure
) {
    if (failure != NULL) {
        *failure = nil;
    }
    IOSUsePlayObservedFixedBackingScale = 0;
    IOSUsePlayObservedRasterizationScale = 0;
    IOSUsePlaySceneBackingFailure = nil;
    if (sceneView == nil) {
        IOSUsePlaySceneBackingStatus = @"waiting-for-scene-view";
        IOSUsePlaySceneBackingFailure =
            @"UIKitMacHelper scene view is unavailable";
        if (failure != NULL) {
            *failure = IOSUsePlaySceneBackingFailure;
        }
        return NO;
    }
    NSString *rasterGetterName = @"rasterizationScaleFactor";
    NSString *fixedGetterName = @"fixedBackingScaleFactor";
    if (!IOSUseBridgeInstanceFloatMethodMatches(
            sceneView,
            rasterGetterName,
            NO
        )) {
        IOSUsePlaySceneBackingStatus = @"unavailable";
        IOSUsePlaySceneBackingFailure =
            @"UIKitMacHelper rasterization scale is unavailable";
        if (failure != NULL) {
            *failure = IOSUsePlaySceneBackingFailure;
        }
        return NO;
    }
    if (IOSUsePlayRequest3XBacking) {
        NSString *fixedSetterName = @"setFixedBackingScaleFactor:";
        if (!IOSUseBridgeInstanceFloatMethodMatches(
                sceneView,
                fixedGetterName,
                NO
            ) ||
            !IOSUseBridgeInstanceFloatMethodMatches(
                sceneView,
                fixedSetterName,
                YES
            )) {
            IOSUsePlaySceneBackingStatus = @"abi-mismatch";
            IOSUsePlaySceneBackingFailure =
                @"UIKitMacHelper fixed backing scale has an unsupported ABI";
            if (failure != NULL) {
                *failure = IOSUsePlaySceneBackingFailure;
            }
            return NO;
        }
        ((void (*)(id, SEL, CGFloat))objc_msgSend)(
            sceneView,
            NSSelectorFromString(fixedSetterName),
            3.0
        );
        IOSUseBridgeLayoutIfNeeded(sceneView);
    }
    if (IOSUseBridgeInstanceFloatMethodMatches(
            sceneView,
            fixedGetterName,
            NO
        )) {
        IOSUsePlayObservedFixedBackingScale =
            ((CGFloat (*)(id, SEL))objc_msgSend)(
                sceneView,
                NSSelectorFromString(fixedGetterName)
            );
    }
    IOSUsePlayObservedRasterizationScale =
        ((CGFloat (*)(id, SEL))objc_msgSend)(
            sceneView,
            NSSelectorFromString(rasterGetterName)
        );
    BOOL ready =
        isfinite(IOSUsePlayObservedRasterizationScale) &&
        IOSUsePlayObservedRasterizationScale > 0;
    if (IOSUsePlayRequest3XBacking) {
        ready = ready && IOSUseBridgeApproximatelyEqual(
            IOSUsePlayObservedFixedBackingScale,
            3.0
        ) && IOSUseBridgeApproximatelyEqual(
            IOSUsePlayObservedRasterizationScale,
            3.0
        );
    }
    IOSUsePlaySceneBackingStatus = ready
        ? IOSUsePlayRequest3XBacking
            ? @"fixed-3x"
            : @"catalyst-managed"
        : @"rejected";
    IOSUsePlaySceneBackingFailure = ready
        ? nil
        : @"UIKitMacHelper scene backing scale is not ready";
    if (!ready && failure != NULL) {
        *failure = IOSUsePlaySceneBackingFailure;
    }
    return ready;
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
        IOSUsePlayHostContentView == nil) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:IOSUsePlayWindowErrorDomain
                                         code:7
                                     userInfo:@{
                NSLocalizedDescriptionKey:
                    @"native Catalyst content is not ready for capture",
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
    CGRect contentBounds = IOSUseBridgeRect(
        IOSUsePlayHostContentView,
        @"bounds"
    );
    CGFloat backingScaleFactor =
        IOSUseBridgeBackingScaleFactor(window);
    CGFloat geometryTolerance = backingScaleFactor > 0
        ? 0.5 / backingScaleFactor
        : 0;
    BOOL contentReady = IOSUseBridgeHostContentCGWindowRect(
        window,
        IOSUsePlayHostContentView,
        &contentCGWindowRect
    );
    if (hostMetadata == nil || CGRectIsNull(hostCGWindowBounds) ||
        !contentReady || CGRectIsEmpty(contentBounds) ||
        geometryTolerance <= 0 ||
        CGRectGetMinX(contentCGWindowRect) <
            CGRectGetMinX(hostCGWindowBounds) - geometryTolerance ||
        CGRectGetMinY(contentCGWindowRect) <
            CGRectGetMinY(hostCGWindowBounds) - geometryTolerance ||
        CGRectGetMaxX(contentCGWindowRect) >
            CGRectGetMaxX(hostCGWindowBounds) + geometryTolerance ||
        CGRectGetMaxY(contentCGWindowRect) >
            CGRectGetMaxY(hostCGWindowBounds) + geometryTolerance) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:IOSUsePlayWindowErrorDomain
                                         code:8
                                     userInfo:@{
                NSLocalizedDescriptionKey:
                    @"could not resolve native content inside the host CGWindow",
            }];
        }
        return nil;
    }
    return @{
        @"hostFrame": IOSUseBridgeRectJSON(
            IOSUseBridgeRect(window, @"frame")
        ),
        @"hostContentBounds": IOSUseBridgeRectJSON(contentBounds),
        @"hostContentCGWindowRect": IOSUseBridgeRectJSON(
            contentCGWindowRect
        ),
        @"hostCGWindowBounds": IOSUseBridgeRectJSON(hostCGWindowBounds),
        // The native Catalyst content is the complete target canvas. Only
        // coordinate/capture normalization maps it to the fixed phone model.
        @"canvasCGWindowRect": IOSUseBridgeRectJSON(
            contentCGWindowRect
        ),
        @"backingScaleFactor": @(backingScaleFactor),
        @"halfPixelTolerance": @(geometryTolerance),
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
    // NSEventMask is defined as one shifted by NSEventType in pinned
    // PlayTools/AppKit. Hover is disabled by default; define
    // IOS_USE_PLAY_ENABLE_HOVER=1 when compiling the Runtime to restore it.
    NSUInteger mask = ((NSUInteger)1 << 1) | ((NSUInteger)1 << 2);
#if !IOS_USE_PLAY_ENABLE_HOVER
    // MouseMoved, MouseEntered, MouseExited, and CursorUpdate.
    mask |= ((NSUInteger)1 << 5) |
        ((NSUInteger)1 << 8) |
        ((NSUInteger)1 << 9) |
        ((NSUInteger)1 << 17);
#endif
    id handler = ^id(id event) {
        NSInteger eventType = IOSUseBridgeInteger(event, @"type");
#if !IOS_USE_PLAY_ENABLE_HOVER
        if (eventType == 5 || eventType == 8 ||
            eventType == 9 || eventType == 17) {
            return nil;
        }
#endif
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
        CGRect contentBounds = IOSUseBridgeRect(
            IOSUsePlayHostContentView,
            @"bounds"
        );
        BOOL hostCanvasReady = eventWindow == IOSUsePlayHostWindow &&
            IOSUsePlayHostContentView != nil &&
            IOSUseBridgeAccessibilityFiniteRect(contentBounds);
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
            IOSUsePlayMapHostContentPointToDevice(
                contentBounds,
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
            @"contentBounds": hostCanvasReady
                ? IOSUseBridgeRectJSON(contentBounds)
                : (id)NSNull.null,
            @"targetHitTest": @(targetHitTest),
            @"transformFailure": inverseFailure ?:
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
        (NSDictionary<NSString *, id> *)nativeAlertSnapshot;

@end

@implementation IOSUsePlayAppKitBridge

+ (void)captureSceneBackingLaunchEnvironment {
    const char *value = getenv("IOS_USE_PLAY_ENABLE_3X_BACKING");
    IOSUsePlayRequest3XBacking =
        value != NULL && strcmp(value, "1") == 0;
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
            @"NSWindowDidChangeBackingPropertiesNotification",
            @"NSWindowDidChangeScreenNotification",
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
    });
    // PlayLoader invokes this from a constructor before UIApplicationMain.
    // Window reconciliation starts only after UIKit creates a scene.
}

+ (BOOL)configureFixedWindow:(NSError **)error {
    NSParameterAssert(NSThread.isMainThread);
    IOSUsePlayWindowAttemptCount += 1;
    UIWindow *uiWindow = IOSUseBridgeAutomationUIKitWindow();
    id window = uiWindow == nil
        ? nil
        : IOSUseBridgeWindowForUIKitWindow(uiWindow, NO);
    NSError *safeAreaError = nil;
    BOOL safeAreaReconciled =
        IOSUsePlaySafeAreaCompatibilityReconcile(&safeAreaError);
    if (uiWindow == nil || window == nil) {
        IOSUsePlayWindowStatus = @"waiting-for-window";
        IOSUsePlayWindowFailure =
            @"UIKit/AppKit window bridge is unavailable";
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
        IOSUsePlayWindowFailure = IOSUsePlaySceneGeometryFailure ?:
            @"fixed UIKit scene geometry is unavailable";
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
            @"could not make the native Catalyst window non-resizable";
        if (error != NULL) {
            *error = [NSError errorWithDomain:IOSUsePlayWindowErrorDomain
                                         code:10
                                     userInfo:@{
                NSLocalizedDescriptionKey: IOSUsePlayWindowFailure,
            }];
        }
        return NO;
    }
    if (!IOSUseBridgeCaptureNativeHost(window)) {
        IOSUsePlayWindowStatus = @"failed";
        IOSUsePlayWindowFailure =
            @"native Catalyst content view is unavailable";
        if (error != NULL) {
            *error = [NSError errorWithDomain:IOSUsePlayWindowErrorDomain
                                         code:5
                                     userInfo:@{
                NSLocalizedDescriptionKey: IOSUsePlayWindowFailure,
            }];
        }
        return NO;
    }
    IOSUseBridgeLayoutIfNeeded(IOSUsePlayHostContentView);
    id sceneRenderView =
        IOSUseBridgeSceneRenderView(IOSUsePlayHostContentView);
    id inputRenderView =
        IOSUseBridgeInputRenderView(sceneRenderView);
    NSString *backingFailure = nil;
    BOOL backingReady = IOSUseBridgeReconcileSceneBacking(
        sceneRenderView,
        &backingFailure
    );
    BOOL mouseMonitorReady =
        IOSUseBridgeInstallMouseLocalMonitor();

    UISceneSizeRestrictions *restrictions =
        uiWindow.windowScene.sizeRestrictions;
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
    BOOL sceneGeometryReady =
        IOSUsePlaySceneGeometryState ==
            IOSUseBridgeSceneGeometryStateReady &&
        IOSUsePlaySceneGeometryScene == uiWindow.windowScene;
    id currentContent = [window respondsToSelector:
        NSSelectorFromString(@"contentView")]
        ? ((IOSUseBridgeSendID)objc_msgSend)(
            window,
            NSSelectorFromString(@"contentView")
        )
        : nil;
    BOOL geometryExact =
        IOSUseBridgeWindowPolicyIsHost(window) &&
        sceneFixed &&
        sceneGeometryReady &&
        currentContent == IOSUsePlayHostContentView &&
        sceneRenderView != nil &&
        inputRenderView != nil &&
        backingReady &&
        mouseMonitorReady &&
        IOSUseBridgeRectIsDeviceScreen(uiWindow.bounds);
    BOOL safeAreaReady =
        safeAreaReconciled &&
        IOSUsePlaySafeAreaCompatibilityIsReadyForWindow(uiWindow);
    if (geometryExact && !safeAreaReady) {
        NSDictionary<NSString *, id> *safeAreaDiagnostics =
            IOSUsePlaySafeAreaCompatibilityDiagnostics();
        BOOL failed = [
            safeAreaDiagnostics[@"stage"] isEqual:@"failed"
        ];
        id diagnosticsFailure = safeAreaDiagnostics[@"failure"];
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
            *error = [NSError errorWithDomain:IOSUsePlayWindowErrorDomain
                                         code:failed ? 13 : 12
                                     userInfo:@{
                NSLocalizedDescriptionKey: IOSUsePlayWindowFailure,
            }];
        }
        return NO;
    }
    BOOL exact = geometryExact && safeAreaReady;
    IOSUsePlayWindowStatus = exact
        ? @"configured"
        : @"geometry-mismatch";
    IOSUsePlayWindowFailure = exact
        ? nil
        : backingFailure ?:
            (sceneGeometryReady
                ? @"native Catalyst host geometry is not ready"
                : IOSUsePlaySceneGeometryFailure ?:
                    @"fixed UIKit scene geometry is not ready");
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
    CGRect contentBounds = IOSUseBridgeRect(
        IOSUsePlayHostContentView,
        @"bounds"
    );
    if (!IOSUseBridgeAccessibilityFiniteRect(contentBounds) ||
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
    return IOSUsePlayMapHostContentPointToDevice(
        contentBounds,
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
    if (IOSUsePlayHostWindow == nil ||
        IOSUsePlayHostContentView == nil) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:IOSUsePlayWindowErrorDomain
                                         code:9
                                     userInfo:@{
                NSLocalizedDescriptionKey:
                    @"native Catalyst content is unavailable",
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
    id selectedWindow =
        includeStatusOnlyFields || IOSUsePlayHostWindow == nil
            ? IOSUseBridgeSelectedWindow()
            : nil;
    id window = IOSUsePlayHostWindow ?: selectedWindow;
    id rawCapturedMetadata =
        nativeAlertSnapshot[@"_cgWindowMetadata"];
    NSDictionary<
        NSNumber *,
        NSDictionary<NSString *, id> *
    > *cgWindowMetadata =
        [rawCapturedMetadata isKindOfClass:NSDictionary.class]
            ? rawCapturedMetadata
            : IOSUseBridgeOwnOnscreenCGWindowMetadata();
    CGRect frame = IOSUseBridgeRect(window, @"frame");
    id contentView = [window respondsToSelector:
        NSSelectorFromString(@"contentView")]
        ? ((IOSUseBridgeSendID)objc_msgSend)(
            window,
            NSSelectorFromString(@"contentView")
        )
        : nil;
    CGRect contentBounds = IOSUseBridgeRect(contentView, @"bounds");
    UIWindow *uiWindow = IOSUseBridgeAutomationUIKitWindow();
    CGRect canvasBounds =
        uiWindow == nil ? CGRectZero : uiWindow.bounds;
    id sceneRenderView =
        IOSUseBridgeSceneRenderView(contentView);
    id inputRenderView =
        IOSUseBridgeInputRenderView(sceneRenderView);
    CGFloat backingScale = IOSUseBridgeBackingScaleFactor(window);
    NSError *captureError = nil;
    NSDictionary<NSString *, id> *canvasCapture =
        IOSUseBridgeHostCanvasCaptureGeometry(
            window,
            cgWindowMetadata,
            &captureError
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
    NSMutableDictionary<NSString *, id> *result = [@{
        @"status": IOSUsePlayWindowStatus,
        @"failure": IOSUsePlayWindowFailure ?: NSNull.null,
        @"frame": IOSUseBridgeRectJSON(frame),
        @"hostFrame": IOSUseBridgeRectJSON(frame),
        @"hostContentBounds": IOSUseBridgeRectJSON(contentBounds),
        @"canvasBounds": IOSUseBridgeRectJSON(canvasBounds),
        @"backingScaleFactor": @(backingScale),
        @"sceneRasterizationScale":
            @(IOSUsePlayObservedRasterizationScale),
        @"fixedBackingScale":
            @(IOSUsePlayObservedFixedBackingScale),
        @"sceneBacking": @{
            @"status": IOSUsePlaySceneBackingStatus,
            @"failure":
                IOSUsePlaySceneBackingFailure ?: NSNull.null,
            @"requestedScale": @(
                IOSUsePlayRequest3XBacking ? 3.0 : 0.0
            ),
        },
        @"canvasCapture": canvasCapture ?: (id)@{
            @"error":
                captureError.localizedDescription ?: @"unavailable",
        },
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
        @"hostPolicy": @(IOSUseBridgeWindowPolicyIsHost(window)),
        @"nativeContentView": @(
            window == IOSUsePlayHostWindow &&
            contentView == IOSUsePlayHostContentView
        ),
        @"sceneGeometry": @{
            @"failure":
                IOSUsePlaySceneGeometryFailure ?: NSNull.null,
        },
    } mutableCopy];
    if (!includeStatusOnlyFields) {
        return result;
    }

    id windowScreen = [window respondsToSelector:
        NSSelectorFromString(@"screen")]
        ? ((IOSUseBridgeSendID)objc_msgSend)(
            window,
            NSSelectorFromString(@"screen")
        )
        : nil;
    CGDirectDisplayID screenDisplayID =
        IOSUseBridgeDisplayIDForScreen(windowScreen);
    UISceneSizeRestrictions *restrictions =
        uiWindow.windowScene.sizeRestrictions;
    NSDictionary<NSString *, id> *baseCGWindow =
        IOSUseBridgeExactOnscreenCGWindowMetadata(
            window,
            cgWindowMetadata
        );
    CGRect expectedCGWindowBounds = CGRectNull;
    (void)IOSUseBridgeAppKitScreenRectToCGWindowRect(
        frame,
        &expectedCGWindowBounds
    );
    NSDictionary<NSString *, id> *nativeAlertSelection =
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
        : IOSUseBridgeNativeAlertText(nativeAlertWindow);
    NSArray<NSDictionary<NSString *, id> *> *nativeAlertActions =
        nativeAlertSnapshot != nil
            ? nativeAlertSnapshot[@"actions"] ?: @[]
            : IOSUseBridgePublicNativeAlertActions(nativeAlertWindow);
    [result addEntriesFromDictionary:@{
        @"attempts": @(IOSUsePlayWindowAttemptCount),
        @"contentLayoutRect": IOSUseBridgeRectJSON(
            IOSUseBridgeRect(window, @"contentLayoutRect")
        ),
        @"contentViewFrame": IOSUseBridgeRectJSON(
            IOSUseBridgeRect(contentView, @"frame")
        ),
        @"contentViewBounds": IOSUseBridgeRectJSON(contentBounds),
        @"sceneView": @{
            @"class": sceneRenderView == nil
                ? (id)NSNull.null
                : NSStringFromClass([sceneRenderView class]),
            @"frame": IOSUseBridgeRectJSON(
                IOSUseBridgeRect(sceneRenderView, @"frame")
            ),
            @"bounds": IOSUseBridgeRectJSON(
                IOSUseBridgeRect(sceneRenderView, @"bounds")
            ),
            @"inputFrame": IOSUseBridgeRectJSON(
                IOSUseBridgeRect(inputRenderView, @"frame")
            ),
            @"inputBounds": IOSUseBridgeRectJSON(
                IOSUseBridgeRect(inputRenderView, @"bounds")
            ),
        },
        @"screenFrame": IOSUseBridgeRectJSON(
            IOSUseBridgeRect(windowScreen, @"frame")
        ),
        @"screenVisibleFrame": IOSUseBridgeRectJSON(
            IOSUseBridgeRect(windowScreen, @"visibleFrame")
        ),
        @"screenDisplayID": @(screenDisplayID),
        @"screenIsMain": @(
            screenDisplayID != kCGNullDirectDisplay &&
            CGDisplayIsMain(screenDisplayID) != 0
        ),
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
        @"contentViewTree":
            IOSUseBridgeViewInventory(contentView, 3),
        @"windowClass": window == nil
            ? (id)NSNull.null
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
            @"failure":
                IOSUsePlaySceneGeometryFailure ?: NSNull.null,
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
        @"bootstrapNativeAlert":
            IOSUseBridgeBootstrapNativeAlertDiagnostics(),
        @"borderless": @NO,
        @"styleMask": @(IOSUseBridgeInteger(window, @"styleMask")),
        @"hasShadow": @(IOSUseBridgeBool(window, @"hasShadow")),
        @"movable": @(IOSUseBridgeBool(window, @"isMovable")),
        @"ignoresMouseEvents": @(
            IOSUseBridgeBool(window, @"ignoresMouseEvents")
        ),
        @"acceptsMouseMovedEvents": @(
            IOSUseBridgeBool(window, @"acceptsMouseMovedEvents")
        ),
        @"safeAreaCompatibility":
            IOSUsePlaySafeAreaCompatibilityDiagnostics(),
        @"lastTextInputTransientDismissal":
            IOSUsePlayLastTextInputTransientDismissal ?:
                (id)NSNull.null,
        @"mouseMonitorReady":
            @((BOOL)(IOSUsePlayMouseLocalMonitor != nil)),
        @"lastMouseDelivery":
            IOSUsePlayLastMouseDelivery ?: (id)NSNull.null,
        @"lastMouseDownDelivery":
            IOSUsePlayLastMouseDownDelivery ?: (id)NSNull.null,
        @"lastMouseUpDelivery":
            IOSUsePlayLastMouseUpDelivery ?: (id)NSNull.null,
        @"mouseDeliveryCount": @(IOSUsePlayMouseDeliveryCount),
    }];
    return result;
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
