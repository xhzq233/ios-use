#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT void IOSUsePlayRuntimeStartSocket(
    NSDictionary<NSString *, id> *profile
);

FOUNDATION_EXPORT NSDictionary<NSString *, id> *
IOSUsePlayRuntimeSocketIdentity(void);

FOUNDATION_EXPORT NSDictionary<NSString *, id> *
IOSUsePlayRuntimeHookDiagnostics(void);

NS_ASSUME_NONNULL_END
