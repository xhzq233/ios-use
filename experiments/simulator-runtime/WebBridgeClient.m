// Opt-in proof of API forwarding. The original UIKit object still owns layout.
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "WebBridgeTransport.h"

@interface NSObject (WebBridgeSceneAPI)
- (NSString *)_sceneIdentifier;
@end
@interface RuntimeWebPage : NSObject
@property(nonatomic, weak) WKWebView *web;
@property(nonatomic, weak) id<WKNavigationDelegate> delegate;
@property(nonatomic, strong) CALayer *imageLayer;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, id> *callbacks;
@property(nonatomic, copy) NSString *sceneIdentifier;
@property(nonatomic) uint64_t identifier;
@property(nonatomic) uint64_t nextRequest;
@property(nonatomic) uint64_t navigation;
@property(nonatomic) CGSize size;
@property(nonatomic) BOOL created;
@property(nonatomic) BOOL closed;
- (void)close;
@end

static char pageKey;
static NSMapTable<NSNumber *, RuntimeWebPage *> *pages;
static mach_port_t brokerPort, replyPort;
static dispatch_source_t receiver;
static uint64_t nextPage;

static NSError *cancelled(void) {
    return [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled
        userInfo:@{NSLocalizedDescriptionKey: @"The bridged web view was removed or its Scene closed."}];
}
static NSError *decodeError(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    return [NSError errorWithDomain:value[@"domain"] ?: @"IOSUseWebBridge" code:[value[@"code"] integerValue]
        userInfo:@{NSLocalizedDescriptionKey: value[@"message"] ?: @"Native WebKit operation failed."}];
}
static void sendWeb(RuntimeWebPage *page, NSString *operation, NSDictionary *fields) {
    NSMutableDictionary *message = [fields mutableCopy] ?: [NSMutableDictionary new];
    message[@"op"] = operation; message[@"view"] = @(page.identifier);
    IOSUseSendWebMessage(brokerPort, message, [operation isEqualToString:@"create"] ? replyPort : MACH_PORT_NULL, NULL);
}

@implementation RuntimeWebPage
- (void)close {
    if (self.closed) return;
    self.closed = YES;
    if (self.created) sendWeb(self, @"destroy", nil);
    [pages removeObjectForKey:@(self.identifier)];
    self.imageLayer.contents = nil;
    [self.imageLayer removeFromSuperlayer];
    // Once snapshots stop, publish the final removal without depending on the
    // next incoming web frame. Run after the caller's synchronous view edits.
    dispatch_async(dispatch_get_main_queue(), ^{ [CATransaction flush]; });
    NSArray *callbacks = self.callbacks.allValues;
    [self.callbacks removeAllObjects];
    for (void (^completion)(id, NSError *) in callbacks)
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, cancelled()); });
}
- (void)dealloc {
    // Associated state follows the real WKWebView's lifetime. No WebKit C++
    // objects or private navigation wrappers are synthesized by this adapter.
    if (!self.closed && self.created) sendWeb(self, @"destroy", nil);
    NSArray *callbacks = self.callbacks.allValues;
    for (void (^completion)(id, NSError *) in callbacks)
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, cancelled()); });
}
@end

NSUInteger IOSUseWebBridgeViewCount(void) {
    NSUInteger count = 0;
    for (RuntimeWebPage *page in pages.objectEnumerator) if (page.created && !page.closed) count++;
    return count;
}
NSUInteger IOSUseWebBridgeOutstandingCallbacks(void) {
    NSUInteger count = 0;
    for (RuntimeWebPage *page in pages.objectEnumerator) count += page.callbacks.count;
    return count;
}
void IOSUseRetireWebViewsForScene(NSString *identifier) {
    for (RuntimeWebPage *page in pages.objectEnumerator.allObjects)
        if ([page.sceneIdentifier isEqualToString:identifier]) [page close];
}

static void received(NSDictionary *message, IOSurfaceRef surface) {
    RuntimeWebPage *page = [pages objectForKey:message[@"view"]];
    NSString *operation = message[@"op"];
    if ([operation isEqualToString:@"frame"]) {
        if (page && !page.closed && surface) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            page.imageLayer.contents = (__bridge id)surface;
            [CATransaction commit];
            [CATransaction flush];
        }
        // The native producer allocates a distinct surface for every frame;
        // UIKit/CA retain the displayed contents independently of this ack.
        IOSUseSendWebMessage(brokerPort, @{@"op": @"frameAck", @"view": message[@"view"]}, MACH_PORT_NULL, NULL);
        return;
    }
    if (!page || page.closed) return;
    if ([operation isEqualToString:@"evaluation"]) {
        void (^completion)(id, NSError *) = page.callbacks[message[@"request"]];
        [page.callbacks removeObjectForKey:message[@"request"]];
        id value = message[@"value"];
        if (completion) completion(value, decodeError(message[@"error"]));
    } else if ([operation isEqualToString:@"navigation"] && [message[@"request"] unsignedLongLongValue] == page.navigation) {
        id<WKNavigationDelegate> delegate = page.delegate;
        NSString *event = message[@"event"];
        if ([event isEqualToString:@"start"] && [delegate respondsToSelector:@selector(webView:didStartProvisionalNavigation:)])
            [delegate webView:page.web didStartProvisionalNavigation:nil];
        else if ([event isEqualToString:@"commit"] && [delegate respondsToSelector:@selector(webView:didCommitNavigation:)])
            [delegate webView:page.web didCommitNavigation:nil];
        else if ([event isEqualToString:@"finish"] && [delegate respondsToSelector:@selector(webView:didFinishNavigation:)])
            [delegate webView:page.web didFinishNavigation:nil];
        else if ([event isEqualToString:@"fail"]) {
            NSError *error = decodeError(message[@"error"]);
            if ([message[@"provisional"] boolValue] && [delegate respondsToSelector:@selector(webView:didFailProvisionalNavigation:withError:)])
                [delegate webView:page.web didFailProvisionalNavigation:nil withError:error];
            else if ([delegate respondsToSelector:@selector(webView:didFailNavigation:withError:)])
                [delegate webView:page.web didFailNavigation:nil withError:error];
        }
    } else if ([operation isEqualToString:@"error"]) {
        NSError *error = decodeError(message[@"error"]);
        void (^completion)(id, NSError *) = page.callbacks[message[@"request"] ?: @0];
        [page.callbacks removeObjectForKey:message[@"request"] ?: @0];
        if (completion) completion(nil, error);
        else {
            NSString *failedOperation = message[@"operation"];
            if ([failedOperation isEqualToString:@"create"] || [failedOperation isEqualToString:@"load"]) {
                id<WKNavigationDelegate> delegate = page.delegate;
                if ([delegate respondsToSelector:@selector(webView:didFailProvisionalNavigation:withError:)])
                    [delegate webView:page.web didFailProvisionalNavigation:nil withError:error];
                if ([failedOperation isEqualToString:@"create"]) [page close];
            } else {
                NSLog(@"[web-bridge] host operation failed: %@", error);
                exit(171); // Selected diagnostic cannot continue with a broken frame path.
            }
        }
    }
}

static void connectBridge(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pages = [NSMapTable strongToWeakObjectsMapTable];
        mach_port_array_t ports = NULL; mach_msg_type_number_t count = 0;
        if (mach_ports_lookup(mach_task_self(), &ports, &count) || !count) exit(170);
        brokerPort = ports[0];
        for (unsigned i = 1; i < count; i++) if (ports[i]) mach_port_deallocate(mach_task_self(), ports[i]);
        vm_deallocate(mach_task_self(), (vm_address_t)ports, count * sizeof(mach_port_t));
        if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &replyPort) ||
            mach_port_insert_right(mach_task_self(), replyPort, replyPort, MACH_MSG_TYPE_MAKE_SEND)) exit(170);
        receiver = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, replyPort, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(receiver, ^{
            struct { mach_msg_header_t header; char remainder[512]; } packet = {0};
            if (mach_msg(&packet.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(packet), replyPort, 0, 0)) return;
            mach_port_t unusedPort; IOSurfaceRef surface;
            NSDictionary *message = IOSUseDecodeWebMessage(&packet.header, &unusedPort, &surface);
            if (unusedPort) mach_port_deallocate(mach_task_self(), unusedPort);
            if (message) received(message, surface);
            if (surface) CFRelease(surface);
        });
        dispatch_resume(receiver);
    });
}

static void updateLayout(RuntimeWebPage *page) {
    if (!page || page.closed) return;
    WKWebView *web = page.web;
    web.scrollView.hidden = YES;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    page.imageLayer.frame = web.bounds;
    [CATransaction commit];
    NSString *identifier = [(NSObject *)web.window.windowScene _sceneIdentifier];
    if (identifier) page.sceneIdentifier = identifier;
    if (page.created && !CGSizeEqualToSize(page.size, web.bounds.size)) {
        page.size = web.bounds.size;
        sendWeb(page, @"resize", @{@"width": @(page.size.width), @"height": @(page.size.height)});
    }
}
static void ensureCreated(RuntimeWebPage *page) {
    updateLayout(page);
    if (page.created || page.closed) return;
    page.created = YES;
    page.size = page.web.bounds.size;
    sendWeb(page, @"create", @{@"width": @(page.size.width), @"height": @(page.size.height)});
}

static id (*originalInit)(WKWebView *, SEL, CGRect, WKWebViewConfiguration *);
static void (*originalLayout)(WKWebView *, SEL), (*originalMove)(WKWebView *, SEL), (*originalRemove)(WKWebView *, SEL);
static void (*originalSetDelegate)(WKWebView *, SEL, id);
static id (*originalGetDelegate)(WKWebView *, SEL);
static id bridgeInit(WKWebView *web, SEL selector, CGRect frame, WKWebViewConfiguration *configuration) {
    web = originalInit(web, selector, frame, configuration);
    if (!web) return nil;
    connectBridge();
    RuntimeWebPage *page = [RuntimeWebPage new];
    page.web = web; page.identifier = ++nextPage;
    page.callbacks = [NSMutableDictionary new];
    page.imageLayer = [CALayer layer];
    page.imageLayer.contentsGravity = kCAGravityResize;
    [web.layer addSublayer:page.imageLayer];
    objc_setAssociatedObject(web, &pageKey, page, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [pages setObject:page forKey:@(page.identifier)];
    updateLayout(page);
    return web;
}
static void bridgeLayout(WKWebView *web, SEL selector) { originalLayout(web, selector); updateLayout(objc_getAssociatedObject(web, &pageKey)); }
static void bridgeMove(WKWebView *web, SEL selector) { originalMove(web, selector); updateLayout(objc_getAssociatedObject(web, &pageKey)); }
static void bridgeRemove(WKWebView *web, SEL selector) {
    [objc_getAssociatedObject(web, &pageKey) close];
    originalRemove(web, selector);
}
static void bridgeSetDelegate(WKWebView *web, SEL selector, id delegate) {
    RuntimeWebPage *page = objc_getAssociatedObject(web, &pageKey);
    if (page) page.delegate = delegate; else originalSetDelegate(web, selector, delegate);
}
static id bridgeGetDelegate(WKWebView *web, SEL selector) {
    RuntimeWebPage *page = objc_getAssociatedObject(web, &pageKey);
    return page ? page.delegate : originalGetDelegate(web, selector);
}
static WKNavigation *bridgeLoad(WKWebView *web, SEL selector, NSString *html, NSURL *baseURL) {
    RuntimeWebPage *page = objc_getAssociatedObject(web, &pageKey);
    if (page.closed) return nil;
    ensureCreated(page);
    page.navigation = ++page.nextRequest;
    sendWeb(page, @"load", @{@"html": html, @"baseURL": baseURL.absoluteString ?: (id)NSNull.null, @"request": @(page.navigation)});
    // WKNavigation owns an internal C++ object, with no public constructor.
    // This limited adapter does not manufacture a navigation identity.
    return nil;
}
static void bridgeEvaluate(WKWebView *web, SEL selector, NSString *script, void (^completion)(id, NSError *)) {
    RuntimeWebPage *page = objc_getAssociatedObject(web, &pageKey);
    if (page.closed) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, cancelled()); });
        return;
    }
    ensureCreated(page);
    NSNumber *request = @(++page.nextRequest);
    if (completion) page.callbacks[request] = [completion copy];
    sendWeb(page, @"eval", @{@"script": script, @"request": request});
}
static IMP replace(SEL selector, IMP implementation) {
    Class cls = WKWebView.class;
    Method method = class_getInstanceMethod(cls, selector);
    IMP previous = method_getImplementation(method);
    // Several hooks inherit UIView's implementation; never replace UIView globally.
    if (!class_addMethod(cls, selector, implementation, method_getTypeEncoding(method)))
        method_setImplementation(class_getInstanceMethod(cls, selector), implementation);
    return previous;
}
__attribute__((constructor)) static void installWebBridge(void) {
    originalInit = (void *)replace(@selector(initWithFrame:configuration:), (IMP)bridgeInit);
    originalLayout = (void *)replace(@selector(layoutSubviews), (IMP)bridgeLayout);
    originalMove = (void *)replace(@selector(didMoveToWindow), (IMP)bridgeMove);
    originalRemove = (void *)replace(@selector(removeFromSuperview), (IMP)bridgeRemove);
    originalSetDelegate = (void *)replace(@selector(setNavigationDelegate:), (IMP)bridgeSetDelegate);
    originalGetDelegate = (void *)replace(@selector(navigationDelegate), (IMP)bridgeGetDelegate);
    replace(@selector(loadHTMLString:baseURL:), (IMP)bridgeLoad);
    replace(@selector(evaluateJavaScript:completionHandler:), (IMP)bridgeEvaluate);
}
