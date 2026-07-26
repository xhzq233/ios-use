#import "IOSUsePlayAppKitBridge.h"
#import "IOSUsePlayDevice.h"
#import "IOSUsePlayWindowCompositor.h"

#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

typedef id (*IOSUseBridgeSendID)(id, SEL);
typedef id (*IOSUseBridgeSendIDInteger)(id, SEL, NSInteger);
typedef BOOL (*IOSUseBridgeSendBool)(id, SEL);
typedef NSInteger (*IOSUseBridgeSendInteger)(id, SEL);
typedef CGFloat (*IOSUseBridgeSendFloat)(id, SEL);
typedef CGPoint (*IOSUseBridgeSendPoint)(id, SEL);
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
typedef void (*IOSUseBridgeSendIDArgument)(id, SEL, id);
typedef void (*IOSUseBridgeSendIntegerArgument)(id, SEL, NSInteger);
typedef void (*IOSUseBridgeSendPointArgument)(id, SEL, CGPoint);
typedef void (*IOSUseBridgeSendRectArgument)(id, SEL, CGRect);
typedef void (*IOSUseBridgeSendSizeArgument)(id, SEL, CGSize);
typedef id (*IOSUseBridgeSendIDUnsignedIntegerID)(
    id,
    SEL,
    NSUInteger,
    id
);
typedef NSUInteger (*IOSUseBridgeSendUnsignedIntegerID)(
    id,
    SEL,
    id
);
typedef id (*IOSUseBridgeSendIDIDUnsignedIntegerUnsignedInteger)(
    id,
    SEL,
    id,
    NSUInteger,
    NSUInteger
);
typedef CFArrayRef _Nullable (*IOSUseBridgeCGWindowListCopyWindowInfo)(
    CGWindowListOption,
    CGWindowID
);

static NSString *const IOSUsePlayWindowErrorDomain =
    @"io.ios-use.play-runtime.window";
static NSString *const IOSUsePlayNativeAlertErrorDomain =
    @"io.ios-use.play-runtime.native-alert";
static NSString *const IOSUsePlayAccessibilityBridgeErrorDomain =
    @"io.ios-use.play-runtime.appkit-accessibility";
static const NSUInteger
    IOSUseBridgeMaximumAccessibilityTraversalCount = 4096;
static const NSUInteger
    IOSUseBridgeMaximumAccessibilityDepth = 64;
static const NSUInteger
    IOSUseBridgeMaximumAccessibilityChildrenPerNode = 512;
static const NSUInteger
    IOSUseBridgeMaximumAccessibilityElementCount = 512;
static const NSUInteger
    IOSUseBridgeMaximumAccessibilityStringLength = 4096;
static const NSUInteger
    IOSUseBridgeMaximumAccessibilityTotalStringLength = 512 * 1024;
static NSString *IOSUsePlayWindowStatus = @"not-configured";
static NSString *IOSUsePlayWindowFailure;
static NSUInteger IOSUsePlayWindowAttemptCount;
static NSString *IOSUsePlaySceneScaleStatus = @"not-configured";
static NSString *IOSUsePlaySceneScaleFailure;
static CGFloat IOSUsePlayObservedIdiomScale;
static CGFloat IOSUsePlayObservedWindowScale;
static BOOL IOSUsePlayObservedDownscale;
static NSDictionary<NSString *, id> *
    IOSUsePlayLastTextInputTransientDismissal;
static id IOSUsePlayMouseLocalMonitor;
static NSDictionary<NSString *, id> *IOSUsePlayLastMouseDelivery;
static NSDictionary<NSString *, id> *IOSUsePlayLastMouseDownDelivery;
static NSDictionary<NSString *, id> *IOSUsePlayLastMouseUpDelivery;
static NSUInteger IOSUsePlayMouseDeliveryCount;

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
        IOSUseBridgeKeyUIKitWindow(),
        YES
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

static BOOL IOSUseBridgeSetPoint(
    id object,
    NSString *selectorName,
    CGPoint value
) {
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) {
        return NO;
    }
    ((IOSUseBridgeSendPointArgument)objc_msgSend)(
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

static NSDictionary<
    NSNumber *,
    NSDictionary<NSString *, id> *
> *IOSUseBridgeOwnOnscreenCGWindowMetadata(void) {
    static IOSUseBridgeCGWindowListCopyWindowInfo copyWindowInfo;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        copyWindowInfo =
            (IOSUseBridgeCGWindowListCopyWindowInfo)dlsym(
                RTLD_DEFAULT,
                "CGWindowListCopyWindowInfo"
            );
    });
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

static BOOL IOSUseBridgeReallySetWindowFrame(
    id window,
    CGRect value
) {
    Class windowClass = NSClassFromString(@"NSWindow");
    SEL selector = NSSelectorFromString(@"_reallySetFrame:");
    Method method = class_getInstanceMethod(windowClass, selector);
    if (windowClass == Nil ||
        ![window isKindOfClass:windowClass] ||
        method == NULL ||
        method_getNumberOfArguments(method) != 3) {
        return NO;
    }
    char *returnType = method_copyReturnType(method);
    char *argumentType = method_copyArgumentType(method, 2);
    BOOL signatureMatches =
        returnType != NULL &&
        argumentType != NULL &&
        strcmp(returnType, @encode(void)) == 0 &&
        strcmp(argumentType, @encode(CGRect)) == 0;
    free(returnType);
    free(argumentType);
    if (!signatureMatches) {
        return NO;
    }
    ((IOSUseBridgeSendRectArgument)method_getImplementation(method))(
        window,
        selector,
        value
    );
    return YES;
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

static BOOL IOSUseBridgeSizeIsDeviceScreen(CGSize size) {
    return IOSUseBridgeApproximatelyEqual(
            size.width,
            IOSUsePlayDeviceLogicalWidth
        ) &&
        IOSUseBridgeApproximatelyEqual(
            size.height,
            IOSUsePlayDeviceLogicalHeight
        );
}

static BOOL IOSUseBridgeAlwaysAllowsWindowFocus(
    __unused id object,
    __unused SEL selector
) {
    return YES;
}

static BOOL IOSUseBridgeClassOwnsSelector(Class target, SEL selector) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(target, &count);
    BOOL owns = NO;
    for (unsigned int index = 0; index < count; index += 1) {
        if (method_getName(methods[index]) == selector) {
            owns = YES;
            break;
        }
    }
    free(methods);
    return owns;
}

static BOOL IOSUseBridgeMakeBorderlessWindowFocusable(id window) {
    Class windowClass = NSClassFromString(@"NSWindow");
    Class concreteClass = object_getClass(window);
    if (windowClass == Nil ||
        concreteClass == Nil ||
        ![window isKindOfClass:windowClass]) {
        return NO;
    }
    for (NSString *selectorName in @[
        @"canBecomeKeyWindow",
        @"canBecomeMainWindow",
    ]) {
        SEL selector = NSSelectorFromString(selectorName);
        Method inheritedMethod =
            class_getInstanceMethod(concreteClass, selector);
        const char *types = inheritedMethod == NULL
            ? "c@:"
            : method_getTypeEncoding(inheritedMethod);
        if (!IOSUseBridgeClassOwnsSelector(concreteClass, selector)) {
            if (!class_addMethod(
                    concreteClass,
                    selector,
                    (IMP)IOSUseBridgeAlwaysAllowsWindowFocus,
                    types
                )) {
                return NO;
            }
        } else {
            Method concreteMethod =
                class_getInstanceMethod(concreteClass, selector);
            if (concreteMethod == NULL) {
                return NO;
            }
            method_setImplementation(
                concreteMethod,
                (IMP)IOSUseBridgeAlwaysAllowsWindowFocus
            );
        }
    }
    return IOSUseBridgeBool(window, @"canBecomeKeyWindow") &&
        IOSUseBridgeBool(window, @"canBecomeMainWindow");
}

static BOOL IOSUseBridgeWindowPolicyIsFixed(id window) {
    return IOSUseBridgeInteger(window, @"styleMask") == 0 &&
        IOSUseBridgeBool(window, @"canBecomeKeyWindow") &&
        IOSUseBridgeBool(window, @"canBecomeMainWindow") &&
        !IOSUseBridgeBool(window, @"hasShadow") &&
        !IOSUseBridgeBool(window, @"isMovable") &&
        IOSUseBridgeSizeIsDeviceScreen(
            IOSUseBridgeSize(window, @"minSize")
        ) &&
        IOSUseBridgeSizeIsDeviceScreen(
            IOSUseBridgeSize(window, @"maxSize")
        ) &&
        IOSUseBridgeSizeIsDeviceScreen(
            IOSUseBridgeSize(window, @"contentMinSize")
        ) &&
        IOSUseBridgeSizeIsDeviceScreen(
            IOSUseBridgeSize(window, @"contentMaxSize")
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

static UIWindow *
IOSUseBridgeBackgroundActivationUIKitWindow(void) {
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

static BOOL IOSUseBridgeAccessibilityObject(
    id object,
    NSString *selectorName,
    id _Nullable __autoreleasing *value,
    NSError * _Nullable __autoreleasing *error
) {
    if (value != NULL) {
        *value = nil;
    }
    SEL selector = NSSelectorFromString(selectorName);
    if (object == nil || ![object respondsToSelector:selector]) {
        return YES;
    }
    @try {
        id result = ((IOSUseBridgeSendID)objc_msgSend)(
            object,
            selector
        );
        if (value != NULL) {
            *value = result;
        }
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            *error = IOSUseBridgeAccessibilityError(
                2,
                [NSString stringWithFormat:
                    @"AppKit accessibility selector %@ raised %@",
                    selectorName,
                    exception.name]
            );
        }
        return NO;
    }
}

static NSArray * _Nullable IOSUseBridgeAccessibilityChildren(
    id object,
    NSError * _Nullable __autoreleasing *error
) {
    SEL countSelector =
        NSSelectorFromString(@"accessibilityArrayAttributeCount:");
    SEL valuesSelector = NSSelectorFromString(
        @"accessibilityArrayAttributeValues:index:maxCount:"
    );
    NSString *childrenAttribute = @"AXChildren";
    if ([object respondsToSelector:countSelector] &&
        [object respondsToSelector:valuesSelector]) {
        @try {
            NSUInteger count = (
                (IOSUseBridgeSendUnsignedIntegerID)objc_msgSend
            )(
                object,
                countSelector,
                childrenAttribute
            );
            if (count >
                IOSUseBridgeMaximumAccessibilityChildrenPerNode) {
                if (error != NULL) {
                    *error = IOSUseBridgeAccessibilityError(
                        10,
                        @"AppKit accessibility node exceeded 512 children"
                    );
                }
                return nil;
            }
            if (count == 0) {
                return @[];
            }
            id values = (
                (IOSUseBridgeSendIDIDUnsignedIntegerUnsignedInteger)
                    objc_msgSend
            )(
                object,
                valuesSelector,
                childrenAttribute,
                0,
                count
            );
            if (![values isKindOfClass:NSArray.class] ||
                [(NSArray *)values count] > count) {
                if (error != NULL) {
                    *error = IOSUseBridgeAccessibilityError(
                        9,
                        @"bounded AppKit AXChildren query returned invalid data"
                    );
                }
                return nil;
            }
            return values;
        } @catch (__unused NSException *exception) {
            // Some Catalyst proxy objects advertise the legacy bounded API
            // but reject AXChildren. Fall through to the modern property;
            // its materialized result is still immediately count-checked.
        }
    }

    id childrenValue = nil;
    if (!IOSUseBridgeAccessibilityObject(
            object,
            @"accessibilityChildren",
            &childrenValue,
            error
        )) {
        return nil;
    }
    if (childrenValue == nil) {
        return @[];
    }
    if (![childrenValue isKindOfClass:NSArray.class] ||
        [(NSArray *)childrenValue count] >
            IOSUseBridgeMaximumAccessibilityChildrenPerNode) {
        if (error != NULL) {
            *error = IOSUseBridgeAccessibilityError(
                9,
                @"AppKit accessibilityChildren returned invalid data"
            );
        }
        return nil;
    }
    return childrenValue;
}

static BOOL IOSUseBridgeAccessibilityRect(
    id object,
    NSString *selectorName,
    CGRect *value,
    NSError * _Nullable __autoreleasing *error
) {
    if (value != NULL) {
        *value = CGRectZero;
    }
    SEL selector = NSSelectorFromString(selectorName);
    if (object == nil || ![object respondsToSelector:selector]) {
        return YES;
    }
    @try {
        CGRect result = ((IOSUseBridgeSendRect)objc_msgSend)(
            object,
            selector
        );
        if (value != NULL) {
            *value = result;
        }
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            *error = IOSUseBridgeAccessibilityError(
                3,
                [NSString stringWithFormat:
                    @"AppKit accessibility frame selector raised %@",
                    exception.name]
            );
        }
        return NO;
    }
}

static BOOL IOSUseBridgeAccessibilityBool(
    id object,
    NSString *selectorName,
    BOOL fallback,
    BOOL *value,
    NSError * _Nullable __autoreleasing *error
) {
    if (value != NULL) {
        *value = fallback;
    }
    SEL selector = NSSelectorFromString(selectorName);
    if (object == nil || ![object respondsToSelector:selector]) {
        return YES;
    }
    @try {
        BOOL result = ((IOSUseBridgeSendBool)objc_msgSend)(
            object,
            selector
        );
        if (value != NULL) {
            *value = result;
        }
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            *error = IOSUseBridgeAccessibilityError(
                4,
                [NSString stringWithFormat:
                    @"AppKit accessibility boolean selector %@ raised %@",
                    selectorName,
                    exception.name]
            );
        }
        return NO;
    }
}

static NSString * _Nullable IOSUseBridgeAccessibilityString(
    id value,
    NSUInteger *totalStringLength,
    NSError * _Nullable __autoreleasing *error
) {
    NSString *string = nil;
    if ([value isKindOfClass:NSString.class]) {
        string = value;
    } else if ([value isKindOfClass:NSAttributedString.class]) {
        string = [(NSAttributedString *)value string];
    } else if ([value isKindOfClass:NSNumber.class]) {
        string = [(NSNumber *)value stringValue];
    } else if (value == nil || value == NSNull.null) {
        return nil;
    } else {
        return nil;
    }
    if (string.length > IOSUseBridgeMaximumAccessibilityStringLength ||
        *totalStringLength >
            IOSUseBridgeMaximumAccessibilityTotalStringLength -
                string.length) {
        if (error != NULL) {
            *error = IOSUseBridgeAccessibilityError(
                5,
                @"AppKit accessibility strings exceeded fixed bounds"
            );
        }
        return nil;
    }
    *totalStringLength += string.length;
    return string;
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

static NSString * _Nullable IOSUseBridgeAccessibilityRole(
    NSString *rawRole
) {
    if ([rawRole isEqualToString:@"AXButton"]) {
        return @"button";
    }
    if ([rawRole isEqualToString:@"AXLink"]) {
        return @"link";
    }
    if ([rawRole isEqualToString:@"AXStaticText"]) {
        return @"text";
    }
    if ([rawRole isEqualToString:@"AXHeading"]) {
        return @"heading";
    }
    return nil;
}

static CGRect IOSUseBridgeAccessibilityLogicalFrame(
    CGRect appKitScreenFrame,
    id window,
    NSError * _Nullable __autoreleasing *error
) {
    SEL selector = NSSelectorFromString(@"convertRectFromScreen:");
    if (![window respondsToSelector:selector]) {
        if (error != NULL) {
            *error = IOSUseBridgeAccessibilityError(
                13,
                @"selected AppKit window cannot convert accessibility geometry"
            );
        }
        return CGRectNull;
    }
    @try {
        CGRect localFrame = ((IOSUseBridgeSendRectRect)objc_msgSend)(
            window,
            selector,
            appKitScreenFrame
        );
        return CGRectMake(
            localFrame.origin.x,
            IOSUsePlayDeviceLogicalHeight -
                CGRectGetMaxY(localFrame),
            localFrame.size.width,
            localFrame.size.height
        );
    } @catch (NSException *exception) {
        if (error != NULL) {
            *error = IOSUseBridgeAccessibilityError(
                14,
                [NSString stringWithFormat:
                    @"AppKit accessibility geometry conversion raised %@",
                    exception.name]
            );
        }
        return CGRectNull;
    }
}

static NSArray<NSDictionary<NSString *, id> *> * _Nullable
IOSUseBridgeCollectAccessibilityElements(
    id window,
    NSError * _Nullable __autoreleasing *error
) {
    if (window == nil) {
        if (error != NULL) {
            *error = IOSUseBridgeAccessibilityError(
                1,
                @"selected AppKit window is unavailable"
            );
        }
        return nil;
    }
    CGRect windowFrame = IOSUseBridgeRect(window, @"frame");
    CGRect contentLayoutRect =
        IOSUseBridgeRect(window, @"contentLayoutRect");
    id contentView = nil;
    if (!IOSUseBridgeAccessibilityObject(
            window,
            @"contentView",
            &contentView,
            error
        )) {
        return nil;
    }
    CGRect contentBounds =
        IOSUseBridgeRect(contentView, @"bounds");
    if (!IOSUseBridgeAccessibilityFiniteRect(windowFrame) ||
        !IOSUseBridgeApproximatelyEqual(
            windowFrame.size.width,
            IOSUsePlayDeviceLogicalWidth
        ) ||
        !IOSUseBridgeApproximatelyEqual(
            windowFrame.size.height,
            IOSUsePlayDeviceLogicalHeight
        ) ||
        !IOSUseBridgeRectIsDeviceScreen(contentLayoutRect) ||
        !IOSUseBridgeRectIsDeviceScreen(contentBounds)) {
        if (error != NULL) {
            *error = IOSUseBridgeAccessibilityError(
                6,
                @"selected AppKit window does not have the fixed identity "
                 "device geometry"
            );
        }
        return nil;
    }

    NSMutableArray *queue = [NSMutableArray arrayWithObject:window];
    NSMutableArray<NSNumber *> *depths =
        [NSMutableArray arrayWithObject:@0];
    NSHashTable *visited = [NSHashTable
        hashTableWithOptions:
            NSPointerFunctionsObjectPointerPersonality |
            NSPointerFunctionsStrongMemory];
    NSMutableArray<NSDictionary<NSString *, id> *> *elements =
        [NSMutableArray array];
    NSUInteger cursor = 0;
    NSUInteger totalStringLength = 0;
    CGRect logicalScreen = CGRectMake(
        0,
        0,
        IOSUsePlayDeviceLogicalWidth,
        IOSUsePlayDeviceLogicalHeight
    );

    while (cursor < queue.count) {
        if (cursor >=
            IOSUseBridgeMaximumAccessibilityTraversalCount) {
            if (error != NULL) {
                *error = IOSUseBridgeAccessibilityError(
                    7,
                    @"AppKit accessibility traversal exceeded 4096 nodes"
                );
            }
            return nil;
        }
        id object = queue[cursor];
        NSUInteger depth = depths[cursor].unsignedIntegerValue;
        cursor += 1;
        if ([visited containsObject:object]) {
            continue;
        }
        [visited addObject:object];
        if (depth > IOSUseBridgeMaximumAccessibilityDepth) {
            if (error != NULL) {
                *error = IOSUseBridgeAccessibilityError(
                    8,
                    @"AppKit accessibility traversal exceeded 64 levels"
                );
            }
            return nil;
        }

        NSArray *children =
            IOSUseBridgeAccessibilityChildren(object, error);
        if (children == nil) {
            return nil;
        }
        for (id child in children) {
            if (child == nil) {
                continue;
            }
            [queue addObject:child];
            [depths addObject:@(depth + 1)];
        }
        if (queue.count >
            IOSUseBridgeMaximumAccessibilityTraversalCount) {
            if (error != NULL) {
                *error = IOSUseBridgeAccessibilityError(
                    7,
                    @"AppKit accessibility traversal exceeded 4096 nodes"
                );
            }
            return nil;
        }

        BOOL isAccessibilityElement = YES;
        BOOL accessibilityIgnored = NO;
        if (!IOSUseBridgeAccessibilityBool(
                object,
                @"isAccessibilityElement",
                YES,
                &isAccessibilityElement,
                error
            ) ||
            !IOSUseBridgeAccessibilityBool(
                object,
                @"accessibilityIsIgnored",
                NO,
                &accessibilityIgnored,
                error
            )) {
            return nil;
        }
        if (!isAccessibilityElement || accessibilityIgnored) {
            continue;
        }

        id rawRoleValue = nil;
        if (!IOSUseBridgeAccessibilityObject(
                object,
                @"accessibilityRole",
                &rawRoleValue,
                error
            )) {
            return nil;
        }
        NSString *rawRole = [rawRoleValue
            isKindOfClass:NSString.class]
            ? rawRoleValue
            : nil;
        NSString *role =
            IOSUseBridgeAccessibilityRole(rawRole);
        if (role == nil) {
            continue;
        }

        id identifierValue = nil;
        id labelValue = nil;
        id titleValue = nil;
        id helpValue = nil;
        id valueDescriptionValue = nil;
        id valueValue = nil;
        BOOL protectedContent = NO;
        if (!IOSUseBridgeAccessibilityBool(
                object,
                @"isAccessibilityProtectedContent",
                NO,
                &protectedContent,
                error
            )) {
            return nil;
        }
        if (!IOSUseBridgeAccessibilityObject(
                object,
                @"accessibilityIdentifier",
                &identifierValue,
                error
            ) ||
            !IOSUseBridgeAccessibilityObject(
                object,
                @"accessibilityLabel",
                &labelValue,
                error
            ) ||
            !IOSUseBridgeAccessibilityObject(
                object,
                @"accessibilityTitle",
                &titleValue,
                error
            ) ||
            !IOSUseBridgeAccessibilityObject(
                object,
                @"accessibilityHelp",
                &helpValue,
                error
            ) ||
            !IOSUseBridgeAccessibilityObject(
                object,
                @"accessibilityValueDescription",
                &valueDescriptionValue,
                error
            )) {
            return nil;
        }
        if (!protectedContent &&
            !IOSUseBridgeAccessibilityObject(
                object,
                @"accessibilityValue",
                &valueValue,
                error
            )) {
            return nil;
        }
        NSString *identifier = IOSUseBridgeAccessibilityString(
            identifierValue,
            &totalStringLength,
            error
        );
        if (error != NULL && *error != nil) {
            return nil;
        }
        NSString *label = IOSUseBridgeAccessibilityString(
            labelValue,
            &totalStringLength,
            error
        );
        if (error != NULL && *error != nil) {
            return nil;
        }
        NSString *title = IOSUseBridgeAccessibilityString(
            titleValue,
            &totalStringLength,
            error
        );
        if (error != NULL && *error != nil) {
            return nil;
        }
        NSString *help =
            IOSUseBridgeAccessibilityString(
                helpValue,
                &totalStringLength,
                error
            );
        if (error != NULL && *error != nil) {
            return nil;
        }
        NSString *valueDescription =
            IOSUseBridgeAccessibilityString(
                valueDescriptionValue,
                &totalStringLength,
                error
            );
        if (error != NULL && *error != nil) {
            return nil;
        }
        NSString *value = IOSUseBridgeAccessibilityString(
            valueValue,
            &totalStringLength,
            error
        );
        if (error != NULL && *error != nil) {
            return nil;
        }
        if (label.length == 0) {
            label = title.length > 0
                ? title
                : (valueDescription.length > 0
                    ? valueDescription
                    : help);
        }
        if (label.length == 0 && identifier.length == 0 &&
            value.length == 0) {
            continue;
        }

        CGRect appKitFrame = CGRectZero;
        if (!IOSUseBridgeAccessibilityRect(
                object,
                @"accessibilityFrame",
                &appKitFrame,
                error
            )) {
            return nil;
        }
        if (!IOSUseBridgeAccessibilityFiniteRect(appKitFrame)) {
            continue;
        }
        CGRect logicalFrame =
            IOSUseBridgeAccessibilityLogicalFrame(
                appKitFrame,
                window,
                error
            );
        if (error != NULL && *error != nil) {
            return nil;
        }
        if (!IOSUseBridgeAccessibilityFiniteRect(logicalFrame)) {
            continue;
        }
        CGRect visibleFrame =
            CGRectIntersection(logicalFrame, logicalScreen);
        if (!IOSUseBridgeAccessibilityFiniteRect(visibleFrame)) {
            continue;
        }

        BOOL enabled = YES;
        BOOL selected = NO;
        BOOL focused = NO;
        if (!IOSUseBridgeAccessibilityBool(
                object,
                @"isAccessibilityEnabled",
                YES,
                &enabled,
                error
            ) ||
            !IOSUseBridgeAccessibilityBool(
                object,
                @"isAccessibilitySelected",
                NO,
                &selected,
                error
            ) ||
            !IOSUseBridgeAccessibilityBool(
                object,
                @"isAccessibilityFocused",
                NO,
                &focused,
                error
            )) {
            return nil;
        }
        if (elements.count >=
            IOSUseBridgeMaximumAccessibilityElementCount) {
            if (error != NULL) {
                *error = IOSUseBridgeAccessibilityError(
                    11,
                    @"AppKit accessibility bridge exceeded 512 elements"
                );
            }
            return nil;
        }
        [elements addObject:@{
            @"role": role,
            @"label": label ?: @"",
            @"value": value ?: @"",
            @"identifier": identifier ?: @"",
            @"frame": IOSUseBridgeRectJSON(logicalFrame),
            @"enabled": @(enabled),
            @"selected": @(selected),
            @"focused": @(focused),
        }];
    }
    return elements;
}

static BOOL IOSUseBridgeScreenCanFit(id window) {
    SEL screenSelector = NSSelectorFromString(@"screen");
    id screen = [window respondsToSelector:screenSelector]
        ? ((IOSUseBridgeSendID)objc_msgSend)(window, screenSelector)
        : nil;
    CGRect visibleFrame = IOSUseBridgeRect(screen, @"visibleFrame");
    return visibleFrame.size.width >= IOSUsePlayDeviceLogicalWidth &&
        visibleFrame.size.height >= IOSUsePlayDeviceLogicalHeight;
}

static CGRect IOSUseBridgeVisibleFrame(id window) {
    SEL screenSelector = NSSelectorFromString(@"screen");
    id screen = [window respondsToSelector:screenSelector]
        ? ((IOSUseBridgeSendID)objc_msgSend)(window, screenSelector)
        : nil;
    return IOSUseBridgeRect(screen, @"visibleFrame");
}

static CGRect IOSUseBridgeVisibleFrameInCGCoordinates(id window) {
    SEL screenSelector = NSSelectorFromString(@"screen");
    id screen = [window respondsToSelector:screenSelector]
        ? ((IOSUseBridgeSendID)objc_msgSend)(window, screenSelector)
        : nil;
    CGRect screenFrame = IOSUseBridgeRect(screen, @"frame");
    CGRect visibleFrame = IOSUseBridgeRect(screen, @"visibleFrame");
    if (CGRectIsEmpty(screenFrame) || CGRectIsEmpty(visibleFrame)) {
        return CGRectNull;
    }
    return CGRectMake(
        visibleFrame.origin.x,
        CGRectGetMaxY(screenFrame) - CGRectGetMaxY(visibleFrame),
        visibleFrame.size.width,
        visibleFrame.size.height
    );
}

static CGRect IOSUseBridgeExactCGWindowBounds(id window) {
    NSDictionary<
        NSNumber *,
        NSDictionary<NSString *, id> *
    > *metadata = IOSUseBridgeOwnOnscreenCGWindowMetadata();
    NSDictionary<NSString *, id> *exact =
        IOSUseBridgeExactOnscreenCGWindowMetadata(window, metadata);
    return exact == nil
        ? CGRectNull
        : [exact[@"boundsValue"] CGRectValue];
}

static BOOL IOSUseBridgeCGWindowIsInsideVisibleFrame(id window) {
    CGRect bounds = IOSUseBridgeExactCGWindowBounds(window);
    CGRect visible = IOSUseBridgeVisibleFrameInCGCoordinates(window);
    if (CGRectIsNull(bounds) || CGRectIsNull(visible)) {
        return NO;
    }
    return CGRectGetMinX(bounds) >= CGRectGetMinX(visible) - 0.01 &&
        CGRectGetMinY(bounds) >= CGRectGetMinY(visible) - 0.01 &&
        CGRectGetMaxX(bounds) <= CGRectGetMaxX(visible) + 0.01 &&
        CGRectGetMaxY(bounds) <= CGRectGetMaxY(visible) + 0.01;
}

static void IOSUseBridgeReconcileCGWindowPosition(id window) {
    CGRect bounds = IOSUseBridgeExactCGWindowBounds(window);
    CGRect visible = IOSUseBridgeVisibleFrameInCGCoordinates(window);
    if (CGRectIsNull(bounds) || CGRectIsNull(visible)) {
        return;
    }
    CGFloat appKitDeltaX = 0;
    CGFloat appKitDeltaY = 0;
    if (CGRectGetMinX(bounds) < CGRectGetMinX(visible)) {
        appKitDeltaX =
            CGRectGetMinX(visible) - CGRectGetMinX(bounds);
    } else if (CGRectGetMaxX(bounds) > CGRectGetMaxX(visible)) {
        appKitDeltaX =
            CGRectGetMaxX(visible) - CGRectGetMaxX(bounds);
    }
    // AppKit uses a bottom-left origin while CGWindow uses a top-left
    // origin. Increasing the AppKit y origin moves the CG surface upward.
    if (CGRectGetMinY(bounds) < CGRectGetMinY(visible)) {
        appKitDeltaY =
            CGRectGetMinY(bounds) - CGRectGetMinY(visible);
    } else if (CGRectGetMaxY(bounds) > CGRectGetMaxY(visible)) {
        appKitDeltaY =
            CGRectGetMaxY(bounds) - CGRectGetMaxY(visible);
    }
    if (IOSUseBridgeApproximatelyEqual(appKitDeltaX, 0) &&
        IOSUseBridgeApproximatelyEqual(appKitDeltaY, 0)) {
        return;
    }
    CGRect frame = IOSUseBridgeRect(window, @"frame");
    IOSUseBridgeSetPoint(
        window,
        @"setFrameOrigin:",
        CGPointMake(
            frame.origin.x + appKitDeltaX,
            frame.origin.y + appKitDeltaY
        )
    );
}

static void IOSUseBridgeUnlockSceneForAppKit(UIWindow *uiWindow) {
    UIWindowScene *scene = uiWindow.windowScene;
    if (scene.sizeRestrictions != nil) {
        // UIKitMacHelper applies the iOS-on-Mac compatibility scale to scene
        // restrictions. Remove that constraint and let the AppKit bridge own
        // the actual visible point size.
        scene.sizeRestrictions.minimumSize = CGSizeZero;
        scene.sizeRestrictions.maximumSize = CGSizeMake(
            CGFLOAT_MAX,
            CGFLOAT_MAX
        );
        if (@available(macCatalyst 16.0, *)) {
            scene.sizeRestrictions.allowsFullScreen = NO;
        }
    }
}

static void IOSUseBridgeHideStandardButtons(id window) {
    SEL buttonSelector = NSSelectorFromString(@"standardWindowButton:");
    if (![window respondsToSelector:buttonSelector]) {
        return;
    }
    const NSInteger buttonTypes[] = {0, 1, 2, 7};
    for (NSUInteger index = 0;
         index < sizeof(buttonTypes) / sizeof(buttonTypes[0]);
         index += 1) {
        id button = ((IOSUseBridgeSendIDInteger)objc_msgSend)(
            window,
            buttonSelector,
            buttonTypes[index]
        );
        IOSUseBridgeSetBool(button, @"setHidden:", YES);
        IOSUseBridgeSetBool(button, @"setEnabled:", NO);
    }
}

static void IOSUseBridgeApplyWindowPolicy(id window) {
    CGSize requested = CGSizeMake(
        IOSUsePlayDeviceLogicalWidth,
        IOSUsePlayDeviceLogicalHeight
    );
    Class windowClass = NSClassFromString(@"NSWindow");
    IOSUseBridgeSetBool(
        (id)windowClass,
        @"setAllowsAutomaticWindowTabbing:",
        NO
    );
    IOSUseBridgeMakeBorderlessWindowFocusable(window);
    IOSUseBridgeSetInteger(window, @"setStyleMask:", 0);
    IOSUseBridgeSetInteger(window, @"setCollectionBehavior:", 0);
    IOSUseBridgeSetInteger(window, @"setTabbingMode:", 2);
    IOSUseBridgeSetBool(window, @"setHasShadow:", NO);
    IOSUseBridgeSetBool(window, @"setMovable:", NO);
    IOSUseBridgeSetBool(window, @"setMovableByWindowBackground:", NO);
    IOSUseBridgeSetBool(window, @"setIgnoresMouseEvents:", NO);
    IOSUseBridgeSetBool(window, @"setAcceptsMouseMovedEvents:", YES);
    IOSUseBridgeSetBool(window, @"setRestorable:", NO);
    IOSUseBridgeSetBool(window, @"setReleasedWhenClosed:", NO);
    IOSUseBridgeSetBool(window, @"setTitlebarAppearsTransparent:", YES);
    IOSUseBridgeSetInteger(window, @"setTitleVisibility:", 1);
    SEL toolbarSelector = NSSelectorFromString(@"setToolbar:");
    if ([window respondsToSelector:toolbarSelector]) {
        ((IOSUseBridgeSendIDArgument)objc_msgSend)(
            window,
            toolbarSelector,
            nil
        );
    }
    IOSUseBridgeHideStandardButtons(window);
    IOSUseBridgeSetSize(window, @"setContentAspectRatio:", requested);
    IOSUseBridgeSetSize(window, @"setMinSize:", requested);
    IOSUseBridgeSetSize(window, @"setMaxSize:", requested);
    IOSUseBridgeSetSize(window, @"setContentMinSize:", requested);
    IOSUseBridgeSetSize(window, @"setContentMaxSize:", requested);
    CGRect frame = IOSUseBridgeRect(window, @"frame");
    CGRect visible = IOSUseBridgeVisibleFrame(window);
    BOOL sizeReady =
        IOSUseBridgeApproximatelyEqual(
            frame.size.width,
            requested.width
        ) &&
        IOSUseBridgeApproximatelyEqual(
            frame.size.height,
            requested.height
        );
    if (sizeReady) {
        IOSUseBridgeReconcileCGWindowPosition(window);
        return;
    }
    CGFloat x = MIN(
        MAX(frame.origin.x, CGRectGetMinX(visible)),
        CGRectGetMaxX(visible) - requested.width
    );
    CGFloat y = MIN(
        MAX(frame.origin.y, CGRectGetMinY(visible)),
        CGRectGetMaxY(visible) - requested.height
    );
    CGRect requestedFrame = CGRectMake(
        x,
        y,
        requested.width,
        requested.height
    );
    // UINSFullScreenWindow maps the public frame setters through the
    // iOS-on-Mac compatibility scale (~0.77). NSWindow's final frame
    // primitive changes the actual visible window without a view transform.
    IOSUseBridgeReallySetWindowFrame(window, requestedFrame);
    // The private size primitive can retain UIKitMacHelper's compatibility
    // origin offset. Position-only AppKit routing does not rescale content,
    // so finish with the exact visible-frame origin.
    IOSUseBridgeSetPoint(
        window,
        @"setFrameOrigin:",
        requestedFrame.origin
    );
    IOSUseBridgeReconcileCGWindowPosition(window);
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

static NSDictionary<NSString *, id> *
IOSUseBridgeVisibleNativeAlertSelection(void) {
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
    NSDictionary<
        NSNumber *,
        NSDictionary<NSString *, id> *
    > *cgMetadata = IOSUseBridgeOwnOnscreenCGWindowMetadata();
    if (cgMetadata == nil) {
        return nil;
    }
    NSMutableArray<NSDictionary<NSString *, id> *> *candidates =
        [NSMutableArray array];
    NSMutableSet<NSNumber *> *windowNumbers =
        [NSMutableSet set];
    for (id window in (NSArray *)windows) {
        if (!IOSUseBridgeBool(window, @"isVisible") ||
            IOSUseBridgeInteger(window, @"windowNumber") <= 0) {
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

static CGRect IOSUseBridgeAlertButtonLogicalFrame(
    id button,
    CGRect alertDeviceLogicalRect
) {
    CGRect bounds = IOSUseBridgeRect(button, @"bounds");
    SEL convertSelector = NSSelectorFromString(@"convertRect:toView:");
    if (![button respondsToSelector:convertSelector]) {
        return CGRectNull;
    }
    CGRect windowLocalRect =
        ((IOSUseBridgeSendRectRectID)objc_msgSend)(
            button,
            convertSelector,
            bounds,
            nil
        );
    CGRect logicalRect = CGRectNull;
    if (!IOSUsePlayResolveLocalAppKitRect(
            alertDeviceLogicalRect,
            windowLocalRect,
            &logicalRect,
            NULL
        )) {
        return CGRectNull;
    }
    return logicalRect;
}

static CGRect IOSUseBridgeWindowLogicalFrame(
    id window,
    NSDictionary<
        NSNumber *,
        NSDictionary<NSString *, id> *
    > *cgMetadata
) {
    if (window == nil) {
        return CGRectNull;
    }
    id baseWindow = IOSUseBridgeSelectedWindow();
    CGRect frame = IOSUseBridgeRect(window, @"frame");
    CGRect baseFrame = IOSUseBridgeRect(baseWindow, @"frame");
    NSDictionary<NSString *, id> *baseMetadata =
        IOSUseBridgeExactOnscreenCGWindowMetadata(
            baseWindow,
            cgMetadata
        );
    NSDictionary<NSString *, id> *windowMetadata =
        IOSUseBridgeExactOnscreenCGWindowMetadata(
            window,
            cgMetadata
        );
    if (baseWindow == nil ||
        CGRectIsEmpty(frame) ||
        CGRectIsEmpty(baseFrame) ||
        baseMetadata == nil ||
        windowMetadata == nil) {
        return CGRectNull;
    }
    CGRect baseCGWindowBounds =
        [baseMetadata[@"boundsValue"] CGRectValue];
    CGRect cgWindowBounds =
        [windowMetadata[@"boundsValue"] CGRectValue];
    CGRect logicalRect = CGRectNull;
    if (!IOSUsePlayValidateRelativeWindowGeometry(
            baseFrame,
            baseCGWindowBounds,
            frame,
            cgWindowBounds,
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
        return YES;
    }
    Class eventClass = NSClassFromString(@"NSEvent");
    SEL addMonitorSelector = NSSelectorFromString(
        @"addLocalMonitorForEventsMatchingMask:handler:"
    );
    if (eventClass == Nil ||
        ![(id)eventClass respondsToSelector:addMonitorSelector]) {
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
        NSDictionary<
            NSNumber *,
            NSDictionary<NSString *, id> *
        > *cgMetadata = IOSUseBridgeOwnOnscreenCGWindowMetadata();
        CGRect logicalWindow = IOSUseBridgeWindowLogicalFrame(
            eventWindow,
            cgMetadata
        );
        CGPoint logicalPoint = CGPointMake(
            logicalWindow.origin.x + localPoint.x,
            logicalWindow.origin.y +
                logicalWindow.size.height - localPoint.y
        );
        BOOL geometryReady =
            !CGRectIsNull(logicalWindow) &&
            !CGRectIsEmpty(logicalWindow) &&
            isfinite(localPoint.x) &&
            isfinite(localPoint.y) &&
            isfinite(logicalPoint.x) &&
            isfinite(logicalPoint.y);
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
            @"logicalPoint": @{
                @"x": @(logicalPoint.x),
                @"y": @(logicalPoint.y),
            },
            @"windowLogicalFrame":
                geometryReady
                    ? IOSUseBridgeRectJSON(logicalWindow)
                    : (id)NSNull.null,
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
    return IOSUsePlayMouseLocalMonitor != nil;
}

static NSArray<NSDictionary<NSString *, id> *> *
IOSUseBridgeNativeAlertActionInventory(
    id alertWindow,
    NSDictionary<
        NSNumber *,
        NSDictionary<NSString *, id> *
    > *cgMetadata
) {
    if (alertWindow == nil) {
        return @[];
    }
    CGRect alertLogicalRect =
        IOSUseBridgeWindowLogicalFrame(
            alertWindow,
            cgMetadata
        );
    if (CGRectIsNull(alertLogicalRect) ||
        CGRectIsEmpty(alertLogicalRect)) {
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
            alertLogicalRect
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

static NSString *IOSUseBridgeNativeAlertText(
    id alertWindow,
    NSDictionary<
        NSNumber *,
        NSDictionary<NSString *, id> *
    > *cgMetadata
) {
    if (alertWindow == nil) {
        return @"";
    }
    CGRect alertLogicalRect =
        IOSUseBridgeWindowLogicalFrame(
            alertWindow,
            cgMetadata
        );
    if (CGRectIsNull(alertLogicalRect) ||
        CGRectIsEmpty(alertLogicalRect)) {
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
            alertLogicalRect
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

@implementation IOSUsePlayAppKitBridge

+ (BOOL)installFixedSceneScale:(NSError **)error {
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
    if (scaleClass == Nil) {
        IOSUsePlaySceneScaleStatus = @"unavailable";
        IOSUsePlaySceneScaleFailure =
            @"UIKitMacHelper scene scale controller is unavailable";
    } else {
        for (NSString *selectorName in setters) {
            if (!IOSUseBridgeClassScaleMethodMatches(
                    scaleClass,
                    selectorName,
                    YES
                )) {
                IOSUsePlaySceneScaleStatus = @"abi-mismatch";
                IOSUsePlaySceneScaleFailure = [NSString stringWithFormat:
                    @"UIKitMacHelper selector %@ has an unsupported ABI",
                    selectorName
                ];
                break;
            }
        }
        if (IOSUsePlaySceneScaleFailure == nil) {
            for (NSString *selectorName in getters) {
                if (!IOSUseBridgeClassScaleMethodMatches(
                        scaleClass,
                        selectorName,
                        NO
                    )) {
                    IOSUsePlaySceneScaleStatus = @"abi-mismatch";
                    IOSUsePlaySceneScaleFailure = [NSString stringWithFormat:
                        @"UIKitMacHelper selector %@ has an unsupported ABI",
                        selectorName
                    ];
                    break;
                }
            }
        }
        if (IOSUsePlaySceneScaleFailure == nil &&
            (!IOSUseBridgeClassBoolMethodMatches(
                scaleClass,
                @"setDownscaleWindowIfNecessary:",
                YES
            ) ||
             !IOSUseBridgeClassBoolMethodMatches(
                scaleClass,
                @"downscaleWindowIfNecessary",
                NO
            ))) {
            IOSUsePlaySceneScaleStatus = @"abi-mismatch";
            IOSUsePlaySceneScaleFailure =
                @"UIKitMacHelper downscale policy has an unsupported ABI";
        }
    }
    if (IOSUsePlaySceneScaleFailure == nil) {
        for (NSString *selectorName in setters) {
            ((void (*)(id, SEL, CGFloat))objc_msgSend)(
                (id)scaleClass,
                NSSelectorFromString(selectorName),
                1.0
            );
        }
        ((void (*)(id, SEL, BOOL))objc_msgSend)(
            (id)scaleClass,
            NSSelectorFromString(
                @"setDownscaleWindowIfNecessary:"
            ),
            NO
        );
        IOSUsePlayObservedIdiomScale =
            ((CGFloat (*)(id, SEL))objc_msgSend)(
                (id)scaleClass,
                NSSelectorFromString(getters[0])
            );
        IOSUsePlayObservedWindowScale =
            ((CGFloat (*)(id, SEL))objc_msgSend)(
                (id)scaleClass,
                NSSelectorFromString(getters[1])
            );
        IOSUsePlayObservedDownscale =
            ((BOOL (*)(id, SEL))objc_msgSend)(
                (id)scaleClass,
                NSSelectorFromString(
                    @"downscaleWindowIfNecessary"
                )
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
            : @"UIKitMacHelper rejected the fixed identity scene scale";
    }
    if (IOSUsePlaySceneScaleFailure != nil && error != NULL) {
        *error = [NSError errorWithDomain:IOSUsePlayWindowErrorDomain
                                     code:3
                                 userInfo:@{
            NSLocalizedDescriptionKey:
                IOSUsePlaySceneScaleFailure,
        }];
    }
    return IOSUsePlaySceneScaleFailure == nil;
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
            UISceneDidActivateNotification,
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
    // Do not instantiate NSApplication or configure a window here; the
    // notifications above and Runtime's first main-queue probe reconcile the
    // surface after UIKit has created the scene.
}

+ (BOOL)configureFixedWindow:(NSError **)error {
    NSParameterAssert(NSThread.isMainThread);
    IOSUsePlayWindowAttemptCount += 1;
    if (![self installFixedSceneScale:error]) {
        IOSUsePlayWindowStatus = @"failed";
        IOSUsePlayWindowFailure = IOSUsePlaySceneScaleFailure;
        return NO;
    }
    BOOL usedBackgroundActivationFallback = NO;
    UIWindow *uiWindow = IOSUseBridgeKeyUIKitWindow();
    id window = uiWindow == nil
        ? nil
        : IOSUseBridgeWindowForUIKitWindow(uiWindow, YES);
    if (uiWindow == nil) {
        uiWindow =
            IOSUseBridgeBackgroundActivationUIKitWindow();
        if (uiWindow != nil) {
            window = IOSUseBridgeWindowForUIKitWindow(
                uiWindow,
                NO
            );
            usedBackgroundActivationFallback = window != nil;
        }
    }
    if (uiWindow == nil || window == nil) {
        IOSUsePlayWindowStatus = @"waiting-for-window";
        IOSUsePlayWindowFailure = @"UIKit/AppKit window bridge is unavailable";
        return NO;
    }
    if (!IOSUseBridgeScreenCanFit(window)) {
        IOSUsePlayWindowStatus = @"failed";
        IOSUsePlayWindowFailure = [NSString stringWithFormat:
            @"Mac display cannot fit the fixed %ld x %ld window",
            (long)IOSUsePlayDeviceLogicalWidth,
            (long)IOSUsePlayDeviceLogicalHeight];
        if (error != NULL) {
            *error = [NSError errorWithDomain:IOSUsePlayWindowErrorDomain
                                         code:1
                                     userInfo:@{
                NSLocalizedDescriptionKey: IOSUsePlayWindowFailure,
            }];
        }
        return NO;
    }

    IOSUseBridgeUnlockSceneForAppKit(uiWindow);
    IOSUseBridgeApplyWindowPolicy(window);
    IOSUseBridgeSetInteger(
        IOSUseBridgeApplication(),
        @"setActivationPolicy:",
        0
    );
    IOSUseBridgeSetBool(
        IOSUseBridgeApplication(),
        @"activateIgnoringOtherApps:",
        YES
    );
    SEL activateSelector = NSSelectorFromString(@"activate");
    id application = IOSUseBridgeApplication();
    if ([application respondsToSelector:activateSelector]) {
        ((void (*)(id, SEL))objc_msgSend)(
            application,
            activateSelector
        );
    }
    SEL makeKeySelector =
        NSSelectorFromString(@"makeKeyAndOrderFront:");
    if ([window respondsToSelector:makeKeySelector]) {
        ((IOSUseBridgeSendIDArgument)objc_msgSend)(
            window,
            makeKeySelector,
            nil
        );
    }
    SEL orderFrontSelector =
        NSSelectorFromString(@"orderFrontRegardless");
    if ([window respondsToSelector:orderFrontSelector]) {
        ((void (*)(id, SEL))objc_msgSend)(
            window,
            orderFrontSelector
        );
    }
    BOOL mouseMonitorReady =
        IOSUseBridgeInstallMouseLocalMonitor();

    CGRect frame = IOSUseBridgeRect(window, @"frame");
    CGRect content = IOSUseBridgeRect(window, @"contentLayoutRect");
    SEL contentViewSelector = NSSelectorFromString(@"contentView");
    id contentView = [window respondsToSelector:contentViewSelector]
        ? ((IOSUseBridgeSendID)objc_msgSend)(
            window,
            contentViewSelector
        )
        : nil;
    CGRect bounds = IOSUseBridgeRect(contentView, @"bounds");
    BOOL originReady =
        IOSUseBridgeCGWindowIsInsideVisibleFrame(window);
    BOOL exact =
        IOSUseBridgeApproximatelyEqual(
            frame.size.width,
            IOSUsePlayDeviceLogicalWidth
        ) &&
        IOSUseBridgeApproximatelyEqual(
            frame.size.height,
            IOSUsePlayDeviceLogicalHeight
        ) &&
        IOSUseBridgeRectIsDeviceScreen(content) &&
        IOSUseBridgeRectIsDeviceScreen(bounds) &&
        IOSUseBridgeWindowPolicyIsFixed(window) &&
        mouseMonitorReady &&
        originReady;
    if (exact && usedBackgroundActivationFallback) {
        IOSUsePlayWindowStatus =
            @"waiting-for-foreground-activation";
        IOSUsePlayWindowFailure =
            @"background UIKit window was activated; waiting for "
             "strict foreground key-window selection";
        if (error != NULL) {
            *error = [
                NSError
                errorWithDomain:IOSUsePlayWindowErrorDomain
                           code:4
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
        : [NSString stringWithFormat:
            @"AppKit window is not fixed borderless %ld x %ld with full "
             "content at logical origin zero and physical bounds inside "
             "the visible display",
            (long)IOSUsePlayDeviceLogicalWidth,
            (long)IOSUsePlayDeviceLogicalHeight];
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
    id window = IOSUseBridgeSelectedWindow();
    SEL selector = NSSelectorFromString(
        @"mouseLocationOutsideOfEventStream"
    );
    return [window respondsToSelector:selector]
        ? ((IOSUseBridgeSendPoint)objc_msgSend)(window, selector)
        : CGPointZero;
}

+ (CGRect)windowFrame {
    return IOSUseBridgeRect(IOSUseBridgeSelectedWindow(), @"frame");
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

+ (BOOL)hasVisibleNativeAlert {
    NSParameterAssert(NSThread.isMainThread);
    return IOSUseBridgeVisibleNativeAlertSelection() != nil;
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
    return IOSUseBridgeNativeAlertText(
        selection[@"window"],
        selection[@"cgMetadata"]
    );
}

+ (NSArray<NSDictionary<NSString *, id> *> *)nativeAlertActions {
    NSParameterAssert(NSThread.isMainThread);
    NSDictionary<NSString *, id> *selection =
        IOSUseBridgeVisibleNativeAlertSelection();
    NSArray<NSDictionary<NSString *, id> *> *inventory =
        IOSUseBridgeNativeAlertActionInventory(
            selection[@"window"],
            selection[@"cgMetadata"]
        );
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

+ (NSDictionary<NSString *, id> *)
    performNativeAlertActionWithLabel:(NSString *)label
                                error:(NSError **)error {
    NSParameterAssert(NSThread.isMainThread);
    NSDictionary<NSString *, id> *selection =
        IOSUseBridgeVisibleNativeAlertSelection();
    id alertWindow = selection[@"window"];
    NSArray<NSDictionary<NSString *, id> *> *inventory =
        IOSUseBridgeNativeAlertActionInventory(
            alertWindow,
            selection[@"cgMetadata"]
        );
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

+ (NSArray<NSDictionary<NSString *, id> *> * _Nullable)
    activeAccessibilityElementsWithError:
        (NSError * _Nullable * _Nullable)error {
    if (!NSThread.isMainThread) {
        if (error != NULL) {
            *error = IOSUseBridgeAccessibilityError(
                12,
                @"AppKit accessibility bridge must run on the main thread"
            );
        }
        return nil;
    }
    NSError *localError = nil;
    NSArray<NSDictionary<NSString *, id> *> *elements =
        IOSUseBridgeCollectAccessibilityElements(
        IOSUseBridgeSelectedWindow(),
        &localError
    );
    if (elements == nil && error != NULL) {
        *error = localError;
    }
    return elements;
}

+ (NSDictionary<NSString *, id> *)diagnostics {
    id window = IOSUseBridgeSelectedWindow();
    NSDictionary<
        NSNumber *,
        NSDictionary<NSString *, id> *
    > *cgWindowMetadata = IOSUseBridgeOwnOnscreenCGWindowMetadata();
    NSDictionary<NSString *, id> *baseCGWindow =
        IOSUseBridgeExactOnscreenCGWindowMetadata(
            window,
            cgWindowMetadata
        );
    CGRect frame = IOSUseBridgeRect(window, @"frame");
    CGRect content = IOSUseBridgeRect(window, @"contentLayoutRect");
    SEL contentViewSelector = NSSelectorFromString(@"contentView");
    id contentView = [window respondsToSelector:contentViewSelector]
        ? ((IOSUseBridgeSendID)objc_msgSend)(
            window,
            contentViewSelector
        )
        : nil;
    CGRect bounds = IOSUseBridgeRect(contentView, @"bounds");
    CGRect contentViewFrame = IOSUseBridgeRect(contentView, @"frame");
    id windowScreen = [window respondsToSelector:
        NSSelectorFromString(@"screen")]
        ? ((IOSUseBridgeSendID)objc_msgSend)(
            window,
            NSSelectorFromString(@"screen")
        )
        : nil;
    UIWindow *uiWindow = IOSUseBridgeKeyUIKitWindow();
    UISceneSizeRestrictions *restrictions =
        uiWindow.windowScene.sizeRestrictions;
    CGFloat backingScale = [window respondsToSelector:
        NSSelectorFromString(@"backingScaleFactor")]
        ? ((IOSUseBridgeSendFloat)objc_msgSend)(
            window,
            NSSelectorFromString(@"backingScaleFactor")
        )
        : 0;
    CGRect expectedCGWindowBounds = CGRectMake(
        frame.origin.x,
        CGRectGetMaxY(IOSUseBridgeRect(windowScreen, @"frame")) -
            CGRectGetMaxY(frame),
        frame.size.width,
        frame.size.height
    );
    CGRect nativeAlertFrame = [self nativeAlertFrame];
    NSString *nativeAlertText = [self nativeAlertText];
    NSArray<NSDictionary<NSString *, id> *> *nativeAlertActions =
        [self nativeAlertActions];
    return @{
        @"status": IOSUsePlayWindowStatus,
        @"failure": IOSUsePlayWindowFailure ?: NSNull.null,
        @"attempts": @(IOSUsePlayWindowAttemptCount),
        @"frame": IOSUseBridgeRectJSON(frame),
        @"contentLayoutRect": IOSUseBridgeRectJSON(content),
        @"contentViewFrame": IOSUseBridgeRectJSON(contentViewFrame),
        @"contentViewBounds": IOSUseBridgeRectJSON(bounds),
        @"screenFrame": IOSUseBridgeRectJSON(
            IOSUseBridgeRect(windowScreen, @"frame")
        ),
        @"screenVisibleFrame": IOSUseBridgeRectJSON(
            IOSUseBridgeRect(windowScreen, @"visibleFrame")
        ),
        @"cgVisibleFrame": IOSUseBridgeRectJSON(
            IOSUseBridgeVisibleFrameInCGCoordinates(window)
        ),
        @"expectedCGWindowBoundsFromAppKit":
            IOSUseBridgeRectJSON(expectedCGWindowBounds),
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
        @"allWindows": IOSUseBridgeWindowInventory(),
        @"nativeAlert": @{
            @"visible": @(!CGRectIsNull(nativeAlertFrame)),
            @"frame": CGRectIsNull(nativeAlertFrame)
                ? (id)NSNull.null
                : IOSUseBridgeRectJSON(nativeAlertFrame),
            @"text": nativeAlertText,
            @"actions": nativeAlertActions,
        },
        @"backingScaleFactor": @(backingScale),
        @"borderless": @(
            (BOOL)(IOSUseBridgeInteger(window, @"styleMask") == 0)
        ),
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
        @"fixedSizePolicy": @(
            IOSUseBridgeWindowPolicyIsFixed(window)
        ),
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
            IOSUseBridgeRectIsDeviceScreen(content) &&
            IOSUseBridgeRectIsDeviceScreen(bounds)
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

@end
