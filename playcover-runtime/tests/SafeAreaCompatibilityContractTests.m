#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "IOSUsePlayDevice.h"
#import "IOSUsePlaySafeAreaCompatibility.h"

extern UIEdgeInsets IOSUsePlaySafeAreaMaximumInsetsForTesting(
    UIEdgeInsets left,
    UIEdgeInsets right
);
extern BOOL IOSUsePlaySafeAreaMethodHasABIForTesting(
    Method method,
    const char *returnType,
    const char *lastArgumentType,
    unsigned int argumentCount
);
extern UIEdgeInsets IOSUsePlaySafeAreaProviderInsetsForTesting(
    UIEdgeInsets original,
    BOOL includeStatusBar
);
extern BOOL
IOSUsePlaySafeAreaSceneActivationStateSupportsFixedGeometryForTesting(
    UISceneActivationState state
);
extern BOOL
IOSUsePlaySafeAreaPreBindActivationStateSupportsFixedGeometryForTesting(
    UISceneActivationState state,
    BOOL targetBound,
    BOOL attachedPrimaryWindow
);
extern Class IOSUsePlaySafeAreaMethodOwnerForTesting(
    Class receiverClass,
    SEL selector
);
extern BOOL IOSUsePlaySafeAreaClassDispatchesIMPForTesting(
    Class receiverClass,
    SEL selector,
    IMP expected
);
@interface IOSUsePlaySafeAreaABIFixture : NSObject
- (UIEdgeInsets)provider:(BOOL)includeStatusBar;
- (void)invalidate;
- (CGRect)wrongProvider:(BOOL)includeStatusBar;
- (void)wrongInvalidation:(BOOL)value;
@end

@interface IOSUsePlaySafeAreaMethodOwnerFixture : NSObject
- (UIEdgeInsets)provider:(BOOL)includeStatusBar;
@end

@implementation IOSUsePlaySafeAreaMethodOwnerFixture
- (UIEdgeInsets)provider:(BOOL)includeStatusBar {
    return includeStatusBar
        ? UIEdgeInsetsMake(1, 2, 3, 4)
        : UIEdgeInsetsZero;
}
@end

@interface IOSUsePlaySafeAreaInheritedFixture :
    IOSUsePlaySafeAreaMethodOwnerFixture
@end

@implementation IOSUsePlaySafeAreaInheritedFixture
@end

@interface IOSUsePlaySafeAreaOverrideFixture :
    IOSUsePlaySafeAreaMethodOwnerFixture
@end

@implementation IOSUsePlaySafeAreaOverrideFixture
- (UIEdgeInsets)provider:(BOOL)includeStatusBar {
    return includeStatusBar
        ? UIEdgeInsetsMake(5, 6, 7, 8)
        : UIEdgeInsetsZero;
}
@end

static UIEdgeInsets IOSUsePlaySafeAreaFixtureReplacement(
    __unused id receiver,
    __unused SEL selector,
    BOOL includeStatusBar
) {
    return includeStatusBar
        ? UIEdgeInsetsMake(59, 0, 34, 0)
        : UIEdgeInsetsMake(0, 0, 34, 0);
}

static UIEdgeInsets IOSUsePlaySafeAreaFixtureCollision(
    __unused id receiver,
    __unused SEL selector,
    __unused BOOL includeStatusBar
) {
    return UIEdgeInsetsZero;
}

@implementation IOSUsePlaySafeAreaABIFixture
- (UIEdgeInsets)provider:(BOOL)includeStatusBar {
    (void)includeStatusBar;
    return UIEdgeInsetsZero;
}
- (void)invalidate {}
- (CGRect)wrongProvider:(BOOL)includeStatusBar {
    (void)includeStatusBar;
    return CGRectZero;
}
- (void)wrongInvalidation:(BOOL)value {
    (void)value;
}
@end

static BOOL IOSUsePlaySafeAreaRequire(
    BOOL condition,
    NSString *message
) {
    if (!condition) {
        fprintf(
            stderr,
            "[safe-area-contract] %s\n",
            message.UTF8String
        );
    }
    return condition;
}

static BOOL IOSUsePlaySafeAreaInsetsEqual(
    UIEdgeInsets left,
    UIEdgeInsets right
) {
    return UIEdgeInsetsEqualToEdgeInsets(left, right);
}

int main(void) {
    @autoreleasepool {
        BOOL passed = YES;
        NSError *missingInstallError = nil;
        passed &= IOSUsePlaySafeAreaRequire(
            !IOSUsePlaySafeAreaCompatibilityReconcile(
                &missingInstallError
            ) &&
                missingInstallError != nil &&
                missingInstallError.code == 1,
            @"reconcile accepted a missing pre-main hook install"
        );
        UIEdgeInsets device = UIEdgeInsetsMake(
            IOSUsePlayDeviceSafeAreaTop,
            IOSUsePlayDeviceSafeAreaLeft,
            IOSUsePlayDeviceSafeAreaBottom,
            IOSUsePlayDeviceSafeAreaRight
        );
        passed &= IOSUsePlaySafeAreaRequire(
            IOSUsePlaySafeAreaInsetsEqual(
                device,
                UIEdgeInsetsMake(59, 0, 34, 0)
            ),
            @"iPhone16,2 base safe-area constants changed"
        );
        passed &= IOSUsePlaySafeAreaRequire(
            IOSUsePlaySafeAreaInsetsEqual(
                IOSUsePlaySafeAreaProviderInsetsForTesting(
                    UIEdgeInsetsZero,
                    YES
                ),
                device
            ),
            @"status-bar-inclusive provider did not resolve to the "
             "device contract"
        );
        passed &= IOSUsePlaySafeAreaRequire(
            IOSUsePlaySafeAreaInsetsEqual(
                IOSUsePlaySafeAreaProviderInsetsForTesting(
                    UIEdgeInsetsZero,
                    NO
                ),
                UIEdgeInsetsMake(0, 0, 34, 0)
            ),
            @"status-bar-exclusive provider added the device top inset"
        );
        UIEdgeInsets larger = UIEdgeInsetsMake(61, 4, 40, 5);
        passed &= IOSUsePlaySafeAreaRequire(
            IOSUsePlaySafeAreaInsetsEqual(
                IOSUsePlaySafeAreaMaximumInsetsForTesting(
                    larger,
                    device
                ),
                larger
            ),
            @"compatibility helper shrank a larger provider inset"
        );
        passed &= IOSUsePlaySafeAreaRequire(
            IOSUsePlaySafeAreaSceneActivationStateSupportsFixedGeometryForTesting(
                UISceneActivationStateForegroundActive
            ),
            @"foreground-active scene lost fixed geometry"
        );
        passed &= IOSUsePlaySafeAreaRequire(
            IOSUsePlaySafeAreaSceneActivationStateSupportsFixedGeometryForTesting(
                UISceneActivationStateForegroundInactive
            ),
            @"foreground-inactive scene lost fixed geometry"
        );
        passed &= IOSUsePlaySafeAreaRequire(
            !IOSUsePlaySafeAreaSceneActivationStateSupportsFixedGeometryForTesting(
                UISceneActivationStateBackground
            ),
            @"background scene received fixed foreground geometry"
        );
        passed &= IOSUsePlaySafeAreaRequire(
            !IOSUsePlaySafeAreaSceneActivationStateSupportsFixedGeometryForTesting(
                UISceneActivationStateUnattached
            ),
            @"unattached scene received fixed foreground geometry"
        );
        passed &= IOSUsePlaySafeAreaRequire(
            IOSUsePlaySafeAreaPreBindActivationStateSupportsFixedGeometryForTesting(
                UISceneActivationStateUnattached,
                NO,
                YES
            ),
            @"connecting primary window missed the pre-bind fixed geometry"
        );
        passed &= IOSUsePlaySafeAreaRequire(
            !IOSUsePlaySafeAreaPreBindActivationStateSupportsFixedGeometryForTesting(
                UISceneActivationStateUnattached,
                YES,
                YES
            ),
            @"disconnected window retained fixed geometry after binding"
        );
        passed &= IOSUsePlaySafeAreaRequire(
            !IOSUsePlaySafeAreaPreBindActivationStateSupportsFixedGeometryForTesting(
                UISceneActivationStateUnattached,
                NO,
                NO
            ),
            @"unattached auxiliary window received pre-bind geometry"
        );
        Method provider = class_getInstanceMethod(
            IOSUsePlaySafeAreaABIFixture.class,
            @selector(provider:)
        );
        Method invalidation = class_getInstanceMethod(
            IOSUsePlaySafeAreaABIFixture.class,
            @selector(invalidate)
        );
        Method wrongProvider = class_getInstanceMethod(
            IOSUsePlaySafeAreaABIFixture.class,
            @selector(wrongProvider:)
        );
        Method wrongInvalidation = class_getInstanceMethod(
            IOSUsePlaySafeAreaABIFixture.class,
            @selector(wrongInvalidation:)
        );
        passed &= IOSUsePlaySafeAreaRequire(
            IOSUsePlaySafeAreaMethodHasABIForTesting(
                provider,
                @encode(UIEdgeInsets),
                @encode(BOOL),
                3
            ),
            @"UIEdgeInsets(id,SEL,BOOL) provider ABI was rejected"
        );
        passed &= IOSUsePlaySafeAreaRequire(
            IOSUsePlaySafeAreaMethodHasABIForTesting(
                invalidation,
                @encode(void),
                NULL,
                2
            ),
            @"void(id,SEL) invalidation ABI was rejected"
        );
        passed &= IOSUsePlaySafeAreaRequire(
            !IOSUsePlaySafeAreaMethodHasABIForTesting(
                wrongProvider,
                @encode(UIEdgeInsets),
                @encode(BOOL),
                3
            ),
            @"wrong provider return ABI was accepted"
        );
        passed &= IOSUsePlaySafeAreaRequire(
            !IOSUsePlaySafeAreaMethodHasABIForTesting(
                wrongInvalidation,
                @encode(void),
                NULL,
                2
            ),
            @"wrong invalidation argument ABI was accepted"
        );
        passed &= IOSUsePlaySafeAreaRequire(
            IOSUsePlaySafeAreaMethodOwnerForTesting(
                UIWindow.class,
                NSSelectorFromString(
                    @"_sceneSafeAreaInsetsIncludingStatusBar:"
                )
            ) == UIWindow.class,
            @"UIWindow no longer directly owns the private safe-area "
             "provider"
        );
        passed &= IOSUsePlaySafeAreaRequire(
            IOSUsePlaySafeAreaMethodOwnerForTesting(
                UIWindow.class,
                NSSelectorFromString(
                    @"_sceneSettingsSafeAreaInsetsDidChange"
                )
            ) == UIWindow.class,
            @"UIWindow no longer directly owns safe-area invalidation"
        );
        SEL fixtureProvider =
            @selector(provider:);
        Method ownerProvider = class_getInstanceMethod(
            IOSUsePlaySafeAreaMethodOwnerFixture.class,
            fixtureProvider
        );
        IMP ownerOriginal =
            method_getImplementation(ownerProvider);
        method_setImplementation(
            ownerProvider,
            (IMP)IOSUsePlaySafeAreaFixtureReplacement
        );
        passed &= IOSUsePlaySafeAreaRequire(
            IOSUsePlaySafeAreaMethodOwnerForTesting(
                IOSUsePlaySafeAreaMethodOwnerFixture.class,
                fixtureProvider
            ) == IOSUsePlaySafeAreaMethodOwnerFixture.class,
            @"provider method owner was not resolved exactly"
        );
        passed &= IOSUsePlaySafeAreaRequire(
            IOSUsePlaySafeAreaMethodOwnerForTesting(
                IOSUsePlaySafeAreaInheritedFixture.class,
                fixtureProvider
            ) == IOSUsePlaySafeAreaMethodOwnerFixture.class,
            @"inherited provider method owner was not resolved"
        );
        passed &= IOSUsePlaySafeAreaRequire(
            IOSUsePlaySafeAreaMethodOwnerForTesting(
                IOSUsePlaySafeAreaOverrideFixture.class,
                fixtureProvider
            ) == IOSUsePlaySafeAreaOverrideFixture.class,
            @"subclass provider override was not detected"
        );
        passed &= IOSUsePlaySafeAreaRequire(
            IOSUsePlaySafeAreaClassDispatchesIMPForTesting(
                IOSUsePlaySafeAreaMethodOwnerFixture.class,
                fixtureProvider,
                (IMP)IOSUsePlaySafeAreaFixtureReplacement
            ),
            @"method owner did not dispatch to the installed hook"
        );
        passed &= IOSUsePlaySafeAreaRequire(
            IOSUsePlaySafeAreaClassDispatchesIMPForTesting(
                IOSUsePlaySafeAreaInheritedFixture.class,
                fixtureProvider,
                (IMP)IOSUsePlaySafeAreaFixtureReplacement
            ),
            @"inheriting subclass bypassed the installed hook"
        );
        passed &= IOSUsePlaySafeAreaRequire(
            !IOSUsePlaySafeAreaClassDispatchesIMPForTesting(
                IOSUsePlaySafeAreaOverrideFixture.class,
                fixtureProvider,
                (IMP)IOSUsePlaySafeAreaFixtureReplacement
            ),
            @"subclass provider override was reported as hooked"
        );
        method_setImplementation(
            ownerProvider,
            (IMP)IOSUsePlaySafeAreaFixtureCollision
        );
        passed &= IOSUsePlaySafeAreaRequire(
            !IOSUsePlaySafeAreaClassDispatchesIMPForTesting(
                IOSUsePlaySafeAreaMethodOwnerFixture.class,
                fixtureProvider,
                (IMP)IOSUsePlaySafeAreaFixtureReplacement
            ),
            @"post-install provider replacement was not detected"
        );
        method_setImplementation(ownerProvider, ownerOriginal);
        SEL runtimeProviderSelector = NSSelectorFromString(
            @"_sceneSafeAreaInsetsIncludingStatusBar:"
        );
        Method runtimeProvider = class_getInstanceMethod(
            UIWindow.class,
            runtimeProviderSelector
        );
        IMP runtimeOriginal =
            method_getImplementation(runtimeProvider);
        NSError *installError = nil;
        passed &= IOSUsePlaySafeAreaRequire(
            IOSUsePlaySafeAreaCompatibilityInstallBeforeUIApplicationMain(
                &installError
            ) && installError == nil,
            @"production UIWindow hook failed its synchronous install"
        );
        IMP runtimeHook =
            method_getImplementation(runtimeProvider);
        passed &= IOSUsePlaySafeAreaRequire(
            runtimeHook != runtimeOriginal &&
                IOSUsePlaySafeAreaClassDispatchesIMPForTesting(
                    UIWindow.class,
                    runtimeProviderSelector,
                    runtimeHook
                ),
            @"production UIWindow owner did not dispatch to the hook"
        );
        method_setImplementation(runtimeProvider, runtimeOriginal);
        NSError *collisionError = nil;
        passed &= IOSUsePlaySafeAreaRequire(
            !IOSUsePlaySafeAreaCompatibilityReconcile(
                &collisionError
            ) &&
                collisionError != nil &&
                collisionError.code == 1,
            @"production post-install collision did not fail closed"
        );
        if (!passed) {
            return 1;
        }
        puts("[safe-area-contract] PASS");
        return 0;
    }
}
