// Two actual UIKit scenes. The host drives their independent window lifecycle.
#import <UIKit/UIKit.h>
#import <dlfcn.h>

static unsigned connected, backgrounded, restored, disconnected;
static unsigned targetIndex;
static BOOL secondRequested;

@interface MultiSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) UIWindow *overlay;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic) unsigned index;
@property(nonatomic) unsigned phase;
@property(nonatomic) unsigned survivingTicks;
@end

@implementation MultiSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    if (![scene isKindOfClass:UIWindowScene.class] || connected >= 2) exit(150);
    self.index = connected++;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [UIViewController new];
    NSArray<UIColor *> *colors = self.index == 0 ? @[UIColor.redColor, UIColor.yellowColor] :
                                                  @[UIColor.blueColor, UIColor.cyanColor];
    self.window.rootViewController.view.backgroundColor = colors[0];
    [self.window makeKeyAndVisible];
    __weak MultiSceneDelegate *weakSelf = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *timer) {
        MultiSceneDelegate *owner = weakSelf;
        if (!owner) { [timer invalidate]; return; }
        owner.window.rootViewController.view.backgroundColor = colors[++owner.phase % colors.count];
        if (owner.index != targetIndex && disconnected) {
            if (owner.window.windowScene.activationState != UISceneActivationStateForegroundActive ||
                UIApplication.sharedApplication.connectedScenes.count != 1) {
                fprintf(stderr, "[multi-scene] surviving scene lost activation or disconnected scene remained\n");
                exit(151);
            }
            // Give the native host time to verify >=12 real pixel transitions.
            if (++owner.survivingTicks >= 24) {
                fprintf(stderr, "[multi-scene] closed=%c surviving=%c connected=%u background=%u restored=%u disconnected=%u survivingTicks=%u\n",
                    'A' + targetIndex, 'A' + owner.index, connected, backgrounded, restored, disconnected, owner.survivingTicks);
                exit(connected == 2 && backgrounded && restored && disconnected == 1 ? 0 : 152);
            }
        }
    }];
    if (self.index == 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 400 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            void (*createScene)(NSString *) = dlsym(RTLD_DEFAULT, "IOSUseCreateAdditionalScene");
            if (!createScene || secondRequested) exit(153);
            secondRequested = YES;
            createScene(@"secondary");
        });
        // An overlay belongs to A; it must not create a third native window or
        // replace B's pixels. Its dismissal also exercises context retirement.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            MultiSceneDelegate *owner = weakSelf;
            if (!owner.window) return;
            owner.overlay = [[UIWindow alloc] initWithWindowScene:owner.window.windowScene];
            owner.overlay.windowLevel = UIWindowLevelAlert + 1;
            owner.overlay.rootViewController = [UIViewController new];
            owner.overlay.rootViewController.view.backgroundColor = UIColor.whiteColor;
            [owner.overlay makeKeyAndVisible];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 800 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                owner.overlay.hidden = YES;
                owner.overlay = nil;
                [owner.window makeKeyWindow];
            });
        });
    }
}
- (void)sceneDidEnterBackground:(UIScene *)scene {
    if (self.index == targetIndex) backgrounded++;
    else {
        fprintf(stderr, "[multi-scene] %c backgrounded while only %c was minimized\n", 'A' + self.index, 'A' + targetIndex);
        exit(154);
    }
}
- (void)sceneWillEnterForeground:(UIScene *)scene {
    if (self.index == targetIndex && backgrounded) restored++;
}
- (void)sceneDidDisconnect:(UIScene *)scene {
    if (self.index != targetIndex || !backgrounded || !restored || disconnected) {
        fprintf(stderr, "[multi-scene] unexpected disconnect index=%u target=%u background=%u restored=%u disconnected=%u\n",
            self.index, targetIndex, backgrounded, restored, disconnected);
        exit(155);
    }
    disconnected++;
    [self.timer invalidate];
    self.timer = nil;
    self.overlay.hidden = YES;
    self.overlay = nil;
    self.window.hidden = YES;
    self.window = nil;
}
@end

@interface MultiSceneAppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation MultiSceneAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options { return YES; }
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"Runtime Multi Scene" sessionRole:session.role];
    configuration.sceneClass = UIWindowScene.class;
    configuration.delegateClass = MultiSceneDelegate.class;
    return configuration;
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        // The broker forwards argv while constructing an isolated environment.
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--close-second") == 0) targetIndex = 1;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            fprintf(stderr, "[multi-scene] child lifecycle deadline target=%c connected=%u background=%u restored=%u disconnected=%u\n",
                'A' + targetIndex, connected, backgrounded, restored, disconnected);
            exit(156);
        });
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(MultiSceneAppDelegate.class));
    }
}
