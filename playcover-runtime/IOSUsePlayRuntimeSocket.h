#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, IOSUsePlayRuntimeDiagnosticsScope) {
    IOSUsePlayRuntimeDiagnosticsScopeReadiness,
    IOSUsePlayRuntimeDiagnosticsScopeFull,
};

FOUNDATION_EXPORT void IOSUsePlayRuntimeStartSocket(void);

FOUNDATION_EXPORT int IOSUsePlayRuntimeBootstrapStdio(void);

FOUNDATION_EXPORT void IOSUsePlayRuntimeStartCommandLoop(void);

FOUNDATION_EXPORT void IOSUsePlayRuntimeSetUIReadiness(
    NSString *state,
    NSString *stage,
    NSString * _Nullable failure
);

FOUNDATION_EXPORT void IOSUsePlayRuntimePublishUIReadiness(void);

/// Returns nil when a UIKit command may execute. Call this on the main
/// thread immediately before reading or mutating UIKit state so a scene
/// transition cannot race the socket-level readiness gate.
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable
IOSUsePlayRuntimeUICommandError(void);

FOUNDATION_EXPORT BOOL IOSUsePlayRuntimeRequiredHooksReady(void);

FOUNDATION_EXPORT NSString * _Nullable
IOSUsePlayRuntimeRequiredHooksFailure(void);

FOUNDATION_EXPORT NSDictionary<NSString *, id> *
IOSUsePlayRuntimeSocketIdentity(void);

FOUNDATION_EXPORT NSDictionary<NSString *, id> *
IOSUsePlayRuntimeHookDiagnostics(
    IOSUsePlayRuntimeDiagnosticsScope scope,
    NSDictionary<NSString *, id> * _Nullable
        nativeAlertSnapshot,
    NSDictionary<NSString *, id> * _Nullable
        photosAuthorizationDiagnostics
);

NS_ASSUME_NONNULL_END
