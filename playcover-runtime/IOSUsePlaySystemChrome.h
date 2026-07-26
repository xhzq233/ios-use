#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Installs a non-key, hit-test-transparent system-chrome surface in the
/// active foreground UIWindowScene. On Mac Catalyst it also installs a
/// window-scoped UIKit safe-area provider compatibility hook for the primary
/// App UIWindow; it never replaces or mutates the App root view controller.
/// Must be called on the main thread.
FOUNDATION_EXPORT void IOSUsePlaySystemChromeInstall(void);

/// Revalidates the independent chrome surface, selector/ABI/original-IMP
/// compatibility state, scene/window ownership, UIKit safe-area layout guide,
/// and lifecycle observer de-duplication.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *
IOSUsePlaySystemChromeDiagnostics(void);

/// Returns compositor pixel-signature evidence without consulting live UIKit
/// state. This is used by differential tests and is also embedded in the
/// diagnostics from the most recent full verification.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *
IOSUsePlaySystemChromeImageEvidence(CGImageRef image);

/// Verifies that the compositor result contains the independently rendered
/// Dynamic Island, status glyph and Home Indicator regions.
FOUNDATION_EXPORT BOOL IOSUsePlaySystemChromeVerifyImage(
    CGImageRef image,
    NSString * _Nullable * _Nullable failure
);

NS_ASSUME_NONNULL_END
