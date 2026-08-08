#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Stable ABI consumed by IOSUsePlayRuntimeFrida.m.  The framework is built
/// separately from the Runtime and is embedded in every prepared Mac App.
FOUNDATION_EXPORT void *IOSUseFridaEngineCreate(void);
FOUNDATION_EXPORT void IOSUseFridaEngineReset(void *engine);

/// Events are delivered synchronously from the Engine's message dispatcher.
/// The callback must not retain the UTF-8 pointers after it returns.  The
/// Runtime uses this small C ABI to forward console/send/error messages over
/// its already-authenticated Unix socket; no Frida transport is opened.
typedef void (*IOSUseFridaEngineEventCallback)(
    const char *kind,
    const char *display,
    void *context
);

FOUNDATION_EXPORT void IOSUseFridaEngineSetEventCallback(
    void *engine,
    IOSUseFridaEngineEventCallback _Nullable callback,
    void * _Nullable context
);
FOUNDATION_EXPORT void IOSUseFridaEngineClearEventCallback(
    void *engine,
    void * _Nullable context
);
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable
IOSUseFridaEngineEvaluate(
    void *engine,
    NSString * _Nullable script,
    BOOL reset,
    BOOL stream,
    NSError * _Nullable * _Nullable error
);

NS_ASSUME_NONNULL_END
