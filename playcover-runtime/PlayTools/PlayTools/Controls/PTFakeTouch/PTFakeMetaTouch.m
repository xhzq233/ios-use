//
//  PTFakeMetaTouch.m
//  PTFakeTouch
//
//  Created by PugaTang on 16/4/20.
//  Copyright © 2016年 PugaTang. All rights reserved.
//

#import "PTFakeMetaTouch.h"
#import "UITouch-KIFAdditions.h"
#import "UIApplication+Private.h"
#import "UIEvent+Private.h"
#import "IOSUsePlayHookRegistry.h"
#import "CoreFoundation/CFRunLoop.h"
#import <stdatomic.h>
#include <dlfcn.h>
#include <string.h>

static NSMutableArray *livingTouchAry;
atomic_ullong reusageMask = ATOMIC_VAR_INIT(0);
static atomic_ullong deliveryGeneration = ATOMIC_VAR_INIT(0);
static CFRunLoopSourceRef source;
static BOOL IOSUseFakeTouchRequiredPreflightReady;

NSLock *lock;

void eventSendCallback(__unused void* info) {
    IOSUsePlayHookRegistryRecordInvocation(
        @"fake-touch.application-event"
    );
    UIEvent *event = [[UIApplication sharedApplication] _touchesEvent];
    IOSUsePlayHookRegistryRecordInvocation(
        @"fake-touch.event-clear"
    );
    [event _clearTouches];
    // Step1: copy touches and record began touches and mark recyclable touches
    NSMutableArray *begunTouchAry = [[NSMutableArray alloc] init];
    [lock lock];
    [livingTouchAry enumerateObjectsUsingBlock:^(
        UITouch *aTouch,
        NSUInteger idx,
        __unused BOOL *stop
    ) {
        switch (aTouch.phase) {
            case UITouchPhaseEnded:
            case UITouchPhaseCancelled:
                // set this bit to 1
                atomic_fetch_or(&reusageMask, 1ull<<idx);
                break;
            case UITouchPhaseBegan:
                [begunTouchAry addObject:aTouch];
                break;
            default:
                break;
        }
        IOSUsePlayHookRegistryRecordInvocation(
            @"fake-touch.event-add"
        );
        [event _addTouch:aTouch forDelayedDelivery:NO];
    }];
    [lock unlock];

    // Step2: send event
    [[UIApplication sharedApplication] sendEvent:event];
    atomic_fetch_add(&deliveryGeneration, 1);

    // Step 3: change "began" touches to "moved"
    // Do not let a "began" appear twice on a point
    for (UITouch *touch in begunTouchAry) {
        // Double check "began", because phase may have changed
        @synchronized (touch) {
            // Check condition needs to be synchronized too,
            // otherwise phase might also change after condition met
            if ([touch phase] == UITouchPhaseBegan) {
                [touch setPhaseAndUpdateTimestamp:UITouchPhaseMoved];
            }
        }
    }
}

static BOOL IOSUseFakeTouchObserveMethod(
    NSString *identifier,
    Class targetClass,
    SEL selector,
    const char *returnType,
    const char *const *argumentTypes,
    unsigned int argumentCount
) {
    NSError *error = nil;
    BOOL ready = IOSUsePlayHookRegistryObserveMethod(
        identifier,
        YES,
        @"objc-load",
        targetClass,
        NO,
        selector,
        returnType,
        argumentTypes,
        argumentCount,
        NO,
        NO,
        &error
    );
    if (!ready) {
        NSLog(
            @"[ios-use-play] required fake-touch preflight %@ failed: %@",
            identifier,
            error.localizedDescription ?: @"unknown failure"
        );
    }
    return ready;
}

@implementation PTFakeMetaTouch

+ (unsigned long long)deliveryGeneration {
    return atomic_load(&deliveryGeneration);
}

+ (void)load {
    BOOL methodsReady = YES;
    methodsReady = IOSUseFakeTouchObserveMethod(
        @"fake-touch.application-event",
        UIApplication.class,
        @selector(_touchesEvent),
        @encode(id),
        NULL,
        0
    ) && methodsReady;
    methodsReady = IOSUseFakeTouchObserveMethod(
        @"fake-touch.event-clear",
        UIEvent.class,
        @selector(_clearTouches),
        @encode(void),
        NULL,
        0
    ) && methodsReady;
    const char *eventAddArguments[] = {
        @encode(id),
        @encode(BOOL),
    };
    methodsReady = IOSUseFakeTouchObserveMethod(
        @"fake-touch.event-add",
        UIEvent.class,
        @selector(_addTouch:forDelayedDelivery:),
        @encode(void),
        eventAddArguments,
        2
    ) && methodsReady;
    const char *objectArgument[] = {
        @encode(id),
    };
    methodsReady = IOSUseFakeTouchObserveMethod(
        @"fake-touch.set-window",
        UITouch.class,
        @selector(setWindow:),
        @encode(void),
        objectArgument,
        1
    ) && methodsReady;
    methodsReady = IOSUseFakeTouchObserveMethod(
        @"fake-touch.set-view",
        UITouch.class,
        @selector(setView:),
        @encode(void),
        objectArgument,
        1
    ) && methodsReady;
    const char *locationArguments[] = {
        @encode(CGPoint),
        @encode(BOOL),
    };
    methodsReady = IOSUseFakeTouchObserveMethod(
        @"fake-touch.set-location",
        UITouch.class,
        @selector(_setLocationInWindow:resetPrevious:),
        @encode(void),
        locationArguments,
        2
    ) && methodsReady;
    const char *boolArgument[] = {
        @encode(BOOL),
    };
    methodsReady = IOSUseFakeTouchObserveMethod(
        @"fake-touch.set-first-touch",
        UITouch.class,
        @selector(_setIsFirstTouchForView:),
        @encode(void),
        boolArgument,
        1
    ) && methodsReady;
    methodsReady = IOSUseFakeTouchObserveMethod(
        @"fake-touch.set-is-tap",
        UITouch.class,
        @selector(setIsTap:),
        @encode(void),
        boolArgument,
        1
    ) && methodsReady;
    const char *timestampArgument[] = {
        @encode(NSTimeInterval),
    };
    methodsReady = IOSUseFakeTouchObserveMethod(
        @"fake-touch.set-timestamp",
        UITouch.class,
        @selector(setTimestamp:),
        @encode(void),
        timestampArgument,
        1
    ) && methodsReady;
    const char *phaseArgument[] = {
        @encode(UITouchPhase),
    };
    methodsReady = IOSUseFakeTouchObserveMethod(
        @"fake-touch.set-phase",
        UITouch.class,
        @selector(setPhase:),
        @encode(void),
        phaseArgument,
        1
    ) && methodsReady;
    const char *hidEventArgument[] = {
        @encode(IOHIDEventRef),
    };
    methodsReady = IOSUseFakeTouchObserveMethod(
        @"fake-touch.set-hid-event",
        UITouch.class,
        @selector(_setHidEvent:),
        @encode(void),
        hidEventArgument,
        1
    ) && methodsReady;
    livingTouchAry = [[NSMutableArray alloc] init];
    CFRunLoopSourceContext context;
    memset(&context, 0, sizeof(CFRunLoopSourceContext));
    context.perform = eventSendCallback;
    lock = [[NSLock alloc] init];
    // content of context is copied
    source = CFRunLoopSourceCreate(NULL, -2, &context);
    CFRunLoopRef loop = CFRunLoopGetMain();
    if (source != NULL && loop != NULL) {
        CFRunLoopAddSource(loop, source, kCFRunLoopCommonModes);
    }
    BOOL sourceReady = source != NULL &&
        loop != NULL &&
        CFRunLoopContainsSource(
            loop,
            source,
            kCFRunLoopCommonModes
        );
    IOSUsePlayHookRegistryRecordState(
        @"fake-touch.runloop-source",
        YES,
        @"objc-load",
        @"CFRunLoopGetMain",
        @"CFRunLoopSource",
        @"CFRunLoopSourceContext.perform",
        NO,
        sourceReady,
        sourceReady
            ? nil
            : @"fake-touch main runloop source is unavailable"
    );
    IOSUseFakeTouchRequiredPreflightReady =
        methodsReady && sourceReady;
}

+ (NSInteger)fakeTouchId: (NSInteger)pointId AtPoint: (CGPoint)point withTouchPhase: (UITouchPhase)phase inWindow: (UIWindow*)window onView:(UIView*)view {
    if (!IOSUseFakeTouchRequiredPreflightReady) {
        return -1;
    }
    UITouch* touch = NULL;
    // respect the semantics of touch phase, allocate new touch on touch began.
    if(phase == UITouchPhaseBegan) {
        touch = [[UITouch alloc] initAtPoint:point inWindow:window onView:view];
        // Find and clear any 1 bit if possible
        if(atomic_load(&reusageMask) == 0){
            pointId = [livingTouchAry count];
            [lock lock];
        }else{
            // reuse previous ID
            pointId = 0;
            // It is guanranteed other thread only "set" but not "clear" bit
            // So this is safe even if mask changes around here
            while( !(atomic_load(&reusageMask) & (1ull<<pointId)) ){
                pointId++;
            }
            // issue: this could fail if not atomic
            // How:
            // 1. Other thread read
            // 2. This thread read and write
            // 3. Other thread write
            [lock lock];
            atomic_fetch_and(&reusageMask, ~(1ull<<pointId));
            // These must be locked together, because otherwise
            // After we occupy this id, other thread may release it again,
            // before we actually replace the UITouch
        }
        if ((NSUInteger)pointId == livingTouchAry.count) {
            [livingTouchAry addObject:touch];
        } else {
            [livingTouchAry replaceObjectAtIndex:(NSUInteger)pointId
                                      withObject:touch];
        }
        [lock unlock];
    } else {
        touch = [livingTouchAry objectAtIndex:pointId];
        if(touch.phase == UITouchPhaseBegan && phase == UITouchPhaseMoved) {
            // previous touch began event not yet captured by runloop. Ignore this move
            return pointId;
        }
        @synchronized (touch) {
            [touch setLocationInWindow:point];
            [touch setPhaseAndUpdateTimestamp:phase];
        }
    }
    CFRunLoopSourceSignal(source);
    // Check on actual phase of touch
    if([touch phase] == UITouchPhaseEnded || [touch phase] == UITouchPhaseCancelled) {
        pointId = -1;
    }
    return pointId;
}
@end
