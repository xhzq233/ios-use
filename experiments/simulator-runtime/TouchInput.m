// Single-pointer UIKit delivery for the experimental native window.
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import "WindowMessage.h"

typedef struct __IOHIDEvent *IOHIDEventRef;
@interface UITouch (RuntimeTouchAPI)
- (void)setWindow:(UIWindow *)window;
- (void)setView:(UIView *)view;
- (void)setTapCount:(NSUInteger)count;
- (void)setTimestamp:(NSTimeInterval)time;
- (void)setPhase:(UITouchPhase)phase;
- (void)_setLocationInWindow:(CGPoint)point resetPrevious:(BOOL)reset;
- (void)_setIsFirstTouchForView:(BOOL)first;
- (void)_setHidEvent:(IOHIDEventRef)event;
@end
@interface UIEvent (RuntimeTouchAPI)
- (void)_clearTouches;
- (void)_addTouch:(UITouch *)touch forDelayedDelivery:(BOOL)delayed;
- (void)_setHIDEvent:(IOHIDEventRef)event;
- (void)_setTimestamp:(NSTimeInterval)time;
@end
@interface UIApplication (RuntimeTouchAPI)
- (UIEvent *)_touchesEvent;
@end

static __weak UIResponder *textResponder;
@interface UIResponder (RuntimeTextInput)
- (void)iosuseCaptureTextResponder:(id)sender;
@end
@implementation UIResponder (RuntimeTextInput)
- (void)iosuseCaptureTextResponder:(id)sender { textResponder = self; }
@end
@interface NSObject (RuntimeKeyboardAPI)
+ (id)sharedInstance;
- (void)addInputString:(NSString *)text;
- (void)deleteBackward;
@end

static BOOL sendText(uint32_t operation, NSString *text) {
    // UIKit resolves its current first responder through the action chain.
    // Keep selection, editing delegates, and grapheme deletion in the real view.
    textResponder = nil;
    [UIApplication.sharedApplication sendAction:@selector(iosuseCaptureTextResponder:)
                                             to:nil from:nil forEvent:nil];
    UIResponder<UIKeyInput> *input = (id)textResponder;
    if (![input conformsToProtocol:@protocol(UIKeyInput)]) return NO;
    id keyboard = [NSClassFromString(@"UIKeyboardImpl") sharedInstance];
    if (operation == IOSUseTextInsert) [keyboard addInputString:text];
    else if (operation == IOSUseTextDeleteBackward) [keyboard deleteBackward];
    else return NO;
    return YES;
}

static IOHIDEventRef makeDigitizer(CGPoint point, UITouchPhase phase) {
    static IOHIDEventRef (*makeHand)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
        uint32_t, uint32_t, double, double, double, double, double, Boolean, Boolean, uint32_t);
    static IOHIDEventRef (*makeFinger)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
        double, double, double, double, double, double, double, double, double, double, Boolean, Boolean, uint32_t);
    static void (*setInteger)(IOHIDEventRef, uint32_t, CFIndex);
    static void (*append)(IOHIDEventRef, IOHIDEventRef, uint32_t);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        makeHand = dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerEvent");
        makeFinger = dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEventWithQuality");
        setInteger = dlsym(RTLD_DEFAULT, "IOHIDEventSetIntegerValue");
        append = dlsym(RTLD_DEFAULT, "IOHIDEventAppendEvent");
    });
    if (!makeHand || !makeFinger || !setInteger || !append) return NULL;
    BOOL touching = phase != UITouchPhaseEnded && phase != UITouchPhaseCancelled;
    uint32_t mask = phase == UITouchPhaseMoved ? 4 : 3; // position, or range + touch
    uint64_t time = mach_absolute_time();
    IOHIDEventRef hand = makeHand(kCFAllocatorDefault, time, 3, 0, 0, mask, 0,
        0, 0, 0, 0, 0, touching, touching, 0);
    IOHIDEventRef finger = makeFinger(kCFAllocatorDefault, time, 1, 2, mask,
        point.x, point.y, 0, 0, 0, 5, 5, 1, 1, 1, touching, touching, 0);
    if (!hand || !finger) {
        if (hand) CFRelease(hand);
        if (finger) CFRelease(finger);
        return NULL;
    }
    setInteger(hand, (11 << 16) + 25, 1); // digitizer is display-integrated
    setInteger(finger, (11 << 16) + 25, 1);
    append(hand, finger, 0);
    CFRelease(finger);
    return hand;
}

BOOL IOSUseSendTouch(CGPoint point, UITouchPhase phase) {
    NSCAssert(NSThread.isMainThread, @"Touch delivery runs on UIKit's main thread");
    static UITouch *touch;
    UIApplication *app = UIApplication.sharedApplication;
    if (phase == UITouchPhaseBegan) {
        UIWindow *window = nil;
        UIView *hit = nil;
        for (UIWindow *candidate in app.windows.reverseObjectEnumerator) {
            if (candidate.hidden || !candidate.rootViewController) continue;
            hit = [candidate hitTest:point withEvent:nil];
            if (hit) { window = candidate; break; }
        }
        [window makeKeyWindow];
        if (!hit) return NO;
        touch = [UITouch new];
        [touch setWindow:window];
        [touch _setLocationInWindow:point resetPrevious:YES];
        [touch setView:hit];
        [touch setTapCount:1];
        [touch _setIsFirstTouchForView:YES];
        NSLog(@"[touch] target=%@ point=%@ window=%@ root=%@ key=%d gestures=%lu", NSStringFromClass(hit.class),
              NSStringFromCGPoint(point), NSStringFromClass(window.class), NSStringFromClass(window.rootViewController.class),
              window.isKeyWindow, (unsigned long)hit.gestureRecognizers.count);
    }
    if (!touch) return NO;
    IOHIDEventRef hid = makeDigitizer(point, phase);
    if (!hid) return NO;
    NSTimeInterval time = NSProcessInfo.processInfo.systemUptime;
    [touch setPhase:phase];
    [touch setTimestamp:time];
    [touch _setLocationInWindow:point resetPrevious:phase == UITouchPhaseBegan];
    [touch _setHidEvent:hid];
    UIEvent *event = [app _touchesEvent];
    [event _clearTouches];
    [event _setHIDEvent:hid];
    [event _setTimestamp:time];
    [event _addTouch:touch forDelayedDelivery:NO];
    [app sendEvent:event];
    CFRelease(hid);
    if (phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled) {
        // UIApplication's reusable event otherwise retains the ended touch and
        // its window. A dismissed consent window can then intercept later taps.
        [event _clearTouches];
        touch = nil;
    }
    return YES;
}

mach_port_t IOSUseTouchPort(void) {
    static mach_port_t port;
    static dispatch_source_t receiver;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port)) return;
        if (mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND)) return;
        receiver = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, port, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(receiver, ^{
            struct { union {
                mach_msg_header_t header;
                IOSUseWindowPointerMessage pointer;
                IOSUseWindowReleaseMessage release;
                IOSUseWindowTextMessage text;
            } message; char trailer[512]; } packet = {0};
            kern_return_t result = mach_msg(&packet.message.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT,
                0, sizeof(packet), port, 0, 0);
            if (!result && packet.message.header.msgh_id == IOSUseWindowPointer) {
                IOSUseWindowPointerMessage *pointer = &packet.message.pointer;
                BOOL delivered = IOSUseSendTouch(CGPointMake(pointer->x, pointer->y), pointer->phase);
                fprintf(stderr, "[touch] phase=%u delivered=%d\n", pointer->phase, delivered);
            } else if (!result && packet.message.header.msgh_id == IOSUseWindowRelease) {
                void (*releaseFrame)(uint32_t) = dlsym(RTLD_DEFAULT, "IOSUseReleaseFrame");
                if (releaseFrame) releaseFrame(packet.message.release.surfaceID);
            } else if (!result && packet.message.header.msgh_id == IOSUseWindowText) {
                IOSUseWindowTextMessage *message = &packet.message.text;
                if (message->header.msgh_size != sizeof(*message) || message->length > sizeof(message->utf8)) return;
                NSString *text = [[NSString alloc] initWithBytes:message->utf8 length:message->length encoding:NSUTF8StringEncoding];
                BOOL delivered = text && sendText(message->operation, text);
                fprintf(stderr, "[text-input] operation=%u bytes=%u delivered=%d\n", message->operation, message->length, delivered);
            }
        });
        dispatch_resume(receiver);
    });
    return port;
}
