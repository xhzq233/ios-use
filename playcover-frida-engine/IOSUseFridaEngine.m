#import "IOSUseFridaEngine.h"

#include <frida-gumjs.h>

#include <dispatch/dispatch.h>
#include <glib.h>
#include <string.h>

#include "IOSUseFridaAgent.generated.h"

@interface IOSUseFridaEngineState : NSObject {
@public
    GumScriptBackend *_backend;
    GumScript *_script;
    GMainContext *_context;
    GMainLoop *_loop;
    GThread *_contextThread;
    NSCondition *_condition;
    NSString *_pendingID;
    NSString *_display;
    NSMutableArray<NSString *> *_events;
    IOSUseFridaEngineEventCallback _eventCallback;
    void *_eventContext;
    NSUInteger _eventCallbacksInFlight;
    NSUInteger _retainedEventBytes;
    BOOL _retainEvents;
    NSError *_pendingError;
    NSError *_reloadError;
    NSError *_loadError;
    BOOL _pending;
    BOOL _reloadPending;
    BOOL _loading;
    BOOL _stopping;
}
- (BOOL)loadScript:(NSError **)error;
- (BOOL)reset;
- (void)setEventCallback:(IOSUseFridaEngineEventCallback)callback
                 context:(void *)context;
- (void)clearEventCallback:(void *)context;
- (void)appendEvent:(NSString *)display;
- (void)emitEventKind:(NSString *)kind display:(NSString *)display;
- (BOOL)isReady;
- (NSDictionary<NSString *, id> *)evaluate:(NSString *)source
                                     reset:(BOOL)reset
                                    stream:(BOOL)stream
                                     error:(NSError **)error;
@end

static void IOSUseFridaMessageHandler(
    const gchar *message,
    GBytes *data,
    gpointer userData
);

static gboolean IOSUseFridaReloadOnContext(gpointer userData);

static const NSUInteger IOSUseFridaMaximumRetainedEvents = 256;
static const NSUInteger IOSUseFridaMaximumRetainedEventBytes = 1 * 1024 * 1024;

static gpointer IOSUseFridaContextThread(gpointer userData) {
    IOSUseFridaEngineState *state = (__bridge IOSUseFridaEngineState *)userData;
    g_main_context_push_thread_default(state->_context);
    g_main_loop_run(state->_loop);
    g_main_context_pop_thread_default(state->_context);
    return NULL;
}

@implementation IOSUseFridaEngineState

- (instancetype)init {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _context = g_main_context_new();
    _condition = [NSCondition new];
    _events = [NSMutableArray array];
    if (_context == NULL || _condition == nil) {
        return nil;
    }
    GumScriptBackend *backend = gum_script_backend_obtain_qjs();
    if (backend == NULL) {
        return nil;
    }
    _backend = g_object_ref(backend);

    // Gum delivers script messages through the context that is current while
    // the script is created.  The private context is pumped by a dedicated
    // thread so Runtime does not depend on the host app's run loop.
    g_main_context_push_thread_default(_context);
    NSError *loadError = nil;
    if (![self loadScript:&loadError]) {
        g_main_context_pop_thread_default(_context);
        return nil;
    }
    g_main_context_pop_thread_default(_context);

    _loop = g_main_loop_new(_context, FALSE);
    if (_loop == NULL) {
        return nil;
    }
    _contextThread = g_thread_new(
        "ios-use-frida-events",
        IOSUseFridaContextThread,
        (__bridge gpointer)self
    );
    if (_contextThread == NULL) {
        return nil;
    }
    return self;
}

- (BOOL)loadScript:(NSError **)error {
    if (_backend == NULL) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"IOSUseFridaEngine"
                                          code:1
                                      userInfo:@{
                NSLocalizedDescriptionKey: @"QuickJS Gum backend is unavailable"
            }];
        }
        return NO;
    }
    GError *gumError = NULL;
    [_condition lock];
    _loadError = nil;
    _loading = YES;
    [_condition unlock];
    _script = gum_script_backend_create_sync(
        _backend,
        "ios-use-agent",
        (const gchar *)IOSUseFridaAgentSource,
        NULL,
        NULL,
        &gumError
    );
    if (_script == NULL) {
        [_condition lock];
        _loading = NO;
        [_condition unlock];
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"IOSUseFridaEngine"
                                          code:2
                                      userInfo:@{
                NSLocalizedDescriptionKey: gumError != NULL
                    ? [NSString stringWithUTF8String:gumError->message]
                    : @"Gum script creation failed"
            }];
        }
        if (gumError != NULL) {
            g_error_free(gumError);
        }
        return NO;
    }
    gum_script_set_message_handler(
        _script,
        IOSUseFridaMessageHandler,
        (__bridge gpointer)self,
        NULL
    );
    gum_script_load_sync(_script, NULL);
    [_condition lock];
    NSError *loadError = _loadError;
    _loading = NO;
    [_condition unlock];
    if (loadError != nil) {
        if (error != NULL) {
            *error = loadError;
        }
        g_object_unref(_script);
        _script = NULL;
        return NO;
    }
    return YES;
}

- (BOOL)isReady {
    return !_stopping &&
        _context != NULL &&
        _loop != NULL &&
        _contextThread != NULL &&
        _script != NULL;
}

- (BOOL)reset {
    if (![self isReady]) {
        return NO;
    }
    [_condition lock];
    if (_pending) {
        _pendingError = [NSError errorWithDomain:@"IOSUseFridaEngine"
                                              code:3
                                          userInfo:@{
            NSLocalizedDescriptionKey: @"Frida Engine reset while an evaluation was pending"
        }];
        _pending = NO;
        [_condition signal];
    }
    _reloadError = nil;
    _reloadPending = YES;
    [_condition unlock];

    // The script's outgoing-message GSources are owned by this private
    // context.  Reload on that context rather than trying to push it from a
    // caller thread while the event-loop thread owns it.
    g_main_context_invoke(
        _context,
        IOSUseFridaReloadOnContext,
        (__bridge gpointer)self
    );

    [_condition lock];
    while (_reloadPending) {
        [_condition wait];
    }
    BOOL success = (_reloadError == nil && _script != NULL);
    [_condition unlock];
    return success;
}

- (void)setEventCallback:(IOSUseFridaEngineEventCallback)callback
                 context:(void *)context {
    [_condition lock];
    _eventCallback = callback;
    _eventContext = context;
    [_condition unlock];
}

- (void)clearEventCallback:(void *)context {
    [_condition lock];
    if (context == NULL || _eventContext == context) {
        _eventCallback = NULL;
        _eventContext = NULL;
        while (_eventCallbacksInFlight != 0) {
            [_condition wait];
        }
    }
    [_condition unlock];
}

- (void)appendEvent:(NSString *)display {
    if (!_retainEvents || display.length == 0) {
        return;
    }
    NSUInteger bytes = [display lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    NSUInteger retainedBytes = MIN(
        _retainedEventBytes,
        IOSUseFridaMaximumRetainedEventBytes
    );
    if (_events.count >= IOSUseFridaMaximumRetainedEvents ||
        bytes > IOSUseFridaMaximumRetainedEventBytes - retainedBytes ||
        _retainedEventBytes >= IOSUseFridaMaximumRetainedEventBytes) {
        return;
    }
    [_events addObject:display];
    _retainedEventBytes += bytes;
}

- (void)emitEventKind:(NSString *)kind display:(NSString *)display {
    if (display == nil) {
        return;
    }
    IOSUseFridaEngineEventCallback callback = NULL;
    void *context = NULL;
    [_condition lock];
    callback = _eventCallback;
    context = _eventContext;
    if (callback != NULL) {
        _eventCallbacksInFlight += 1;
    }
    [_condition unlock];
    if (callback == NULL) {
        return;
    }
    callback(
        (kind ?: @"event").UTF8String,
        display.UTF8String,
        context
    );
    [_condition lock];
    if (_eventCallbacksInFlight > 0) {
        _eventCallbacksInFlight -= 1;
    }
    if (_eventCallbacksInFlight == 0) {
        [_condition broadcast];
    }
    [_condition unlock];
}

- (NSDictionary<NSString *, id> *)evaluate:(NSString *)source
                                     reset:(BOOL)reset
                                    stream:(BOOL)stream
                                     error:(NSError **)error {
    if (![self isReady]) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"IOSUseFridaEngine"
                                          code:4
                                      userInfo:@{
                NSLocalizedDescriptionKey: @"Frida Engine is not initialized"
            }];
        }
        return nil;
    }
    if (reset && ![self reset]) {
        if (error != NULL) {
            [_condition lock];
            *error = _reloadError ?: [NSError errorWithDomain:@"IOSUseFridaEngine"
                                                            code:9
                                                        userInfo:@{
                NSLocalizedDescriptionKey: @"Frida Agent reset failed"
            }];
            [_condition unlock];
        }
        return nil;
    }
    if (source == nil) {
        return @{
            @"display": @"",
            @"events": @[],
            @"agent": @"frida-gumjs"
        };
    }

    NSString *requestID = [NSUUID UUID].UUIDString;
    [_condition lock];
    _pendingID = requestID;
    _display = nil;
    _pendingError = nil;
    [_events removeAllObjects];
    _retainedEventBytes = 0;
    _retainEvents = !stream;
    _pending = YES;
    GumScript *script = _script;
    [_condition unlock];
    if (script == NULL) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"IOSUseFridaEngine"
                                          code:4
                                      userInfo:@{
                NSLocalizedDescriptionKey: @"Frida Agent is not loaded"
            }];
        }
        return nil;
    }

    NSDictionary *message = @{
        @"type": @"ios_use_eval",
        @"payload": @{
            @"id": requestID,
            @"script": source
        }
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:message
                                                       options:0
                                                         error:error];
    if (data == nil) {
        [_condition lock];
        _pending = NO;
        [_condition unlock];
        return nil;
    }
    NSString *json = [[NSString alloc] initWithData:data
                                             encoding:NSUTF8StringEncoding];
    gum_script_post(script, json.UTF8String, NULL);

    [_condition lock];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10.0];
    while (_pending && [_condition waitUntilDate:deadline]) {
    }
    BOOL timedOut = _pending;
    _pending = NO;
    NSError *pendingError = _pendingError;
    NSString *display = _display ?: @"";
    NSArray<NSString *> *events = [_events copy];
    [_condition unlock];

    if (timedOut) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"IOSUseFridaEngine"
                                          code:5
                                      userInfo:@{
                NSLocalizedDescriptionKey: @"Frida Agent evaluation timed out"
            }];
        }
        return nil;
    }
    if (pendingError != nil) {
        if (error != NULL) {
            *error = pendingError;
        }
        return nil;
    }
    return @{
        @"display": display,
        @"events": events,
        @"agent": @"frida-gumjs"
    };
}

- (void)dealloc {
    [_condition lock];
    _stopping = YES;
    _eventCallback = NULL;
    _eventContext = NULL;
    while (_eventCallbacksInFlight != 0) {
        [_condition wait];
    }
    [_condition unlock];
    if (_loop != NULL) {
        g_main_loop_quit(_loop);
    }
    if (_contextThread != NULL) {
        g_thread_join(_contextThread);
        _contextThread = NULL;
    }
    if (_script != NULL) {
        gum_script_unload_sync(_script, NULL);
        g_object_unref(_script);
        _script = NULL;
    }
    if (_loop != NULL) {
        g_main_loop_unref(_loop);
        _loop = NULL;
    }
    if (_backend != NULL) {
        g_object_unref(_backend);
        _backend = NULL;
    }
    if (_context != NULL) {
        g_main_context_unref(_context);
        _context = NULL;
    }
}

@end

static gboolean IOSUseFridaReloadOnContext(gpointer userData) {
    IOSUseFridaEngineState *state = (__bridge IOSUseFridaEngineState *)userData;
    GumScript *oldScript = state->_script;
    state->_script = NULL;
    if (oldScript != NULL) {
        gum_script_unload_sync(oldScript, NULL);
        g_object_unref(oldScript);
    }
    NSError *reloadError = nil;
    (void)[state loadScript:&reloadError];
    [state->_condition lock];
    state->_reloadError = reloadError;
    state->_reloadPending = NO;
    [state->_condition signal];
    [state->_condition unlock];
    return G_SOURCE_REMOVE;
}

static void IOSUseFridaMessageHandler(
    const gchar *message,
    GBytes *data,
    gpointer userData
) {
    (void)data;
    IOSUseFridaEngineState *state = (__bridge IOSUseFridaEngineState *)userData;
    NSData *bytes = [NSData dataWithBytes:message length:strlen(message)];
    NSDictionary *object = [NSJSONSerialization JSONObjectWithData:bytes
                                                                options:0
                                                                  error:NULL];
    if (![object isKindOfClass:NSDictionary.class]) {
        return;
    }
    NSDictionary *payload = object[@"payload"];
    [state->_condition lock];
    NSString *kind = [payload isKindOfClass:NSDictionary.class]
        ? payload[@"iosUse"]
        : nil;
    if ([kind isEqualToString:@"result"] &&
        [payload[@"id"] isEqualToString:state->_pendingID]) {
        state->_display = [payload[@"display"] isKindOfClass:NSString.class]
            ? payload[@"display"]
            : [payload[@"display"] description];
        state->_pending = NO;
        [state->_condition signal];
    } else if ([kind isEqualToString:@"error"] &&
               [payload[@"id"] isEqualToString:state->_pendingID]) {
        NSString *display = [payload[@"message"] isKindOfClass:NSString.class]
            ? payload[@"message"]
            : @"JavaScript evaluation failed";
        [state appendEvent:display];
        state->_pendingError = [NSError errorWithDomain:@"IOSUseFridaEngine"
                                                      code:6
                                                  userInfo:@{
            NSLocalizedDescriptionKey: payload[@"message"] ?: @"JavaScript evaluation failed",
            @"stack": payload[@"stack"] ?: @""
        }];
        state->_pending = NO;
        [state->_condition signal];
        [state->_condition unlock];
        [state emitEventKind:@"error" display:display];
        return;
    } else if ([kind isEqualToString:@"event"]) {
        NSString *display = [payload[@"display"] isKindOfClass:NSString.class]
            ? payload[@"display"]
            : [payload[@"display"] description];
        NSString *eventKind = [payload[@"kind"] isKindOfClass:NSString.class]
            ? payload[@"kind"]
            : @"event";
        if (display != nil) {
            [state appendEvent:display];
            [state->_condition unlock];
            [state emitEventKind:eventKind display:display];
            return;
        }
    } else if ([object[@"type"] isEqualToString:@"send"]) {
        id value = object[@"payload"];
        NSString *display = nil;
        if (value != nil && [NSJSONSerialization isValidJSONObject:@[value]]) {
            NSData *encoded = [NSJSONSerialization dataWithJSONObject:value
                                                                  options:0
                                                                    error:NULL];
            display = [[NSString alloc] initWithData:encoded
                                             encoding:NSUTF8StringEncoding];
        }
        if (display == nil) {
            display = value == nil ? @"null" : [value description];
        }
        [state appendEvent:display];
        [state->_condition unlock];
        [state emitEventKind:@"send" display:display];
        return;
    } else if ([object[@"type"] isEqualToString:@"error"] &&
               (state->_loading || state->_pending)) {
        NSString *display = [object[@"description"] isKindOfClass:NSString.class]
            ? object[@"description"]
            : @"Frida script error";
        [state appendEvent:display];
        if (state->_loading) {
            state->_loadError = [NSError errorWithDomain:@"IOSUseFridaEngine"
                                                        code:10
                                                    userInfo:@{
                NSLocalizedDescriptionKey: display,
                @"stack": object[@"stack"] ?: @""
            }];
            [state->_condition unlock];
            return;
        }
        state->_pendingError = [NSError errorWithDomain:@"IOSUseFridaEngine"
                                                      code:7
                                                  userInfo:@{
            NSLocalizedDescriptionKey: object[@"description"] ?: @"Frida script error"
        }];
        state->_pending = NO;
        [state->_condition signal];
        [state->_condition unlock];
        [state emitEventKind:@"error" display:display];
        return;
    }
    [state->_condition unlock];
}

static void *IOSUseFridaEngineCreateInternal(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gum_init_embedded();
        gum_script_scheduler_enable_background_thread(
            gum_script_backend_get_scheduler()
        );
    });
    IOSUseFridaEngineState *state = [IOSUseFridaEngineState new];
    if (state == nil || ![state isReady]) {
        return NULL;
    }
    return (__bridge_retained void *)state;
}

void *IOSUseFridaEngineCreate(void) {
    return IOSUseFridaEngineCreateInternal();
}

void IOSUseFridaEngineReset(void *engine) {
    if (engine == NULL) {
        return;
    }
    IOSUseFridaEngineState *state = (__bridge IOSUseFridaEngineState *)engine;
    (void)[state reset];
}

void IOSUseFridaEngineSetEventCallback(
    void *engine,
    IOSUseFridaEngineEventCallback callback,
    void *context
) {
    if (engine == NULL) {
        return;
    }
    IOSUseFridaEngineState *state = (__bridge IOSUseFridaEngineState *)engine;
    [state setEventCallback:callback context:context];
}

void IOSUseFridaEngineClearEventCallback(
    void *engine,
    void *context
) {
    if (engine == NULL) {
        return;
    }
    IOSUseFridaEngineState *state = (__bridge IOSUseFridaEngineState *)engine;
    [state clearEventCallback:context];
}

NSDictionary<NSString *, id> * _Nullable IOSUseFridaEngineEvaluate(
    void *engine,
    NSString *script,
    BOOL reset,
    BOOL stream,
    NSError **error
) {
    if (error != NULL) {
        *error = nil;
    }
    if (engine == NULL) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"IOSUseFridaEngine"
                                          code:8
                                      userInfo:@{
                NSLocalizedDescriptionKey: @"Frida Engine is not initialized"
            }];
        }
        return nil;
    }
    IOSUseFridaEngineState *state = (__bridge IOSUseFridaEngineState *)engine;
    return [state evaluate:script reset:reset stream:stream error:error];
}
