// Startup observation for a user-supplied, already Simulator-compatible app.
// A successful capture is not a complete application compatibility test.
#import <UIKit/UIKit.h>
#import <IOSurface/IOSurfaceRef.h>
#import <dlfcn.h>

extern IOSurfaceRef IOSUseCopyWindowSurface(UIWindow *window);

__attribute__((constructor)) static void observeApplication(void) {
    const char *tap = getenv("IOS_USE_RUNTIME_TAP");
    if (tap) {
        double x, y;
        if (sscanf(tap, "%lf,%lf", &x, &y) != 2) exit(45);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            BOOL (*sendTouch)(CGPoint, UITouchPhase) = dlsym(RTLD_DEFAULT, "IOSUseSendTouch");
            CGPoint point = CGPointMake(x, y);
            if (!sendTouch || !sendTouch(point, UITouchPhaseBegan)) exit(45);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                if (!sendTouch(point, UITouchPhaseEnded)) exit(45);
            });
        });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        UIApplication *app = UIApplication.sharedApplication;
        UIWindow *delegateWindow = [app.delegate respondsToSelector:@selector(window)] ? app.delegate.window : nil;
        NSLog(@"[app-capture] delegate window=%@", delegateWindow);
        UIWindow *window = nil;
        for (UIWindow *candidate in app.windows) {
            NSLog(@"[app-capture] candidate=%@ hidden=%d frame=%@ root=%@ root-frame=%@ alpha=%f", NSStringFromClass(candidate.class),
                  candidate.hidden, NSStringFromCGRect(candidate.frame), NSStringFromClass(candidate.rootViewController.class),
                  NSStringFromCGRect(candidate.rootViewController.view.frame), candidate.alpha);
            if (!candidate.hidden && candidate.rootViewController) window = candidate;
        }
        NSLog(@"[app-capture] state=%ld window=%@ root=%@", (long)app.applicationState, window, window.rootViewController);
        if (!window || app.applicationState != UIApplicationStateActive) exit(43);
        IOSurfaceRef surface = IOSUseCopyWindowSurface(window);
        if (!surface) exit(40);
        if (IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL)) exit(41);
        size_t width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface);
        size_t stride = IOSurfaceGetBytesPerRow(surface);
        const uint8_t *pixels = IOSurfaceGetBaseAddress(surface);
        unsigned minimum = 255, maximum = 0, nonblack = 0;
        for (size_t y = 0; pixels && y < height; ++y) {
            for (size_t x = 0; x < width; ++x) {
                const uint8_t *p = pixels + y * stride + x * 4;
                unsigned light = (p[0] + p[1] + p[2]) / 3;
                minimum = MIN(minimum, light);
                maximum = MAX(maximum, light);
                nonblack += light > 30;
            }
        }
        CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
        CGContextRef bitmap = CGBitmapContextCreate(IOSurfaceGetBaseAddress(surface),
            IOSurfaceGetWidth(surface), IOSurfaceGetHeight(surface), 8, IOSurfaceGetBytesPerRow(surface), color,
            kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
        CGImageRef image = bitmap ? CGBitmapContextCreateImage(bitmap) : NULL;
        BOOL saved = image && [UIImagePNGRepresentation([UIImage imageWithCGImage:image])
            writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"app-composited.png"] atomically:YES];
        if (image) CGImageRelease(image);
        if (bitmap) CGContextRelease(bitmap);
        CGColorSpaceRelease(color);
        IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
        BOOL visibleContent = maximum > minimum + 30 && nonblack > 100;
        fprintf(stderr, "[app-capture] CA snapshot saved=%d nonblack=%u contrast=%u; inspect app-composited.png\n",
                saved, nonblack, maximum - minimum);
        if (!saved || !visibleContent) { CFRelease(surface); exit(42); }
        CFRelease(surface);
        if (getenv("IOS_USE_RUNTIME_PRESENT")) return;
        exit(0);
    });
}
