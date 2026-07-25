#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef BOOL (^IOSUsePlayRuntimeCancellationCheck)(void);

/// Executes a fresh UIKit accessibility traversal and returns the command's
/// `dom` object. The function may be called off-main; UIKit work is marshalled
/// to the main queue. On failure, `commandError` contains the complete JSON
/// error object (`code`, `message`, and optional structured `details`).
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable
IOSUsePlayRuntimeDOMCommand(
    NSDictionary<NSString *, id> *arguments,
    NSDictionary<NSString *, id> * _Nullable * _Nullable commandError
);

/// Polls fresh UIKit accessibility snapshots for the requested selector and
/// returns the command's `waitFor` object.
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable
IOSUsePlayRuntimeWaitForCommand(
    NSDictionary<NSString *, id> *arguments,
    IOSUsePlayRuntimeCancellationCheck cancellationCheck,
    NSDictionary<NSString *, id> * _Nullable * _Nullable commandError
);

NS_ASSUME_NONNULL_END
