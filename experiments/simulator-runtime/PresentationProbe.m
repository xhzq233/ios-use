// A continuously changing UIKit window, with no input or app-specific adapters.
#import <UIKit/UIKit.h>
#import <signal.h>
static BOOL animate = YES;

@interface PresentationDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation PresentationDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [UIViewController new];
    NSArray<UIColor *> *colors = @[UIColor.redColor, UIColor.greenColor, UIColor.blueColor];
    self.window.rootViewController.view.backgroundColor = colors[0];
    [self.window makeKeyAndVisible];
    __block unsigned phase = 0;
    if (animate) [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
        self.window.rootViewController.view.backgroundColor = colors[++phase % colors.count];
    }];
    return YES;
}
@end
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 2 && !strcmp(argv[1], "--static")) animate = NO;
        if (argc == 2 && !strcmp(argv[1], "--ignore-term")) signal(SIGTERM, SIG_IGN);
        // Also support checking host teardown after a normal or failed app exit.
        BOOL exitProbe = argc == 3 && strcmp(argv[1], "--exit-code") == 0;
        int status = exitProbe ? atoi(argv[2]) : 109;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (exitProbe ? 7 : 25) * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{ exit(status); });
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(PresentationDelegate.class));
    }
}
