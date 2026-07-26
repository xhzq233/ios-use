#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Captures the injected process' own UIKit/AppKit window without requesting
/// macOS Screen Recording permission. UIKit and AppKit work is marshalled to
/// the main thread. The returned object is ready to attach to the Runtime
/// response payload as `screenshot`.
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable
IOSUsePlayRuntimeScreenshotCommand(
    NSString * _Nullable * _Nullable failureCode,
    NSString * _Nullable * _Nullable failureMessage
);

/// Returns a stable SHA-256 digest of canonical BGRA8 pixels from the same
/// complete own-process compositor used by screenshot. logicalRect uses the
/// fixed 430 x 932 top-left logical coordinate space and must be wholly
/// inside it. This never writes an artifact or requests Screen Recording.
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable
IOSUsePlayRuntimeScreenshotFingerprint(
    CGRect logicalRect,
    NSString * _Nullable * _Nullable failureCode,
    NSString * _Nullable * _Nullable failureMessage
);

NS_ASSUME_NONNULL_END
