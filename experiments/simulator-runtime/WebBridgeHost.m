// Public macOS WebKit for the explicitly selected experimental UIKit bridge.
// Each hidden native view supplies snapshots; UIKit owns its displayed geometry.
#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#import <IOSurface/IOSurfaceRef.h>
#import <math.h>
#import "WebBridgeTransport.h"

@interface RuntimeWebBridgeView : NSObject <WKNavigationDelegate>
@property(nonatomic, strong) NSNumber *identifier;
@property(nonatomic) mach_port_t replyPort;
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) NSMapTable<WKNavigation *, NSNumber *> *navigations;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic) BOOL closed, snapshotInFlight, waitingForAck, snapshotErrorReported;
@property(nonatomic) NSUInteger frames;
- (void)captureFrame;
- (void)sendNavigation:(WKNavigation *)navigation event:(NSString *)event error:(NSError *)error provisional:(BOOL)provisional;
@end

// Accessed only on the AppKit thread, including WebKit completion callbacks.
static NSMutableDictionary<NSNumber *, RuntimeWebBridgeView *> *views;
static BOOL stopping;
static NSUInteger lateCallbacks;

static NSError *bridgeError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"IOSUseWebBridgeErrorDomain" code:code
                          userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSDictionary *errorPayload(NSError *error) {
    return @{@"domain": error.domain, @"code": @(error.code),
             @"message": error.localizedDescription ?: @"WebKit operation failed"};
}

static void sendError(mach_port_t destination, NSNumber *identifier, NSString *operation,
                      NSNumber *request, NSError *error) {
    NSMutableDictionary *payload = [@{@"op": @"error", @"view": identifier ?: @0,
        @"operation": operation ?: @"invalid", @"error": errorPayload(error)} mutableCopy];
    if (request) payload[@"request"] = request;
    if (destination) IOSUseSendWebMessage(destination, payload, MACH_PORT_NULL, NULL);
    fprintf(stderr, "[web-bridge-host] error view=%llu code=%ld\n",
            identifier.unsignedLongLongValue, (long)error.code);
}

static void ignoredCallback(NSString *kind, NSNumber *identifier) {
    fprintf(stderr, "[web-bridge-host] late %s ignored view=%llu callbacks=%lu views=%lu\n",
            kind.UTF8String, identifier.unsignedLongLongValue, (unsigned long)++lateCallbacks,
            (unsigned long)views.count);
}

static IOSurfaceRef copySnapshotSurface(NSImage *image) {
    CGImageRef pixels = [image CGImageForProposedRect:NULL context:nil hints:nil];
    if (!pixels) return NULL;
    size_t width = CGImageGetWidth(pixels), height = CGImageGetHeight(pixels);
    size_t rowBytes = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * 4);
    IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)@{
        (__bridge NSString *)kIOSurfaceWidth: @(width),
        (__bridge NSString *)kIOSurfaceHeight: @(height),
        (__bridge NSString *)kIOSurfaceBytesPerElement: @4,
        (__bridge NSString *)kIOSurfaceBytesPerRow: @(rowBytes),
        (__bridge NSString *)kIOSurfaceAllocSize: @(rowBytes * height),
        (__bridge NSString *)kIOSurfacePixelFormat: @(0x42475241), // BGRA
    });
    if (!surface) return NULL;
    if (IOSurfaceLock(surface, 0, NULL)) { CFRelease(surface); return NULL; }
    CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmap = CGBitmapContextCreate(IOSurfaceGetBaseAddress(surface), width, height,
        8, rowBytes, color, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    if (bitmap) {
        CGContextSetBlendMode(bitmap, kCGBlendModeCopy);
        CGContextDrawImage(bitmap, CGRectMake(0, 0, width, height), pixels);
        CGContextRelease(bitmap);
    }
    CGColorSpaceRelease(color);
    IOSurfaceUnlock(surface, 0, NULL);
    if (!bitmap) { CFRelease(surface); return NULL; }
    return surface;
}

@implementation RuntimeWebBridgeView
- (void)dealloc { if (_replyPort) mach_port_deallocate(mach_task_self(), _replyPort); }

- (void)captureFrame {
    if (self.closed || self.snapshotInFlight || self.waitingForAck ||
        NSIsEmptyRect(self.webView.bounds)) return;
    self.snapshotInFlight = YES;
    WKSnapshotConfiguration *configuration = [WKSnapshotConfiguration new];
    configuration.rect = self.webView.bounds;
    configuration.snapshotWidth = @(self.webView.bounds.size.width);
    NSNumber *identifier = self.identifier;
    __weak RuntimeWebBridgeView *weakSelf = self;
    [self.webView takeSnapshotWithConfiguration:configuration completionHandler:^(NSImage *image, NSError *error) {
        RuntimeWebBridgeView *view = weakSelf;
        if (!view || view.closed) { ignoredCallback(@"snapshot", identifier); return; }
        view.snapshotInFlight = NO;
        IOSurfaceRef surface = image && !error ? copySnapshotSurface(image) : NULL;
        if (!surface) {
            if (!view.snapshotErrorReported) sendError(view.replyPort, identifier, @"snapshot", nil,
                error ?: bridgeError(4, @"WebKit snapshot could not be copied to an IOSurface"));
            view.snapshotErrorReported = YES;
            return;
        }
        view.snapshotErrorReported = NO;
        view.waitingForAck = YES;
        // A fresh surface remains immutable after handoff. UIKit may retain it
        // beyond frameAck while its own Core Animation transaction completes.
        IOSUseSendWebMessage(view.replyPort, @{@"op": @"frame", @"view": identifier,
            @"width": @(IOSurfaceGetWidth(surface)), @"height": @(IOSurfaceGetHeight(surface))},
            MACH_PORT_NULL, surface);
        CFRelease(surface);
        if (++view.frames == 1 || view.frames % 25 == 0) fprintf(stderr,
            "[web-bridge-host] frame view=%llu frames=%lu views=%lu\n", identifier.unsignedLongLongValue,
            (unsigned long)view.frames, (unsigned long)views.count);
    }];
}

- (void)sendNavigation:(WKNavigation *)navigation event:(NSString *)event error:(NSError *)error provisional:(BOOL)provisional {
    if (self.closed) return;
    NSNumber *request = [self.navigations objectForKey:navigation] ?: @0;
    NSMutableDictionary *payload = [@{@"op": @"navigation", @"view": self.identifier,
        @"request": request, @"event": event} mutableCopy];
    if (error) {
        payload[@"error"] = errorPayload(error);
        payload[@"provisional"] = @(provisional);
    }
    IOSUseSendWebMessage(self.replyPort, payload, MACH_PORT_NULL, NULL);
    if ([event isEqualToString:@"finish"] || [event isEqualToString:@"fail"])
        [self.navigations removeObjectForKey:navigation];
}

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
    [self sendNavigation:navigation event:@"start" error:nil provisional:YES];
}
- (void)webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)navigation {
    [self sendNavigation:navigation event:@"commit" error:nil provisional:NO];
}
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    [self sendNavigation:navigation event:@"finish" error:nil provisional:NO];
}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self sendNavigation:navigation event:@"fail" error:error provisional:YES];
}
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self sendNavigation:navigation event:@"fail" error:error provisional:NO];
}
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    if (self.closed) return;
    NSError *error = [NSError errorWithDomain:WKErrorDomain code:WKErrorWebContentProcessTerminated
        userInfo:@{NSLocalizedDescriptionKey: @"Native WebKit content process terminated"}];
    NSArray *navigations = self.navigations.keyEnumerator.allObjects;
    for (WKNavigation *navigation in navigations)
        [self sendNavigation:navigation event:@"fail" error:error provisional:NO];
    if (!navigations.count) sendError(self.replyPort, self.identifier, @"content", nil, error);
}
@end

static BOOL requestedSize(NSDictionary *payload, NSSize *size) {
    id width = payload[@"width"], height = payload[@"height"];
    if (![width isKindOfClass:NSNumber.class] || ![height isKindOfClass:NSNumber.class]) return NO;
    *size = NSMakeSize([width doubleValue], [height doubleValue]);
    return isfinite(size->width) && isfinite(size->height) && size->width >= 0 && size->height >= 0;
}

static void resizeView(RuntimeWebBridgeView *view, NSSize size) {
    [view.window setContentSize:NSMakeSize(MAX(1, size.width), MAX(1, size.height))];
    view.webView.frame = NSMakeRect(0, 0, size.width, size.height);
    view.snapshotErrorReported = NO;
}

static void destroyView(RuntimeWebBridgeView *view, BOOL notify) {
    if (view.closed) return;
    view.closed = YES;
    [view.timer invalidate]; view.timer = nil;
    view.webView.navigationDelegate = nil;
    [view.webView stopLoading];
    [view.webView removeFromSuperview];
    [view.window close];
    view.webView = nil; view.window = nil;
    [view.navigations removeAllObjects];
    [views removeObjectForKey:view.identifier];
    fprintf(stderr, "[web-bridge-host] destroyed view=%llu views=%lu snapshot=%d frame=%d\n",
            view.identifier.unsignedLongLongValue, (unsigned long)views.count,
            view.snapshotInFlight, view.waitingForAck);
    if (notify) IOSUseSendWebMessage(view.replyPort, @{@"op": @"destroyed", @"view": view.identifier,
        @"remaining": @(views.count)}, MACH_PORT_NULL, NULL);
    if (view.replyPort) mach_port_deallocate(mach_task_self(), view.replyPort);
    view.replyPort = MACH_PORT_NULL;
}

// Returns YES only when the create operation adopted the incoming send right.
static BOOL handlePayload(NSDictionary *payload, mach_port_t incomingReply) {
    NSString *operation = [payload[@"op"] isKindOfClass:NSString.class] ? payload[@"op"] : nil;
    NSNumber *identifier = [payload[@"view"] isKindOfClass:NSNumber.class] ? payload[@"view"] : nil;
    NSNumber *request = [payload[@"request"] isKindOfClass:NSNumber.class] ? payload[@"request"] : nil;
    RuntimeWebBridgeView *view = identifier ? views[identifier] : nil;
    mach_port_t destination = view.replyPort ?: incomingReply;
    // Returning an in-flight frame can race a destroy request or shutdown.
    if ([operation isEqualToString:@"frameAck"] && (!view || stopping)) return NO;
    if (!operation || !identifier || stopping) {
        sendError(destination, identifier, operation, request,
            bridgeError(1, stopping ? @"Web bridge is stopping" : @"A view identifier and operation are required"));
        return NO;
    }
    if ([operation isEqualToString:@"create"]) {
        NSSize size;
        if (view || !incomingReply || !requestedSize(payload, &size)) {
            sendError(destination, identifier, operation, request,
                bridgeError(1, @"Create requires a new view, a reply port, and nonnegative finite dimensions"));
            return NO;
        }
        if (!views) views = [NSMutableDictionary dictionary];
        [NSApplication sharedApplication];
        view = [RuntimeWebBridgeView new];
        view.identifier = identifier;
        view.replyPort = incomingReply;
        view.navigations = [NSMapTable strongToStrongObjectsMapTable];
        WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
        configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
        view.webView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)
                                        configuration:configuration];
        view.webView.navigationDelegate = view;
        view.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, MAX(1, size.width), MAX(1, size.height))
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        view.window.releasedWhenClosed = NO;
        [view.window.contentView addSubview:view.webView];
        [view.window orderOut:nil];
        views[identifier] = view;
        __weak RuntimeWebBridgeView *weakView = view;
        view.timer = [NSTimer timerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *timer) {
            [weakView captureFrame];
        }];
        [NSRunLoop.mainRunLoop addTimer:view.timer forMode:NSRunLoopCommonModes];
        fprintf(stderr, "[web-bridge-host] created view=%llu views=%lu\n",
                identifier.unsignedLongLongValue, (unsigned long)views.count);
        return YES;
    }
    if (!view) {
        sendError(destination, identifier, operation, request, bridgeError(1, @"Web view does not exist"));
        return NO;
    }
    if ([operation isEqualToString:@"load"]) {
        id html = payload[@"html"], base = payload[@"baseURL"];
        if (![html isKindOfClass:NSString.class] || !request ||
            (base && base != NSNull.null && ![base isKindOfClass:NSString.class])) {
            sendError(destination, identifier, operation, request,
                bridgeError(1, @"Load requires HTML, a request identifier, and an optional base URL"));
            return NO;
        }
        NSURL *baseURL = [base isKindOfClass:NSString.class] ? [NSURL URLWithString:base] : nil;
        WKNavigation *navigation = [view.webView loadHTMLString:html baseURL:baseURL];
        if (navigation) [view.navigations setObject:request forKey:navigation];
        else IOSUseSendWebMessage(destination, @{@"op": @"navigation", @"view": identifier,
            @"request": request, @"event": @"fail", @"provisional": @YES, @"error": errorPayload(bridgeError(1,
                @"WebKit did not start the requested navigation"))}, MACH_PORT_NULL, NULL);
        view.snapshotErrorReported = NO;
    } else if ([operation isEqualToString:@"eval"]) {
        NSString *script = payload[@"script"];
        if (![script isKindOfClass:NSString.class] || !request) {
            sendError(destination, identifier, operation, request,
                bridgeError(1, @"Evaluation requires JavaScript and a request identifier"));
            return NO;
        }
        __weak RuntimeWebBridgeView *weakView = view;
        [view.webView evaluateJavaScript:script completionHandler:^(id value, NSError *error) {
            RuntimeWebBridgeView *current = weakView;
            if (!current || current.closed) { ignoredCallback(@"evaluation", identifier); return; }
            if (!error && value && ![NSJSONSerialization isValidJSONObject:@{@"value": value}])
                error = bridgeError(3, @"JavaScript result cannot be represented as JSON");
            NSMutableDictionary *response = [@{@"op": @"evaluation", @"view": identifier,
                @"request": request} mutableCopy];
            if (error) response[@"error"] = errorPayload(error);
            else if (value) response[@"value"] = value;
            IOSUseSendWebMessage(current.replyPort, response, MACH_PORT_NULL, NULL);
        }];
    } else if ([operation isEqualToString:@"resize"]) {
        NSSize size;
        if (requestedSize(payload, &size)) resizeView(view, size);
        else sendError(destination, identifier, operation, request,
            bridgeError(1, @"Resize requires nonnegative finite dimensions"));
    } else if ([operation isEqualToString:@"frameAck"]) {
        view.waitingForAck = NO;
    } else if ([operation isEqualToString:@"destroy"]) {
        destroyView(view, YES);
    } else {
        sendError(destination, identifier, operation, request, bridgeError(2, @"Unsupported web bridge operation"));
    }
    return NO;
}

BOOL IOSUseHandleWebBridgeMessage(mach_msg_header_t *message) {
    if (message->msgh_id != IOSUseWebBridgeMessageID) return NO;
    mach_port_t reply = MACH_PORT_NULL;
    IOSurfaceRef surface = NULL;
    NSDictionary *payload = IOSUseDecodeWebMessage(message, &reply, &surface);
    if (surface) CFRelease(surface); // Client requests do not transfer pixels.
    if (!payload) {
        if (reply) mach_port_deallocate(mach_task_self(), reply);
        fprintf(stderr, "[web-bridge-host] invalid message\n");
        return YES;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL adopted = handlePayload(payload, reply);
        if (reply && !adopted) mach_port_deallocate(mach_task_self(), reply);
    });
    return YES;
}

NSUInteger IOSUseWebBridgeViewCount(void) { return views.count; }

void IOSUseStopWebBridge(void) {
    stopping = YES;
    for (RuntimeWebBridgeView *view in views.allValues) destroyView(view, NO);
}
