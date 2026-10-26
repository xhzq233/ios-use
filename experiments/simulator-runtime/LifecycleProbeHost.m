// Only the workload host automatically minimizes/restores its own window.
#import <AppKit/AppKit.h>
void IOSUseObserveHostFrame(NSWindow *window, BOOL hasInput) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [window miniaturize:nil]; });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [window deminiaturize:nil]; });
    });
}
