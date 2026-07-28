#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Restores the fixed iPhone window safe-area provider contract for the
/// foreground primary App UIWindow. This never creates a window or view and
/// never writes UIViewController.additionalSafeAreaInsets.
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

NS_ASSUME_NONNULL_END
