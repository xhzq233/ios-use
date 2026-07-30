#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Installs the required UIWindow safe-area provider hook synchronously.
/// Runtime initialization calls this before UIApplicationMain; this function
/// never creates UIApplication, a scene, a window, or a view.
FOUNDATION_EXPORT BOOL
IOSUsePlaySafeAreaCompatibilityInstallBeforeUIApplicationMain(
    NSError * _Nullable * _Nullable error
);

/// Restores the fixed iPhone window safe-area provider contract for the
/// foreground primary App UIWindow after the hook has already been installed.
/// This never creates a window or view and never writes
/// UIViewController.additionalSafeAreaInsets.
FOUNDATION_EXPORT BOOL IOSUsePlaySafeAreaCompatibilityReconcile(
    NSError * _Nullable * _Nullable error
);

/// Returns whether the current compatible target is exactly `window`.
FOUNDATION_EXPORT BOOL IOSUsePlaySafeAreaCompatibilityIsReadyForWindow(
    UIWindow * _Nullable window
);

/// Returns window/root/layout-guide evidence for full Runtime diagnostics.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *
IOSUsePlaySafeAreaCompatibilityDiagnostics(void);

/// Bridges the already-installed provider and current target evidence into
/// the required-hook registry. This observes only; it never installs or
/// replaces the provider a second time.
FOUNDATION_EXPORT void
IOSUsePlaySafeAreaCompatibilityBridgeHookRegistry(void);

NS_ASSUME_NONNULL_END
