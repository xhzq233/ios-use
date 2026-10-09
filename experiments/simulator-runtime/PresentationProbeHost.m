// Linked only into the presentation workload. Read pixels from our own window.
#import <AppKit/AppKit.h>
#import <dlfcn.h>

static unsigned frames;
static BOOL completed;

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
            for (int i = 0; i < 3; i++) {
                if (pixel[i] > 200 && pixel[(i + 1) % 3] < 60 && pixel[(i + 2) % 3] < 60) color = i;
            }
        }
        if (bitmap) CGContextRelease(bitmap);
        if (center) CGImageRelease(center);
        CGColorSpaceRelease(rgb);
    }
    CFRelease(images);
    return color;
}

void IOSUseObserveHostFrame(NSWindow *window, BOOL hasInput) {
    if (hasInput) { fprintf(stderr, "[presentation-probe] unexpected input port\n"); exit(110); }
    if (++frames != 1) return;
    __block int previous = -1;
    __block unsigned transitions = 0, colors = 0;
    [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
        int color = windowColor(window);
        if (color < 0) return;
        colors |= 1U << color;
        if (previous != color) {
            if (previous >= 0) transitions++;
            previous = color;
        }
        // More transitions than the three-buffer pool can hold without returns.
        BOOL staticProbe = getenv("IOS_USE_RUNTIME_STATIC_PROBE") != NULL;
        if (staticProbe ? color == 0 : (frames >= 18 && transitions >= 12 && colors == 7)) {
            [timer invalidate];
            completed = YES;
            fprintf(stderr, "[presentation-probe] native RGB colors=%u transitions=%u frames=%u input=absent; closing window\n",
                colors, transitions, frames);
            [window performClose:nil];
        }
    }];
}

__attribute__((constructor)) static void presentationDeadline(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 18 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!completed) {
            fprintf(stderr, "[presentation-probe] native pixel/continuous-frame deadline; frames=%u\n", frames);
            exit(111);
        }
    });
}
