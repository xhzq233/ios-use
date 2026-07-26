#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable
IOSUsePlayRuntimeAutomationCommand(
    NSString *command,
    NSDictionary<NSString *, id> *arguments,
    NSDictionary<NSString *, id> * _Nullable * _Nullable commandError
);

NS_ASSUME_NONNULL_END
