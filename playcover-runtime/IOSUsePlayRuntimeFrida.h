#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Bridge for the separately pinned IOSUseFridaEngine.framework. Every
/// prepared App supplies the Engine as a sibling framework; it is loaded on
/// the first debug command and retained for the App process lifetime.
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

NS_ASSUME_NONNULL_END
