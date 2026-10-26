// Synthetic WKWebView client. Its AppKit observer validates the composed pixels.
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <dlfcn.h>

static unsigned connected, disconnected;
static BOOL secondRequested;
static __weak WKWebView *retiredWeb;

static void fail(const char *message) {
    fprintf(stderr, "[web-bridge-probe] %s\n", message);
    exit(170);
}
static NSUInteger bridgeCount(const char *symbol) {
    NSUInteger (*count)(void) = dlsym(RTLD_DEFAULT, symbol);
    if (!count) fail("bridge diagnostic is unavailable");
    return count();
}

@interface WebBridgeSceneDelegate : UIResponder <UIWindowSceneDelegate, WKNavigationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) UIView *container;
@property(nonatomic, strong) UIView *marker;
@property(nonatomic, strong) UIView *overlay;
@property(nonatomic, strong) WKWebView *web;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic) unsigned index;
@property(nonatomic) unsigned generation;
@property(nonatomic) unsigned navigationStep;
@property(nonatomic) unsigned phase;
@property(nonatomic) unsigned cancelCallbacks;
@property(nonatomic) unsigned successfulLoads;
@property(nonatomic) unsigned nullCallbacks;
@property(nonatomic) unsigned undefinedCallbacks;
@property(nonatomic) BOOL resizedViewportVerified;
@property(nonatomic) unsigned sentinelTicks;
@property(nonatomic) unsigned survivingTicks;
@property(nonatomic) NSTimeInterval phaseTime;
@end

// Intentionally retain A and its second web view after Scene disconnection.
// Retirement must release the native resource even while application objects live.
static WebBridgeSceneDelegate *retainedOwner;

@implementation WebBridgeSceneDelegate
- (void)setProbePhase:(unsigned)phase {
    self.phase = phase;
    self.phaseTime = NSProcessInfo.processInfo.systemUptime;
    NSArray<UIColor *> *colors = @[UIColor.blackColor, UIColor.whiteColor,
        UIColor.yellowColor, UIColor.magentaColor, UIColor.cyanColor];
    self.marker.backgroundColor = colors[phase];
}

- (void)createWebView {
    self.generation++;
    self.navigationStep = 0;
    self.container = [[UIView alloc] initWithFrame:CGRectMake(40, 180, 240, 220)];
    self.container.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1];
    [self.window.rootViewController.view addSubview:self.container];
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
    self.web = [[WKWebView alloc] initWithFrame:self.container.bounds configuration:configuration];
    self.web.navigationDelegate = self;
    [self.container addSubview:self.web];
    WKNavigation *navigation = [self.web loadHTMLString:
        @"<!doctype html><html><head><meta name='viewport' content='width=device-width,initial-scale=1'>"
         "<meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; style-src 'unsafe-inline'\">"
         "<style>html,body{margin:0;width:100%;height:100%;background:rgb(0,255,0)}</style>"
         "</head><body></body></html>" baseURL:nil];
    // The experimental adapter explicitly has no WKNavigation identity support.
    if (navigation) fail("unexpected navigation handle for this bridge version");
}

- (void)adjustWebView {
    self.container.frame = CGRectMake(80, 260, 180, 180);
    self.container.clipsToBounds = YES;
    self.web.frame = CGRectMake(-95, -50, 240, 240);
    self.web.transform = CGAffineTransformMakeScale(0.75, 0.75);
    self.overlay = [[UIView alloc] initWithFrame:CGRectMake(30, 60, 80, 60)];
    self.overlay.backgroundColor = [UIColor.redColor colorWithAlphaComponent:0.5];
    [self.container addSubview:self.overlay];
    [self setProbePhase:2];
    __weak WebBridgeSceneDelegate *weakSelf = self;
    __weak WKWebView *expectedWeb = self.web;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        WebBridgeSceneDelegate *owner = weakSelf;
        if (!owner || owner.web != expectedWeb || owner.phase != 2) fail("resized web view disappeared before viewport query");
        [owner.web evaluateJavaScript:@"[window.innerWidth, window.innerHeight]" completionHandler:^(id value, NSError *error) {
            WebBridgeSceneDelegate *current = weakSelf;
            if (!current || current.web != expectedWeb || current.phase != 2 || error ||
                ![value isKindOfClass:NSArray.class] || [value count] != 2 ||
                ![value[0] isKindOfClass:NSNumber.class] || ![value[1] isKindOfClass:NSNumber.class])
                fail("resized viewport query did not return width and height");
            CGSize bounds = current.web.bounds.size;
            if ([value[0] doubleValue] != bounds.width || [value[1] doubleValue] != bounds.height) {
                fprintf(stderr, "[web-bridge-probe] viewport=%.0fx%.0f UIKit bounds=%.0fx%.0f\n",
                    [value[0] doubleValue], [value[1] doubleValue], bounds.width, bounds.height);
                fail("native page viewport did not resize with UIKit bounds");
            }
            current.resizedViewportVerified = YES;
            fprintf(stderr, "[web-bridge-probe] native page viewport resized to %.0fx%.0f\n", bounds.width, bounds.height);
        }];
    });
}

- (void)destroyFirstWebView {
    if (self.generation != 1 || self.successfulLoads != 1) fail("invalid first-view teardown order");
    retiredWeb = self.web;
    __weak WebBridgeSceneDelegate *weakSelf = self;
    [self.web evaluateJavaScript:@"(() => { const end = performance.now() + 500; while (performance.now() < end) {} return 99; })()"
        completionHandler:^(id value, NSError *error) {
            WebBridgeSceneDelegate *owner = weakSelf;
            if (!owner || ++owner.cancelCallbacks != 1 || value || !error || error.code != NSURLErrorCancelled)
                fail("destroyed-view evaluation did not cancel exactly once");
        }];
    [self.web removeFromSuperview];
    self.web = nil;
    [self.container removeFromSuperview];
    self.container = nil;
    self.overlay = nil;
    [self setProbePhase:3];
}

- (void)tick {
    if (self.index == 1) {
        self.window.rootViewController.view.backgroundColor =
            ++self.sentinelTicks % 2 ? UIColor.cyanColor : UIColor.blueColor;
        if (disconnected) {
            if (self.window.windowScene.activationState != UISceneActivationStateForegroundActive ||
                UIApplication.sharedApplication.connectedScenes.count != 1)
                fail("surviving Scene lost activation after web Scene closed");
            if (bridgeCount("IOSUseWebBridgeViewCount") || bridgeCount("IOSUseWebBridgeOutstandingCallbacks")) return;
            if (++self.survivingTicks >= 24) {
                if (connected != 2 || disconnected != 1 || !retainedOwner.web ||
                    retainedOwner.successfulLoads != 2 || retainedOwner.cancelCallbacks != 1 ||
                    retainedOwner.nullCallbacks != 1 || retainedOwner.undefinedCallbacks != 1 ||
                    !retainedOwner.resizedViewportVerified || retiredWeb)
                    fail("Scene retirement or replacement-view lifecycle is incomplete");
                fprintf(stderr, "[web-bridge-probe] two loads, real JS/error, one cancellation, released first view, retained second view retired; survivor ticks=%u\n",
                    self.survivingTicks);
                exit(0);
            }
        }
        return;
    }
    if (disconnected) return;
    NSTimeInterval elapsed = NSProcessInfo.processInfo.systemUptime - self.phaseTime;
    if (self.phase == 1 && elapsed >= 3) [self adjustWebView];
    else if (self.phase == 2 && elapsed >= 3) [self destroyFirstWebView];
    else if (self.phase == 3 && self.generation == 1 && elapsed >= 3 && self.cancelCallbacks == 1 && !retiredWeb &&
             !bridgeCount("IOSUseWebBridgeViewCount") && !bridgeCount("IOSUseWebBridgeOutstandingCallbacks")) {
        [self createWebView];
    }
}

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    if (![scene isKindOfClass:UIWindowScene.class] || connected >= 2) fail("unexpected Scene connection");
    self.index = connected++;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [UIViewController new];
    self.window.rootViewController.view.backgroundColor = self.index ? UIColor.blueColor : [UIColor colorWithWhite:0.15 alpha:1];
    [self.window makeKeyAndVisible];
    __weak WebBridgeSceneDelegate *weakSelf = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *timer) {
        WebBridgeSceneDelegate *owner = weakSelf;
        if (owner) [owner tick]; else [timer invalidate];
    }];
    if (!self.index) {
        retainedOwner = self;
        self.marker = [[UIView alloc] initWithFrame:CGRectMake(20, 80, 48, 40)];
        [self.window.rootViewController.view addSubview:self.marker];
        [self setProbePhase:0];
        [self createWebView];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 400 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            void (*createScene)(NSString *) = dlsym(RTLD_DEFAULT, "IOSUseCreateAdditionalScene");
            if (!createScene || secondRequested) fail("secondary Scene creation is unavailable");
            secondRequested = YES;
            createScene(@"secondary");
        });
    }
}

- (void)verifyNavigation:(WKNavigation *)navigation web:(WKWebView *)web step:(unsigned)step {
    if (web != self.web || navigation || self.navigationStep + 1 != step || self.index)
        fail("navigation callback order or web-view identity is wrong");
    self.navigationStep = step;
}
- (void)webView:(WKWebView *)web didStartProvisionalNavigation:(WKNavigation *)navigation {
    [self verifyNavigation:navigation web:web step:1];
}
- (void)webView:(WKWebView *)web didCommitNavigation:(WKNavigation *)navigation {
    [self verifyNavigation:navigation web:web step:2];
}
- (void)webView:(WKWebView *)web didFinishNavigation:(WKNavigation *)navigation {
    [self verifyNavigation:navigation web:web step:3];
    unsigned generation = self.generation;
    __weak WKWebView *expectedWeb = web;
    __weak WebBridgeSceneDelegate *weakSelf = self;
    [web evaluateJavaScript:generation == 1 ? @"6 * 7" : @"7 * 7" completionHandler:^(id value, NSError *error) {
        WebBridgeSceneDelegate *owner = weakSelf;
        if (!owner || owner.web != expectedWeb || owner.generation != generation || error ||
            ![value isKindOfClass:NSNumber.class] || [value intValue] != (generation == 1 ? 42 : 49))
            fail("JavaScript result was wrong or crossed view generations");
        void (^verifyException)(void) = ^{
            [expectedWeb evaluateJavaScript:@"throw new Error('synthetic probe error')" completionHandler:^(id result, NSError *exception) {
                WebBridgeSceneDelegate *current = weakSelf;
                if (!current || current.web != expectedWeb || current.generation != generation || result || !exception)
                    fail("JavaScript exception did not reach the matching completion handler");
                if (++current.successfulLoads != generation) fail("duplicate load completion");
                [current setProbePhase:generation == 1 ? 1 : 4];
            }];
        };
        if (generation != 1) { verifyException(); return; }
        [owner.web evaluateJavaScript:@"null" completionHandler:^(id result, NSError *failure) {
            WebBridgeSceneDelegate *current = weakSelf;
            if (!current || current.web != expectedWeb || current.generation != generation ||
                ++current.nullCallbacks != 1 || failure || ![result isKindOfClass:NSNull.class])
                fail("JavaScript null did not return NSNull exactly once");
            [current.web evaluateJavaScript:@"undefined" completionHandler:^(id undefined, NSError *undefinedError) {
                WebBridgeSceneDelegate *matching = weakSelf;
                if (!matching || matching.web != expectedWeb || matching.generation != generation ||
                    ++matching.undefinedCallbacks != 1 || undefinedError || undefined)
                    fail("JavaScript undefined did not return nil exactly once");
                verifyException();
            }];
        }];
    }];
}
- (void)webView:(WKWebView *)web didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    fail("synthetic navigation failed");
}
- (void)webView:(WKWebView *)web didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    fail("synthetic provisional navigation failed");
}
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)web { fail("web content process terminated"); }
- (void)sceneDidDisconnect:(UIScene *)scene {
    if (self.index || self.phase != 4 || !self.web || disconnected) fail("unexpected Scene disconnection");
    disconnected++;
    [self.timer invalidate];
    self.timer = nil;
    // Keep web/window references deliberately; the Scene hook owns bridge teardown.
}
@end

@interface WebBridgeAppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation WebBridgeAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options { return YES; }
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"Runtime Web Bridge" sessionRole:session.role];
    configuration.sceneClass = UIWindowScene.class;
    configuration.delegateClass = WebBridgeSceneDelegate.class;
    return configuration;
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 42 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            fprintf(stderr, "[web-bridge-probe] deadline phase=%u loads=%u cancellations=%u connected=%u disconnected=%u views=%lu callbacks=%lu\n",
                retainedOwner.phase, retainedOwner.successfulLoads, retainedOwner.cancelCallbacks, connected, disconnected,
                (unsigned long)bridgeCount("IOSUseWebBridgeViewCount"), (unsigned long)bridgeCount("IOSUseWebBridgeOutstandingCallbacks"));
            exit(171);
        });
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(WebBridgeAppDelegate.class));
    }
}
