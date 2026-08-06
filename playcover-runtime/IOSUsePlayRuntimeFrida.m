#import "IOSUsePlayRuntimeFrida.h"

#import <dlfcn.h>
#import <stdlib.h>
#import <string.h>

typedef void *(*IOSUseFridaEngineCreateFunction)(void);
typedef void (*IOSUseFridaEngineResetFunction)(void *engine);
typedef void (*IOSUseFridaEngineSetEventCallbackFunction)(
    void *engine,
    void (*callback)(const char *kind, const char *display, void *context),
    void *context
);
typedef void (*IOSUseFridaEngineClearEventCallbackFunction)(
    void *engine,
    void *context
);
typedef NSDictionary<NSString *, id> *(*IOSUseFridaEngineEvaluateFunction)(
    void *engine,
    NSString * _Nullable script,
    BOOL reset,
    BOOL stream,
    NSError * _Nullable *error
);
typedef void *(*IOSUseFridaSymbolLookupFunction)(
    void *handle,
    const char *name
);

static NSLock *IOSUseFridaLock(void) {
    static NSLock *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [NSLock new];
    });
    return lock;
}

static void *IOSUseFridaHandle;
static void *IOSUseFridaEngine;
static IOSUseFridaEngineCreateFunction IOSUseFridaCreate;
static IOSUseFridaEngineResetFunction IOSUseFridaReset;
static IOSUseFridaEngineSetEventCallbackFunction IOSUseFridaSetEventCallback;
static IOSUseFridaEngineClearEventCallbackFunction IOSUseFridaClearEventCallback;
static IOSUseFridaEngineEvaluateFunction IOSUseFridaEvaluate;
static void *IOSUseFridaSubscriptionContext;
static BOOL IOSUseFridaLoadAttempted;
static NSDictionary<NSString *, id> *IOSUseFridaLoadError;

BOOL IOSUsePlayRuntimeFridaEnabled(void) {
    const char *value = getenv("IOS_USE_PLAY_FRIDA");
    return value != NULL && strcmp(value, "1") == 0;
}

static NSDictionary<NSString *, id> *IOSUseFridaError(
    NSString *code,
    NSString *message,
    NSString *category,
    NSString *phase,
    BOOL retryable,
    NSArray<NSString *> *suggestions
) {
    return @{
        @"code": code,
        @"message": message,
        @"details": @{
            @"category": category,
            @"phase": phase,
            @"retryable": @(retryable),
            @"fatal": @NO,
            @"candidateCount": @0,
            @"candidates": @[],
            @"suggestions": suggestions ?: @[],
        },
    };
}

static void IOSUseFridaClearResolvedSymbols(void) {
    IOSUseFridaCreate = NULL;
    IOSUseFridaReset = NULL;
    IOSUseFridaSetEventCallback = NULL;
    IOSUseFridaClearEventCallback = NULL;
    IOSUseFridaEvaluate = NULL;
}

static NSString * _Nullable IOSUseFridaResolveEngineABI(
    void *handle,
    IOSUseFridaSymbolLookupFunction lookup
) {
    IOSUseFridaCreate = (IOSUseFridaEngineCreateFunction)lookup(
        handle,
        "IOSUseFridaEngineCreate"
    );
    IOSUseFridaReset = (IOSUseFridaEngineResetFunction)lookup(
        handle,
        "IOSUseFridaEngineReset"
    );
    IOSUseFridaSetEventCallback =
        (IOSUseFridaEngineSetEventCallbackFunction)lookup(
            handle,
            "IOSUseFridaEngineSetEventCallback"
        );
    IOSUseFridaClearEventCallback =
        (IOSUseFridaEngineClearEventCallbackFunction)lookup(
            handle,
            "IOSUseFridaEngineClearEventCallback"
        );
    IOSUseFridaEvaluate = (IOSUseFridaEngineEvaluateFunction)lookup(
        handle,
        "IOSUseFridaEngineEvaluate"
    );

    if (IOSUseFridaCreate == NULL) {
        return @"IOSUseFridaEngineCreate";
    }
    if (IOSUseFridaReset == NULL) {
        return @"IOSUseFridaEngineReset";
    }
    if (IOSUseFridaSetEventCallback == NULL) {
        return @"IOSUseFridaEngineSetEventCallback";
    }
    if (IOSUseFridaClearEventCallback == NULL) {
        return @"IOSUseFridaEngineClearEventCallback";
    }
    if (IOSUseFridaEvaluate == NULL) {
        return @"IOSUseFridaEngineEvaluate";
    }
    return nil;
}

static NSDictionary<NSString *, id> *IOSUseFridaABIMismatchError(
    NSString *missingSymbol
) {
    return IOSUseFridaError(
        @"frida_engine_abi_mismatch",
        [NSString stringWithFormat:
            @"IOSUseFridaEngine.framework is missing required symbol %@",
            missingSymbol],
        @"internal",
        @"debug_engine",
        NO,
        @[]
    );
}

static BOOL IOSUseFridaResolveSymbols(void) {
    if (IOSUseFridaLoadAttempted) {
        return IOSUseFridaHandle != NULL &&
            IOSUseFridaCreate != NULL &&
            IOSUseFridaReset != NULL &&
            IOSUseFridaSetEventCallback != NULL &&
            IOSUseFridaClearEventCallback != NULL &&
            IOSUseFridaEvaluate != NULL;
    }
    IOSUseFridaLoadAttempted = YES;
    NSBundle *mainBundle = NSBundle.mainBundle;
    NSMutableArray<NSString *> *frameworkRoots = [NSMutableArray array];
    if (mainBundle.privateFrameworksPath.length > 0) {
        [frameworkRoots addObject:mainBundle.privateFrameworksPath];
    }
    // Catalyst applications prepared from iPhoneOS bundles retain the iOS
    // `App.app/Frameworks` layout; NSBundle.privateFrameworksPath can point
    // at the macOS `Contents/Frameworks` spelling instead.
    [frameworkRoots addObject:[mainBundle.bundleURL.path
        stringByAppendingPathComponent:@"Frameworks"]];
    [frameworkRoots addObject:[mainBundle.bundleURL.URLByDeletingLastPathComponent.path
        stringByAppendingPathComponent:@"Frameworks"]];
    [frameworkRoots addObject:[mainBundle.bundleURL.path
        stringByAppendingPathComponent:@"Contents/Frameworks"]];
    void *handle = NULL;
    NSMutableString *loadErrors = [NSMutableString string];
    for (NSString *root in frameworkRoots) {
        NSString *frameworkPath = [root
            stringByAppendingPathComponent:@"IOSUseFridaEngine.framework"];
        NSString *candidate = [frameworkPath
            stringByAppendingPathComponent:@"IOSUseFridaEngine"];
        handle = dlopen(
            candidate.fileSystemRepresentation,
            RTLD_NOW | RTLD_LOCAL
        );
        if (handle != NULL) {
            break;
        }
        const char *loadError = dlerror();
        if (loadError != NULL) {
            [loadErrors appendFormat:@" %@: %s;", candidate, loadError];
        }
    }
    if (handle == NULL) {
        NSString *suffix = loadErrors.length == 0
            ? @""
            : [NSString stringWithFormat:@" (%@)", loadErrors];
        IOSUseFridaLoadError = IOSUseFridaError(
            @"frida_engine_missing",
            [NSString stringWithFormat:
                @"the prepared App does not contain a loadable pinned "
                "IOSUseFridaEngine.framework%@", suffix],
            @"internal",
            @"debug_engine",
            NO,
            @[]
        );
        return NO;
    }
    IOSUseFridaHandle = handle;
    NSString *missingSymbol = IOSUseFridaResolveEngineABI(handle, dlsym);
    if (missingSymbol != nil) {
        IOSUseFridaLoadError = IOSUseFridaABIMismatchError(missingSymbol);
        dlclose(handle);
        IOSUseFridaHandle = NULL;
        IOSUseFridaClearResolvedSymbols();
        IOSUseFridaSubscriptionContext = NULL;
        return NO;
    }
    return YES;
}

#if defined(IOS_USE_PLAY_RUNTIME_FRIDA_TESTING)
NSDictionary<NSString *, id> * _Nullable
IOSUsePlayRuntimeFridaTestResolveEngineABI(
    void *handle,
    IOSUseFridaSymbolLookupFunction lookup
) {
    NSString *missingSymbol = IOSUseFridaResolveEngineABI(handle, lookup);
    NSDictionary<NSString *, id> *result = missingSymbol == nil
        ? nil
        : IOSUseFridaABIMismatchError(missingSymbol);
    IOSUseFridaClearResolvedSymbols();
    return result;
}
#endif

NSDictionary<NSString *, id> * _Nullable
IOSUsePlayRuntimeFridaDebugCommand(
    NSDictionary<NSString *, id> *arguments,
    void (*eventCallback)(
        const char *kind,
        const char *display,
        void *context
    ),
    void *eventContext,
    BOOL keepEventSubscription,
    NSDictionary<NSString *, id> * _Nullable *error
) {
    if (error != NULL) {
        *error = nil;
    }
    if (!IOSUsePlayRuntimeFridaEnabled()) {
        if (error != NULL) {
            *error = IOSUseFridaError(
                @"frida_capability_unavailable",
                @"the active App generation was not prepared with --frida",
                @"validation",
                @"debug_preflight",
                NO,
                @[]
            );
        }
        return nil;
    }
    if (![arguments isKindOfClass:NSDictionary.class]) {
        if (error != NULL) {
            *error = IOSUseFridaError(
                @"invalid_arguments",
                @"debug arguments must be an object",
                @"validation",
                @"validation",
                NO,
                @[]
            );
        }
        return nil;
    }
    NSString *script = arguments[@"script"];
    BOOL reset = [arguments[@"reset"] boolValue];
    BOOL stream = [arguments[@"stream"] boolValue];
    if (script != nil && ![script isKindOfClass:NSString.class]) {
        if (error != NULL) {
            *error = IOSUseFridaError(
                @"invalid_arguments",
                @"debug script must be a string or null",
                @"validation",
                @"validation",
                NO,
                @[]
            );
        }
        return nil;
    }
    NSLock *lock = IOSUseFridaLock();
    [lock lock];
    @try {
        if (!IOSUseFridaResolveSymbols()) {
            if (error != NULL) {
                *error = IOSUseFridaLoadError ?: IOSUseFridaError(
                    @"frida_engine_missing",
                    @"the pinned Frida Engine could not be loaded",
                    @"internal",
                    @"debug_engine",
                    NO,
                    @[]
                );
            }
            return nil;
        }
        if (IOSUseFridaEngine == NULL) {
            IOSUseFridaEngine = IOSUseFridaCreate();
            if (IOSUseFridaEngine == NULL) {
                if (error != NULL) {
                    *error = IOSUseFridaError(
                        @"frida_engine_init_failed",
                        @"the pinned Frida Engine failed to initialize",
                        @"internal",
                        @"debug_engine",
                        NO,
                        @[]
                    );
                }
                return nil;
            }
        }
        // IOSUseFridaEngineEvaluate owns the reset/reload operation.  Keep it
        // in one layer so a --reset request does not unload and reload the
        // Agent twice before evaluating the script.
        BOOL streamAlreadyActive =
            IOSUseFridaSubscriptionContext != NULL;
        BOOL installedEventCallback = NO;
        if (keepEventSubscription) {
            if (streamAlreadyActive &&
                IOSUseFridaSubscriptionContext != eventContext) {
                if (error != NULL) {
                    *error = IOSUseFridaError(
                        @"frida_stream_busy",
                        @"another Frida stream is already active",
                        @"session",
                        @"debug_stream",
                        YES,
                        @[
                            @"Close the existing ios-use debug --stream connection and retry.",
                        ]
                    );
                }
                return nil;
            }
            IOSUseFridaSetEventCallback(
                IOSUseFridaEngine,
                eventCallback,
                eventContext
            );
            if (!streamAlreadyActive) {
                IOSUseFridaSubscriptionContext = eventContext;
                installedEventCallback = YES;
            }
        } else if (!streamAlreadyActive) {
            IOSUseFridaSetEventCallback(
                IOSUseFridaEngine,
                eventCallback,
                eventContext
            );
            installedEventCallback = YES;
        }
        NSError *evaluationError = nil;
        NSDictionary<NSString *, id> *result = IOSUseFridaEvaluate(
            IOSUseFridaEngine,
            script,
            reset,
            stream || streamAlreadyActive,
            &evaluationError
        );
        if (result == nil) {
            // A stream owns its callback only after the evaluation succeeds.
            // If initialization/reset/evaluation fails, clear the callback
            // here while the caller still owns the connection context; the
            // serve loop will not receive a successful subscription marker
            // in that case.
            if (installedEventCallback) {
                IOSUseFridaClearEventCallback(
                    IOSUseFridaEngine,
                    eventContext
                );
                if (IOSUseFridaSubscriptionContext == eventContext) {
                    IOSUseFridaSubscriptionContext = NULL;
                }
            }
            if (error != NULL) {
                NSString *evaluationMessage =
                    evaluationError.localizedDescription ?:
                        @"Frida Engine evaluation failed";
                NSString *failureMessage = evaluationMessage;
                NSString *stack = [evaluationError.userInfo[@"stack"]
                    isKindOfClass:NSString.class]
                        ? evaluationError.userInfo[@"stack"]
                        : @"";
                if (stack.length > 0) {
                    failureMessage = [NSString stringWithFormat:
                        @"%@\n%@",
                        failureMessage,
                        stack];
                }
                BOOL resetOnly = reset && script.length == 0;
                BOOL timedOut =
                    !resetOnly &&
                    [evaluationError.domain isEqualToString:
                        @"IOSUseFridaEngine"] &&
                    evaluationError.code == 5;
                BOOL invalidQuery =
                    !resetOnly &&
                    [evaluationMessage rangeOfString:@"invalid query"
                                               options:NSCaseInsensitiveSearch]
                        .location != NSNotFound;
                NSString *failureCode = @"frida_eval_failed";
                NSArray<NSString *> *suggestions = @[
                    @"Run ios-use debug --reset before continuing if you need a clean Agent.",
                ];
                if (resetOnly) {
                    failureCode = @"frida_reset_failed";
                } else if (timedOut) {
                    failureCode = @"frida_eval_timeout";
                    suggestions = @[
                        @"Narrow symbol work to one loaded Module and a specific pattern; avoid full-process symbol enumeration.",
                        @"Run ios-use debug --reset before continuing if you need a clean Agent.",
                    ];
                } else if (invalidQuery) {
                    failureCode = @"frida_invalid_query";
                    suggestions = @[
                        @"Swift resolver queries require functions:<module-pattern>!<symbol-pattern>, for example functions:*MyApp*!*recordProbe*.",
                        @"Run ios-use debug --reset before continuing if you need a clean Agent.",
                    ];
                }
                *error = IOSUseFridaError(
                    failureCode,
                    failureMessage,
                    @"action",
                    resetOnly ? @"debug_reset" : @"debug_eval",
                    YES,
                    suggestions
                );
            }
            return nil;
        }
        if (!keepEventSubscription && !streamAlreadyActive) {
            IOSUseFridaClearEventCallback(
                IOSUseFridaEngine,
                eventContext
            );
        }
        return result;
    } @finally {
        [lock unlock];
    }
}

void IOSUsePlayRuntimeFridaClearEventSubscription(void) {
    NSLock *lock = IOSUseFridaLock();
    [lock lock];
    @try {
        if (IOSUseFridaEngine != NULL &&
            IOSUseFridaClearEventCallback != NULL) {
            IOSUseFridaClearEventCallback(IOSUseFridaEngine, NULL);
            IOSUseFridaSubscriptionContext = NULL;
        }
    } @finally {
        [lock unlock];
    }
}
