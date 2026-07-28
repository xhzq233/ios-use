#import "IOSUsePlaySafeAreaCompatibility.h"
#import "IOSUsePlayDevice.h"

#import <TargetConditionals.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>
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
static NSUInteger IOSUsePlaySafeAreaInvalidationCount;
static NSUInteger IOSUsePlaySafeAreaSceneReplacementCount;
static NSUInteger IOSUsePlaySafeAreaWindowReplacementCount;

static NSInteger IOSUsePlaySafeAreaRuntimeMajorVersion(void) {
    return UIDevice.currentDevice.systemVersion.integerValue;
}

static BOOL IOSUsePlaySafeAreaRuntimeMajorIsValidated(
    NSInteger majorVersion
) {
    // iPhone16,2 shipped on iOS 17. The portrait base geometry is unchanged
    // on the iOS 17, iOS 18, and iOS 26 runtime families we support. Keep the
    // validated runtime set explicit so a future compatibility runtime cannot
    // silently inherit an unverified device profile.
    switch (majorVersion) {
        case 17:
        case 18:
        case 26:
            return YES;
        default:
            return NO;
    }
}

static UIEdgeInsets IOSUsePlaySafeAreaDeviceInsets(void) {
    return UIEdgeInsetsMake(
        IOSUsePlayDeviceSafeAreaTop,
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
    id delegate = scene.delegate;
    SEL windowSelector = NSSelectorFromString(@"window");
    if ([delegate respondsToSelector:windowSelector]) {
        UIWindow *delegateWindow =
            ((id (*)(id, SEL))objc_msgSend)(
                delegate,
                windowSelector
            );
        if (IOSUsePlaySafeAreaIsEligibleWindow(
                delegateWindow,
                scene
            )) {
            return delegateWindow;
        }
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
        if (scene.activationState !=
                UISceneActivationStateForegroundActive ||
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
    UIWindowScene *targetScene = IOSUsePlaySafeAreaTargetScene;
    if (window != IOSUsePlaySafeAreaTargetWindow ||
        window.windowScene != targetScene ||
        targetScene.activationState !=
            UISceneActivationStateForegroundActive) {
        return original;
    }
    return IOSUsePlaySafeAreaMaximumInsets(
        original,
        IOSUsePlaySafeAreaDeviceInsets()
    );
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
        method_getImplementation(method) ==
            (IMP)IOSUsePlaySafeAreaProviderHook;
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
    UIEdgeInsets deviceSafeArea = IOSUsePlaySafeAreaDeviceInsets();
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
        class_getMethodImplementation(
            window.class,
            IOSUsePlaySafeAreaProviderSelector
        ) == (IMP)IOSUsePlaySafeAreaProviderHook;
#else
        YES;
#endif
    BOOL compatibilityReady =
        classHookReady && targetDispatchesHook;
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
        IOSUsePlaySafeAreaRuntimeMajorIsValidated(
            IOSUsePlaySafeAreaRuntimeMajorVersion()
        ) &&
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
        @"safeAreaReady": @(safeAreaReady),
        @"deviceContractReady": @(deviceContractReady),
        @"safeAreaLayoutGuideReady": @(layoutGuideReady),
        @"additionalSafeAreaPreserved":
            @(additionalSafeAreaPreserved),
        @"deviceSafeArea":
            IOSUsePlaySafeAreaInsetsJSON(deviceSafeArea),
        @"runtimeProfile": @{
            @"systemName":
                UIDevice.currentDevice.systemName ?: NSNull.null,
            @"systemVersion":
                UIDevice.currentDevice.systemVersion ?: NSNull.null,
            @"systemMajor":
                @(IOSUsePlaySafeAreaRuntimeMajorVersion()),
            @"validatedSystemMajors": @[@17, @18, @26],
            @"validated": @(
                IOSUsePlaySafeAreaRuntimeMajorIsValidated(
                    IOSUsePlaySafeAreaRuntimeMajorVersion()
                )
            ),
            @"uikitBundleVersion": [[NSBundle
                bundleForClass:UIWindow.class]
                objectForInfoDictionaryKey:@"CFBundleVersion"] ?:
                    NSNull.null,
            @"uikitPlatformVersion": [[NSBundle
                bundleForClass:UIWindow.class]
                objectForInfoDictionaryKey:@"DTPlatformVersion"] ?:
                    NSNull.null,
            @"hostOperatingSystem":
                NSProcessInfo.processInfo
                    .operatingSystemVersionString ?: NSNull.null,
        },
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
            @"abiCompatible":
                @(IOSUsePlaySafeAreaHookABICompatible),
            @"originalIMPRecorded": @(
                IOSUsePlaySafeAreaOriginalProvider != NULL
            ),
            @"classHookActive": @(classHookReady),
            @"targetDispatchesHook":
                @(targetDispatchesHook),
            @"scope":
                @"active-foreground-primary-app-window-only",
            @"invalidations":
                @(IOSUsePlaySafeAreaInvalidationCount),
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
    if (!IOSUsePlaySafeAreaInstallHook()) {
        IOSUsePlaySafeAreaBind(nil, nil);
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
    NSInteger runtimeMajor =
        IOSUsePlaySafeAreaRuntimeMajorVersion();
    if (!IOSUsePlaySafeAreaRuntimeMajorIsValidated(runtimeMajor)) {
        IOSUsePlaySafeAreaBind(nil, nil);
        IOSUsePlaySafeAreaStage = @"failed";
        IOSUsePlaySafeAreaFailureCode =
            @"safe_area_runtime_profile_unverified";
        IOSUsePlaySafeAreaFailure = [NSString stringWithFormat:
            @"iPhone16,2 safe-area profile is not validated for "
             "UIKit runtime major %ld",
            (long)runtimeMajor
        ];
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
            ? @"active foreground UIWindowScene is unavailable"
            : @"active foreground scene has no primary App UIWindow";
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

BOOL IOSUsePlaySafeAreaRuntimeMajorIsValidatedForTesting(
    NSInteger majorVersion
) {
    return IOSUsePlaySafeAreaRuntimeMajorIsValidated(majorVersion);
}
#endif
