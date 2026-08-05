#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Optional, capability-gated bridge for the separately pinned
/// IOSUseFridaEngine.framework. The base Runtime deliberately does not embed
/// a JavaScript VM or a substitute hook implementation; if the signed
/// framework is absent, callers receive a stable capability error.
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable
IOSUsePlayRuntimeFridaDebugCommand(
    NSDictionary<NSString *, id> *arguments,
    void (* _Nullable eventCallback)(
        const char *kind,
        const char *display,
        void * _Nullable context
    ),
    void * _Nullable eventContext,
    BOOL keepEventSubscription,
    NSDictionary<NSString *, id> * _Nullable * _Nullable error
);

/// Clears the callback retained by the active Engine.  The Runtime calls this
/// when a streaming Unix-socket connection closes or a non-streaming request
/// has completed.
FOUNDATION_EXPORT void IOSUsePlayRuntimeFridaClearEventSubscription(void);

FOUNDATION_EXPORT BOOL IOSUsePlayRuntimeFridaEnabled(void);

NS_ASSUME_NONNULL_END
