#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Captures the injected process' own UIKit/AppKit window without requesting
/// macOS Screen Recording permission. UIKit and AppKit work is marshalled to
/// the main thread. The returned object is ready to attach to the Runtime
/// response payload as `screenshot`.
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable
IOSUsePlayRuntimeScreenshotCommand(
    NSDictionary<NSString *, id> *profile,
    NSString * _Nullable * _Nullable failureCode,
    NSString * _Nullable * _Nullable failureMessage
);

NS_ASSUME_NONNULL_END
