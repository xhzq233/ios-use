#import "IOSUseFridaEngine.h"

#import <Foundation/Foundation.h>

static void IOSUseCaptureEvent(
    const char *kind,
    const char *display,
    void *context
) {
    if (context == NULL || display == NULL) {
        return;
    }
    NSMutableArray<NSString *> *events =
        (__bridge NSMutableArray<NSString *> *)context;
    NSString *event = [NSString stringWithFormat:
        @"%s:%s",
        kind ?: "event",
        display
    ];
    @synchronized (events) {
        [events addObject:event];
    }
}

static BOOL IOSUseEvaluate(
    void *engine,
    NSString *script,
    BOOL reset,
    NSString *expectedDisplay,
    BOOL expectConsole
) {
    NSError *error = nil;
    NSDictionary<NSString *, id> *result =
        IOSUseFridaEngineEvaluate(
            engine,
            script,
            reset,
            NO,
            &error
        );
    if (result == nil || error != nil) {
        NSLog(@"Engine evaluation failed: %@", error);
        return NO;
    }
    if (![result[@"display"] isEqualToString:expectedDisplay]) {
        NSLog(@"Unexpected display: %@", result[@"display"]);
        return NO;
    }
    NSArray<NSString *> *events = result[@"events"];
    if (![events isKindOfClass:NSArray.class]) {
        NSLog(@"Engine did not return an event array");
        return NO;
    }
    if (expectConsole &&
        ![events containsObject:@"\"engine-live-event\""]) {
        NSLog(@"Console event was not retained: %@", events);
        return NO;
    }
    return YES;
}

int main(void) {
    @autoreleasepool {
        void *engine = IOSUseFridaEngineCreate();
        if (engine == NULL) {
            NSLog(@"Engine initialization failed");
            return 1;
        }
        NSMutableArray<NSString *> *callbackEvents =
            [NSMutableArray array];
        IOSUseFridaEngineSetEventCallback(
            engine,
            IOSUseCaptureEvent,
            (__bridge void *)callbackEvents
        );
        if (!IOSUseEvaluate(
                engine,
                @"console.log('engine-live-event'); 6 * 7",
                NO,
                @"42",
                YES
            ) ||
            !IOSUseEvaluate(
                engine,
                @"Promise.resolve(84)",
                YES,
                @"84",
                NO
            )) {
            IOSUseFridaEngineClearEventCallback(
                engine,
                (__bridge void *)callbackEvents
            );
            return 1;
        }
        IOSUseFridaEngineClearEventCallback(
            engine,
            (__bridge void *)callbackEvents
        );
        @synchronized (callbackEvents) {
            if (![callbackEvents containsObject:
                    @"console:\"engine-live-event\""]) {
                NSLog(@"Engine callback was not delivered: %@", callbackEvents);
                return 1;
            }
        }
        NSLog(@"IOSUseFridaEngine live smoke PASS");
        return 0;
    }
}
