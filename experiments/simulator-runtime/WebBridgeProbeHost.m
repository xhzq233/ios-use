// Observe only this workload's native windows; UIKit composes every sampled pixel.
#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <unistd.h>

typedef struct { uint8_t r, g, b; BOOL valid; } Pixel;
@interface WebBridgeWindowObservation : NSObject
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic) int role;
@property(nonatomic) int lastColor;
@property(nonatomic) unsigned frames;
@property(nonatomic) unsigned transitions;
@property(nonatomic) int lastPhase;
@property(nonatomic) NSUInteger lastBridgeCount;
@property(nonatomic) uint32_t lastTargetRGB;
@property(nonatomic) BOOL closed;
@end
@implementation WebBridgeWindowObservation
@end
static NSMutableDictionary<NSNumber *, WebBridgeWindowObservation *> *observations;
static BOOL sawInitial, sawComposition, sawEmpty, sawReplacement, completed;
static unsigned survivorAtClose;

static void fail(const char *message) {
    fprintf(stderr, "[web-bridge-host-probe] %s\n", message);
    exit(172);
}
static NSUInteger bridgeCount(void) {
    NSUInteger (*count)(void) = dlsym(RTLD_DEFAULT, "IOSUseWebBridgeViewCount");
    if (!count) fail("native bridge count is unavailable");
    return count();
}
static CGImageRef copyWindowImage(NSWindow *window) {
    uint32_t (*connection)(void) = dlsym(RTLD_DEFAULT, "CGSMainConnectionID");
    CFArrayRef (*capture)(uint32_t, const uint32_t *, uint32_t, uint32_t) = dlsym(RTLD_DEFAULT, "CGSHWCaptureWindowList");
    if (!connection || !capture) return NULL;
    uint32_t identifier = (uint32_t)window.windowNumber;
    CFArrayRef images = capture(connection(), &identifier, 1, (1U << 11) | (1U << 8) | (1U << 19));
    CGImageRef image = images && CFArrayGetCount(images) ? CGImageRetain((CGImageRef)CFArrayGetValueAtIndex(images, 0)) : NULL;
    if (images) CFRelease(images);
    return image;
}
static Pixel pixelAt(CGImageRef image, NSWindow *window, CGFloat x, CGFloat y) {
    Pixel result = {0};
    if (!image) return result;
    // The capture omits shadow. Account for any title bar above the content,
    // then map UIKit's fixed logical viewport into the captured backing pixels.
    CGFloat scale = CGImageGetWidth(image) / window.frame.size.width;
    CGFloat contentHeight = window.contentView.bounds.size.height * scale;
    CGFloat top = MAX(0, CGImageGetHeight(image) - contentHeight);
    CGRect point = CGRectMake(x / 402 * CGImageGetWidth(image), top + y / 874 * contentHeight, 1, 1);
    CGImageRef sample = CGImageCreateWithImageInRect(image, point);
    uint8_t bytes[4] = {0};
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmap = CGBitmapContextCreate(bytes, 1, 1, 8, 4, rgb,
        kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast);
    if (sample && bitmap) {
        CGContextDrawImage(bitmap, CGRectMake(0, 0, 1, 1), sample);
        result = (Pixel){bytes[0], bytes[1], bytes[2], YES};
    }
    if (bitmap) CGContextRelease(bitmap);
    if (sample) CGImageRelease(sample);
    CGColorSpaceRelease(rgb);
    return result;
}
static BOOL gray(Pixel p) { return p.valid && p.r > 20 && p.r < 80 && p.g > 20 && p.g < 80 && p.b > 20 && p.b < 80; }
static BOOL green(Pixel p) { return p.valid && p.r < 50 && p.g > 200 && p.b < 50; }
static int phaseColor(Pixel p) {
    if (!p.valid) return 0;
    if (p.r > 200 && p.g > 200 && p.b > 200) return 1;
    if (p.r > 200 && p.g > 200 && p.b < 50) return 2;
    if (p.r > 200 && p.g < 50 && p.b > 200) return 3;
    if (p.r < 50 && p.g > 200 && p.b > 200) return 4;
    return 0;
}
static void sampleWindows(NSTimer *timer) {
    WebBridgeWindowObservation *a = nil, *b = nil;
    for (WebBridgeWindowObservation *observation in observations.allValues) {
        if (!observation.closed) {
            CGImageRef image = copyWindowImage(observation.window);
            Pixel identity = pixelAt(image, observation.window, 20, 700);
            int role = gray(identity) ? 0 : (identity.valid && identity.r < 50 && identity.b > 200 ? 1 : -1);
            if (role >= 0) {
                if (observation.role >= 0 && observation.role != role) fail("pixels crossed Scene windows");
                observation.role = role;
            }
            if (observation.role == 1 && identity.valid) {
                int color = identity.g > 200 ? 1 : identity.g < 50 ? 0 : -1;
                if (color >= 0) {
                    if (observation.lastColor >= 0 && observation.lastColor != color) observation.transitions++;
                    observation.lastColor = color;
                }
            } else if (observation.role == 0) {
                Pixel marker = pixelAt(image, observation.window, 44, 100);
                Pixel target = pixelAt(image, observation.window, 140, 260);
                int phase = phaseColor(marker);
                NSUInteger views = bridgeCount();
                uint32_t targetRGB = target.valid ? (1U << 24) | (target.r << 16) | (target.g << 8) | target.b : 0;
                if (phase != observation.lastPhase || (phase == 3 &&
                    (views != observation.lastBridgeCount || targetRGB != observation.lastTargetRGB))) {
                    fprintf(stderr, "[web-bridge-host-probe] phase=%d markerRGB=%u,%u,%u targetRGB=%u,%u,%u valid=%d views=%lu frames=%u\n",
                        phase, marker.r, marker.g, marker.b, target.r, target.g, target.b, target.valid,
                        (unsigned long)views, observation.frames);
                }
                observation.lastPhase = phase;
                observation.lastBridgeCount = views;
                observation.lastTargetRGB = targetRGB;
                if (phase == 1 && green(target) &&
                    gray(pixelAt(image, observation.window, 320, 260))) sawInitial = YES;
                if (phase == 2) {
                    Pixel mixed = pixelAt(image, observation.window, 150, 350);
                    BOOL blend = mixed.valid && mixed.r > 80 && mixed.r < 220 && mixed.g > 80 && mixed.g < 220 && mixed.b < 50;
                    if (green(pixelAt(image, observation.window, 100, 290)) && blend &&
                        gray(pixelAt(image, observation.window, 235, 350)) &&
                        gray(pixelAt(image, observation.window, 60, 330)) &&
                        gray(pixelAt(image, observation.window, 60, 210))) sawComposition = YES;
                }
                if (phase == 3 && gray(target) && !views) sawEmpty = YES;
                if (phase == 4 && green(target) && views == 1) sawReplacement = YES;
            }
            if (image) CGImageRelease(image);
        }
        if (observation.role == 0) {
            if (a) fail("duplicate web Scene window");
            a = observation;
        } else if (observation.role == 1) {
            if (b) fail("duplicate sentinel Scene window");
            b = observation;
        }
    }
    if (!a || !b) return;
    if (!a.closed && sawInitial && sawComposition && sawEmpty && sawReplacement && b.transitions >= 12) {
        fprintf(stderr, "[web-bridge-host-probe] green HTML, transformed/clipped web, translucent UIKit overlay, empty gap, replacement pixels verified; closing web Scene\n");
        a.closed = YES;
        survivorAtClose = b.transitions;
        [a.window performClose:nil];
    } else if (a.closed && b.transitions >= survivorAtClose + 12 && !bridgeCount()) {
        completed = YES;
        [timer invalidate];
        fprintf(stderr, "[web-bridge-host-probe] native web count=0; surviving Scene pixel transitions=%u\n", b.transitions - survivorAtClose);
        // The child independently checks callbacks, weak lifetime and Scene state.
    }
}

void IOSUseObserveHostFrame(NSWindow *window, BOOL hasInput) {
    if (hasInput) fail("unexpected input dependency");
    if (!observations) {
        observations = [NSMutableDictionary new];
        [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) { sampleWindows(timer); }];
    }
    NSNumber *key = @(window.windowNumber);
    WebBridgeWindowObservation *observation = observations[key];
    if (!observation) {
        if (observations.count >= 2) fail("extra native window for embedded WKWebView");
        observation = [WebBridgeWindowObservation new];
        observation.window = window;
        observation.role = -1;
        observation.lastColor = -1;
        observation.lastPhase = -1;
        observations[key] = observation;
        NSRect screen = window.screen.visibleFrame;
        [window setFrameOrigin:NSMakePoint(NSMinX(screen) + 30 + (observations.count - 1) * 430,
            NSMaxY(screen) - window.frame.size.height)];
    }
    observation.frames++;
}
static void verifyCompletion(void) {
    if (!completed) {
        fprintf(stderr, "[web-bridge-host-probe] incomplete pixels/lifecycle initial=%d composition=%d empty=%d replacement=%d\n",
            sawInitial, sawComposition, sawEmpty, sawReplacement);
        _exit(173);
    }
}
__attribute__((constructor)) static void webBridgeDeadline(void) {
    atexit(verifyCompletion);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 44 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!completed) fail("native web bridge pixel/lifecycle deadline");
    });
}
