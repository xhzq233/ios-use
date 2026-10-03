#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurfaceRef.h>
#import <mach/mach.h>
#import <sys/wait.h>
#import <dlfcn.h>
#import <math.h>
#import <unistd.h>
#import "WindowMessage.h"

extern NSWindow *IOSUseUserNotificationWindow(void);
extern void IOSUseStopUserNotifications(void);

static mach_port_t inputPort;
static void sendHostMessage(const mach_msg_header_t *message) {
    mach_port_t destination = message->msgh_remote_port;
    if (!destination) return;
    // Input bursts must not delay returning a frame to the producer. Each
    // channel waits on its own serial queue, off the AppKit thread.
    // Retain the destination while queued; incoming frames replace its send right.
    kern_return_t retained = mach_port_mod_refs(mach_task_self(), destination, MACH_PORT_RIGHT_SEND, 1);
    if (retained) { fprintf(stderr, "[host-window] message destination unavailable=%d\n", retained); return; }
    static dispatch_queue_t inputQueue, releaseQueue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inputQueue = dispatch_queue_create("iosuse.runtime.input", DISPATCH_QUEUE_SERIAL);
        releaseQueue = dispatch_queue_create("iosuse.runtime.frame-release", DISPATCH_QUEUE_SERIAL);
    });
    dispatch_queue_t queue = message->msgh_id == IOSUseWindowRelease ? releaseQueue : inputQueue;
    NSMutableData *packet = [NSMutableData dataWithBytes:message length:message->msgh_size];
    dispatch_async(queue, ^{
        kern_return_t sent = mach_msg(packet.mutableBytes, MACH_SEND_MSG, (mach_msg_size_t)packet.length, 0, 0, 0, 0);
        mach_port_deallocate(mach_task_self(), destination);
        if (sent) fprintf(stderr, "[host-window] message handoff=%d\n", sent);
    });
}

static void sendText(NSString *text, uint32_t operation) {
    if (!inputPort) return;
    if (IOSUseUserNotificationWindow()) {
        fprintf(stderr, "[host-window] finish the consent dialog before entering app text\n");
        return;
    }
    NSData *utf8 = [text dataUsingEncoding:NSUTF8StringEncoding];
    IOSUseWindowTextMessage message = {0};
    if (utf8.length > sizeof(message.utf8)) {
        fprintf(stderr, "[host-window] text exceeds 4096 UTF-8 bytes\n");
        return;
    }
    message.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    message.header.msgh_size = sizeof(message);
    message.header.msgh_remote_port = inputPort;
    message.header.msgh_id = IOSUseWindowText;
    message.operation = operation;
    message.length = (uint32_t)utf8.length;
    [utf8 getBytes:message.utf8 length:utf8.length];
    sendHostMessage(&message.header);
}
static void releaseSurface(mach_port_t release, uint32_t identifier) {
    if (!release || !identifier) return;
    IOSUseWindowReleaseMessage message = {0};
    message.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    message.header.msgh_size = sizeof(message);
    message.header.msgh_remote_port = release;
    message.header.msgh_id = IOSUseWindowRelease;
    message.surfaceID = identifier;
    sendHostMessage(&message.header);
}
@interface RuntimeSurfaceView : NSView
@end
@implementation RuntimeSurfaceView
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (BOOL)acceptsFirstResponder { return inputPort != MACH_PORT_NULL; }
- (void)keyDown:(NSEvent *)event { [self interpretKeyEvents:@[event]]; }
- (void)insertText:(id)value {
    NSString *text = [value isKindOfClass:NSAttributedString.class] ? [value string] : value;
    sendText(text, IOSUseTextInsert);
}
- (void)deleteBackward:(id)sender { sendText(@"", IOSUseTextDeleteBackward); }
- (void)insertNewline:(id)sender { sendText(@"\n", IOSUseTextInsert); }
- (void)sendPointer:(NSEvent *)event phase:(uint32_t)phase {
    if (!inputPort) return;
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    IOSUseWindowPointerMessage message = {0};
    message.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    message.header.msgh_size = sizeof(message);
    message.header.msgh_remote_port = inputPort;
    message.header.msgh_id = IOSUseWindowPointer;
    message.x = point.x * 402 / self.bounds.size.width;
    message.y = point.y * 874 / self.bounds.size.height;
    message.phase = phase;
    sendHostMessage(&message.header);
}
- (void)mouseDown:(NSEvent *)event { [self sendPointer:event phase:0]; }
- (void)mouseDragged:(NSEvent *)event { [self sendPointer:event phase:1]; }
- (void)mouseUp:(NSEvent *)event { [self sendPointer:event phase:3]; }
@end

@interface RuntimeWindowDelegate : NSObject <NSWindowDelegate>
@property(nonatomic) pid_t client;
@property(nonatomic) BOOL closed;
@end
static void stopPresentation(void);
@implementation RuntimeWindowDelegate
- (void)windowWillClose:(NSNotification *)notification {
    self.closed = YES;
    stopPresentation();
    kill(self.client, SIGTERM);
}
@end

static NSWindow *window;
static CALayer *surfaceLayer;
static RuntimeWindowDelegate *windowDelegate;
static NSString *artifactDirectory;
static uint32_t displayedSurface;
static mach_port_t displayedReleasePort;

static void stopPresentation(void) {
    surfaceLayer.contents = nil;
    [CATransaction flush];
    releaseSurface(displayedReleasePort, displayedSurface);
    if (displayedReleasePort) mach_port_deallocate(mach_task_self(), displayedReleasePort);
    displayedReleasePort = MACH_PORT_NULL;
    displayedSurface = 0;
    if (inputPort) mach_port_deallocate(mach_task_self(), inputPort);
    inputPort = MACH_PORT_NULL;
}

BOOL IOSUseHostWindowClosedNormally(void) { return windowDelegate.closed; }

static void sendTap(double x, double y) {
    NSWindow *prompt = IOSUseUserNotificationWindow();
    NSWindow *target = prompt ?: window;
    if (!target) { fprintf(stderr, "[host-window] window not ready\n"); return; }
    NSPoint point = NSMakePoint(x, target.contentView.bounds.size.height - y);
    NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:point modifierFlags:0
        timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:target.windowNumber context:nil
        eventNumber:1 clickCount:1 pressure:1];
    if (prompt) {
        // NSButton tracks mouse-up inside mouseDown; queue the release first.
        NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:point modifierFlags:0
            timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:target.windowNumber context:nil
            eventNumber:2 clickCount:1 pressure:0];
        [NSApp postEvent:up atStart:YES];
        [target sendEvent:down];
        fprintf(stderr, "[host-prompt] tap completed %.1f %.1f\n", x, y);
        return;
    }
    [target sendEvent:down];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:point modifierFlags:0
            timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:target.windowNumber context:nil
            eventNumber:2 clickCount:1 pressure:0];
        [target sendEvent:up];
        fprintf(stderr, "[host-window] tap completed %.1f %.1f\n", x, y);
    });
}

// Explicit diagnostic readback; presentation itself only shares surfaces.
static void saveStreamFrame(IOSurfaceRef surface, NSString *filename) {
    if (IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL)) return;
    CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmap = CGBitmapContextCreate(IOSurfaceGetBaseAddress(surface),
        IOSurfaceGetWidth(surface), IOSurfaceGetHeight(surface), 8,
        IOSurfaceGetBytesPerRow(surface), color,
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGImageRef image = bitmap ? CGBitmapContextCreateImage(bitmap) : NULL;
    if (image) {
        NSBitmapImageRep *representation = [[NSBitmapImageRep alloc] initWithCGImage:image];
        NSData *png = [representation representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        BOOL saved = [png writeToFile:[artifactDirectory stringByAppendingPathComponent:filename] atomically:YES];
        fprintf(stderr, "[host-window] stream diagnostic saved=%d file=%s\n", saved, filename.UTF8String);
        CGImageRelease(image);
    }
    if (bitmap) CGContextRelease(bitmap);
    CGColorSpaceRelease(color);
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
}

void IOSUseShowSurface(mach_port_t port, mach_port_t release, mach_port_t input, uint32_t identifier) {
    IOSurfaceRef surface = IOSurfaceLookupFromMachPort(port);
    mach_port_deallocate(mach_task_self(), port);
    if (!surface) {
        releaseSurface(release, identifier);
        if (release) mach_port_deallocate(mach_task_self(), release);
        if (input) mach_port_deallocate(mach_task_self(), input);
        fprintf(stderr, "[host-window] surface lookup failed\n");
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (windowDelegate.closed) {
            releaseSurface(release, identifier);
            if (release) mach_port_deallocate(mach_task_self(), release);
            if (input) mach_port_deallocate(mach_task_self(), input);
            CFRelease(surface);
            return;
        }
        if (inputPort) mach_port_deallocate(mach_task_self(), inputPort);
        inputPort = input;
        if (!window) {
            window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 402, 874)
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
                backing:NSBackingStoreBuffered defer:NO];
            window.releasedWhenClosed = NO;
            window.title = @"iOS runtime 26 — experimental app";
            window.delegate = windowDelegate;
            window.contentView = [[RuntimeSurfaceView alloc] initWithFrame:NSMakeRect(0, 0, 402, 874)];
            window.contentView.wantsLayer = YES;
            [window makeFirstResponder:window.contentView];
            surfaceLayer = [CALayer layer];
            surfaceLayer.frame = window.contentView.bounds;
            surfaceLayer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
            surfaceLayer.contentsGravity = kCAGravityResizeAspect;
            [window.contentView.layer addSublayer:surfaceLayer];
            [window center];
            [window makeKeyAndOrderFront:nil];
            [NSApp activateIgnoringOtherApps:YES];
            const char *tap = getenv("IOS_USE_RUNTIME_TAP");
            double x, y;
            if (tap && sscanf(tap, "%lf,%lf", &x, &y) == 2) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    sendTap(x, y);
                });
            }
        }
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        uint32_t previous = displayedSurface;
        mach_port_t previousRelease = displayedReleasePort;
        displayedSurface = identifier;
        displayedReleasePort = release;
        // Keep the displayed buffer leased. Return its predecessor only after
        // the native transaction replaces it, so the producer cannot overwrite it.
        [CATransaction setCompletionBlock:^{
            releaseSurface(previousRelease, previous);
            if (previousRelease) mach_port_deallocate(mach_task_self(), previousRelease);
        }];
        surfaceLayer.contents = (__bridge id)surface;
        [CATransaction commit];
        [CATransaction flush];
        static unsigned frames;
        if (++frames == 1 || frames % 30 == 0) fprintf(stderr, "[host-window] window=%ld frames=%u size=%zux%zu\n",
            (long)window.windowNumber, frames, IOSurfaceGetWidth(surface), IOSurfaceGetHeight(surface));
        // Linked only into the presentation workload's broker.
        static void (*observeFrame)(NSWindow *, BOOL);
        static dispatch_once_t observerOnce;
        dispatch_once(&observerOnce, ^{ observeFrame = dlsym(RTLD_DEFAULT, "IOSUseObserveHostFrame"); });
        if (observeFrame) observeFrame(window, inputPort != MACH_PORT_NULL);
        CFRelease(surface);
    });
}

int IOSUseRunHostWindow(pid_t client, NSString *home) {
    artifactDirectory = home;
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    windowDelegate = [RuntimeWindowDelegate new];
    windowDelegate.client = client;
    if (isatty(STDIN_FILENO)) {
        // Interactive diagnostics use the same native mouse path as the window.
        // No extra daemon, listening socket, or accessibility permission is needed.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            char *line = NULL;
            size_t capacity = 0;
            while (getline(&line, &capacity, stdin) > 0) {
                @autoreleasepool {
                    NSString *rawCommand = [@(line) stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
                    NSString *command = [rawCommand stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                    double x, y;
                    char extra;
                    if (sscanf(command.UTF8String, "tap %lf %lf %c", &x, &y, &extra) == 2 && isfinite(x) && isfinite(y)) {
                        dispatch_async(dispatch_get_main_queue(), ^{ sendTap(x, y); });
                    } else if ([rawCommand hasPrefix:@"text "]) {
                        NSString *text = [rawCommand substringFromIndex:5];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [(RuntimeSurfaceView *)window.contentView insertText:text];
                        });
                    } else if ([command isEqualToString:@"backspace"]) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [(RuntimeSurfaceView *)window.contentView deleteBackward:nil];
                        });
                    } else if ([command isEqualToString:@"capture"]) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            NSWindow *prompt = IOSUseUserNotificationWindow();
                            if (prompt) {
                                NSView *view = prompt.contentView;
                                [view display];
                                NSBitmapImageRep *bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
                                [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
                                static unsigned captures;
                                NSString *filename = [NSString stringWithFormat:@"prompt-%03u.png", ++captures];
                                NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                                BOOL saved = [png writeToFile:[artifactDirectory stringByAppendingPathComponent:filename] atomically:YES];
                                fprintf(stderr, "[host-prompt] view diagnostic saved=%d file=%s\n", saved, filename.UTF8String);
                                return;
                            }
                            IOSurfaceRef surface = (__bridge IOSurfaceRef)surfaceLayer.contents;
                            if (!surface) { fprintf(stderr, "[host-window] frame not ready\n"); return; }
                            static unsigned capture;
                            saveStreamFrame(surface, [NSString stringWithFormat:@"capture-%03u.png", ++capture]);
                        });
                    } else if ([command isEqualToString:@"quit"]) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            IOSUseStopUserNotifications();
                            if (window) [window performClose:nil];
                            else { windowDelegate.closed = YES; kill(client, SIGTERM); }
                        });
                        break;
                    } else {
                        fprintf(stderr, "[host-window] commands: tap X Y, text TEXT, backspace, capture, quit\n");
                    }
                }
            }
            free(line);
        });
    }
    __block int status = 0;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        while (waitpid(client, &status, 0) < 0 && errno == EINTR) {}
        dispatch_async(dispatch_get_main_queue(), ^{
            IOSUseStopUserNotifications();
            stopPresentation();
            [window orderOut:nil];
            [NSApp stop:nil];
            [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint
                modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0] atStart:YES];
        });
    });
    [NSApp run];
    return status;
}
