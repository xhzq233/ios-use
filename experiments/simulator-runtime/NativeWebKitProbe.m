// Native-host feasibility probe. This does not bridge Simulator WKWebView.
#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>

@interface NativeWebKitDelegate : NSObject <NSApplicationDelegate, WKNavigationDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) WKWebView *web;
@property(nonatomic) BOOL finished;
@property(nonatomic) int result;
@end

@implementation NativeWebKitDelegate
- (void)finishWithCode:(int)code message:(NSString *)message {
    if (self.finished) return;
    self.finished = YES;
    self.result = code;
    fprintf(stderr, "[native-webkit] %s\n", message.UTF8String);
    self.web.navigationDelegate = nil;
    [self.web stopLoading];
    [self.web removeFromSuperview];
    self.web = nil;
    [self.window close];
    [NSApp stop:nil];
    // Wake the event loop so main can return the probe's actual result.
    [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                      location:NSZeroPoint modifierFlags:0
                                     timestamp:0 windowNumber:0 context:nil
                                       subtype:0 data1:0 data2:0] atStart:NO];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 320, 240)
                                             styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                               backing:NSBackingStoreBuffered defer:NO];
    self.window.releasedWhenClosed = NO;
    self.window.title = @"Native WebKit Probe";
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
    self.web = [[WKWebView alloc] initWithFrame:self.window.contentView.bounds configuration:configuration];
    self.web.navigationDelegate = self;
    self.web.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.window.contentView addSubview:self.web];
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [self.web loadHTMLString:@"<!doctype html><html><head>"
                            "<meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; style-src 'unsafe-inline'\">"
                            "<style>html,body{margin:0;width:100%;height:100%;background:rgb(0,255,0)}</style>"
                            "</head><body></body></html>" baseURL:nil];
}

- (void)webView:(WKWebView *)web didFinishNavigation:(WKNavigation *)navigation {
    fprintf(stderr, "[native-webkit] navigation complete\n");
    [web evaluateJavaScript:@"6 * 7" completionHandler:^(id value, NSError *error) {
        if (self.finished) return;
        if (error || ![value isKindOfClass:NSNumber.class] || [value intValue] != 42) {
            [self finishWithCode:123 message:[NSString stringWithFormat:@"JavaScript failed: value=%@ error=%@", value, error]];
            return;
        }
        [web takeSnapshotWithConfiguration:nil completionHandler:^(NSImage *image, NSError *error) {
            if (self.finished) return;
            CGImageRef cgImage = [image CGImageForProposedRect:NULL context:nil hints:nil];
            if (error || !cgImage || !CGImageGetWidth(cgImage) || !CGImageGetHeight(cgImage)) {
                [self finishWithCode:124 message:[NSString stringWithFormat:@"Snapshot failed: %@", error]];
                return;
            }
            NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithCGImage:cgImage];
            NSColor *pixel = [[bitmap colorAtX:bitmap.pixelsWide / 2 y:bitmap.pixelsHigh / 2]
                             colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
            BOOL green = pixel && pixel.greenComponent > 0.9 && pixel.redComponent < 0.1 && pixel.blueComponent < 0.1;
            fprintf(stderr, "[native-webkit] JS=%d snapshot=%ldx%ld center RGB=%.3f,%.3f,%.3f\n",
                    [value intValue], (long)bitmap.pixelsWide, (long)bitmap.pixelsHigh,
                    pixel.redComponent, pixel.greenComponent, pixel.blueComponent);
            [self finishWithCode:green ? 0 : 125 message:green ? @"PASS" : @"Snapshot center is not green"];
        }];
    }];
}

- (void)webView:(WKWebView *)web didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self finishWithCode:121 message:[NSString stringWithFormat:@"Navigation failed: %@", error]];
}
- (void)webView:(WKWebView *)web didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self finishWithCode:122 message:[NSString stringWithFormat:@"Provisional navigation failed: %@", error]];
}
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)web {
    [self finishWithCode:126 message:@"Web content process terminated"];
}
@end

int main(void) {
    @autoreleasepool {
        NSApplication *application = NSApplication.sharedApplication;
        [application setActivationPolicy:NSApplicationActivationPolicyRegular];
        NativeWebKitDelegate *delegate = [NativeWebKitDelegate new];
        delegate.result = 127;
        application.delegate = delegate;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [delegate finishWithCode:127 message:@"Deadline exceeded"];
        });
        [application run];
        return delegate.result;
    }
}
