// Native pixel/lifecycle observer linked only into the multi-scene workload.
#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <unistd.h>

@interface MultiSceneWindowObservation : NSObject
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic) int role;
@property(nonatomic) int lastColor;
@property(nonatomic) unsigned frames;
@property(nonatomic) unsigned transitions;
@property(nonatomic) BOOL sawOverlay;
@property(nonatomic) BOOL overlayCleared;
@property(nonatomic) BOOL closed;
@end
@implementation MultiSceneWindowObservation
@end

static NSMutableDictionary<NSNumber *, MultiSceneWindowObservation *> *observations;
static BOOL completed;
static BOOL closeSecond;

static int windowColor(NSWindow *window) {
    uint32_t (*connection)(void) = dlsym(RTLD_DEFAULT, "CGSMainConnectionID");
    CFArrayRef (*capture)(uint32_t, const uint32_t *, uint32_t, uint32_t) =
        dlsym(RTLD_DEFAULT, "CGSHWCaptureWindowList");
    if (!connection || !capture) return -1;
    uint32_t identifier = (uint32_t)window.windowNumber;
    CFArrayRef images = capture(connection(), &identifier, 1, (1U << 11) | (1U << 8) | (1U << 19));
    if (!images) return -1;
    int color = -1;
    if (CFArrayGetCount(images)) {
        CGImageRef image = (CGImageRef)CFArrayGetValueAtIndex(images, 0);
        CGImageRef center = CGImageCreateWithImageInRect(image,
            CGRectMake(CGImageGetWidth(image) / 2, CGImageGetHeight(image) / 2, 1, 1));
        uint8_t pixel[4] = {0};
        CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
        CGContextRef bitmap = CGBitmapContextCreate(pixel, 1, 1, 8, 4, rgb,
            kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast);
        if (center && bitmap) {
            CGContextDrawImage(bitmap, CGRectMake(0, 0, 1, 1), center);
            BOOL red = pixel[0] > 200, green = pixel[1] > 200, blue = pixel[2] > 200;
            if (red && pixel[2] < 60 && (green || pixel[1] < 60)) color = green ? 1 : 0;
            if (blue && pixel[0] < 60 && (green || pixel[1] < 60)) color = green ? 3 : 2;
            if (red && green && blue) color = 4;
        }
        if (bitmap) CGContextRelease(bitmap);
        if (center) CGImageRelease(center);
        CGColorSpaceRelease(rgb);
    }
    CFRelease(images);
    return color;
}

static void sampleWindows(NSTimer *timer) {
    static unsigned stage, targetRestoredAt, survivorClosedAt;
    static NSTimeInterval stageTime;
    MultiSceneWindowObservation *a = nil, *b = nil;
    for (MultiSceneWindowObservation *observation in observations.allValues) {
        if (!observation.closed && !observation.window.miniaturized) {
            int color = windowColor(observation.window);
            if (color >= 0) {
                if (color == 4) observation.sawOverlay = YES;
                else {
                    int role = color / 2;
                    if (observation.role >= 0 && observation.role != role) {
                        fprintf(stderr, "[multi-scene-host] pixels crossed scene boundaries\n"); exit(157);
                    }
                    observation.role = role;
                    if (observation.sawOverlay) observation.overlayCleared = YES;
                    if (observation.lastColor >= 0 && observation.lastColor != color) observation.transitions++;
                    observation.lastColor = color;
                }
            }
        }
        if (observation.role == 0) {
            if (a) { fprintf(stderr, "[multi-scene-host] duplicate A window\n"); exit(158); }
            a = observation;
        } else if (observation.role == 1) {
            if (b || observation.sawOverlay) {
                fprintf(stderr, "[multi-scene-host] duplicate B window or A overlay appeared in B\n"); exit(158);
            }
            b = observation;
        }
    }
    if (!a || !b) return;
    MultiSceneWindowObservation *target = closeSecond ? b : a;
    MultiSceneWindowObservation *survivor = closeSecond ? a : b;
    char targetName = 'A' + target.role, survivorName = 'A' + survivor.role;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (stage == 0 && a.transitions >= 12 && b.transitions >= 12 && a.frames >= 18 && b.frames >= 18 && a.overlayCleared) {
        fprintf(stderr, "[multi-scene-host] independent pixels A=%u B=%u transitions; overlay isolated; minimizing %c\n",
            a.transitions, b.transitions, targetName);
        stage = 1; stageTime = now;
        [target.window miniaturize:nil];
    } else if (stage == 1 && now - stageTime >= 0.8) {
        stage = 2; stageTime = now; targetRestoredAt = target.transitions;
        [target.window deminiaturize:nil];
    } else if (stage == 2 && now - stageTime >= 0.8 && target.transitions >= targetRestoredAt + 3) {
        stage = 3; survivorClosedAt = survivor.transitions;
        target.closed = YES;
        fprintf(stderr, "[multi-scene-host] restored %c; closing %c while %c remains open\n", targetName, targetName, survivorName);
        [target.window performClose:nil];
    } else if (stage == 3 && survivor.transitions >= survivorClosedAt + 12) {
        completed = YES;
        [timer invalidate];
        fprintf(stderr, "[multi-scene-host] %c continued %u pixel transitions after %c closed; awaiting child lifecycle result\n",
            survivorName, survivor.transitions - survivorClosedAt, targetName);
        // The child exits only after validating the real UIKit callbacks. Do
        // not close the survivor: closing the last window could mask a failure.
    }
}

void IOSUseObserveHostFrame(NSWindow *window, BOOL hasInput) {
    if (hasInput) { fprintf(stderr, "[multi-scene-host] unexpected input port\n"); exit(159); }
    if (!observations) {
        observations = [NSMutableDictionary new];
        [NSTimer scheduledTimerWithTimeInterval:0.08 repeats:YES block:^(NSTimer *timer) { sampleWindows(timer); }];
    }
    NSNumber *key = @(window.windowNumber);
    MultiSceneWindowObservation *observation = observations[key];
    if (!observation) {
        if (observations.count >= 2) { fprintf(stderr, "[multi-scene-host] extra native window for a scene layer\n"); exit(160); }
        observation = [MultiSceneWindowObservation new];
        observation.window = window;
        observation.role = -1;
        observation.lastColor = -1;
        observations[key] = observation;
        NSRect screen = window.screen.visibleFrame;
        [window setFrameOrigin:NSMakePoint(NSMinX(screen) + 30 + (observations.count - 1) * 430,
                                          NSMaxY(screen) - window.frame.size.height)];
    }
    observation.frames++;
}

static void verifyNativeCompletion(void) {
    if (!completed) {
        fprintf(stderr, "[multi-scene-host] host exited before independent pixel/lifecycle checks completed\n");
        _exit(161);
    }
}
__attribute__((constructor)) static void multiSceneDeadline(void) {
    const char *value = getenv("IOS_USE_RUNTIME_CLOSE_SECOND");
    closeSecond = value && strcmp(value, "1") == 0;
    atexit(verifyNativeCompletion);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 26 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!completed) { fprintf(stderr, "[multi-scene-host] native window deadline\n"); exit(162); }
    });
}
