#import "IOSUsePlaySnapshot.h"
#import <stdatomic.h>
#import <unistd.h>

static void require(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "[snapshot] FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

@interface SlowContainer : NSObject
@property(nonatomic) NSInteger count;
@property(nonatomic) useconds_t delay;
@property(atomic) NSUInteger calls;
@end
@implementation SlowContainer
- (NSInteger)accessibilityElementCount { return self.count; }
- (id)accessibilityElementAtIndex:(NSInteger)index {
    self.calls += 1;
    usleep(self.delay);
    return @(index);
}
@end

static id capture(SlowContainer *container, NSTimeInterval timeout,
                  BOOL (^cancel)(void), IOSUsePlaySnapshotStopReason *reason) {
    return IOSUsePlayRunSnapshot(timeout, cancel, ^id(IOSUsePlaySnapshotBudget *budget) {
        require(NSThread.isMainThread, @"capture ran outside main thread");
        NSString *failure = nil;
        return IOSUsePlaySnapshotContainerElements(container, 100, budget, &failure);
    }, reason);
}

static NSTimeInterval waitForMain(void) {
    NSTimeInterval start = NSProcessInfo.processInfo.systemUptime;
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{ dispatch_semaphore_signal(ready); });
    require(dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0,
            @"main thread did not recover");
    return NSProcessInfo.processInfo.systemUptime - start;
}

static void runTests(void) {
    SlowContainer *container = [SlowContainer new];
    container.count = 60;
    container.delay = 10000;
    IOSUsePlaySnapshotStopReason reason;
    id result = capture(container, 0.08, nil, &reason);
    require(result == nil && reason == IOSUsePlaySnapshotStopDeadline, @"deadline returned a partial snapshot");
    NSTimeInterval recovery = waitForMain();
    require(container.calls > 0 && container.calls < 60, @"deadline did not stop enumeration");
    require(recovery < 0.25, @"traversal continued after timeout");
    printf("[snapshot] deadline stopped after %lu/60 getters; main recovered in %.3fs\n",
           (unsigned long)container.calls, recovery);

    container.calls = 0;
    NSTimeInterval cancelAt = NSProcessInfo.processInfo.systemUptime + 0.03;
    result = capture(container, 1.0, ^BOOL { return NSProcessInfo.processInfo.systemUptime >= cancelAt; }, &reason);
    require(result == nil && reason == IOSUsePlaySnapshotStopCancelled, @"client cancellation was not propagated");
    waitForMain();
    require(container.calls > 0 && container.calls < 60, @"cancelled enumeration continued");

    // A single non-returning getter cannot be preempted. Its late result must
    // still be discarded, and a queued request must not start after expiry.
    container.count = 1;
    container.delay = 200000;
    result = capture(container, 0.03, nil, &reason);
    require(result == nil && reason == IOSUsePlaySnapshotStopDeadline, @"slow getter returned success after deadline");
    __block BOOL queuedCaptureRan = NO;
    result = IOSUsePlayRunSnapshot(0.02, nil, ^id(IOSUsePlaySnapshotBudget *budget) {
        (void)budget;
        queuedCaptureRan = YES;
        return @"stale";
    }, &reason);
    require(result == nil && reason == IOSUsePlaySnapshotStopDeadline, @"queued deadline was ignored");
    waitForMain();
    container.delay = 0;
    container.count = 3;
    result = capture(container, 1.0, nil, &reason);
    require([result isEqual:@[@0, @1, @2]] && reason == IOSUsePlaySnapshotStopNone,
            @"fresh capture did not recover after slow getter");
    require(!queuedCaptureRan, @"expired queued capture executed later");

    container.calls = 0;
    result = capture(container, 1.0, ^BOOL { return YES; }, &reason);
    require(result == nil && reason == IOSUsePlaySnapshotStopCancelled && container.calls == 0,
            @"already cancelled request invoked getters");

    container.count = 101;
    NSString *failure = nil;
    IOSUsePlaySnapshotBudget *budget = [[IOSUsePlaySnapshotBudget alloc] initWithTimeout:1];
    result = IOSUsePlaySnapshotContainerElements(container, 100, budget, &failure);
    require(result == nil && failure != nil && container.calls == 0, @"child bound was lost");

    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        SlowContainer *slow = [SlowContainer new];
        slow.count = 1;
        slow.delay = 50000;
        IOSUsePlaySnapshotStopReason mainReason;
        id mainResult = capture(slow, 0.01, nil, &mainReason);
        require(mainResult == nil && mainReason == IOSUsePlaySnapshotStopDeadline,
                @"main-thread direct capture ignored its deadline");
        dispatch_semaphore_signal(done);
    });
    require(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0,
            @"direct capture did not finish");
    puts("[snapshot] cancellation, queued expiry, late-result rejection and recovery PASS");
}

int main(void) {
    @autoreleasepool {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10*NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ _exit(99); });
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            runTests();
            exit(0);
        });
        CFRunLoopRun();
    }
}
