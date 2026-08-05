#import "IOSUsePlaySafeAreaCompatibility.h"
#import "IOSUsePlayDevice.h"
#import "IOSUsePlayHookRegistry.h"

#import <TargetConditionals.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <stdlib.h>
#import <string.h>

static NSString *const IOSUsePlaySafeAreaErrorDomain =
    @"io.ios-use.play-runtime.safe-area";
static NSString *const IOSUsePlaySafeAreaProviderSelectorName =
    @"_sceneSafeAreaInsetsIncludingStatusBar:";
static NSString *const IOSUsePlaySafeAreaInvalidationSelectorName =
    @"_sceneSettingsSafeAreaInsetsDidChange";

typedef UIEdgeInsets (*IOSUsePlaySafeAreaProviderIMP)(
    UIWindow *,
    SEL,
    BOOL
);

@interface IOSUsePlaySafeAreaFirstProviderEvidence : NSObject {
@public
    NSUInteger generation;
    NSUInteger invocationCount;
    BOOL installedBeforeDispatch;
    BOOL includeStatusBar;
    BOOL fixedGeometryApplied;
    BOOL resultMatchedExpected;
    UIEdgeInsets original;
    UIEdgeInsets expected;
    UIEdgeInsets result;
    NSString *windowClass;
    NSString *activationState;
    NSString *sceneIdentifier;
}
@end

@implementation IOSUsePlaySafeAreaFirstProviderEvidence
@end

static __weak UIWindowScene *IOSUsePlaySafeAreaTargetScene;
static __weak UIWindow *IOSUsePlaySafeAreaTargetWindow;
static BOOL IOSUsePlaySafeAreaHookAttempted;
static BOOL IOSUsePlaySafeAreaHookInstalled;
static BOOL IOSUsePlaySafeAreaHookABICompatible;
static SEL IOSUsePlaySafeAreaProviderSelector;
static SEL IOSUsePlaySafeAreaInvalidationSelector;
static IOSUsePlaySafeAreaProviderIMP IOSUsePlaySafeAreaOriginalProvider;
static NSString *IOSUsePlaySafeAreaHookStatus = @"not-installed";
static NSString *IOSUsePlaySafeAreaStage = @"not-installed";
static NSString *IOSUsePlaySafeAreaFailureCode;
static NSString *IOSUsePlaySafeAreaFailure;
static NSString *IOSUsePlaySafeAreaProviderABI;
static NSString *IOSUsePlaySafeAreaProviderOwner;
static NSString *IOSUsePlaySafeAreaInvalidationOwner;
static NSUInteger IOSUsePlaySafeAreaInvalidationCount;
static NSUInteger IOSUsePlaySafeAreaSceneReplacementCount;
static NSUInteger IOSUsePlaySafeAreaWindowReplacementCount;
static BOOL IOSUsePlaySafeAreaPreMainInstallAttempted;
static BOOL IOSUsePlaySafeAreaPreMainInstallSucceeded;
static os_unfair_lock IOSUsePlaySafeAreaEvidenceLock =
    OS_UNFAIR_LOCK_INIT;
static NSUInteger IOSUsePlaySafeAreaNextEvidenceGeneration;
static NSUInteger
    IOSUsePlaySafeAreaLastRegistryEvidenceGeneration;
static char IOSUsePlaySafeAreaEvidenceAssociationKey;

static UIEdgeInsets IOSUsePlaySafeAreaDeviceInsets(
    BOOL includeStatusBar
) {
    return UIEdgeInsetsMake(
        includeStatusBar ? IOSUsePlayDeviceSafeAreaTop : 0,
        IOSUsePlayDeviceSafeAreaLeft,
        IOSUsePlayDeviceSafeAreaBottom,
        IOSUsePlayDeviceSafeAreaRight
    );
}

static UIEdgeInsets IOSUsePlaySafeAreaMaximumInsets(
    UIEdgeInsets left,
    UIEdgeInsets right
) {
    return UIEdgeInsetsMake(
        MAX(left.top, right.top),
        MAX(left.left, right.left),
        MAX(left.bottom, right.bottom),
        MAX(left.right, right.right)
    );
}

static NSDictionary<NSString *, NSNumber *> *
IOSUsePlaySafeAreaInsetsJSON(UIEdgeInsets insets) {
    return @{
        @"top": @(insets.top),
        @"left": @(insets.left),
        @"bottom": @(insets.bottom),
        @"right": @(insets.right),
    };
}

static NSDictionary<NSString *, NSNumber *> *
IOSUsePlaySafeAreaRectJSON(CGRect rect) {
    return @{
        @"x": @(rect.origin.x),
        @"y": @(rect.origin.y),
        @"width": @(rect.size.width),
        @"height": @(rect.size.height),
    };
}

static BOOL IOSUsePlaySafeAreaScalarMatches(
    CGFloat left,
    CGFloat right
) {
    return isfinite(left) &&
        isfinite(right) &&
        fabs(left - right) <= 0.5;
}

static BOOL IOSUsePlaySafeAreaInsetsMatch(
    UIEdgeInsets left,
    UIEdgeInsets right
) {
    return IOSUsePlaySafeAreaScalarMatches(left.top, right.top) &&
        IOSUsePlaySafeAreaScalarMatches(left.left, right.left) &&
        IOSUsePlaySafeAreaScalarMatches(left.bottom, right.bottom) &&
        IOSUsePlaySafeAreaScalarMatches(left.right, right.right);
}

static BOOL IOSUsePlaySafeAreaRectsMatch(CGRect left, CGRect right) {
    return IOSUsePlaySafeAreaScalarMatches(
            CGRectGetMinX(left),
            CGRectGetMinX(right)
        ) &&
        IOSUsePlaySafeAreaScalarMatches(
            CGRectGetMinY(left),
            CGRectGetMinY(right)
        ) &&
        IOSUsePlaySafeAreaScalarMatches(
            CGRectGetWidth(left),
            CGRectGetWidth(right)
        ) &&
        IOSUsePlaySafeAreaScalarMatches(
            CGRectGetHeight(left),
            CGRectGetHeight(right)
        );
}

static BOOL IOSUsePlaySafeAreaIsAuxiliaryWindow(UIWindow *window) {
    if (window == nil) {
        return YES;
    }
    NSString *className = NSStringFromClass(window.class);
    for (NSString *fragment in @[
        @"Alert",
        @"Keyboard",
        @"TextEffects",
        @"StatusBar",
    ]) {
        if ([className rangeOfString:fragment
                            options:NSCaseInsensitiveSearch].location !=
            NSNotFound) {
            return YES;
        }
    }
    return NO;
}

static BOOL IOSUsePlaySafeAreaSceneSupportsFixedGeometry(
    UIWindowScene *scene
) {
    return scene != nil &&
        (scene.activationState ==
            UISceneActivationStateForegroundActive ||
         scene.activationState ==
            UISceneActivationStateForegroundInactive);
}

static UIWindow *IOSUsePlaySafeAreaSceneDelegateWindow(
    UIWindowScene *scene
) {
    id delegate = scene.delegate;
    SEL windowSelector = NSSelectorFromString(@"window");
    if (![delegate respondsToSelector:windowSelector]) {
        return nil;
    }
    id candidate = ((id (*)(id, SEL))objc_msgSend)(
        delegate,
        windowSelector
    );
    return [candidate isKindOfClass:UIWindow.class]
        ? candidate
        : nil;
}

static BOOL IOSUsePlaySafeAreaPreBindContractMatches(
    BOOL sceneAttached,
    BOOL applicationRole,
    BOOL normalWindowLevel,
    BOOL auxiliaryWindow
) {
    return sceneAttached &&
        applicationRole &&
        normalWindowLevel &&
        !auxiliaryWindow;
}

static BOOL IOSUsePlaySafeAreaIsPreBindAppWindow(UIWindow *window) {
    UIWindowScene *scene = window.windowScene;
    return IOSUsePlaySafeAreaPreBindContractMatches(
        scene != nil,
        [scene.session.role
            isEqualToString:UIWindowSceneSessionRoleApplication],
        fabs(window.windowLevel - UIWindowLevelNormal) <= 0.5,
        IOSUsePlaySafeAreaIsAuxiliaryWindow(window)
    );
}

static BOOL IOSUsePlaySafeAreaIsEligibleWindow(
    UIWindow *window,
    UIWindowScene *scene
) {
    return window != nil &&
        window.windowScene == scene &&
        [scene.windows containsObject:window] &&
        !window.hidden &&
        window.alpha > 0.01 &&
        window.rootViewController != nil &&
        fabs(window.windowLevel - UIWindowLevelNormal) <= 0.5 &&
        window.bounds.size.width > 0 &&
        window.bounds.size.height > 0 &&
        !IOSUsePlaySafeAreaIsAuxiliaryWindow(window);
}

static NSInteger IOSUsePlaySafeAreaActivationRank(
    UIWindowScene *scene
) {
    switch (scene.activationState) {
        case UISceneActivationStateForegroundActive:
            return 2;
        case UISceneActivationStateForegroundInactive:
            return 1;
        default:
            return 0;
    }
}

static NSString *IOSUsePlaySafeAreaActivationStateName(
    UISceneActivationState state
) {
    switch (state) {
        case UISceneActivationStateUnattached:
            return @"unattached";
        case UISceneActivationStateForegroundActive:
            return @"foreground-active";
        case UISceneActivationStateBackground:
            return @"background";
        case UISceneActivationStateForegroundInactive:
            return @"foreground-inactive";
    }
    return @"unknown";
}

static UIWindow *IOSUsePlaySafeAreaPrimaryWindow(
    UIWindowScene *scene
) {
    UIWindow *existing = IOSUsePlaySafeAreaTargetWindow;
    if (IOSUsePlaySafeAreaIsEligibleWindow(existing, scene)) {
        return existing;
    }
    for (UIWindow *window in scene.windows) {
        if (window.isKeyWindow &&
            IOSUsePlaySafeAreaIsEligibleWindow(window, scene)) {
            return window;
        }
    }
    UIWindow *delegateWindow =
        IOSUsePlaySafeAreaSceneDelegateWindow(scene);
    if (IOSUsePlaySafeAreaIsEligibleWindow(
            delegateWindow,
            scene
        )) {
        return delegateWindow;
    }
    for (UIWindow *window in [scene.windows reverseObjectEnumerator]) {
        if (IOSUsePlaySafeAreaIsEligibleWindow(window, scene)) {
            return window;
        }
    }
    return nil;
}

static UIWindowScene *IOSUsePlaySafeAreaForegroundScene(void) {
    UIWindowScene *existing = IOSUsePlaySafeAreaTargetScene;
    if (existing.activationState ==
            UISceneActivationStateForegroundActive &&
        IOSUsePlaySafeAreaPrimaryWindow(existing) != nil) {
        return existing;
    }
    NSMutableArray<UIWindowScene *> *scenes =
        [NSMutableArray array];
    for (UIScene *candidate in
         UIApplication.sharedApplication.connectedScenes) {
        if (![candidate isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        UIWindowScene *scene = (UIWindowScene *)candidate;
        if (!IOSUsePlaySafeAreaSceneSupportsFixedGeometry(scene) ||
            ![scene.session.role
                isEqualToString:UIWindowSceneSessionRoleApplication] ||
            IOSUsePlaySafeAreaPrimaryWindow(scene) == nil) {
            continue;
        }
        [scenes addObject:scene];
    }
    [scenes sortUsingComparator:^NSComparisonResult(
        UIWindowScene *left,
        UIWindowScene *right
    ) {
        NSInteger leftRank =
            IOSUsePlaySafeAreaActivationRank(left);
        NSInteger rightRank =
            IOSUsePlaySafeAreaActivationRank(right);
        if (leftRank != rightRank) {
            return leftRank > rightRank
                ? NSOrderedAscending
                : NSOrderedDescending;
        }
        BOOL leftKey =
            IOSUsePlaySafeAreaPrimaryWindow(left).isKeyWindow;
        BOOL rightKey =
            IOSUsePlaySafeAreaPrimaryWindow(right).isKeyWindow;
        if (leftKey != rightKey) {
            return leftKey ? NSOrderedAscending : NSOrderedDescending;
        }
        NSString *leftIdentifier =
            left.session.persistentIdentifier ?: @"";
        NSString *rightIdentifier =
            right.session.persistentIdentifier ?: @"";
        return [leftIdentifier compare:rightIdentifier];
    }];
    return scenes.firstObject;
}

static BOOL IOSUsePlaySafeAreaReceiverUsesFixedGeometry(
    UIWindow *window
) {
    // First reads can happen immediately after UIWindow(windowScene:) and
    // before root/visibility/scene.windows/activation state are established.
    // Keep strict primary selection in reconciliation; the provider's
    // pre-bind scope is the narrower semantic App-window contract instead.
    return IOSUsePlaySafeAreaIsPreBindAppWindow(window);
}

static UIEdgeInsets IOSUsePlaySafeAreaProviderInsets(
    UIEdgeInsets original,
    BOOL includeStatusBar
) {
    return IOSUsePlaySafeAreaMaximumInsets(
        original,
        IOSUsePlaySafeAreaDeviceInsets(includeStatusBar)
    );
}

static void IOSUsePlaySafeAreaRecordProviderInvocation(
    UIWindow *window,
    BOOL includeStatusBar,
    UIEdgeInsets original,
    UIEdgeInsets result,
    BOOL fixedGeometryApplied
) {
    if (window == nil || !fixedGeometryApplied) {
        return;
    }
    UIEdgeInsets expected =
        IOSUsePlaySafeAreaProviderInsets(
            original,
            includeStatusBar
        );
    UIWindowScene *scene = window.windowScene;
    IOSUsePlaySafeAreaFirstProviderEvidence *candidate =
        [IOSUsePlaySafeAreaFirstProviderEvidence new];
    candidate->invocationCount = 1;
    candidate->installedBeforeDispatch =
        IOSUsePlaySafeAreaHookInstalled &&
        IOSUsePlaySafeAreaHookABICompatible;
    candidate->includeStatusBar = includeStatusBar;
    candidate->fixedGeometryApplied = fixedGeometryApplied;
    candidate->resultMatchedExpected =
        IOSUsePlaySafeAreaInsetsMatch(result, expected);
    candidate->original = original;
    candidate->expected = expected;
    candidate->result = result;
    candidate->windowClass = NSStringFromClass(window.class);
    candidate->activationState = scene == nil
        ? @"not-attached"
        : IOSUsePlaySafeAreaActivationStateName(
            scene.activationState
        );
    candidate->sceneIdentifier =
        scene.session.persistentIdentifier;
    os_unfair_lock_lock(&IOSUsePlaySafeAreaEvidenceLock);
    IOSUsePlaySafeAreaFirstProviderEvidence *evidence =
        objc_getAssociatedObject(
            window,
            &IOSUsePlaySafeAreaEvidenceAssociationKey
        );
    if (evidence == nil) {
        IOSUsePlaySafeAreaNextEvidenceGeneration += 1;
        candidate->generation =
            IOSUsePlaySafeAreaNextEvidenceGeneration;
        evidence = candidate;
        objc_setAssociatedObject(
            window,
            &IOSUsePlaySafeAreaEvidenceAssociationKey,
            evidence,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );
    } else {
        evidence->invocationCount += 1;
    }
    os_unfair_lock_unlock(&IOSUsePlaySafeAreaEvidenceLock);
}

static IOSUsePlaySafeAreaFirstProviderEvidence *
IOSUsePlaySafeAreaEvidenceForWindow(UIWindow *window) {
    if (window == nil) {
        return nil;
    }
    os_unfair_lock_lock(&IOSUsePlaySafeAreaEvidenceLock);
    IOSUsePlaySafeAreaFirstProviderEvidence *evidence =
        objc_getAssociatedObject(
            window,
            &IOSUsePlaySafeAreaEvidenceAssociationKey
        );
    os_unfair_lock_unlock(&IOSUsePlaySafeAreaEvidenceLock);
    return evidence;
}

static BOOL IOSUsePlaySafeAreaEvidenceIsReadyForWindow(
    UIWindow *window
) {
    IOSUsePlaySafeAreaFirstProviderEvidence *evidence =
        IOSUsePlaySafeAreaEvidenceForWindow(window);
    if (evidence == nil) {
        return NO;
    }
    os_unfair_lock_lock(&IOSUsePlaySafeAreaEvidenceLock);
    BOOL ready =
        evidence->installedBeforeDispatch &&
        evidence->fixedGeometryApplied &&
        evidence->resultMatchedExpected;
    os_unfair_lock_unlock(&IOSUsePlaySafeAreaEvidenceLock);
    return ready;
}

static NSDictionary<NSString *, id> *
IOSUsePlaySafeAreaEvidenceJSONForWindow(UIWindow *window) {
    IOSUsePlaySafeAreaFirstProviderEvidence *evidence =
        IOSUsePlaySafeAreaEvidenceForWindow(window);
    if (evidence == nil) {
        return @{
            @"recorded": @NO,
            @"evidenceKind":
                @"first-eligible-app-window-provider-hook-invocation",
            @"businessInvocationProven": @NO,
            @"generation": NSNull.null,
        };
    }
    os_unfair_lock_lock(&IOSUsePlaySafeAreaEvidenceLock);
    NSDictionary<NSString *, id> *resultJSON = @{
        @"recorded": @YES,
        @"evidenceKind":
            @"first-eligible-app-window-provider-hook-invocation",
        @"businessInvocationProven": @NO,
        @"generation": @(evidence->generation),
        @"providerInvocationCount":
            @(evidence->invocationCount),
        @"installedBeforeDispatch":
            @(evidence->installedBeforeDispatch),
        @"includeStatusBar": @(evidence->includeStatusBar),
        @"fixedGeometryApplied":
            @(evidence->fixedGeometryApplied),
        @"resultMatchedExpected":
            @(evidence->resultMatchedExpected),
        @"windowClass":
            evidence->windowClass ?: NSNull.null,
        @"activationState":
            evidence->activationState ?: NSNull.null,
        @"sceneIdentifier":
            evidence->sceneIdentifier ?: NSNull.null,
        @"original":
            IOSUsePlaySafeAreaInsetsJSON(evidence->original),
        @"expected":
            IOSUsePlaySafeAreaInsetsJSON(evidence->expected),
        @"result":
            IOSUsePlaySafeAreaInsetsJSON(evidence->result),
    };
    os_unfair_lock_unlock(&IOSUsePlaySafeAreaEvidenceLock);
    return resultJSON;
}

static UIEdgeInsets IOSUsePlaySafeAreaProviderHook(
    UIWindow *window,
    SEL selector,
    BOOL includeStatusBar
) {
    UIEdgeInsets original = UIEdgeInsetsZero;
    if (IOSUsePlaySafeAreaOriginalProvider != NULL) {
        original = IOSUsePlaySafeAreaOriginalProvider(
            window,
            selector,
            includeStatusBar
        );
    }
    BOOL fixedGeometryApplied =
        IOSUsePlaySafeAreaReceiverUsesFixedGeometry(window);
    UIEdgeInsets result =
        fixedGeometryApplied
            ? IOSUsePlaySafeAreaProviderInsets(
                original,
                includeStatusBar
            )
            : original;
    IOSUsePlaySafeAreaRecordProviderInvocation(
        window,
        includeStatusBar,
        original,
        result,
        fixedGeometryApplied
    );
    return result;
}

static BOOL IOSUsePlaySafeAreaMethodHasABI(
    Method method,
    const char *returnType,
    const char *lastArgumentType,
    unsigned int argumentCount
) {
    if (method == NULL ||
        method_getNumberOfArguments(method) != argumentCount) {
        return NO;
    }
    char *actualReturn = method_copyReturnType(method);
    char *actualArgument = argumentCount > 2
        ? method_copyArgumentType(method, argumentCount - 1)
        : NULL;
    BOOL matches =
        actualReturn != NULL &&
        strcmp(actualReturn, returnType) == 0 &&
        ((lastArgumentType == NULL && actualArgument == NULL) ||
         (lastArgumentType != NULL &&
          actualArgument != NULL &&
          strcmp(actualArgument, lastArgumentType) == 0));
    free(actualReturn);
    free(actualArgument);
    return matches;
}

static Class IOSUsePlaySafeAreaMethodOwner(
    Class receiverClass,
    SEL selector
) {
    for (Class candidate = receiverClass;
         candidate != Nil;
         candidate = class_getSuperclass(candidate)) {
        unsigned int methodCount = 0;
        Method *methods =
            class_copyMethodList(candidate, &methodCount);
        BOOL found = NO;
        for (unsigned int index = 0;
             index < methodCount;
             index += 1) {
            if (method_getName(methods[index]) == selector) {
                found = YES;
                break;
            }
        }
        free(methods);
        if (found) {
            return candidate;
        }
    }
    return Nil;
}

static BOOL IOSUsePlaySafeAreaClassDispatchesIMP(
    Class receiverClass,
    SEL selector,
    IMP expected
) {
    return receiverClass != Nil &&
        selector != NULL &&
        expected != NULL &&
        class_getMethodImplementation(
            receiverClass,
            selector
        ) == expected;
}

static BOOL IOSUsePlaySafeAreaHookIsActive(void) {
#if TARGET_OS_MACCATALYST
    if (!IOSUsePlaySafeAreaHookAttempted ||
        IOSUsePlaySafeAreaProviderSelector == NULL) {
        return NO;
    }
    Method method = class_getInstanceMethod(
        UIWindow.class,
        IOSUsePlaySafeAreaProviderSelector
    );
    return IOSUsePlaySafeAreaHookInstalled &&
        IOSUsePlaySafeAreaHookABICompatible &&
        method != NULL &&
        IOSUsePlaySafeAreaMethodOwner(
            UIWindow.class,
            IOSUsePlaySafeAreaProviderSelector
        ) == UIWindow.class &&
        IOSUsePlaySafeAreaClassDispatchesIMP(
            UIWindow.class,
            IOSUsePlaySafeAreaProviderSelector,
            (IMP)IOSUsePlaySafeAreaProviderHook
        );
#else
    return YES;
#endif
}

static BOOL IOSUsePlaySafeAreaInstallHook(void) {
    if (IOSUsePlaySafeAreaHookAttempted) {
        if (IOSUsePlaySafeAreaHookIsActive()) {
            return YES;
        }
#if TARGET_OS_MACCATALYST
        IOSUsePlaySafeAreaHookStatus = @"failed";
        IOSUsePlaySafeAreaFailureCode = @"safe_area_hook_replaced";
        IOSUsePlaySafeAreaFailure =
            @"UIWindow safe-area provider no longer dispatches to the "
             "installed compatibility hook";
#endif
        return NO;
    }
    IOSUsePlaySafeAreaHookAttempted = YES;
#if !TARGET_OS_MACCATALYST
    IOSUsePlaySafeAreaHookStatus = @"native-uikit";
    IOSUsePlaySafeAreaHookABICompatible = YES;
    return YES;
#else
    IOSUsePlaySafeAreaProviderSelector =
        NSSelectorFromString(IOSUsePlaySafeAreaProviderSelectorName);
    IOSUsePlaySafeAreaInvalidationSelector =
        NSSelectorFromString(
            IOSUsePlaySafeAreaInvalidationSelectorName
        );
    Method provider = class_getInstanceMethod(
        UIWindow.class,
        IOSUsePlaySafeAreaProviderSelector
    );
    Method invalidation = class_getInstanceMethod(
        UIWindow.class,
        IOSUsePlaySafeAreaInvalidationSelector
    );
    Class providerOwner = IOSUsePlaySafeAreaMethodOwner(
        UIWindow.class,
        IOSUsePlaySafeAreaProviderSelector
    );
    Class invalidationOwner = IOSUsePlaySafeAreaMethodOwner(
        UIWindow.class,
        IOSUsePlaySafeAreaInvalidationSelector
    );
    IOSUsePlaySafeAreaProviderOwner = providerOwner == Nil
        ? nil
        : NSStringFromClass(providerOwner);
    IOSUsePlaySafeAreaInvalidationOwner =
        invalidationOwner == Nil
            ? nil
            : NSStringFromClass(invalidationOwner);
    IOSUsePlaySafeAreaProviderABI = provider == NULL
        ? nil
        : [NSString stringWithUTF8String:
            method_getTypeEncoding(provider)];
    if (provider == NULL) {
        IOSUsePlaySafeAreaHookStatus = @"failed";
        IOSUsePlaySafeAreaFailureCode =
            @"safe_area_provider_unavailable";
        IOSUsePlaySafeAreaFailure =
            @"UIWindow safe-area provider selector is unavailable";
        return NO;
    }
    if (providerOwner != UIWindow.class) {
        IOSUsePlaySafeAreaHookStatus = @"failed";
        IOSUsePlaySafeAreaFailureCode =
            @"safe_area_provider_owner_mismatch";
        IOSUsePlaySafeAreaFailure =
            @"UIWindow does not directly own the safe-area provider";
        return NO;
    }
    if (!IOSUsePlaySafeAreaMethodHasABI(
            provider,
            @encode(UIEdgeInsets),
            @encode(BOOL),
            3
        )) {
        IOSUsePlaySafeAreaHookStatus = @"failed";
        IOSUsePlaySafeAreaFailureCode =
            @"safe_area_provider_abi_mismatch";
        IOSUsePlaySafeAreaFailure =
            @"UIWindow safe-area provider ABI does not match "
             "UIEdgeInsets(id,SEL,BOOL)";
        return NO;
    }
    if (invalidation == NULL) {
        IOSUsePlaySafeAreaHookStatus = @"failed";
        IOSUsePlaySafeAreaFailureCode =
            @"safe_area_invalidation_unavailable";
        IOSUsePlaySafeAreaFailure =
            @"UIWindow safe-area invalidation selector is unavailable";
        return NO;
    }
    if (invalidationOwner != UIWindow.class) {
        IOSUsePlaySafeAreaHookStatus = @"failed";
        IOSUsePlaySafeAreaFailureCode =
            @"safe_area_invalidation_owner_mismatch";
        IOSUsePlaySafeAreaFailure =
            @"UIWindow does not directly own safe-area invalidation";
        return NO;
    }
    if (!IOSUsePlaySafeAreaMethodHasABI(
            invalidation,
            @encode(void),
            NULL,
            2
        )) {
        IOSUsePlaySafeAreaHookStatus = @"failed";
        IOSUsePlaySafeAreaFailureCode =
            @"safe_area_invalidation_abi_mismatch";
        IOSUsePlaySafeAreaFailure =
            @"UIWindow safe-area invalidation ABI is not void(id,SEL)";
        return NO;
    }
    IOSUsePlaySafeAreaOriginalProvider =
        (IOSUsePlaySafeAreaProviderIMP)
            method_getImplementation(provider);
    if (IOSUsePlaySafeAreaOriginalProvider == NULL ||
        (IMP)IOSUsePlaySafeAreaOriginalProvider ==
            (IMP)IOSUsePlaySafeAreaProviderHook) {
        IOSUsePlaySafeAreaHookStatus = @"failed";
        IOSUsePlaySafeAreaFailureCode =
            @"safe_area_original_imp_invalid";
        IOSUsePlaySafeAreaFailure =
            @"UIWindow safe-area provider original IMP is unavailable";
        return NO;
    }
    IMP replaced = method_setImplementation(
        provider,
        (IMP)IOSUsePlaySafeAreaProviderHook
    );
    if (replaced != (IMP)IOSUsePlaySafeAreaOriginalProvider ||
        method_getImplementation(provider) !=
            (IMP)IOSUsePlaySafeAreaProviderHook) {
        IOSUsePlaySafeAreaHookStatus = @"failed";
        IOSUsePlaySafeAreaFailureCode =
            @"safe_area_hook_install_failed";
        IOSUsePlaySafeAreaFailure =
            @"UIWindow safe-area provider hook did not install";
        return NO;
    }
    IOSUsePlaySafeAreaHookABICompatible = YES;
    IOSUsePlaySafeAreaHookInstalled = YES;
    IOSUsePlaySafeAreaHookStatus = @"installed";
    IOSUsePlaySafeAreaFailureCode = nil;
    IOSUsePlaySafeAreaFailure = nil;
    return YES;
#endif
}

static BOOL IOSUsePlaySafeAreaInvalidate(UIWindow *window) {
    if (window == nil ||
        IOSUsePlaySafeAreaInvalidationSelector == NULL ||
        ![window respondsToSelector:
            IOSUsePlaySafeAreaInvalidationSelector]) {
#if TARGET_OS_MACCATALYST
        return NO;
#else
        return YES;
#endif
    }
    IOSUsePlaySafeAreaInvalidationCount += 1;
    ((void (*)(id, SEL))objc_msgSend)(
        window,
        IOSUsePlaySafeAreaInvalidationSelector
    );
    [window setNeedsUpdateConstraints];
    [window setNeedsLayout];
    [window layoutIfNeeded];
    UIView *rootView = window.rootViewController.view;
    [rootView setNeedsUpdateConstraints];
    [rootView setNeedsLayout];
    [rootView layoutIfNeeded];
    return YES;
}

static void IOSUsePlaySafeAreaBind(
    UIWindowScene *scene,
    UIWindow *window
) {
    UIWindowScene *oldScene = IOSUsePlaySafeAreaTargetScene;
    UIWindow *oldWindow = IOSUsePlaySafeAreaTargetWindow;
    BOOL sceneChanged = oldScene != scene;
    BOOL windowChanged = oldWindow != window;
    if (!sceneChanged && !windowChanged) {
        (void)IOSUsePlaySafeAreaInvalidate(window);
        return;
    }
    IOSUsePlaySafeAreaTargetScene = nil;
    IOSUsePlaySafeAreaTargetWindow = nil;
    (void)IOSUsePlaySafeAreaInvalidate(oldWindow);
    if (sceneChanged && oldScene != nil) {
        IOSUsePlaySafeAreaSceneReplacementCount += 1;
    }
    if (windowChanged && oldWindow != nil) {
        IOSUsePlaySafeAreaWindowReplacementCount += 1;
    }
    IOSUsePlaySafeAreaTargetScene = scene;
    IOSUsePlaySafeAreaTargetWindow = window;
    (void)IOSUsePlaySafeAreaInvalidate(window);
}

NSDictionary<NSString *, id> *
IOSUsePlaySafeAreaCompatibilityDiagnostics(void) {
    NSCAssert(NSThread.isMainThread, @"safe-area diagnostics are main-only");
    UIWindowScene *scene = IOSUsePlaySafeAreaTargetScene;
    UIWindow *window = IOSUsePlaySafeAreaTargetWindow;
    UIWindowScene *selectedScene = IOSUsePlaySafeAreaForegroundScene();
    UIWindow *selectedWindow =
        IOSUsePlaySafeAreaPrimaryWindow(selectedScene);
    UIViewController *root = window.rootViewController;
    UIView *rootView = root.view;
    UIEdgeInsets windowSafeArea = window.safeAreaInsets;
    UIEdgeInsets rootSafeArea = rootView.safeAreaInsets;
    UIEdgeInsets additionalSafeArea = root.additionalSafeAreaInsets;
    UIEdgeInsets originalProviderSafeArea = UIEdgeInsetsZero;
    if (window != nil &&
        IOSUsePlaySafeAreaOriginalProvider != NULL) {
        originalProviderSafeArea =
            IOSUsePlaySafeAreaOriginalProvider(
                window,
                IOSUsePlaySafeAreaProviderSelector,
                YES
            );
    }
    UIEdgeInsets deviceSafeArea =
        IOSUsePlaySafeAreaDeviceInsets(YES);
    UIEdgeInsets expectedWindowSafeArea =
        IOSUsePlaySafeAreaMaximumInsets(
            originalProviderSafeArea,
            deviceSafeArea
        );
    UIEdgeInsets expectedRootSafeArea = UIEdgeInsetsMake(
        expectedWindowSafeArea.top + additionalSafeArea.top,
        expectedWindowSafeArea.left + additionalSafeArea.left,
        expectedWindowSafeArea.bottom + additionalSafeArea.bottom,
        expectedWindowSafeArea.right + additionalSafeArea.right
    );
    CGRect layoutFrame = rootView.safeAreaLayoutGuide.layoutFrame;
    CGRect expectedLayoutFrame = UIEdgeInsetsInsetRect(
        rootView.bounds,
        expectedRootSafeArea
    );
    BOOL classHookReady = IOSUsePlaySafeAreaHookIsActive();
    BOOL targetDispatchesHook =
#if TARGET_OS_MACCATALYST
        IOSUsePlaySafeAreaProviderSelector != NULL &&
        window != nil &&
        IOSUsePlaySafeAreaClassDispatchesIMP(
            window.class,
            IOSUsePlaySafeAreaProviderSelector,
            (IMP)IOSUsePlaySafeAreaProviderHook
        );
#else
        YES;
#endif
    NSDictionary<NSString *, id>
        *targetFirstEligibleProviderInvocation =
        IOSUsePlaySafeAreaEvidenceJSONForWindow(window);
#if TARGET_OS_MACCATALYST
    BOOL installEvidenceReady =
        IOSUsePlaySafeAreaPreMainInstallAttempted &&
        IOSUsePlaySafeAreaPreMainInstallSucceeded &&
        classHookReady;
    BOOL firstEligibleProviderInvocationReady =
        IOSUsePlaySafeAreaEvidenceIsReadyForWindow(window);
#else
    BOOL installEvidenceReady = YES;
    BOOL firstEligibleProviderInvocationReady = YES;
#endif
    BOOL compatibilityReady =
        installEvidenceReady &&
        targetDispatchesHook &&
        firstEligibleProviderInvocationReady;
    BOOL deviceContractReady =
        IOSUsePlaySafeAreaInsetsMatch(
            expectedWindowSafeArea,
            deviceSafeArea
        );
    BOOL additionalSafeAreaPreserved =
        IOSUsePlaySafeAreaInsetsMatch(
            rootSafeArea,
            expectedRootSafeArea
        );
    BOOL layoutGuideReady = IOSUsePlaySafeAreaRectsMatch(
        layoutFrame,
        expectedLayoutFrame
    );
    BOOL safeAreaReady =
        scene != nil &&
        window != nil &&
        selectedScene == scene &&
        selectedWindow == window &&
        compatibilityReady &&
        deviceContractReady &&
        IOSUsePlaySafeAreaInsetsMatch(
            windowSafeArea,
            expectedWindowSafeArea
        ) &&
        additionalSafeAreaPreserved &&
        layoutGuideReady;
    return @{
        @"stage": IOSUsePlaySafeAreaStage,
        @"failureCode":
            IOSUsePlaySafeAreaFailureCode ?: NSNull.null,
        @"failure": IOSUsePlaySafeAreaFailure ?: NSNull.null,
        @"safeAreaCompatibilityReady": @(compatibilityReady),
        @"installEvidenceReady": @(installEvidenceReady),
        @"firstEligibleProviderInvocationReady":
            @(firstEligibleProviderInvocationReady),
        @"safeAreaReady": @(safeAreaReady),
        @"deviceContractReady": @(deviceContractReady),
        @"safeAreaLayoutGuideReady": @(layoutGuideReady),
        @"additionalSafeAreaPreserved":
            @(additionalSafeAreaPreserved),
        @"deviceSafeArea":
            IOSUsePlaySafeAreaInsetsJSON(deviceSafeArea),
        @"windowSafeArea":
            IOSUsePlaySafeAreaInsetsJSON(windowSafeArea),
        @"originalProviderSafeArea":
            IOSUsePlaySafeAreaInsetsJSON(
                originalProviderSafeArea
            ),
        @"expectedWindowSafeArea":
            IOSUsePlaySafeAreaInsetsJSON(
                expectedWindowSafeArea
            ),
        @"safeArea": IOSUsePlaySafeAreaInsetsJSON(rootSafeArea),
        @"additionalSafeArea":
            IOSUsePlaySafeAreaInsetsJSON(additionalSafeArea),
        @"expectedRootSafeArea":
            IOSUsePlaySafeAreaInsetsJSON(expectedRootSafeArea),
        @"safeAreaLayoutFrame":
            IOSUsePlaySafeAreaRectJSON(layoutFrame),
        @"expectedSafeAreaLayoutFrame":
            IOSUsePlaySafeAreaRectJSON(expectedLayoutFrame),
        @"runtimeAdditionalSafeAreaWriteCount": @0,
        @"selection": @{
            @"sceneMatches": @(selectedScene == scene),
            @"windowMatches": @(selectedWindow == window),
            @"sceneIdentifier":
                scene.session.persistentIdentifier ?: NSNull.null,
            @"windowClass": window == nil
                ? NSNull.null
                : NSStringFromClass(window.class),
            @"windowIsKey": @(window.isKeyWindow),
        },
        @"compatibilityHook": @{
            @"status": IOSUsePlaySafeAreaHookStatus,
            @"selector":
                IOSUsePlaySafeAreaProviderSelectorName,
            @"invalidationSelector":
                IOSUsePlaySafeAreaInvalidationSelectorName,
            @"abi":
                IOSUsePlaySafeAreaProviderABI ?: NSNull.null,
            @"providerOwner":
                IOSUsePlaySafeAreaProviderOwner ?: NSNull.null,
            @"invalidationOwner":
                IOSUsePlaySafeAreaInvalidationOwner ?: NSNull.null,
            @"abiCompatible":
                @(IOSUsePlaySafeAreaHookABICompatible),
            @"originalIMPRecorded": @(
                IOSUsePlaySafeAreaOriginalProvider != NULL
            ),
            @"classHookActive": @(classHookReady),
            @"targetDispatchesHook":
                @(targetDispatchesHook),
            @"scope":
                @"scene-attached-application-role-normal-app-window",
            @"invalidations":
                @(IOSUsePlaySafeAreaInvalidationCount),
            @"installPhase": @"pre-main-constructor",
            @"preMainInstallAttempted":
                @(IOSUsePlaySafeAreaPreMainInstallAttempted),
            @"preMainInstallSucceeded":
                @(IOSUsePlaySafeAreaPreMainInstallSucceeded),
            @"targetFirstEligibleProviderInvocation":
                targetFirstEligibleProviderInvocation,
        },
        @"lifecycle": @{
            @"sceneReplacements":
                @(IOSUsePlaySafeAreaSceneReplacementCount),
            @"windowReplacements":
                @(IOSUsePlaySafeAreaWindowReplacementCount),
        },
    };
}

BOOL IOSUsePlaySafeAreaCompatibilityReconcile(
    NSError * _Nullable * _Nullable error
) {
    NSCAssert(NSThread.isMainThread, @"safe-area reconcile is main-only");
    if (!IOSUsePlaySafeAreaHookIsActive()) {
        IOSUsePlaySafeAreaHookStatus = @"failed";
        IOSUsePlaySafeAreaFailureCode =
            IOSUsePlaySafeAreaHookAttempted
                ? @"safe_area_hook_replaced"
                : @"safe_area_hook_not_preinstalled";
        IOSUsePlaySafeAreaFailure =
            IOSUsePlaySafeAreaHookAttempted
                ? @"UIWindow safe-area provider no longer dispatches "
                  "to the installed compatibility hook"
                : @"UIWindow safe-area provider hook was not installed "
                  "before UIApplicationMain";
        IOSUsePlaySafeAreaBind(nil, nil);
        IOSUsePlaySafeAreaStage = @"failed";
        if (error != NULL) {
            *error = [NSError
                errorWithDomain:IOSUsePlaySafeAreaErrorDomain
                           code:1
                       userInfo:@{
                NSLocalizedDescriptionKey:
                    IOSUsePlaySafeAreaFailure,
            }];
        }
        return NO;
    }
    UIWindowScene *scene = IOSUsePlaySafeAreaForegroundScene();
    UIWindow *window = IOSUsePlaySafeAreaPrimaryWindow(scene);
    if (scene == nil || window == nil) {
        IOSUsePlaySafeAreaBind(nil, nil);
        IOSUsePlaySafeAreaStage = scene == nil
            ? @"waiting-for-scene"
            : @"waiting-for-window";
        IOSUsePlaySafeAreaFailureCode = scene == nil
            ? @"foreground_scene_unavailable"
            : @"primary_app_window_unavailable";
        IOSUsePlaySafeAreaFailure = scene == nil
            ? @"foreground-active/inactive UIWindowScene is unavailable"
            : @"foreground scene has no primary App UIWindow";
        if (error != NULL) {
            *error = [NSError
                errorWithDomain:IOSUsePlaySafeAreaErrorDomain
                           code:2
                       userInfo:@{
                NSLocalizedDescriptionKey:
                    IOSUsePlaySafeAreaFailure,
            }];
        }
        return NO;
    }
    IOSUsePlaySafeAreaBind(scene, window);
    NSDictionary<NSString *, id> *diagnostics =
        IOSUsePlaySafeAreaCompatibilityDiagnostics();
    NSDictionary<NSString *, id> *firstEligibleProviderInvocation =
        diagnostics[@"compatibilityHook"][
            @"targetFirstEligibleProviderInvocation"
        ];
    if (![firstEligibleProviderInvocation[
            @"recorded"
        ] boolValue]) {
        IOSUsePlaySafeAreaStage =
            @"waiting-for-first-eligible-provider-invocation";
        IOSUsePlaySafeAreaFailureCode =
            @"safe_area_first_eligible_provider_unavailable";
        IOSUsePlaySafeAreaFailure =
            @"the target window has no eligible App-window provider "
             "invocation evidence";
        if (error != NULL) {
            *error = [NSError
                errorWithDomain:IOSUsePlaySafeAreaErrorDomain
                           code:2
                       userInfo:@{
                NSLocalizedDescriptionKey:
                    IOSUsePlaySafeAreaFailure,
            }];
        }
        return NO;
    }
    if (![diagnostics[
            @"firstEligibleProviderInvocationReady"
        ] boolValue]) {
        IOSUsePlaySafeAreaStage = @"failed";
        if (![firstEligibleProviderInvocation[
                @"installedBeforeDispatch"
            ] boolValue]) {
            IOSUsePlaySafeAreaFailureCode =
                @"safe_area_first_provider_before_install";
            IOSUsePlaySafeAreaFailure =
                @"the target window's first observed provider "
                 "invocation preceded hook installation";
        } else if (![firstEligibleProviderInvocation[
                @"fixedGeometryApplied"
            ] boolValue]) {
            IOSUsePlaySafeAreaFailureCode =
                @"safe_area_first_provider_outside_prebind_scope";
            IOSUsePlaySafeAreaFailure =
                @"the target window's first observed provider "
                 "invocation occurred "
                 "outside the App-window pre-bind scope";
        } else {
            IOSUsePlaySafeAreaFailureCode =
                @"safe_area_first_provider_result_mismatch";
            IOSUsePlaySafeAreaFailure =
                @"the target window's first observed provider "
                 "invocation returned "
                 "geometry outside the fixed iPhone contract";
        }
        if (error != NULL) {
            *error = [NSError
                errorWithDomain:IOSUsePlaySafeAreaErrorDomain
                           code:3
                       userInfo:@{
                NSLocalizedDescriptionKey:
                    IOSUsePlaySafeAreaFailure,
            }];
        }
        return NO;
    }
    if ([diagnostics[@"safeAreaReady"] boolValue]) {
        IOSUsePlaySafeAreaStage = @"ready";
        IOSUsePlaySafeAreaFailureCode = nil;
        IOSUsePlaySafeAreaFailure = nil;
        return YES;
    }
    IOSUsePlaySafeAreaStage = @"waiting-for-layout";
    IOSUsePlaySafeAreaFailureCode =
        [diagnostics[@"safeAreaCompatibilityReady"] boolValue]
            ? @"safe_area_layout_mismatch"
            : @"safe_area_compatibility_failed";
    IOSUsePlaySafeAreaFailure =
        [diagnostics[@"safeAreaCompatibilityReady"] boolValue]
            ? @"UIKit safe-area values/layout guide do not match the "
              "fixed iPhone contract"
            : @"window-scoped safe-area compatibility is not active";
    if (error != NULL) {
        *error = [NSError
            errorWithDomain:IOSUsePlaySafeAreaErrorDomain
                       code:2
                   userInfo:@{
            NSLocalizedDescriptionKey:
                IOSUsePlaySafeAreaFailure,
        }];
    }
    return NO;
}

BOOL IOSUsePlaySafeAreaCompatibilityInstallBeforeUIApplicationMain(
    NSError * _Nullable * _Nullable error
) {
    IOSUsePlaySafeAreaPreMainInstallAttempted = YES;
    BOOL installed = IOSUsePlaySafeAreaInstallHook();
    IOSUsePlaySafeAreaPreMainInstallSucceeded = installed;
    if (installed) {
        if ([IOSUsePlaySafeAreaStage
                isEqualToString:@"not-installed"]) {
            IOSUsePlaySafeAreaStage = @"hook-installed";
        }
        return YES;
    }
    IOSUsePlaySafeAreaStage = @"failed";
    if (error != NULL) {
        *error = [NSError
            errorWithDomain:IOSUsePlaySafeAreaErrorDomain
                       code:1
                   userInfo:@{
            NSLocalizedDescriptionKey:
                IOSUsePlaySafeAreaFailure ?:
                    @"safe-area compatibility hook failed",
        }];
    }
    return NO;
}

BOOL IOSUsePlaySafeAreaCompatibilityIsReadyForWindow(
    UIWindow *window
) {
    NSCAssert(NSThread.isMainThread, @"safe-area readiness is main-only");
    if (window == nil ||
        window != IOSUsePlaySafeAreaTargetWindow ||
        window.windowScene != IOSUsePlaySafeAreaTargetScene) {
        return NO;
    }
    return [
        IOSUsePlaySafeAreaCompatibilityDiagnostics()[
            @"safeAreaReady"
        ] boolValue
    ];
}

void IOSUsePlaySafeAreaCompatibilityBridgeHookRegistry(void) {
    const char *argumentTypes[] = {
        @encode(BOOL),
    };
    NSError *error = nil;
    BOOL active = IOSUsePlaySafeAreaHookIsActive();
    BOOL observed = active &&
        IOSUsePlayHookRegistryObserveMethod(
            @"safe-area.provider",
            YES,
            @"pre-main",
            UIWindow.class,
            NO,
            IOSUsePlaySafeAreaProviderSelector ?:
                NSSelectorFromString(
                    IOSUsePlaySafeAreaProviderSelectorName
                ),
            @encode(UIEdgeInsets),
            argumentTypes,
            1,
            YES,
            YES,
            &error
        );
    if (!observed) {
        IOSUsePlayHookRegistryRecordState(
            @"safe-area.provider",
            YES,
            @"pre-main",
            @"UIWindow",
            IOSUsePlaySafeAreaProviderSelectorName,
            IOSUsePlaySafeAreaProviderABI ?: @"unavailable",
            YES,
            NO,
            error.localizedDescription ?:
                IOSUsePlaySafeAreaFailure ?:
                    @"safe-area provider hook is inactive"
        );
        return;
    }
    UIWindow *window = IOSUsePlaySafeAreaTargetWindow;
    if (IOSUsePlaySafeAreaEvidenceIsReadyForWindow(window)) {
        IOSUsePlaySafeAreaFirstProviderEvidence *evidence =
            IOSUsePlaySafeAreaEvidenceForWindow(window);
        BOOL recordsNewEvidence = NO;
        os_unfair_lock_lock(&IOSUsePlaySafeAreaEvidenceLock);
        if (evidence != nil &&
            evidence->generation >
                IOSUsePlaySafeAreaLastRegistryEvidenceGeneration) {
            IOSUsePlaySafeAreaLastRegistryEvidenceGeneration =
                evidence->generation;
            recordsNewEvidence = YES;
        }
        os_unfair_lock_unlock(&IOSUsePlaySafeAreaEvidenceLock);
        if (recordsNewEvidence) {
            IOSUsePlayHookRegistryRecordFirstUse(
                @"safe-area.provider",
                window.class
            );
        }
    }
}

#if defined(IOS_USE_PLAY_SAFE_AREA_TESTING)
UIEdgeInsets IOSUsePlaySafeAreaMaximumInsetsForTesting(
    UIEdgeInsets left,
    UIEdgeInsets right
) {
    return IOSUsePlaySafeAreaMaximumInsets(left, right);
}

BOOL IOSUsePlaySafeAreaMethodHasABIForTesting(
    Method method,
    const char *returnType,
    const char *lastArgumentType,
    unsigned int argumentCount
) {
    return IOSUsePlaySafeAreaMethodHasABI(
        method,
        returnType,
        lastArgumentType,
        argumentCount
    );
}

UIEdgeInsets IOSUsePlaySafeAreaProviderInsetsForTesting(
    UIEdgeInsets original,
    BOOL includeStatusBar
) {
    return IOSUsePlaySafeAreaProviderInsets(
        original,
        includeStatusBar
    );
}

BOOL IOSUsePlaySafeAreaSceneActivationStateSupportsFixedGeometryForTesting(
    UISceneActivationState state
) {
    return state == UISceneActivationStateForegroundActive ||
        state == UISceneActivationStateForegroundInactive;
}

BOOL IOSUsePlaySafeAreaPreBindContractMatchesForTesting(
    BOOL sceneAttached,
    BOOL applicationRole,
    BOOL normalWindowLevel,
    BOOL auxiliaryWindow
) {
    return IOSUsePlaySafeAreaPreBindContractMatches(
        sceneAttached,
        applicationRole,
        normalWindowLevel,
        auxiliaryWindow
    );
}

void IOSUsePlaySafeAreaRecordProviderInvocationForTesting(
    UIWindow *window,
    BOOL includeStatusBar,
    UIEdgeInsets original,
    UIEdgeInsets result,
    BOOL fixedGeometryApplied
) {
    IOSUsePlaySafeAreaRecordProviderInvocation(
        window,
        includeStatusBar,
        original,
        result,
        fixedGeometryApplied
    );
}

BOOL
IOSUsePlaySafeAreaFirstProviderInvocationReadyForWindowForTesting(
    UIWindow *window
) {
    return IOSUsePlaySafeAreaEvidenceIsReadyForWindow(window);
}

NSDictionary<NSString *, id> *
IOSUsePlaySafeAreaFirstProviderEvidenceForWindowForTesting(
    UIWindow *window
) {
    return IOSUsePlaySafeAreaEvidenceJSONForWindow(window);
}

void IOSUsePlaySafeAreaResetEvidenceForWindowForTesting(
    UIWindow *window
) {
    os_unfair_lock_lock(&IOSUsePlaySafeAreaEvidenceLock);
    objc_setAssociatedObject(
        window,
        &IOSUsePlaySafeAreaEvidenceAssociationKey,
        nil,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );
    os_unfair_lock_unlock(&IOSUsePlaySafeAreaEvidenceLock);
}

Class IOSUsePlaySafeAreaMethodOwnerForTesting(
    Class receiverClass,
    SEL selector
) {
    return IOSUsePlaySafeAreaMethodOwner(
        receiverClass,
        selector
    );
}

BOOL IOSUsePlaySafeAreaClassDispatchesIMPForTesting(
    Class receiverClass,
    SEL selector,
    IMP expected
) {
    return IOSUsePlaySafeAreaClassDispatchesIMP(
        receiverClass,
        selector,
        expected
    );
}

#endif
