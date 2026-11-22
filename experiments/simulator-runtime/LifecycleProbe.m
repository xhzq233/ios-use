#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurfaceRef.h>
#import <mach/mach.h>
#import <dlfcn.h>
static double duration = 60;
static unsigned backgrounded, foregrounded;
@interface LifecycleDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) UIWindow *overlay;
@property(nonatomic) unsigned cycles;
@property(nonatomic) unsigned phase;
@property(nonatomic) NSUInteger initialContexts;
@property(nonatomic) CFTimeInterval started;
@end
@implementation LifecycleDelegate
- (void)applicationDidEnterBackground:(UIApplication *)app { backgrounded++; fprintf(stderr, "[lifecycle] background state=%ld\n", (long)app.applicationState); }
- (void)applicationWillEnterForeground:(UIApplication *)app { foregrounded++; }
- (BOOL)pixelIsYellow:(BOOL)yellow {
    IOSurfaceRef (*copySurface)(UIWindow *) = dlsym(RTLD_DEFAULT, "IOSUseCopyPresentedWindowSurface");
    IOSurfaceRef surface = copySurface(self.window);
    if (!surface || IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL)) return NO;
    const uint8_t *p = (const uint8_t *)IOSurfaceGetBaseAddress(surface) +
        (IOSurfaceGetHeight(surface) / 2) * IOSurfaceGetBytesPerRow(surface) + (IOSurfaceGetWidth(surface) / 2) * 4;
    BOOL matches = p[1] > 220 && p[0] < 30 && (yellow ? p[2] > 220 : p[2] < 30);
    if (!matches) fprintf(stderr, "[lifecycle] expected yellow=%d RGB=%u,%u,%u\n", yellow, p[2], p[1], p[0]);
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL); CFRelease(surface);
    return matches;
}
- (void)tick:(NSTimer *)timer {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    NSUInteger (*contexts)(void) = dlsym(RTLD_DEFAULT, "IOSUseHostedContextCount");
    if (!self.started) { self.started = CACurrentMediaTime(); self.initialContexts = contexts(); }
    if (self.phase == 0) {
        if (![self pixelIsYellow:NO]) exit(130);
        // UIKit retains one reusable transition context after the first overlay.
        if (contexts() > self.initialContexts + 1) { fprintf(stderr, "[lifecycle] contexts accumulated=%lu\n", contexts()); exit(131); }
        if (CACurrentMediaTime() - self.started >= duration) {
            fprintf(stderr, "[lifecycle] cycles=%u background=%u foreground=%u contexts=%lu\n", self.cycles, backgrounded, foregrounded, contexts());
            exit(self.cycles >= 10 && backgrounded && foregrounded ? 0 : 132);
        }
        self.overlay = [[UIWindow alloc] initWithWindowScene:self.window.windowScene];
        self.overlay.windowLevel = UIWindowLevelAlert + 1;
        self.overlay.rootViewController = [UIViewController new];
        self.overlay.rootViewController.view.backgroundColor = UIColor.yellowColor;
        [self.overlay makeKeyAndVisible];
        self.phase = 1;
    } else {
        if (![self pixelIsYellow:YES]) exit(133);
        self.overlay.hidden = YES;
        self.overlay = nil;
        [self.window makeKeyWindow];
        self.cycles++;
        self.phase = 0;
        if (self.cycles % 10 == 0) {
            task_vm_info_data_t info; mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
            if (!task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count))
                fprintf(stderr, "[lifecycle] cycles=%u footprint=%llu contexts=%lu\n", self.cycles, info.phys_footprint, contexts());
        }
    }
}
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [UIViewController new];
    self.window.rootViewController.view.backgroundColor = UIColor.greenColor;
    [self.window makeKeyAndVisible];
    UIView *pulse = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 10)];
    [self.window.rootViewController.view addSubview:pulse];
    [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
        pulse.backgroundColor = pulse.backgroundColor == UIColor.redColor ? UIColor.blueColor : UIColor.redColor;
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:0.3 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    });
    return YES;
}
@end
int main(int argc, char **argv) {
    if (argc > 1) duration = atof(argv[1]);
    @autoreleasepool {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (duration + 20) * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ exit(134); });
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(LifecycleDelegate.class));
    }
}
