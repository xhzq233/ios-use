#import "IOSUsePlaySnapshot.h"
#import <objc/message.h>
#import <stdatomic.h>
#import <math.h>

@implementation IOSUsePlaySnapshotBudget {
    NSTimeInterval _deadline;
    atomic_uint _stopReason;
}

- (instancetype)initWithTimeout:(NSTimeInterval)timeout {
    self = [super init];
    if (self) {
        _deadline = NSProcessInfo.processInfo.systemUptime +
            (isfinite(timeout) && timeout > 0 ? timeout : 0);
        atomic_init(&_stopReason, IOSUsePlaySnapshotStopNone);
    }
    return self;
}

- (NSTimeInterval)remainingSeconds {
    return MAX(0, _deadline - NSProcessInfo.processInfo.systemUptime);
}

- (BOOL)shouldContinue {
    if (atomic_load(&_stopReason) != IOSUsePlaySnapshotStopNone) return NO;
    if (self.remainingSeconds <= 0) {
        unsigned int expected = IOSUsePlaySnapshotStopNone;
        atomic_compare_exchange_strong(&_stopReason, &expected, IOSUsePlaySnapshotStopDeadline);
        return NO;
    }
    return atomic_load(&_stopReason) == IOSUsePlaySnapshotStopNone;
}

- (IOSUsePlaySnapshotStopReason)stopReason {
    (void)[self shouldContinue];
    return (IOSUsePlaySnapshotStopReason)atomic_load(&_stopReason);
}

- (void)cancel {
    unsigned int expected = IOSUsePlaySnapshotStopNone;
    atomic_compare_exchange_strong(&_stopReason, &expected, IOSUsePlaySnapshotStopCancelled);
}
@end

id IOSUsePlayRunSnapshot(
    NSTimeInterval timeout,
    BOOL (^cancellationCheck)(void),
    id (^capture)(IOSUsePlaySnapshotBudget *),
    IOSUsePlaySnapshotStopReason *stopReason
) {
    IOSUsePlaySnapshotBudget *budget = [[IOSUsePlaySnapshotBudget alloc] initWithTimeout:timeout];
    *stopReason = IOSUsePlaySnapshotStopNone;
    if (cancellationCheck != nil && cancellationCheck()) [budget cancel];
    if (![budget shouldContinue]) {
        *stopReason = budget.stopReason;
        return nil;
    }
    if (NSThread.isMainThread) {
        id result = capture(budget);
        *stopReason = budget.stopReason;
        return *stopReason == IOSUsePlaySnapshotStopNone ? result : nil;
    }

    static dispatch_queue_t coordinator;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        coordinator = dispatch_queue_create("io.ios-use.play-runtime.dom-snapshots", DISPATCH_QUEUE_SERIAL);
    });
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    __block id result = nil;
    dispatch_async(coordinator, ^{
        @autoreleasepool {
            if ([budget shouldContinue]) {
                dispatch_semaphore_t mainCompleted = dispatch_semaphore_create(0);
                dispatch_async(dispatch_get_main_queue(), ^{
                    @try {
                        if ([budget shouldContinue]) result = capture(budget);
                    } @finally {
                        dispatch_semaphore_signal(mainCompleted);
                    }
                });
                // Do not overlap captures if one getter is still executing.
                // The caller can time out independently; traversal observes budget.
                dispatch_semaphore_wait(mainCompleted, DISPATCH_TIME_FOREVER);
            }
            dispatch_semaphore_signal(completed);
        }
    });
    while ([budget shouldContinue]) {
        dispatch_time_t waitUntil = dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(MIN(0.05, budget.remainingSeconds) * NSEC_PER_SEC));
        if (dispatch_semaphore_wait(completed, waitUntil) == 0) {
            *stopReason = budget.stopReason;
            return *stopReason == IOSUsePlaySnapshotStopNone ? result : nil;
        }
        if (cancellationCheck != nil && cancellationCheck()) [budget cancel];
    }
    *stopReason = budget.stopReason;
    return nil;
}

NSArray *IOSUsePlaySnapshotContainerElements(
    id object, NSUInteger maximumChildren, IOSUsePlaySnapshotBudget *budget, NSString **failureMessage
) {
    SEL countSelector = NSSelectorFromString(@"accessibilityElementCount");
    SEL elementSelector = NSSelectorFromString(@"accessibilityElementAtIndex:");
    if ((budget != nil && ![budget shouldContinue]) ||
        ![object respondsToSelector:countSelector] || ![object respondsToSelector:elementSelector]) return nil;
    NSInteger count;
    @try {
        count = ((NSInteger (*)(id, SEL))objc_msgSend)(object, countSelector);
    } @catch (__unused NSException *exception) { return nil; }
    if (budget != nil && ![budget shouldContinue]) return nil;
    if (count < 0 || count == NSNotFound) return nil;
    if ((NSUInteger)count > maximumChildren) {
        if (failureMessage != NULL) *failureMessage = [NSString stringWithFormat:
            @"accessibility container %@ reported %ld children, exceeding the %lu-child limit",
            NSStringFromClass([object class]) ?: @"NSObject", (long)count, (unsigned long)maximumChildren];
        return nil;
    }
    NSMutableArray *elements = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
    for (NSInteger index = 0; index < count; index++) {
        if (budget != nil && ![budget shouldContinue]) return nil;
        id element = nil;
        @try {
            element = ((id (*)(id, SEL, NSInteger))objc_msgSend)(object, elementSelector, index);
        } @catch (__unused NSException *exception) { element = nil; }
        if (element != nil) [elements addObject:element];
    }
    return budget == nil || [budget shouldContinue] ? elements : nil;
}
