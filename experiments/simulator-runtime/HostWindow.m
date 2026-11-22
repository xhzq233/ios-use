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

@interface RuntimeSceneWindow : NSObject <NSWindowDelegate>
@property(nonatomic) uint32_t sceneID;
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) CALayer *surfaceLayer;
@property(nonatomic) mach_port_t inputPort;
@property(nonatomic) mach_port_t releasePort;
@property(nonatomic) uint32_t displayedSurface;
@property(nonatomic) unsigned frames;
@property(nonatomic) BOOL closed;
@end

// All Scene records and process lifecycle state are owned by the AppKit thread.
static NSMutableDictionary<NSNumber *, RuntimeSceneWindow *> *sceneWindows;
static NSMutableSet<NSNumber *> *closedSceneIDs;
static NSString *artifactDirectory;
static pid_t clientPID;
static BOOL clientExited, clientTerminating, hostClosedNormally;

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
    BOOL presentation = message->msgh_id == IOSUseWindowRelease ||
        message->msgh_id == IOSUseWindowSceneState || message->msgh_id == IOSUseWindowSceneClose;
    dispatch_queue_t queue = presentation ? releaseQueue : inputQueue;
    NSMutableData *packet = [NSMutableData dataWithBytes:message length:message->msgh_size];
    dispatch_async(queue, ^{
        kern_return_t sent = mach_msg(packet.mutableBytes, MACH_SEND_MSG, (mach_msg_size_t)packet.length, 0, 0, 0, 0);
        mach_port_deallocate(mach_task_self(), destination);
        if (sent) fprintf(stderr, "[host-window] message handoff=%d\n", sent);
    });
}

static void sendText(mach_port_t inputPort, NSString *text, uint32_t operation) {
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
@property(nonatomic, weak) RuntimeSceneWindow *scene;
@end
@implementation RuntimeSurfaceView
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (BOOL)acceptsFirstResponder { return self.scene.inputPort != MACH_PORT_NULL; }
- (void)keyDown:(NSEvent *)event { [self interpretKeyEvents:@[event]]; }
- (void)insertText:(id)value {
    NSString *text = [value isKindOfClass:NSAttributedString.class] ? [value string] : value;
    sendText(self.scene.inputPort, text, IOSUseTextInsert);
}
- (void)deleteBackward:(id)sender { sendText(self.scene.inputPort, @"", IOSUseTextDeleteBackward); }
- (void)insertNewline:(id)sender { sendText(self.scene.inputPort, @"\n", IOSUseTextInsert); }
- (void)sendPointer:(NSEvent *)event phase:(uint32_t)phase {
    mach_port_t inputPort = self.scene.inputPort;
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

static void sendSceneState(RuntimeSceneWindow *scene, BOOL foreground) {
    IOSUseWindowSceneStateMessage message = {0};
    message.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    message.header.msgh_size = sizeof(message);
    message.header.msgh_remote_port = scene.releasePort;
    message.header.msgh_id = IOSUseWindowSceneState;
    message.foreground = foreground;
    sendHostMessage(&message.header);
}

static void stopPresentation(RuntimeSceneWindow *scene) {
    uint32_t previous = scene.displayedSurface;
    mach_port_t previousRelease = scene.releasePort;
    scene.releasePort = MACH_PORT_NULL;
    scene.displayedSurface = 0;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    // Keep the last buffer leased until AppKit retires the layer contents, just
    // as when replacing a frame. The producer stops after these leases return.
    [CATransaction setCompletionBlock:^{
        releaseSurface(previousRelease, previous);
        if (previousRelease) mach_port_deallocate(mach_task_self(), previousRelease);
    }];
    scene.surfaceLayer.contents = nil;
    [CATransaction commit];
    [CATransaction flush];
    if (scene.inputPort) mach_port_deallocate(mach_task_self(), scene.inputPort);
    scene.inputPort = MACH_PORT_NULL;
}

static void retireScene(RuntimeSceneWindow *scene, BOOL closeWindow) {
    if (scene.closed) return;
    scene.closed = YES;
    [closedSceneIDs addObject:@(scene.sceneID)];
    stopPresentation(scene);
    scene.window.delegate = nil;
    if (closeWindow) [scene.window close];
    [sceneWindows removeObjectForKey:@(scene.sceneID)];
}

static void stopWebBridge(void) {
    void (*stop)(void) = dlsym(RTLD_DEFAULT, "IOSUseStopWebBridge");
    if (stop) stop();
}

static void terminateClient(void) {
    if (clientTerminating || clientExited) return;
    clientTerminating = YES;
    hostClosedNormally = YES;
    IOSUseStopUserNotifications();
    stopWebBridge();
    for (RuntimeSceneWindow *scene in sceneWindows.allValues) retireScene(scene, YES);
    kill(clientPID, SIGTERM);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        // waitid below keeps the PID owned until the main thread reaps it.
        if (!clientExited) kill(clientPID, SIGKILL);
    });
}

@implementation RuntimeSceneWindow
- (void)windowDidMiniaturize:(NSNotification *)notification { sendSceneState(self, NO); }
- (void)windowDidDeminiaturize:(NSNotification *)notification { sendSceneState(self, YES); }
- (void)windowWillClose:(NSNotification *)notification {
    if (self.closed) return;
    if (sceneWindows.count > 1) {
        mach_msg_header_t message = {0};
        message.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
        message.msgh_size = sizeof(message);
        message.msgh_remote_port = self.releasePort;
        message.msgh_id = IOSUseWindowSceneClose;
        sendHostMessage(&message);
    }
    retireScene(self, NO);
    if (!sceneWindows.count) terminateClient();
}
@end

BOOL IOSUseHostWindowClosedNormally(void) { return hostClosedNormally; }

void IOSUseCloseSceneWindow(uint32_t sceneID) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [closedSceneIDs addObject:@(sceneID)];
        RuntimeSceneWindow *scene = sceneWindows[@(sceneID)];
        if (!scene) return;
        retireScene(scene, YES);
        if (!sceneWindows.count) terminateClient();
    });
}

static RuntimeSceneWindow *selectedScene(void) {
    for (RuntimeSceneWindow *scene in sceneWindows.allValues) {
        if (scene.window == NSApp.keyWindow) return scene;
    }
    // Scene IDs keep the fallback deterministic when no app window is key.
    NSNumber *first = [[sceneWindows.allKeys sortedArrayUsingSelector:@selector(compare:)] firstObject];
    return first ? sceneWindows[first] : nil;
}

static void sendTap(double x, double y) {
    NSWindow *prompt = IOSUseUserNotificationWindow();
    NSWindow *target = prompt ?: selectedScene().window;
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

void IOSUseShowSurface(mach_port_t port, mach_port_t release, mach_port_t input, uint32_t identifier, uint32_t sceneID) {
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
        if (clientTerminating || clientExited || [closedSceneIDs containsObject:@(sceneID)]) {
            releaseSurface(release, identifier);
            if (release) mach_port_deallocate(mach_task_self(), release);
            if (input) mach_port_deallocate(mach_task_self(), input);
            CFRelease(surface);
            return;
        }
        RuntimeSceneWindow *scene = sceneWindows[@(sceneID)];
        if (!scene) {
            scene = [RuntimeSceneWindow new];
            scene.sceneID = sceneID;
            sceneWindows[@(sceneID)] = scene;
            NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 402, 874)
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
                backing:NSBackingStoreBuffered defer:NO];
            scene.window = window;
            window.releasedWhenClosed = NO;
            window.title = @"iOS runtime 26 — experimental app";
            window.delegate = scene;
            RuntimeSurfaceView *view = [[RuntimeSurfaceView alloc] initWithFrame:NSMakeRect(0, 0, 402, 874)];
            view.scene = scene;
            window.contentView = view;
            window.contentView.wantsLayer = YES;
            CALayer *surfaceLayer = [CALayer layer];
            scene.surfaceLayer = surfaceLayer;
            surfaceLayer.frame = window.contentView.bounds;
            surfaceLayer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
            surfaceLayer.contentsGravity = kCAGravityResizeAspect;
            [window.contentView.layer addSublayer:surfaceLayer];
            [window center];
            // Keep independent Scene windows visibly separate without changing
            // the shared logical display size expected by the runtime adapter.
            if (sceneWindows.count > 1) {
                NSPoint origin = window.frame.origin;
                CGFloat offset = 28 * (sceneWindows.count - 1);
                [window setFrameOrigin:NSMakePoint(origin.x + offset, origin.y - offset)];
            }
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
        BOOL hadInput = scene.inputPort != MACH_PORT_NULL;
        if (scene.inputPort) mach_port_deallocate(mach_task_self(), scene.inputPort);
        scene.inputPort = input;
        if (!hadInput && input) [scene.window makeFirstResponder:scene.window.contentView];
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        uint32_t previous = scene.displayedSurface;
        mach_port_t previousRelease = scene.releasePort;
        scene.displayedSurface = identifier;
        scene.releasePort = release;
        // Keep the displayed buffer leased. Return its predecessor only after
        // the native transaction replaces it, so the producer cannot overwrite it.
        [CATransaction setCompletionBlock:^{
            releaseSurface(previousRelease, previous);
            if (previousRelease) mach_port_deallocate(mach_task_self(), previousRelease);
        }];
        scene.surfaceLayer.contents = (__bridge id)surface;
        [CATransaction commit];
        [CATransaction flush];
        if (++scene.frames == 1 || scene.frames % 30 == 0) fprintf(stderr, "[host-window] scene=%u window=%ld frames=%u size=%zux%zu\n",
            sceneID, (long)scene.window.windowNumber, scene.frames, IOSurfaceGetWidth(surface), IOSurfaceGetHeight(surface));
        // Linked only into the presentation workload's broker.
        static void (*observeFrame)(NSWindow *, BOOL);
        static dispatch_once_t observerOnce;
        dispatch_once(&observerOnce, ^{ observeFrame = dlsym(RTLD_DEFAULT, "IOSUseObserveHostFrame"); });
        if (observeFrame) observeFrame(scene.window, scene.inputPort != MACH_PORT_NULL);
        CFRelease(surface);
    });
}

int IOSUseRunHostWindow(pid_t client, NSString *home) {
    artifactDirectory = home;
    clientPID = client;
    sceneWindows = [NSMutableDictionary dictionary];
    closedSceneIDs = [NSMutableSet set];
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
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
                            [(RuntimeSurfaceView *)selectedScene().window.contentView insertText:text];
                        });
                    } else if ([command isEqualToString:@"backspace"]) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [(RuntimeSurfaceView *)selectedScene().window.contentView deleteBackward:nil];
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
                            IOSurfaceRef surface = (__bridge IOSurfaceRef)selectedScene().surfaceLayer.contents;
                            if (!surface) { fprintf(stderr, "[host-window] frame not ready\n"); return; }
                            static unsigned capture;
                            saveStreamFrame(surface, [NSString stringWithFormat:@"capture-%03u.png", ++capture]);
                        });
                    } else if ([command isEqualToString:@"quit"]) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            terminateClient();
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
        siginfo_t info = {0};
        int rc;
        do { rc = waitid(P_PID, client, &info, WEXITED | WNOWAIT); } while (rc < 0 && errno == EINTR);
        dispatch_async(dispatch_get_main_queue(), ^{
            clientExited = YES;
            pid_t reaped;
            do { reaped = waitpid(client, &status, 0); } while (reaped < 0 && errno == EINTR);
            if (rc < 0 || reaped != client) status = 8 << 8;
            IOSUseStopUserNotifications();
            stopWebBridge();
            for (RuntimeSceneWindow *scene in sceneWindows.allValues) retireScene(scene, YES);
            [NSApp stop:nil];
            [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint
                modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0] atStart:YES];
        });
    });
    [NSApp run];
    return status;
}
