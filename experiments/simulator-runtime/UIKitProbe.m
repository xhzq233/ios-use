#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <IOSurface/IOSurfaceRef.h>
#import <dlfcn.h>

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

static int captureCompositedWindow(UIWindow *window) {
    IOSurfaceRef (*copySurface)(UIWindow *) = dlsym(RTLD_DEFAULT, "IOSUseCopyWindowSurface");
    if (!copySurface) return 40;
    CFTimeInterval start = CACurrentMediaTime();
    IOSurfaceRef surface = copySurface(window);
    if (!surface) return 40;
    double elapsed = (CACurrentMediaTime() - start) * 1000;
    if (IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL)) { CFRelease(surface); return 41; }
    size_t width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface);
    size_t stride = IOSurfaceGetBytesPerRow(surface);
    uint8_t *pixels = IOSurfaceGetBaseAddress(surface);
    unsigned white = 0, blue = 0, green = 0;
    for (size_t y = 0; pixels && y < height; ++y) {
        for (size_t x = 0; x < width; ++x) {
            uint8_t *p = pixels + y * stride + x * 4;
            white += p[0] > 240 && p[1] > 240 && p[2] > 240;
            blue += p[0] > 180 && p[1] < 180 && p[2] < 100;
            green += p[1] > 150 && p[0] < 150 && p[2] < 150;
        }
    }
    CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmap = CGBitmapContextCreate(pixels, width, height, 8, stride, color,
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGImageRef image = bitmap ? CGBitmapContextCreateImage(bitmap) : NULL;
    BOOL saved = image && [UIImagePNGRepresentation([UIImage imageWithCGImage:image])
        writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"composited.png"] atomically:YES];
    if (image) CGImageRelease(image);
    if (bitmap) CGContextRelease(bitmap);
    CGColorSpaceRelease(color);
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    CFRelease(surface);
    printf("[application] CA composition %.1f ms; white=%u blue=%u green=%u saved=%d\n",
           elapsed, white, blue, green, saved);
    return saved && white > 100 && blue > 100 && green > 100 ? 0 : 42;
}

@interface RuntimeProbeDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) CADisplayLink *displayLink;
@property(nonatomic) unsigned frames;
@property(nonatomic) CFTimeInterval lastFrame;
@property(nonatomic, strong) UIWindow *overlay;
@property(nonatomic, weak) UIWindow *releasedOverlay;
@property(nonatomic) BOOL overlayTapped;
@end

@implementation RuntimeProbeDelegate
- (void)dismissOverlay:(UIButton *)sender {
    self.overlayTapped = YES;
    self.overlay = nil;
    [self.window makeKeyWindow];
}
- (void)frame:(CADisplayLink *)link {
    if (self.frames && link.timestamp <= self.lastFrame) exit(54);
    self.lastFrame = link.timestamp;
    ++self.frames;
}
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
    self.displayLink = [self.window.windowScene.screen displayLinkWithTarget:self selector:@selector(frame:)];
    if (!self.displayLink) exit(54);
    [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        self.overlay = [[UIWindow alloc] initWithWindowScene:self.window.windowScene];
        self.overlay.frame = self.window.frame;
        self.overlay.rootViewController = [UIViewController new];
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.frame = CGRectMake(0, 0, 100, 100);
        [button addTarget:self action:@selector(dismissOverlay:) forControlEvents:UIControlEventTouchUpInside];
        [self.overlay.rootViewController.view addSubview:button];
        self.releasedOverlay = self.overlay;
        [self.overlay makeKeyAndVisible];
        BOOL (*sendTouch)(CGPoint, UITouchPhase) = dlsym(RTLD_DEFAULT, "IOSUseSendTouch");
        if (!sendTouch || !sendTouch(CGPointMake(50, 50), UITouchPhaseBegan)) exit(56);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (!sendTouch(CGPointMake(50, 50), UITouchPhaseEnded)) exit(56);
        });
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        printf("[application] overlay tapped=%d released=%d\n", self.overlayTapped, self.releasedOverlay == nil);
        if (!self.overlayTapped || self.releasedOverlay) exit(56);
        [self.displayLink invalidate];
        printf("[application] screen display-link callbacks=%u\n", self.frames);
        if (self.frames < 2) exit(54);
        [self.window layoutIfNeeded];
        if (!self.window.rootViewController || self.window.hidden) exit(36);
        int softwareStatus = captureProbeView(self.window, @"window.png");
        if (softwareStatus) exit(softwareStatus);
        exit(captureCompositedWindow(self.window));
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
