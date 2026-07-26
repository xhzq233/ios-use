#import "IOSUsePlaySystemChrome.h"
#import "IOSUsePlayDevice.h"

#import <TargetConditionals.h>
#import <UIKit/UIKit.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <string.h>

static NSString *const IOSUseSystemChromeWindowMarker =
    @"io.ios-use.play-runtime.system-chrome";
static NSString *const IOSUseSystemChromeSafeAreaSelectorName =
    @"_sceneSafeAreaInsetsIncludingStatusBar:";
static NSString *const IOSUseSystemChromeInvalidationSelectorName =
    @"_sceneSettingsSafeAreaInsetsDidChange";

@class IOSUsePlayPassthroughWindow;

typedef UIEdgeInsets (*IOSUseSystemChromeSafeAreaIMP)(
    UIWindow *,
    SEL,
    BOOL
);

static IOSUsePlayPassthroughWindow *IOSUseSystemChromeWindow;
static __weak UIWindowScene *IOSUseSystemChromeTargetScene;
static __weak UIWindow *IOSUseSystemChromeTargetAppWindow;
static NSString *IOSUseSystemChromeStage = @"not-installed";
static NSString *IOSUseSystemChromeFailureCode;
static NSString *IOSUseSystemChromeFailure;
static NSUInteger IOSUseSystemChromeSceneReplacementCount;
static NSUInteger IOSUseSystemChromeWindowReplacementCount;
static NSUInteger IOSUseSystemChromeDetachedWindowCount;
static NSUInteger IOSUseSystemChromeReconcileRequestCount;
static NSUInteger IOSUseSystemChromeReconcileRunCount;
static NSUInteger IOSUseSystemChromeObserverInstallCount;
static NSUInteger IOSUseSystemChromeObserverNotificationCount;
static NSArray<id> *IOSUseSystemChromeObserverTokens;
static BOOL IOSUseSystemChromeReconcileScheduled;
static NSTimer *IOSUseSystemChromeMinuteTimer;
static NSUInteger IOSUseSystemChromeMinuteTimerInstallCount;
static NSUInteger IOSUseSystemChromeMinuteTimerCalibrationCount;
static NSUInteger IOSUseSystemChromeMinuteTimerFireCount;
static NSUInteger IOSUseSystemChromeTimeRefreshCount;

static BOOL IOSUseSystemChromeHookAttempted;
static BOOL IOSUseSystemChromeHookInstalled;
static BOOL IOSUseSystemChromeHookABICompatible;
static NSString *IOSUseSystemChromeHookStatus = @"not-installed";
static NSString *IOSUseSystemChromeHookFailureCode;
static NSString *IOSUseSystemChromeHookFailure;
static NSString *IOSUseSystemChromeHookABI;
static SEL IOSUseSystemChromeSafeAreaSelector;
static SEL IOSUseSystemChromeInvalidationSelector;
static IOSUseSystemChromeSafeAreaIMP
    IOSUseSystemChromeOriginalSafeAreaIMP;
static NSUInteger IOSUseSystemChromeHookInvocationCount;
static NSUInteger IOSUseSystemChromeHookAppliedCount;
static NSUInteger IOSUseSystemChromeSafeAreaInvalidationCount;
static NSDictionary<NSString *, id> *
    IOSUseSystemChromeLastImageEvidence;

@interface IOSUsePlayPassthroughWindow : UIWindow
@end

@implementation IOSUsePlayPassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    (void)point;
    (void)event;
    return nil;
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    (void)point;
    (void)event;
    return NO;
}
- (BOOL)canBecomeKeyWindow {
    return NO;
}
@end

typedef NS_ENUM(NSUInteger, IOSUsePlayChromeSurfaceKind) {
    IOSUsePlayChromeSurfaceKindStatus,
    IOSUsePlayChromeSurfaceKindDynamicIsland,
    IOSUsePlayChromeSurfaceKindHomeIndicator,
};

static CGRect IOSUseSystemChromeStatusFrame(void) {
    return CGRectMake(
        0,
        0,
        IOSUsePlayDeviceLogicalWidth,
        IOSUsePlayDeviceStatusBarHeight
    );
}

static CGRect IOSUseSystemChromeDynamicIslandFrame(void) {
    return CGRectMake(
        (IOSUsePlayDeviceLogicalWidth -
            IOSUsePlayDeviceDynamicIslandWidth) / 2.0,
        IOSUsePlayDeviceDynamicIslandTop,
        IOSUsePlayDeviceDynamicIslandWidth,
        IOSUsePlayDeviceDynamicIslandHeight
    );
}

static CGRect IOSUseSystemChromeHomeIndicatorFrame(void) {
    return CGRectMake(
        (IOSUsePlayDeviceLogicalWidth -
            IOSUsePlayDeviceHomeIndicatorWidth) / 2.0,
        IOSUsePlayDeviceLogicalHeight -
            IOSUsePlayDeviceHomeIndicatorBottom -
            IOSUsePlayDeviceHomeIndicatorHeight,
        IOSUsePlayDeviceHomeIndicatorWidth,
        IOSUsePlayDeviceHomeIndicatorHeight
    );
}

@interface IOSUsePlayChromeSurfaceView : UIView
- (instancetype)initWithFrame:(CGRect)frame
                          kind:(IOSUsePlayChromeSurfaceKind)kind;
@property(nonatomic, readonly) IOSUsePlayChromeSurfaceKind kind;
@end

@interface IOSUsePlayChromeView : UIView
@property(nonatomic, strong, readonly)
    IOSUsePlayChromeSurfaceView *statusSurface;
@property(nonatomic, strong, readonly)
    IOSUsePlayChromeSurfaceView *dynamicIslandSurface;
@property(nonatomic, strong, readonly)
    IOSUsePlayChromeSurfaceView *homeIndicatorSurface;
@end

static UIViewController *IOSUseChromeStatusBarController(
    UIViewController *controller
) {
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    while (controller != nil) {
        NSValue *identity =
            [NSValue valueWithNonretainedObject:controller];
        if ([visited containsObject:identity]) {
            break;
        }
        [visited addObject:identity];
        UIViewController *presented =
            controller.presentedViewController;
        if (presented != nil &&
            !presented.isBeingDismissed) {
            controller = presented;
            continue;
        }
        UIViewController *child =
            controller.childViewControllerForStatusBarStyle;
        if (child == nil || child == controller) {
            break;
        }
        controller = child;
    }
    return controller;
}

static UIColor *IOSUseChromeForegroundColor(void) {
    UIWindow *appWindow = IOSUseSystemChromeTargetAppWindow;
    UIViewController *controller =
        IOSUseChromeStatusBarController(
            appWindow.rootViewController
        );
    return controller.preferredStatusBarStyle == UIStatusBarStyleLightContent
        ? UIColor.whiteColor
        : UIColor.blackColor;
}

@implementation IOSUsePlayChromeSurfaceView {
    IOSUsePlayChromeSurfaceKind _kind;
}

- (instancetype)initWithFrame:(CGRect)frame
                          kind:(IOSUsePlayChromeSurfaceKind)kind {
    self = [super initWithFrame:frame];
    if (self != nil) {
        _kind = kind;
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.userInteractionEnabled = NO;
        self.accessibilityElementsHidden = YES;
        self.contentMode = UIViewContentModeRedraw;
    }
    return self;
}

- (IOSUsePlayChromeSurfaceKind)kind {
    return _kind;
}

- (void)drawRect:(CGRect)rect {
    (void)rect;
    CGContextRef context = UIGraphicsGetCurrentContext();
    if (context == NULL) {
        return;
    }
    UIColor *foreground = IOSUseChromeForegroundColor();
    [foreground setFill];
    [foreground setStroke];

    if (_kind == IOSUsePlayChromeSurfaceKindDynamicIsland) {
        UIBezierPath *islandPath = [UIBezierPath
            bezierPathWithRoundedRect:self.bounds
                        cornerRadius:self.bounds.size.height / 2.0];
        [UIColor.blackColor setFill];
        [islandPath fill];
        return;
    }
    if (_kind == IOSUsePlayChromeSurfaceKindHomeIndicator) {
        UIBezierPath *homePath = [UIBezierPath
            bezierPathWithRoundedRect:self.bounds
                        cornerRadius:self.bounds.size.height / 2.0];
        [foreground setFill];
        [homePath fill];
        return;
    }

    NSString *time = [NSDateFormatter localizedStringFromDate:NSDate.date
                                                     dateStyle:NSDateFormatterNoStyle
                                                     timeStyle:NSDateFormatterShortStyle];
    NSDictionary<NSAttributedStringKey, id> *attributes = @{
        NSFontAttributeName:
            [UIFont monospacedDigitSystemFontOfSize:15
                                             weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: foreground,
    };
    [time drawAtPoint:CGPointMake(27, 18) withAttributes:attributes];

    CGContextSetLineWidth(context, 2.0);
    CGContextSetLineCap(context, kCGLineCapRound);
    // Cellular bars.
    for (NSInteger index = 0; index < 4; index += 1) {
        CGFloat height = 3.0 + index * 2.2;
        CGRect bar = CGRectMake(
            326 + index * 4.0,
            31 - height,
            2.5,
            height
        );
        UIBezierPath *path = [UIBezierPath
            bezierPathWithRoundedRect:bar cornerRadius:1.0];
        [path fill];
    }
    // Wi-Fi arcs.
    CGPoint wifiCenter = CGPointMake(355, 30);
    for (NSInteger index = 0; index < 2; index += 1) {
        CGFloat radius = 5.0 + index * 4.0;
        CGContextAddArc(
            context,
            wifiCenter.x,
            wifiCenter.y,
            radius,
            (CGFloat)(M_PI * 1.18),
            (CGFloat)(M_PI * 1.82),
            0
        );
        CGContextStrokePath(context);
    }
    CGContextFillEllipseInRect(
        context,
        CGRectMake(wifiCenter.x - 1.5, wifiCenter.y - 1.5, 3, 3)
    );
    // Battery body and terminal.
    UIBezierPath *battery = [UIBezierPath
        bezierPathWithRoundedRect:CGRectMake(378, 20, 25, 12)
                    cornerRadius:3];
    battery.lineWidth = 1.3;
    [battery stroke];
    UIBezierPath *charge = [UIBezierPath
        bezierPathWithRoundedRect:CGRectMake(380, 22, 18, 8)
                    cornerRadius:1.5];
    [charge fill];
    CGContextFillRect(context, CGRectMake(404, 24, 2, 4));
}

@end

@implementation IOSUsePlayChromeView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self != nil) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.userInteractionEnabled = NO;
        self.accessibilityElementsHidden = YES;
        _statusSurface = [[IOSUsePlayChromeSurfaceView alloc]
            initWithFrame:IOSUseSystemChromeStatusFrame()
                     kind:IOSUsePlayChromeSurfaceKindStatus];
        _statusSurface.accessibilityIdentifier =
            @"io.ios-use.play-runtime.system-chrome.status";
        _dynamicIslandSurface = [[IOSUsePlayChromeSurfaceView alloc]
            initWithFrame:IOSUseSystemChromeDynamicIslandFrame()
                     kind:IOSUsePlayChromeSurfaceKindDynamicIsland];
        _dynamicIslandSurface.accessibilityIdentifier =
            @"io.ios-use.play-runtime.system-chrome.dynamic-island";
        _homeIndicatorSurface = [[IOSUsePlayChromeSurfaceView alloc]
            initWithFrame:IOSUseSystemChromeHomeIndicatorFrame()
                     kind:IOSUsePlayChromeSurfaceKindHomeIndicator];
        _homeIndicatorSurface.accessibilityIdentifier =
            @"io.ios-use.play-runtime.system-chrome.home-indicator";
        [self addSubview:_statusSurface];
        [self addSubview:_dynamicIslandSurface];
        [self addSubview:_homeIndicatorSurface];
    }
    return self;
}

@end

static UIEdgeInsets IOSUseSystemChromeDeviceSafeArea(void) {
    return UIEdgeInsetsMake(
        IOSUsePlayDeviceSafeAreaTop,
        IOSUsePlayDeviceSafeAreaLeft,
        IOSUsePlayDeviceSafeAreaBottom,
        IOSUsePlayDeviceSafeAreaRight
    );
}

static UIEdgeInsets IOSUseSystemChromeMaximumInsets(
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

static NSDictionary<NSString *, NSNumber *> *IOSUseInsetsJSON(
    UIEdgeInsets insets
) {
    return @{
        @"top": @(insets.top),
        @"left": @(insets.left),
        @"bottom": @(insets.bottom),
        @"right": @(insets.right),
    };
}

static NSDictionary<NSString *, NSNumber *> *IOSUseRectJSON(CGRect rect) {
    return @{
        @"x": @(rect.origin.x),
        @"y": @(rect.origin.y),
        @"width": @(rect.size.width),
        @"height": @(rect.size.height),
    };
}

static BOOL IOSUseSystemChromeScalarMatches(
    CGFloat left,
    CGFloat right
) {
    return isfinite(left) &&
        isfinite(right) &&
        fabs(left - right) <= 0.5;
}

static BOOL IOSUseSystemChromeInsetsMatch(
    UIEdgeInsets left,
    UIEdgeInsets right
) {
    return IOSUseSystemChromeScalarMatches(left.top, right.top) &&
        IOSUseSystemChromeScalarMatches(left.left, right.left) &&
        IOSUseSystemChromeScalarMatches(left.bottom, right.bottom) &&
        IOSUseSystemChromeScalarMatches(left.right, right.right);
}

static BOOL IOSUseSystemChromeRectsMatch(CGRect left, CGRect right) {
    return IOSUseSystemChromeScalarMatches(
            CGRectGetMinX(left),
            CGRectGetMinX(right)
        ) &&
        IOSUseSystemChromeScalarMatches(
            CGRectGetMinY(left),
            CGRectGetMinY(right)
        ) &&
        IOSUseSystemChromeScalarMatches(
            CGRectGetWidth(left),
            CGRectGetWidth(right)
        ) &&
        IOSUseSystemChromeScalarMatches(
            CGRectGetHeight(left),
            CGRectGetHeight(right)
        );
}

static BOOL IOSUseSystemChromeIsAuxiliaryWindow(UIWindow *window) {
    if (window == nil ||
        window == IOSUseSystemChromeWindow ||
        [window.accessibilityIdentifier
            isEqualToString:IOSUseSystemChromeWindowMarker]) {
        return YES;
    }
    NSString *className = NSStringFromClass(window.class);
    for (NSString *fragment in @[
        @"Alert",
        @"Keyboard",
        @"TextEffects",
        @"StatusBar",
        @"SystemChrome",
    ]) {
        if ([className rangeOfString:fragment
                            options:NSCaseInsensitiveSearch].location !=
            NSNotFound) {
            return YES;
        }
    }
    return NO;
}

static BOOL IOSUseSystemChromeIsEligibleAppWindow(
    UIWindow *window,
    UIWindowScene *scene
) {
    return window != nil &&
        window.windowScene == scene &&
        !window.hidden &&
        window.alpha > 0 &&
        window.rootViewController != nil &&
        fabs(window.windowLevel - UIWindowLevelNormal) <= 0.5 &&
        window.bounds.size.width > 0 &&
        window.bounds.size.height > 0 &&
        !IOSUseSystemChromeIsAuxiliaryWindow(window);
}

// This intentionally mirrors pinned PlayTools' foreground-active/key-window
// policy while keeping the prior target stable.  It is named as a replaceable
// boundary for the planned shared IOSUsePlayWindowPolicy extraction.
static UIWindow *IOSUseSystemChromeSelectPrimaryAppWindow(
    UIWindowScene *scene
) {
    UIWindow *existing = IOSUseSystemChromeTargetAppWindow;
    if (IOSUseSystemChromeIsEligibleAppWindow(existing, scene)) {
        return existing;
    }
    for (UIWindow *window in scene.windows) {
        if (window.isKeyWindow &&
            IOSUseSystemChromeIsEligibleAppWindow(window, scene)) {
            return window;
        }
    }
    id delegate = scene.delegate;
    SEL windowSelector = NSSelectorFromString(@"window");
    if ([delegate respondsToSelector:windowSelector]) {
        UIWindow *delegateWindow =
            ((id (*)(id, SEL))objc_msgSend)(delegate, windowSelector);
        if (IOSUseSystemChromeIsEligibleAppWindow(
                delegateWindow,
                scene
            )) {
            return delegateWindow;
        }
    }
    for (UIWindow *window in [scene.windows reverseObjectEnumerator]) {
        if (IOSUseSystemChromeIsEligibleAppWindow(window, scene)) {
            return window;
        }
    }
    return nil;
}

static UIWindowScene *IOSUseSystemChromeSelectForegroundScene(void) {
    UIWindowScene *existing = IOSUseSystemChromeTargetScene;
    if (existing.activationState ==
            UISceneActivationStateForegroundActive &&
        IOSUseSystemChromeSelectPrimaryAppWindow(existing) != nil) {
        return existing;
    }
    NSMutableArray<UIWindowScene *> *scenes = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class] &&
            scene.activationState ==
                UISceneActivationStateForegroundActive &&
            IOSUseSystemChromeSelectPrimaryAppWindow(
                (UIWindowScene *)scene
            ) != nil) {
            [scenes addObject:(UIWindowScene *)scene];
        }
    }
    [scenes sortUsingComparator:^NSComparisonResult(
        UIWindowScene *left,
        UIWindowScene *right
    ) {
        BOOL leftKey =
            IOSUseSystemChromeSelectPrimaryAppWindow(left).isKeyWindow;
        BOOL rightKey =
            IOSUseSystemChromeSelectPrimaryAppWindow(right).isKeyWindow;
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

static UIEdgeInsets IOSUseSystemChromeSafeAreaHook(
    UIWindow *window,
    SEL selector,
    BOOL includeStatusBar
) {
    IOSUseSystemChromeHookInvocationCount += 1;
    UIEdgeInsets original = UIEdgeInsetsZero;
    if (IOSUseSystemChromeOriginalSafeAreaIMP != NULL) {
        original = IOSUseSystemChromeOriginalSafeAreaIMP(
            window,
            selector,
            includeStatusBar
        );
    }
    UIWindow *targetWindow = IOSUseSystemChromeTargetAppWindow;
    UIWindowScene *targetScene = IOSUseSystemChromeTargetScene;
    if (window != targetWindow ||
        window.windowScene != targetScene ||
        targetScene.activationState !=
            UISceneActivationStateForegroundActive) {
        return original;
    }
    IOSUseSystemChromeHookAppliedCount += 1;
    // This is the scene/window base inset. UIKit adds the App controller's
    // existing additionalSafeAreaInsets afterwards, preserving its semantics
    // without reading or writing the App root controller in the hook.
    return IOSUseSystemChromeMaximumInsets(
        original,
        IOSUseSystemChromeDeviceSafeArea()
    );
}

static BOOL IOSUseSystemChromeMethodHasABI(
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

static BOOL IOSUseSystemChromeHookIsActive(void) {
#if TARGET_OS_MACCATALYST
    if (!IOSUseSystemChromeHookAttempted ||
        IOSUseSystemChromeSafeAreaSelector == NULL) {
        return NO;
    }
    Method method = class_getInstanceMethod(
        UIWindow.class,
        IOSUseSystemChromeSafeAreaSelector
    );
    return IOSUseSystemChromeHookInstalled &&
        IOSUseSystemChromeHookABICompatible &&
        method != NULL &&
        method_getImplementation(method) ==
            (IMP)IOSUseSystemChromeSafeAreaHook;
#else
    return YES;
#endif
}

static BOOL IOSUseSystemChromeInstallSafeAreaHook(void) {
    if (IOSUseSystemChromeHookAttempted) {
        if (!IOSUseSystemChromeHookIsActive()) {
#if TARGET_OS_MACCATALYST
            IOSUseSystemChromeHookStatus = @"failed";
            IOSUseSystemChromeHookFailureCode =
                @"safe_area_hook_replaced";
            IOSUseSystemChromeHookFailure =
                @"UIWindow safe-area provider no longer dispatches to "
                @"the installed compatibility hook";
#endif
            return NO;
        }
        return YES;
    }
    IOSUseSystemChromeHookAttempted = YES;
#if !TARGET_OS_MACCATALYST
    IOSUseSystemChromeHookStatus = @"native-uikit";
    IOSUseSystemChromeHookABICompatible = YES;
    return YES;
#else
    IOSUseSystemChromeSafeAreaSelector =
        NSSelectorFromString(IOSUseSystemChromeSafeAreaSelectorName);
    IOSUseSystemChromeInvalidationSelector =
        NSSelectorFromString(IOSUseSystemChromeInvalidationSelectorName);
    Method provider = class_getInstanceMethod(
        UIWindow.class,
        IOSUseSystemChromeSafeAreaSelector
    );
    Method invalidation = class_getInstanceMethod(
        UIWindow.class,
        IOSUseSystemChromeInvalidationSelector
    );
    IOSUseSystemChromeHookABI = provider == NULL
        ? nil
        : [NSString stringWithUTF8String:
            method_getTypeEncoding(provider)];
    if (provider == NULL) {
        IOSUseSystemChromeHookStatus = @"failed";
        IOSUseSystemChromeHookFailureCode =
            @"safe_area_provider_unavailable";
        IOSUseSystemChromeHookFailure =
            @"UIWindow safe-area provider selector is unavailable";
        return NO;
    }
    if (!IOSUseSystemChromeMethodHasABI(
            provider,
            @encode(UIEdgeInsets),
            @encode(BOOL),
            3
        )) {
        IOSUseSystemChromeHookStatus = @"failed";
        IOSUseSystemChromeHookFailureCode =
            @"safe_area_provider_abi_mismatch";
        IOSUseSystemChromeHookFailure =
            @"UIWindow safe-area provider ABI does not match "
            @"UIEdgeInsets(id,SEL,BOOL)";
        return NO;
    }
    if (invalidation == NULL) {
        IOSUseSystemChromeHookStatus = @"failed";
        IOSUseSystemChromeHookFailureCode =
            @"safe_area_invalidation_unavailable";
        IOSUseSystemChromeHookFailure =
            @"UIWindow safe-area invalidation selector is unavailable";
        return NO;
    }
    if (!IOSUseSystemChromeMethodHasABI(
            invalidation,
            @encode(void),
            NULL,
            2
        )) {
        IOSUseSystemChromeHookStatus = @"failed";
        IOSUseSystemChromeHookFailureCode =
            @"safe_area_invalidation_abi_mismatch";
        IOSUseSystemChromeHookFailure =
            @"UIWindow safe-area invalidation ABI is not void(id,SEL)";
        return NO;
    }
    IOSUseSystemChromeOriginalSafeAreaIMP =
        (IOSUseSystemChromeSafeAreaIMP)
            method_getImplementation(provider);
    if (IOSUseSystemChromeOriginalSafeAreaIMP == NULL ||
        (IMP)IOSUseSystemChromeOriginalSafeAreaIMP ==
            (IMP)IOSUseSystemChromeSafeAreaHook) {
        IOSUseSystemChromeHookStatus = @"failed";
        IOSUseSystemChromeHookFailureCode =
            @"safe_area_original_imp_invalid";
        IOSUseSystemChromeHookFailure =
            @"UIWindow safe-area provider original IMP is unavailable";
        return NO;
    }
    IMP replaced = method_setImplementation(
        provider,
        (IMP)IOSUseSystemChromeSafeAreaHook
    );
    if (replaced != (IMP)IOSUseSystemChromeOriginalSafeAreaIMP ||
        method_getImplementation(provider) !=
            (IMP)IOSUseSystemChromeSafeAreaHook) {
        IOSUseSystemChromeHookStatus = @"failed";
        IOSUseSystemChromeHookFailureCode =
            @"safe_area_hook_install_failed";
        IOSUseSystemChromeHookFailure =
            @"UIWindow safe-area provider hook did not install";
        return NO;
    }
    IOSUseSystemChromeHookABICompatible = YES;
    IOSUseSystemChromeHookInstalled = YES;
    IOSUseSystemChromeHookStatus = @"installed";
    IOSUseSystemChromeHookFailureCode = nil;
    IOSUseSystemChromeHookFailure = nil;
    return YES;
#endif
}

static BOOL IOSUseSystemChromeInvalidateSafeArea(UIWindow *window) {
    if (window == nil ||
        IOSUseSystemChromeInvalidationSelector == NULL ||
        ![window respondsToSelector:
            IOSUseSystemChromeInvalidationSelector]) {
        return NO;
    }
    IOSUseSystemChromeSafeAreaInvalidationCount += 1;
    ((void (*)(id, SEL))objc_msgSend)(
        window,
        IOSUseSystemChromeInvalidationSelector
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

static void IOSUseSystemChromeDetachWindow(void) {
    if (IOSUseSystemChromeWindow == nil) {
        return;
    }
    IOSUseSystemChromeWindow.hidden = YES;
    IOSUseSystemChromeWindow.rootViewController = nil;
    IOSUseSystemChromeWindow.windowScene = nil;
    IOSUseSystemChromeWindow = nil;
    IOSUseSystemChromeDetachedWindowCount += 1;
}

static void IOSUseSystemChromeBindTarget(
    UIWindowScene *scene,
    UIWindow *appWindow
) {
    UIWindowScene *oldScene = IOSUseSystemChromeTargetScene;
    UIWindow *oldWindow = IOSUseSystemChromeTargetAppWindow;
    BOOL sceneChanged = oldScene != scene;
    BOOL windowChanged = oldWindow != appWindow;
    if (!sceneChanged && !windowChanged) {
        IOSUseSystemChromeInvalidateSafeArea(appWindow);
        return;
    }

    IOSUseSystemChromeTargetScene = nil;
    IOSUseSystemChromeTargetAppWindow = nil;
    IOSUseSystemChromeInvalidateSafeArea(oldWindow);
    if (sceneChanged && oldScene != nil) {
        IOSUseSystemChromeSceneReplacementCount += 1;
    }
    if (windowChanged && oldWindow != nil) {
        IOSUseSystemChromeWindowReplacementCount += 1;
    }
    if (IOSUseSystemChromeWindow.windowScene != scene) {
        IOSUseSystemChromeDetachWindow();
    }
    IOSUseSystemChromeTargetScene = scene;
    IOSUseSystemChromeTargetAppWindow = appWindow;
    IOSUseSystemChromeInvalidateSafeArea(appWindow);
}

static void IOSUseSystemChromeRefreshTimeSurface(void) {
    NSCAssert(NSThread.isMainThread, @"chrome refresh is main-only");
    if (IOSUseSystemChromeTargetScene.activationState !=
            UISceneActivationStateForegroundActive ||
        IOSUseSystemChromeWindow == nil ||
        IOSUseSystemChromeWindow.hidden) {
        return;
    }
    IOSUsePlayChromeView *chromeView =
        (IOSUsePlayChromeView *)
            IOSUseSystemChromeWindow.rootViewController.view;
    if (![chromeView isKindOfClass:IOSUsePlayChromeView.class]) {
        return;
    }
    IOSUseSystemChromeTimeRefreshCount += 1;
    [chromeView.statusSurface setNeedsDisplay];
    [chromeView.statusSurface.layer displayIfNeeded];
}

static NSDate *IOSUseSystemChromeNextMinuteBoundary(void) {
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSTimeInterval next = (floor(now / 60.0) + 1.0) * 60.0;
    return [NSDate dateWithTimeIntervalSince1970:next];
}

static void IOSUseSystemChromeCalibrateMinuteTimer(void) {
    NSCAssert(NSThread.isMainThread, @"chrome timer is main-only");
    NSDate *nextFireDate = IOSUseSystemChromeNextMinuteBoundary();
    if (IOSUseSystemChromeMinuteTimer == nil ||
        !IOSUseSystemChromeMinuteTimer.valid) {
        IOSUseSystemChromeMinuteTimer = [[NSTimer alloc]
            initWithFireDate:nextFireDate
                    interval:60.0
                     repeats:YES
                       block:^(__unused NSTimer *timer) {
                           IOSUseSystemChromeMinuteTimerFireCount += 1;
                           IOSUseSystemChromeRefreshTimeSurface();
                       }];
        [NSRunLoop.mainRunLoop
            addTimer:IOSUseSystemChromeMinuteTimer
            forMode:NSRunLoopCommonModes];
        IOSUseSystemChromeMinuteTimerInstallCount += 1;
    } else {
        IOSUseSystemChromeMinuteTimer.fireDate = nextFireDate;
    }
    IOSUseSystemChromeMinuteTimerCalibrationCount += 1;
}

static void IOSUseSystemChromeScheduleReconcile(void) {
    IOSUseSystemChromeReconcileRequestCount += 1;
    if (IOSUseSystemChromeReconcileScheduled) {
        return;
    }
    IOSUseSystemChromeReconcileScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        IOSUseSystemChromeReconcileScheduled = NO;
        IOSUseSystemChromeReconcileRunCount += 1;
        IOSUsePlaySystemChromeInstall();
    });
}

static void IOSUseSystemChromeInstallObservers(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray<id> *tokens = [NSMutableArray array];
        for (NSNotificationName name in @[
            UISceneWillEnterForegroundNotification,
            UISceneDidActivateNotification,
            UISceneDidDisconnectNotification,
            UIWindowDidBecomeKeyNotification,
        ]) {
            id token = [
                NSNotificationCenter.defaultCenter
                addObserverForName:name
                            object:nil
                             queue:NSOperationQueue.mainQueue
                        usingBlock:^(
                            __unused NSNotification *notification
                        ) {
                            IOSUseSystemChromeObserverNotificationCount += 1;
                            IOSUseSystemChromeScheduleReconcile();
                        }
            ];
            [tokens addObject:token];
        }
        IOSUseSystemChromeObserverTokens = [tokens copy];
        IOSUseSystemChromeObserverInstallCount += 1;
    });
}

void IOSUsePlaySystemChromeInstall(void) {
    NSCAssert(NSThread.isMainThread, @"system chrome must install on main");
    IOSUseSystemChromeInstallObservers();
    BOOL hookReady = IOSUseSystemChromeInstallSafeAreaHook();
    UIWindowScene *scene = IOSUseSystemChromeSelectForegroundScene();
    if (scene == nil) {
        IOSUseSystemChromeBindTarget(nil, nil);
        IOSUseSystemChromeStage = @"waiting-for-scene";
        IOSUseSystemChromeFailureCode = @"foreground_scene_unavailable";
        IOSUseSystemChromeFailure =
            @"active foreground UIWindowScene is unavailable";
        return;
    }
    UIWindow *appWindow =
        IOSUseSystemChromeSelectPrimaryAppWindow(scene);
    if (appWindow == nil) {
        IOSUseSystemChromeBindTarget(nil, nil);
        IOSUseSystemChromeStage = @"waiting-for-app-window";
        IOSUseSystemChromeFailureCode = @"primary_app_window_unavailable";
        IOSUseSystemChromeFailure =
            @"active foreground scene has no primary App UIWindow";
        return;
    }
    IOSUseSystemChromeBindTarget(scene, appWindow);

    CGRect frame = CGRectMake(
        0,
        0,
        IOSUsePlayDeviceLogicalWidth,
        IOSUsePlayDeviceLogicalHeight
    );
    if (IOSUseSystemChromeWindow == nil) {
        IOSUseSystemChromeWindow =
            [[IOSUsePlayPassthroughWindow alloc] initWithWindowScene:scene];
        IOSUseSystemChromeWindow.accessibilityIdentifier =
            IOSUseSystemChromeWindowMarker;
        IOSUseSystemChromeWindow.windowLevel =
            UIWindowLevelStatusBar + 100;
        UIViewController *controller = [[UIViewController alloc] init];
        controller.view = [[IOSUsePlayChromeView alloc] initWithFrame:frame];
        IOSUseSystemChromeWindow.rootViewController = controller;
    }
    IOSUseSystemChromeWindow.frame = frame;
    IOSUseSystemChromeWindow.rootViewController.view.frame =
        IOSUseSystemChromeWindow.bounds;
    IOSUseSystemChromeWindow.hidden = NO;
    IOSUseSystemChromeWindow.userInteractionEnabled = NO;
    IOSUseSystemChromeWindow.accessibilityElementsHidden = YES;
    IOSUseSystemChromeWindow.backgroundColor = UIColor.clearColor;
    IOSUsePlayChromeView *chromeView =
        (IOSUsePlayChromeView *)
            IOSUseSystemChromeWindow.rootViewController.view;
    [chromeView.dynamicIslandSurface setNeedsDisplay];
    [chromeView.homeIndicatorSurface setNeedsDisplay];
    [chromeView.dynamicIslandSurface.layer displayIfNeeded];
    [chromeView.homeIndicatorSurface.layer displayIfNeeded];
    IOSUseSystemChromeCalibrateMinuteTimer();
    IOSUseSystemChromeRefreshTimeSurface();
    IOSUseSystemChromeInvalidateSafeArea(appWindow);

    NSDictionary<NSString *, id> *diagnostics =
        IOSUsePlaySystemChromeDiagnostics();
    if (!hookReady ||
        ![diagnostics[@"safeAreaCompatibilityReady"] boolValue]) {
        IOSUseSystemChromeStage = @"safe-area-hook-failed";
        IOSUseSystemChromeFailureCode =
            IOSUseSystemChromeHookFailureCode ?:
            @"safe_area_compatibility_failed";
        IOSUseSystemChromeFailure =
            IOSUseSystemChromeHookFailure ?:
            @"window-scoped safe-area compatibility is not active";
    } else if (![diagnostics[@"safeAreaReady"] boolValue]) {
        IOSUseSystemChromeStage = @"waiting-for-safe-area";
        IOSUseSystemChromeFailureCode = [diagnostics[
            @"safeAreaLayoutGuideReady"
        ] boolValue]
            ? @"safe_area_values_mismatch"
            : @"safe_area_layout_guide_mismatch";
        IOSUseSystemChromeFailure =
            @"UIKit safe-area values/layout guide do not match "
            @"the fixed device contract";
    } else if (![diagnostics[@"geometryReady"] boolValue] ||
               ![diagnostics[@"passthrough"] boolValue]) {
        IOSUseSystemChromeStage = @"waiting-for-chrome-window";
        IOSUseSystemChromeFailureCode =
            @"system_chrome_window_invalid";
        IOSUseSystemChromeFailure =
            @"independent system-chrome window is not compositor-ready";
    } else if (![diagnostics[@"dynamicIslandSurface"] boolValue] ||
               ![diagnostics[@"statusSurface"] boolValue] ||
               ![diagnostics[@"homeIndicatorSurface"] boolValue]) {
        IOSUseSystemChromeStage = @"waiting-for-chrome-surfaces";
        IOSUseSystemChromeFailureCode =
            @"system_chrome_surface_invalid";
        IOSUseSystemChromeFailure =
            @"one or more independent chrome surfaces are not live";
    } else if ([diagnostics[@"chromeWindowCount"]
                    unsignedIntegerValue] != 1) {
        IOSUseSystemChromeStage = @"duplicate-chrome-window";
        IOSUseSystemChromeFailureCode =
            @"duplicate_system_chrome_windows";
        IOSUseSystemChromeFailure =
            @"exactly one attached system-chrome window is required";
    } else {
        IOSUseSystemChromeStage = @"installed";
        IOSUseSystemChromeFailureCode = nil;
        IOSUseSystemChromeFailure = nil;
    }
}

NSDictionary<NSString *, id> *IOSUsePlaySystemChromeDiagnostics(void) {
    __block NSDictionary<NSString *, id> *result;
    void (^capture)(void) = ^{
        UIWindowScene *scene = IOSUseSystemChromeTargetScene;
        UIWindow *appWindow = IOSUseSystemChromeTargetAppWindow;
        UIWindowScene *selectedScene =
            IOSUseSystemChromeSelectForegroundScene();
        UIWindow *selectedWindow =
            IOSUseSystemChromeSelectPrimaryAppWindow(selectedScene);
        NSUInteger chromeWindowCount = 0;
        for (UIScene *candidateScene in
             UIApplication.sharedApplication.connectedScenes) {
            if (![candidateScene
                    isKindOfClass:UIWindowScene.class]) {
                continue;
            }
            for (UIWindow *window in
                 ((UIWindowScene *)candidateScene).windows) {
                if ([window.accessibilityIdentifier
                        isEqualToString:
                            IOSUseSystemChromeWindowMarker]) {
                    chromeWindowCount += 1;
                }
            }
        }
        UIViewController *root = appWindow.rootViewController;
        UIView *rootView = root.view;
        UIEdgeInsets windowSafeArea = appWindow.safeAreaInsets;
        UIEdgeInsets rootSafeArea = rootView.safeAreaInsets;
        UIEdgeInsets additionalSafeArea =
            root.additionalSafeAreaInsets;
        UIEdgeInsets originalProviderSafeArea = UIEdgeInsetsZero;
        if (appWindow != nil &&
            IOSUseSystemChromeOriginalSafeAreaIMP != NULL) {
            originalProviderSafeArea =
                IOSUseSystemChromeOriginalSafeAreaIMP(
                    appWindow,
                    IOSUseSystemChromeSafeAreaSelector,
                    YES
                );
        }
        UIEdgeInsets expectedWindowSafeArea =
            IOSUseSystemChromeMaximumInsets(
                originalProviderSafeArea,
                IOSUseSystemChromeDeviceSafeArea()
            );
        UIEdgeInsets expectedRootSafeArea = UIEdgeInsetsMake(
            expectedWindowSafeArea.top + additionalSafeArea.top,
            expectedWindowSafeArea.left + additionalSafeArea.left,
            expectedWindowSafeArea.bottom + additionalSafeArea.bottom,
            expectedWindowSafeArea.right + additionalSafeArea.right
        );
        CGRect expectedLayoutFrame = UIEdgeInsetsInsetRect(
            rootView.bounds,
            expectedRootSafeArea
        );
        CGRect layoutFrame =
            rootView.safeAreaLayoutGuide.layoutFrame;
        Method provider = NULL;
#if TARGET_OS_MACCATALYST
        if (IOSUseSystemChromeSafeAreaSelector != NULL) {
            provider = class_getInstanceMethod(
                UIWindow.class,
                IOSUseSystemChromeSafeAreaSelector
            );
        }
#endif
        BOOL classHookReady =
#if TARGET_OS_MACCATALYST
            provider != NULL &&
            method_getImplementation(provider) ==
                (IMP)IOSUseSystemChromeSafeAreaHook;
#else
            YES;
#endif
        BOOL targetDispatchesHook =
#if TARGET_OS_MACCATALYST
            IOSUseSystemChromeSafeAreaSelector != NULL &&
            appWindow != nil &&
            class_getMethodImplementation(
                appWindow.class,
                IOSUseSystemChromeSafeAreaSelector
            ) == (IMP)IOSUseSystemChromeSafeAreaHook;
#else
            YES;
#endif
        BOOL safeAreaCompatibilityReady =
            IOSUseSystemChromeHookIsActive() &&
            classHookReady &&
            targetDispatchesHook;
        BOOL additionalSafeAreaPreserved =
            IOSUseSystemChromeInsetsMatch(
                rootSafeArea,
                expectedRootSafeArea
            );
        BOOL layoutGuideReady =
            IOSUseSystemChromeRectsMatch(
                layoutFrame,
                expectedLayoutFrame
            );
        BOOL safeAreaReady =
            scene != nil &&
            appWindow != nil &&
            selectedScene == scene &&
            selectedWindow == appWindow &&
            safeAreaCompatibilityReady &&
            IOSUseSystemChromeInsetsMatch(
                windowSafeArea,
                expectedWindowSafeArea
            ) &&
            additionalSafeAreaPreserved &&
            layoutGuideReady;
        BOOL geometry =
            IOSUseSystemChromeRectsMatch(
                IOSUseSystemChromeWindow.frame,
                CGRectMake(
                    0,
                    0,
                    IOSUsePlayDeviceLogicalWidth,
                    IOSUsePlayDeviceLogicalHeight
                )
            ) &&
            IOSUseSystemChromeRectsMatch(
                IOSUseSystemChromeWindow.bounds,
                CGRectMake(
                    0,
                    0,
                    IOSUsePlayDeviceLogicalWidth,
                    IOSUsePlayDeviceLogicalHeight
                )
            );
        CGPoint probe = CGPointMake(
            IOSUsePlayDeviceLogicalWidth / 2.0,
            IOSUsePlayDeviceLogicalHeight / 2.0
        );
        BOOL passthrough =
            IOSUseSystemChromeWindow != nil &&
            !IOSUseSystemChromeWindow.userInteractionEnabled &&
            !IOSUseSystemChromeWindow.isKeyWindow &&
            [IOSUseSystemChromeWindow
                hitTest:probe
              withEvent:nil] == nil &&
            [IOSUseSystemChromeWindow
                isKindOfClass:IOSUsePlayPassthroughWindow.class];
        IOSUsePlayChromeView *chromeView =
            (IOSUsePlayChromeView *)
                IOSUseSystemChromeWindow.rootViewController.view;
        BOOL chromeViewReady =
            IOSUseSystemChromeWindow != nil &&
            !IOSUseSystemChromeWindow.hidden &&
            [chromeView isKindOfClass:IOSUsePlayChromeView.class];
        BOOL dynamicIslandSurface =
            chromeViewReady &&
            chromeView.dynamicIslandSurface.superview == chromeView &&
            !chromeView.dynamicIslandSurface.hidden &&
            chromeView.dynamicIslandSurface.alpha > 0 &&
            chromeView.dynamicIslandSurface.kind ==
                IOSUsePlayChromeSurfaceKindDynamicIsland &&
            IOSUseSystemChromeRectsMatch(
                chromeView.dynamicIslandSurface.frame,
                IOSUseSystemChromeDynamicIslandFrame()
            );
        BOOL statusSurface =
            chromeViewReady &&
            chromeView.statusSurface.superview == chromeView &&
            !chromeView.statusSurface.hidden &&
            chromeView.statusSurface.alpha > 0 &&
            chromeView.statusSurface.kind ==
                IOSUsePlayChromeSurfaceKindStatus &&
            IOSUseSystemChromeRectsMatch(
                chromeView.statusSurface.frame,
                IOSUseSystemChromeStatusFrame()
            ) &&
            IOSUseSystemChromeTimeRefreshCount > 0 &&
            IOSUseSystemChromeMinuteTimer.valid;
        BOOL homeIndicatorSurface =
            chromeViewReady &&
            chromeView.homeIndicatorSurface.superview == chromeView &&
            !chromeView.homeIndicatorSurface.hidden &&
            chromeView.homeIndicatorSurface.alpha > 0 &&
            chromeView.homeIndicatorSurface.kind ==
                IOSUsePlayChromeSurfaceKindHomeIndicator &&
            IOSUseSystemChromeRectsMatch(
                chromeView.homeIndicatorSurface.frame,
                IOSUseSystemChromeHomeIndicatorFrame()
            );
        result = @{
            @"stage": IOSUseSystemChromeStage,
            @"failureCode":
                IOSUseSystemChromeFailureCode ?: NSNull.null,
            @"failure": IOSUseSystemChromeFailure ?: NSNull.null,
            @"windowAttached": @(
                IOSUseSystemChromeWindow.windowScene == scene &&
                scene != nil
            ),
            @"chromeWindowCount": @(chromeWindowCount),
            @"passthrough": @(passthrough),
            @"geometryReady": @(geometry),
            @"safeAreaReady": @(safeAreaReady),
            @"safeAreaCompatibilityReady":
                @(safeAreaCompatibilityReady),
            @"safeAreaLayoutGuideReady": @(layoutGuideReady),
            @"additionalSafeAreaPreserved":
                @(additionalSafeAreaPreserved),
            @"safeArea": IOSUseInsetsJSON(rootSafeArea),
            @"windowSafeArea": IOSUseInsetsJSON(windowSafeArea),
            @"originalProviderSafeArea":
                IOSUseInsetsJSON(originalProviderSafeArea),
            @"expectedWindowSafeArea":
                IOSUseInsetsJSON(expectedWindowSafeArea),
            @"additionalSafeArea":
                IOSUseInsetsJSON(additionalSafeArea),
            @"expectedRootSafeArea":
                IOSUseInsetsJSON(expectedRootSafeArea),
            @"safeAreaLayoutFrame":
                IOSUseRectJSON(layoutFrame),
            @"expectedSafeAreaLayoutFrame":
                IOSUseRectJSON(expectedLayoutFrame),
            @"runtimeAdditionalSafeAreaWriteCount": @0,
            @"lastImageEvidence":
                IOSUseSystemChromeLastImageEvidence ?: NSNull.null,
            @"selection": @{
                @"policy":
                    @"pinned-playtools-foreground-active-primary-key",
                @"sceneMatches": @(selectedScene == scene),
                @"windowMatches": @(selectedWindow == appWindow),
                @"sceneIdentifier":
                    scene.session.persistentIdentifier ?: NSNull.null,
                @"appWindowClass":
                    appWindow == nil
                        ? NSNull.null
                        : NSStringFromClass(appWindow.class),
                @"appWindowIsKey": @(appWindow.isKeyWindow),
            },
            @"compatibilityHook": @{
                @"status": IOSUseSystemChromeHookStatus,
                @"failureCode":
                    IOSUseSystemChromeHookFailureCode ?: NSNull.null,
                @"failure":
                    IOSUseSystemChromeHookFailure ?: NSNull.null,
                @"selector":
                    IOSUseSystemChromeSafeAreaSelectorName,
                @"invalidationSelector":
                    IOSUseSystemChromeInvalidationSelectorName,
                @"abi":
                    IOSUseSystemChromeHookABI ?: NSNull.null,
                @"abiCompatible":
                    @(IOSUseSystemChromeHookABICompatible),
                @"originalIMPRecorded": @(
                    IOSUseSystemChromeOriginalSafeAreaIMP != NULL
                ),
                @"classHookActive": @(classHookReady),
                @"targetDispatchesHook":
                    @(targetDispatchesHook),
                @"scope":
                    @"active-foreground-primary-app-window-only",
                @"platformCondition":
#if TARGET_OS_MACCATALYST
                    @"macCatalyst",
#else
                    @"native-uikit",
#endif
                @"invocations":
                    @(IOSUseSystemChromeHookInvocationCount),
                @"applied":
                    @(IOSUseSystemChromeHookAppliedCount),
                @"invalidations":
                    @(IOSUseSystemChromeSafeAreaInvalidationCount),
            },
            @"lifecycle": @{
                @"observerInstallCount":
                    @(IOSUseSystemChromeObserverInstallCount),
                @"observerTokenCount":
                    @(IOSUseSystemChromeObserverTokens.count),
                @"observerNotifications":
                    @(IOSUseSystemChromeObserverNotificationCount),
                @"reconcileRequests":
                    @(IOSUseSystemChromeReconcileRequestCount),
                @"reconcileRuns":
                    @(IOSUseSystemChromeReconcileRunCount),
                @"sceneReplacements":
                    @(IOSUseSystemChromeSceneReplacementCount),
                @"windowReplacements":
                    @(IOSUseSystemChromeWindowReplacementCount),
                @"detachedChromeWindows":
                    @(IOSUseSystemChromeDetachedWindowCount),
                @"observerDeduplicated": @(
                    IOSUseSystemChromeObserverInstallCount == 1 &&
                    IOSUseSystemChromeObserverTokens.count == 4
                ),
                @"minuteTimerInstallCount":
                    @(IOSUseSystemChromeMinuteTimerInstallCount),
                @"minuteTimerCalibrationCount":
                    @(IOSUseSystemChromeMinuteTimerCalibrationCount),
                @"minuteTimerFireCount":
                    @(IOSUseSystemChromeMinuteTimerFireCount),
                @"timeRefreshCount":
                    @(IOSUseSystemChromeTimeRefreshCount),
                @"minuteTimerValid":
                    @(IOSUseSystemChromeMinuteTimer.valid),
                @"minuteTimerNextFire":
                    IOSUseSystemChromeMinuteTimer.fireDate == nil
                        ? NSNull.null
                        : @(
                            IOSUseSystemChromeMinuteTimer.fireDate
                                .timeIntervalSince1970
                        ),
                @"minuteTimerUnique": @(
                    IOSUseSystemChromeMinuteTimerInstallCount == 1 &&
                    IOSUseSystemChromeMinuteTimer.valid
                ),
            },
            @"dynamicIslandSurface": @(dynamicIslandSurface),
            @"statusSurface": @(statusSurface),
            @"homeIndicatorSurface": @(homeIndicatorSurface),
            @"surfaceEvidence": @{
                @"dynamicIsland": @{
                    @"class":
                        chromeView.dynamicIslandSurface == nil
                            ? NSNull.null
                            : NSStringFromClass(
                                chromeView.dynamicIslandSurface.class
                            ),
                    @"frame": IOSUseRectJSON(
                        chromeView.dynamicIslandSurface.frame
                    ),
                    @"ready": @(dynamicIslandSurface),
                },
                @"status": @{
                    @"class":
                        chromeView.statusSurface == nil
                            ? NSNull.null
                            : NSStringFromClass(
                                chromeView.statusSurface.class
                            ),
                    @"frame": IOSUseRectJSON(
                        chromeView.statusSurface.frame
                    ),
                    @"timeRefreshCount":
                        @(IOSUseSystemChromeTimeRefreshCount),
                    @"ready": @(statusSurface),
                },
                @"homeIndicator": @{
                    @"class":
                        chromeView.homeIndicatorSurface == nil
                            ? NSNull.null
                            : NSStringFromClass(
                                chromeView.homeIndicatorSurface.class
                            ),
                    @"frame": IOSUseRectJSON(
                        chromeView.homeIndicatorSurface.frame
                    ),
                    @"ready": @(homeIndicatorSurface),
                },
            },
        };
    };
    if (NSThread.isMainThread) {
        capture();
    } else {
        dispatch_sync(dispatch_get_main_queue(), capture);
    }
    return result ?: @{};
}

typedef struct {
    NSUInteger samples;
    NSUInteger darkSamples;
    NSUInteger lightSamples;
    NSUInteger edgeTransitions;
    NSUInteger dimmedEdgeTransitions;
    CGFloat minimum;
    CGFloat maximum;
    CGFloat mean;
} IOSUseSystemChromePixelEvidence;

static CGFloat IOSUseSystemChromePixelLuminance(
    const uint8_t *pixels,
    size_t rowBytes,
    NSInteger x,
    NSInteger y
) {
    const uint8_t *pixel =
        pixels + (NSUInteger)y * rowBytes + (NSUInteger)x * 4;
    return 0.2126 * pixel[2] +
        0.7152 * pixel[1] +
        0.0722 * pixel[0];
}

static IOSUseSystemChromePixelEvidence
IOSUseSystemChromeMeasureRegion(
    const uint8_t *pixels,
    size_t rowBytes,
    CGRect region,
    CGFloat scale
) {
    IOSUseSystemChromePixelEvidence evidence = {
        .minimum = CGFLOAT_MAX,
        .maximum = -CGFLOAT_MAX,
    };
    NSInteger minX = (NSInteger)floor(CGRectGetMinX(region) * scale);
    NSInteger maxX = (NSInteger)ceil(CGRectGetMaxX(region) * scale);
    NSInteger minY = (NSInteger)floor(CGRectGetMinY(region) * scale);
    NSInteger maxY = (NSInteger)ceil(CGRectGetMaxY(region) * scale);
    for (NSInteger y = minY; y < maxY; y += 2) {
        for (NSInteger x = minX; x < maxX; x += 2) {
            CGFloat luminance = IOSUseSystemChromePixelLuminance(
                pixels,
                rowBytes,
                x,
                y
            );
            evidence.minimum = MIN(evidence.minimum, luminance);
            evidence.maximum = MAX(evidence.maximum, luminance);
            evidence.darkSamples += luminance < 45 ? 1 : 0;
            evidence.lightSamples += luminance > 210 ? 1 : 0;
            evidence.mean += luminance;
            evidence.samples += 1;
            if (x + 2 < maxX) {
                CGFloat neighbor =
                    IOSUseSystemChromePixelLuminance(
                        pixels,
                        rowBytes,
                        x + 2,
                        y
                );
                evidence.edgeTransitions +=
                    fabs(luminance - neighbor) >= 55 ? 1 : 0;
                evidence.dimmedEdgeTransitions +=
                    fabs(luminance - neighbor) >= 12 ? 1 : 0;
            }
            if (y + 2 < maxY) {
                CGFloat neighbor =
                    IOSUseSystemChromePixelLuminance(
                        pixels,
                        rowBytes,
                        x,
                        y + 2
                );
                evidence.edgeTransitions +=
                    fabs(luminance - neighbor) >= 55 ? 1 : 0;
                evidence.dimmedEdgeTransitions +=
                    fabs(luminance - neighbor) >= 12 ? 1 : 0;
            }
        }
    }
    if (evidence.samples == 0) {
        evidence.minimum = 0;
        evidence.maximum = 0;
    } else {
        evidence.mean /= evidence.samples;
    }
    return evidence;
}

static NSDictionary<NSString *, NSNumber *> *
IOSUseSystemChromePixelEvidenceJSON(
    IOSUseSystemChromePixelEvidence evidence
) {
    return @{
        @"samples": @(evidence.samples),
        @"darkSamples": @(evidence.darkSamples),
        @"lightSamples": @(evidence.lightSamples),
        @"edgeTransitions": @(evidence.edgeTransitions),
        @"dimmedEdgeTransitions": @(evidence.dimmedEdgeTransitions),
        @"minimumLuminance": @(evidence.minimum),
        @"maximumLuminance": @(evidence.maximum),
        @"meanLuminance": @(evidence.mean),
    };
}

static IOSUseSystemChromePixelEvidence
IOSUseSystemChromeMeasureIslandPeriphery(
    const uint8_t *pixels,
    size_t rowBytes,
    CGRect island,
    CGFloat scale
) {
    CGRect regions[] = {
        CGRectMake(
            CGRectGetMinX(island) + 20,
            CGRectGetMinY(island) - 4,
            CGRectGetWidth(island) - 40,
            3
        ),
        CGRectMake(
            CGRectGetMinX(island) + 20,
            CGRectGetMaxY(island) + 1,
            CGRectGetWidth(island) - 40,
            3
        ),
        CGRectMake(
            CGRectGetMinX(island) - 4,
            CGRectGetMinY(island) + 10,
            3,
            CGRectGetHeight(island) - 20
        ),
        CGRectMake(
            CGRectGetMaxX(island) + 1,
            CGRectGetMinY(island) + 10,
            3,
            CGRectGetHeight(island) - 20
        ),
    };
    IOSUseSystemChromePixelEvidence combined = {
        .minimum = CGFLOAT_MAX,
        .maximum = -CGFLOAT_MAX,
    };
    for (NSUInteger index = 0;
         index < sizeof(regions) / sizeof(regions[0]);
         index += 1) {
        IOSUseSystemChromePixelEvidence measured =
            IOSUseSystemChromeMeasureRegion(
                pixels,
                rowBytes,
                regions[index],
                scale
            );
        combined.samples += measured.samples;
        combined.darkSamples += measured.darkSamples;
        combined.lightSamples += measured.lightSamples;
        combined.edgeTransitions += measured.edgeTransitions;
        combined.dimmedEdgeTransitions +=
            measured.dimmedEdgeTransitions;
        combined.minimum = MIN(combined.minimum, measured.minimum);
        combined.maximum = MAX(combined.maximum, measured.maximum);
        combined.mean += measured.mean * measured.samples;
    }
    if (combined.samples == 0) {
        combined.minimum = 0;
        combined.maximum = 0;
    } else {
        combined.mean /= combined.samples;
    }
    return combined;
}

NSDictionary<NSString *, id> *
IOSUsePlaySystemChromeImageEvidence(CGImageRef image) {
    if (image == NULL ||
        CGImageGetWidth(image) != IOSUsePlayDeviceNativeWidth ||
        CGImageGetHeight(image) != IOSUsePlayDeviceNativeHeight) {
        return @{
            @"geometryReady": @NO,
            @"failureCode": @"invalid_image_geometry",
        };
    }
    size_t width = CGImageGetWidth(image);
    size_t height = CGImageGetHeight(image);
    size_t rowBytes = width * 4;
    NSMutableData *storage =
        [NSMutableData dataWithLength:rowBytes * height];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(
        storage.mutableBytes,
        width,
        height,
        8,
        rowBytes,
        colorSpace,
        kCGBitmapByteOrder32Little |
            kCGImageAlphaPremultipliedFirst
    );
    CGColorSpaceRelease(colorSpace);
    if (context == NULL) {
        return @{
            @"geometryReady": @NO,
            @"failureCode": @"pixel_context_unavailable",
        };
    }
    CGContextDrawImage(
        context,
        CGRectMake(0, 0, width, height),
        image
    );
    CGContextRelease(context);
    CGFloat scale = IOSUsePlayDeviceScale;
    CGRect island = IOSUseSystemChromeDynamicIslandFrame();
    CGRect islandCenter = CGRectInset(island, 12, 7);
    CGRect timeRegion = CGRectMake(23, 14, 90, 27);
    CGRect glyphRegion = CGRectMake(322, 14, 87, 24);
    CGRect home = IOSUseSystemChromeHomeIndicatorFrame();
    CGRect homeCenter = CGRectInset(home, 10, 0);
    CGRect homeAbove = CGRectMake(
        CGRectGetMinX(homeCenter),
        CGRectGetMinY(home) - 4,
        CGRectGetWidth(homeCenter),
        3
    );
    CGRect homeBelow = CGRectMake(
        CGRectGetMinX(homeCenter),
        CGRectGetMaxY(home) + 1,
        CGRectGetWidth(homeCenter),
        3
    );
    const uint8_t *pixels = storage.bytes;
    IOSUseSystemChromePixelEvidence islandCenterEvidence =
        IOSUseSystemChromeMeasureRegion(
            pixels,
            rowBytes,
            islandCenter,
            scale
        );
    IOSUseSystemChromePixelEvidence islandPeripheryEvidence =
        IOSUseSystemChromeMeasureIslandPeriphery(
            pixels,
            rowBytes,
            island,
            scale
        );
    IOSUseSystemChromePixelEvidence timeEvidence =
        IOSUseSystemChromeMeasureRegion(
            pixels,
            rowBytes,
            timeRegion,
            scale
        );
    IOSUseSystemChromePixelEvidence glyphEvidence =
        IOSUseSystemChromeMeasureRegion(
            pixels,
            rowBytes,
            glyphRegion,
            scale
        );
    IOSUseSystemChromePixelEvidence homeCenterEvidence =
        IOSUseSystemChromeMeasureRegion(
            pixels,
            rowBytes,
            homeCenter,
            scale
        );
    IOSUseSystemChromePixelEvidence homeAboveEvidence =
        IOSUseSystemChromeMeasureRegion(
            pixels,
            rowBytes,
            homeAbove,
            scale
        );
    IOSUseSystemChromePixelEvidence homeBelowEvidence =
        IOSUseSystemChromeMeasureRegion(
            pixels,
            rowBytes,
            homeBelow,
            scale
        );
    CGFloat homePeripheryMean =
        (
            homeAboveEvidence.mean * homeAboveEvidence.samples +
            homeBelowEvidence.mean * homeBelowEvidence.samples
        ) / MAX(
            (NSUInteger)1,
            homeAboveEvidence.samples + homeBelowEvidence.samples
        );

    BOOL islandPixelObservable =
        islandPeripheryEvidence.samples >= 32 &&
        islandPeripheryEvidence.mean >= 25;
    BOOL islandCenterDark =
        islandCenterEvidence.samples >= 128 &&
        islandCenterEvidence.darkSamples * 100 /
            MAX((NSUInteger)1, islandCenterEvidence.samples) >= 80;
    BOOL islandPixelSignature =
        islandPixelObservable &&
        islandCenterDark &&
        islandPeripheryEvidence.mean -
            islandCenterEvidence.mean >= 25;
    BOOL islandDimmedPixelSignature =
        islandPixelObservable &&
        islandCenterEvidence.mean <=
            islandPeripheryEvidence.mean * 0.75 &&
        islandPeripheryEvidence.mean -
            islandCenterEvidence.mean >= 8;
    BOOL timePixelSignature =
        timeEvidence.samples >= 256 &&
        timeEvidence.maximum - timeEvidence.minimum >= 90 &&
        timeEvidence.edgeTransitions >= 24;
    BOOL glyphPixelSignature =
        glyphEvidence.samples >= 256 &&
        glyphEvidence.maximum - glyphEvidence.minimum >= 90 &&
        glyphEvidence.edgeTransitions >= 32;
    BOOL homePixelSignature =
        homeCenterEvidence.samples >= 128 &&
        fabs(homeCenterEvidence.mean - homePeripheryMean) >= 45;
    BOOL timeDimmedPixelSignature =
        timeEvidence.samples >= 256 &&
        timeEvidence.maximum - timeEvidence.minimum >= 24 &&
        timeEvidence.dimmedEdgeTransitions >= 24;
    BOOL glyphDimmedPixelSignature =
        glyphEvidence.samples >= 256 &&
        glyphEvidence.maximum - glyphEvidence.minimum >= 24 &&
        glyphEvidence.dimmedEdgeTransitions >= 32;
    BOOL homeDimmedPixelSignature =
        homeCenterEvidence.samples >= 128 &&
        fabs(homeCenterEvidence.mean - homePeripheryMean) >= 12;
    return @{
        @"geometryReady": @YES,
        @"dynamicIsland": @{
            @"pixelObservable": @(islandPixelObservable),
            @"pixelSignature": @(islandPixelSignature),
            @"dimmedPixelSignature":
                @(islandDimmedPixelSignature),
            @"center":
                IOSUseSystemChromePixelEvidenceJSON(
                    islandCenterEvidence
                ),
            @"periphery":
                IOSUseSystemChromePixelEvidenceJSON(
                    islandPeripheryEvidence
                ),
        },
        @"statusTime": @{
            @"pixelSignature": @(timePixelSignature),
            @"dimmedPixelSignature":
                @(timeDimmedPixelSignature),
            @"evidence":
                IOSUseSystemChromePixelEvidenceJSON(timeEvidence),
        },
        @"statusGlyphs": @{
            @"pixelSignature": @(glyphPixelSignature),
            @"dimmedPixelSignature":
                @(glyphDimmedPixelSignature),
            @"evidence":
                IOSUseSystemChromePixelEvidenceJSON(glyphEvidence),
        },
        @"homeIndicator": @{
            @"pixelSignature": @(homePixelSignature),
            @"dimmedPixelSignature":
                @(homeDimmedPixelSignature),
            @"center":
                IOSUseSystemChromePixelEvidenceJSON(
                    homeCenterEvidence
                ),
            @"above":
                IOSUseSystemChromePixelEvidenceJSON(
                    homeAboveEvidence
                ),
            @"below":
                IOSUseSystemChromePixelEvidenceJSON(
                    homeBelowEvidence
                ),
            @"peripheryMean": @(homePeripheryMean),
        },
    };
}

static BOOL IOSUseSystemChromeNativeAlertVisible(void) {
    Class bridgeClass = NSClassFromString(@"IOSUsePlayAppKitBridge");
    SEL selector = NSSelectorFromString(@"hasVisibleNativeAlert");
    if (bridgeClass == Nil ||
        ![(id)bridgeClass respondsToSelector:selector]) {
        return NO;
    }
    @try {
        return ((BOOL (*)(id, SEL))objc_msgSend)(
            (id)bridgeClass,
            selector
        );
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

BOOL IOSUsePlaySystemChromeVerifyImage(
    CGImageRef image,
    NSString **failure
) {
    NSDictionary<NSString *, id> *pixelEvidence =
        IOSUsePlaySystemChromeImageEvidence(image);
    if (![pixelEvidence[@"geometryReady"] boolValue]) {
        IOSUseSystemChromeLastImageEvidence = pixelEvidence;
        if (failure != NULL) {
            *failure = [pixelEvidence[@"failureCode"]
                isEqualToString:@"pixel_context_unavailable"]
                ? @"could not inspect compositor pixels"
                : [NSString stringWithFormat:
                    @"compositor image geometry is not %ldx%ld",
                    (long)IOSUsePlayDeviceNativeWidth,
                    (long)IOSUsePlayDeviceNativeHeight];
        }
        return NO;
    }

    NSDictionary<NSString *, id> *diagnostics =
        IOSUsePlaySystemChromeDiagnostics();
    BOOL liveIsland =
        [diagnostics[@"dynamicIslandSurface"] boolValue];
    BOOL liveStatus = [diagnostics[@"statusSurface"] boolValue];
    BOOL liveHome =
        [diagnostics[@"homeIndicatorSurface"] boolValue];
    NSDictionary<NSString *, id> *islandPixels =
        pixelEvidence[@"dynamicIsland"];
    BOOL islandPixelObservable =
        [islandPixels[@"pixelObservable"] boolValue];
    BOOL islandPixelSignature =
        [islandPixels[@"pixelSignature"] boolValue];
    BOOL timePixelSignature =
        [pixelEvidence[@"statusTime"][@"pixelSignature"] boolValue];
    BOOL glyphPixelSignature =
        [pixelEvidence[@"statusGlyphs"][@"pixelSignature"] boolValue];
    BOOL homePixelSignature =
        [pixelEvidence[@"homeIndicator"][@"pixelSignature"] boolValue];
    BOOL nativeAlertVisible =
        IOSUseSystemChromeNativeAlertVisible();
    BOOL islandDimmedPixelSignature =
        [islandPixels[@"dimmedPixelSignature"] boolValue];
    BOOL timeDimmedPixelSignature =
        [pixelEvidence[@"statusTime"][@"dimmedPixelSignature"] boolValue];
    BOOL glyphDimmedPixelSignature =
        [pixelEvidence[@"statusGlyphs"][@"dimmedPixelSignature"] boolValue];
    BOOL homeDimmedPixelSignature =
        [pixelEvidence[@"homeIndicator"][@"dimmedPixelSignature"] boolValue];
    BOOL modalDimmedSignatures =
        nativeAlertVisible &&
        (islandDimmedPixelSignature || !islandPixelObservable) &&
        timeDimmedPixelSignature &&
        glyphDimmedPixelSignature &&
        homeDimmedPixelSignature;
    BOOL islandAccepted =
        islandPixelSignature ||
        (!islandPixelObservable && liveIsland) ||
        modalDimmedSignatures;
    NSString *islandFallbackReason =
        !islandPixelObservable && liveIsland
            ? @"black/dark compositor background makes a black Island "
              @"pixel-indistinguishable; accepted only with the live "
              @"independent Island surface plus same-frame status/home "
              @"pixel signatures"
            : @"none";
    BOOL liveSurfaces =
        liveIsland &&
        liveStatus &&
        liveHome &&
        [diagnostics[@"passthrough"] boolValue] &&
        [diagnostics[@"safeAreaReady"] boolValue];
    BOOL ready = liveSurfaces &&
        (
            (
                islandAccepted &&
                timePixelSignature &&
                glyphPixelSignature &&
                homePixelSignature
            ) ||
            modalDimmedSignatures
        );
    NSMutableDictionary<NSString *, id> *combined =
        [pixelEvidence mutableCopy];
    NSMutableDictionary<NSString *, id> *combinedIsland =
        [islandPixels mutableCopy];
    combinedIsland[@"liveSurface"] = @(liveIsland);
    combinedIsland[@"accepted"] = @(islandAccepted);
    combinedIsland[@"fallbackReason"] = islandFallbackReason;
    combined[@"dynamicIsland"] = combinedIsland;
    NSMutableDictionary<NSString *, id> *combinedTime =
        [pixelEvidence[@"statusTime"] mutableCopy];
    combinedTime[@"liveSurface"] = @(liveStatus);
    combined[@"statusTime"] = combinedTime;
    NSMutableDictionary<NSString *, id> *combinedGlyphs =
        [pixelEvidence[@"statusGlyphs"] mutableCopy];
    combinedGlyphs[@"liveSurface"] = @(liveStatus);
    combined[@"statusGlyphs"] = combinedGlyphs;
    NSMutableDictionary<NSString *, id> *combinedHome =
        [pixelEvidence[@"homeIndicator"] mutableCopy];
    combinedHome[@"liveSurface"] = @(liveHome);
    combined[@"homeIndicator"] = combinedHome;
    combined[@"liveSurfacesReady"] = @(liveSurfaces);
    combined[@"nativeAlertVisible"] = @(nativeAlertVisible);
    combined[@"modalDimmedSignatures"] =
        @(modalDimmedSignatures);
    combined[@"ready"] = @(ready);
    IOSUseSystemChromeLastImageEvidence = [combined copy];
    if (!ready && failure != NULL) {
        *failure = [NSString stringWithFormat:
            @"compositor chrome signatures failed "
             "island=%d(observable=%d live=%d) "
             "time=%d glyphs=%d home=%d liveSurfaces=%d "
             "nativeAlert=%d modalDimmed=%d",
            islandPixelSignature,
            islandPixelObservable,
            liveIsland,
            timePixelSignature,
            glyphPixelSignature,
            homePixelSignature,
            liveSurfaces,
            nativeAlertVisible,
            modalDimmedSignatures
        ];
    }
    return ready;
}
