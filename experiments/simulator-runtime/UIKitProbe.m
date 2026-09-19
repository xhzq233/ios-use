#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static UIView *makeProbeView(void) {
    UIView *view = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 180)];
    view.backgroundColor = UIColor.systemBlueColor;
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(20, 30, 280, 100)];
    label.text = @"UIKit 26\nStandalone runtime";
    label.numberOfLines = 2;
    label.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBold];
    label.textColor = UIColor.whiteColor;
    [view addSubview:label];
    UIView *capsule = [[UIView alloc] initWithFrame:CGRectMake(20, 130, 280, 36)];
    capsule.backgroundColor = UIColor.systemGreenColor;
    if (@available(iOS 26.0, *)) {
        capsule.cornerConfiguration = UICornerConfiguration.capsuleConfiguration;
    } else {
        exit(34);
    }
    [view addSubview:capsule];
    [view layoutIfNeeded];

    return view;
}

static int captureProbeView(UIView *view, NSString *filename) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
        initWithSize:CGSizeMake(320, 180) format:format];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [view.layer renderInContext:context.CGContext];
    }];
    if (!image.CGImage || CGImageGetWidth(image.CGImage) != 320 || CGImageGetHeight(image.CGImage) != 180) return 30;
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:filename];
    BOOL saved = [UIImagePNGRepresentation(image) writeToFile:path atomically:YES];
    printf("[uikit] PNG=%s saved=%d\n", path.UTF8String, saved);
    if (!saved) return 31;
    uint8_t *pixels = calloc(320 * 180, 4);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmap = CGBitmapContextCreate(pixels, 320, 180, 8, 320 * 4,
        colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (!bitmap) { free(pixels); return 32; }
    CGContextDrawImage(bitmap, CGRectMake(0, 0, 320, 180), image.CGImage);
    unsigned whitePixels = 0;
    for (int i = 0; i < 320 * 180; ++i) {
        if (pixels[4*i] > 240 && pixels[4*i+1] > 240 && pixels[4*i+2] > 240) ++whitePixels;
    }
    CGContextRelease(bitmap);
    free(pixels);
    printf("[uikit] white text pixels=%u\n", whitePixels);
    return whitePixels > 100 ? 0 : 33;
}

@interface RuntimeProbeDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation RuntimeProbeDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    CGRect bounds = UIScreen.mainScreen.bounds;
    printf("[application] real launch callback; screen=%.0fx%.0f\n", bounds.size.width, bounds.size.height);
    if (CGRectIsEmpty(bounds)) exit(35);
    self.window = [[UIWindow alloc] initWithFrame:bounds];
    UIViewController *controller = [UIViewController new];
    controller.view = makeProbeView();
    self.window.rootViewController = controller;
    // Capture the delegate-created view tree before requesting window presentation.
    // A successful callback/snapshot does not imply the whole launch has completed.
    int captureStatus = captureProbeView(controller.view, @"launch.png");
    if (captureStatus) exit(captureStatus);
    [self.window makeKeyAndVisible];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [self.window layoutIfNeeded];
        if (!self.window.rootViewController || self.window.hidden) exit(36);
        exit(captureProbeView(self.window, @"window.png"));
    });
    return YES;
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        setbuf(stdout, NULL);
        printf("[uikit] image=%s\n", class_getImageName(UIView.class));
        if (argc > 1 && strcmp(argv[1], "application") == 0) {
            // A running event loop without the real launch callback is failure.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                fprintf(stderr, "[application] launch/capture deadline exceeded\n");
                exit(37);
            });
            return UIApplicationMain(argc, argv, nil, NSStringFromClass(RuntimeProbeDelegate.class));
        }
        return captureProbeView(makeProbeView(), @"uikit.png");
    }
}
