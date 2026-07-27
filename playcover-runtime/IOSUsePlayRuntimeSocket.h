#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, IOSUsePlayRuntimeDiagnosticsScope) {
    IOSUsePlayRuntimeDiagnosticsScopeReadiness,
    IOSUsePlayRuntimeDiagnosticsScopeFull,
};

FOUNDATION_EXPORT void IOSUsePlayRuntimeStartSocket(void);

FOUNDATION_EXPORT NSDictionary<NSString *, id> *
IOSUsePlayRuntimeSocketIdentity(void);

FOUNDATION_EXPORT NSDictionary<NSString *, id> *
IOSUsePlayRuntimeHookDiagnostics(
    IOSUsePlayRuntimeDiagnosticsScope scope
);

NS_ASSUME_NONNULL_END
