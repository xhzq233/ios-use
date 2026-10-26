#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
@interface WebKitDelegate : UIResponder <UIApplicationDelegate, WKNavigationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) WKWebView *web;
@end
@implementation WebKitDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [UIViewController new];
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
    self.web = [[WKWebView alloc] initWithFrame:self.window.bounds configuration:configuration];
    self.web.navigationDelegate = self;
    [self.window.rootViewController.view addSubview:self.web];
    [self.window makeKeyAndVisible];
    [self.web loadHTMLString:@"<meta name='viewport' content='width=device-width'><body style='margin:0;background:rgb(0,255,0)'><script>window.answer=6*7</script>" baseURL:nil];
    return YES;
}
- (void)webView:(WKWebView *)web didFinishNavigation:(WKNavigation *)navigation {
    [web evaluateJavaScript:@"window.answer" completionHandler:^(id value, NSError *error) {
        if (error || [value intValue] != 42) exit(123);
        [web takeSnapshotWithConfiguration:nil completionHandler:^(UIImage *image, NSError *error) {
            if (error || !image.CGImage) exit(124);
            CGImageRef center = CGImageCreateWithImageInRect(image.CGImage, CGRectMake(20, 20, 1, 1));
            uint8_t pixel[4] = {0}; CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
            CGContextRef bitmap = CGBitmapContextCreate(pixel, 1, 1, 8, 4, color, kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast);
            CGContextDrawImage(bitmap, CGRectMake(0, 0, 1, 1), center);
            fprintf(stderr, "[webkit-probe] JS=%d RGB=%u,%u,%u\n", [value intValue], pixel[0], pixel[1], pixel[2]);
            BOOL correct = pixel[1] > 200 && pixel[0] < 50 && pixel[2] < 50;
            CGContextRelease(bitmap); CGColorSpaceRelease(color); CGImageRelease(center);
            exit(correct ? 0 : 125);
        }];
    }];
}
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)web { fprintf(stderr, "[webkit-probe] content process terminated\n"); exit(126); }
@end
int main(int argc, char **argv) {
    @autoreleasepool {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ exit(127); });
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(WebKitDelegate.class));
    }
}
