#import "IOSUsePlayDeviceChrome.h"
#import "IOSUsePlayDevice.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

static id host, decoration;
static CALayer *artwork, *overlay;
static CAShapeLayer *bezel, *corners;
static NSMutableArray *observers;
static UIImage *localFrame;
static NSDictionary *localSizing;
static id titlebarAccessory;
static BOOL updating;
static id get(id object, NSString *name) {
    return ((id (*)(id, SEL))objc_msgSend)(object, NSSelectorFromString(name));
}
static CGRect rect(id object, NSString *name) {
    return ((CGRect (*)(id, SEL))objc_msgSend)(object, NSSelectorFromString(name));
}
static void boolean(id object, NSString *name, BOOL value) {
    ((void (*)(id, SEL, BOOL))objc_msgSend)(object, NSSelectorFromString(name), value);
}
static void object(id target, NSString *name, id value) {
    ((void (*)(id, SEL, id))objc_msgSend)(target, NSSelectorFromString(name), value);
}

@interface IOSUsePlayDeviceChromeResources : NSObject
@end
@implementation IOSUsePlayDeviceChromeResources
@end

static UIImage *image(NSString *name) {
    NSBundle *bundle = [NSBundle bundleForClass:IOSUsePlayDeviceChromeResources.class];
    return [UIImage imageWithContentsOfFile:[bundle pathForResource:name ofType:@"png"]];
}

static void drawPDF(NSString *directory, NSString *name, CGRect target, CGContextRef context) {
    if (!name) return;
    NSURL *url = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"pdf"]]];
    CGPDFDocumentRef document = CGPDFDocumentCreateWithURL((__bridge CFURLRef)url);
    if (!document) return;
    CGPDFPageRef page = CGPDFDocumentGetPage(document, 1);
    if (page) {
        CGContextSaveGState(context);
        CGContextConcatCTM(context, CGPDFPageGetDrawingTransform(page, kCGPDFMediaBox, target, 0, false));
        CGContextDrawPDFPage(context, page);
        CGContextRestoreGState(context);
    }
    CGPDFDocumentRelease(document);
}

static void loadLocalFrame(void) {
    // Read artwork from the user's DeviceKit installation. Never bundle it.
    NSString *preset = @(IOSUsePlayDeviceCurrent()->name);
    NSString *model = [preset isEqual:@"ipad-pro-11"] ? @"tablet2" :
        [preset isEqual:@"iphone-15-pro-max"] ? @"phone10" :
        [preset isEqual:@"iphone-15-pro"] ? @"phone9" : nil;
    if (!model) return;
    NSString *directory = [NSString stringWithFormat:@"/Library/Developer/DeviceKit/Chrome/%@.devicechrome/Contents/Resources", model];
    NSData *data = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"chrome.json"]];
    NSDictionary *profile = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    NSDictionary *images = profile[@"images"];
    NSDictionary *sizing = images[@"sizing"];
    if (![sizing isKindOfClass:NSDictionary.class]) return;
    CGFloat width = IOSUsePlayDeviceLogicalWidth + [sizing[@"leftWidth"] doubleValue] + [sizing[@"rightWidth"] doubleValue];
    CGFloat height = IOSUsePlayDeviceLogicalHeight + [sizing[@"topHeight"] doubleValue] + [sizing[@"bottomHeight"] doubleValue];
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(width, height), NO, 2);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextTranslateCTM(context, 0, height);
    CGContextScaleCTM(context, 1, -1);
    if (images[@"composite"]) {
        drawPDF(directory, images[@"composite"], CGRectMake(0, 0, width, height), context);
    } else {
        CGFloat c = 80;
        NSArray *names = @[@"bottomLeft", @"bottom", @"bottomRight", @"left", @"right", @"topLeft", @"top", @"topRight"];
        CGRect tiles[] = {
            { {0, 0}, {c, c} }, { {c, 0}, {width-2*c, c} }, { {width-c, 0}, {c, c} },
            { {0, c}, {c, height-2*c} }, { {width-c, c}, {c, height-2*c} },
            { {0, height-c}, {c, c} }, { {c, height-c}, {width-2*c, c} }, { {width-c, height-c}, {c, c} }
        };
        for (NSUInteger i = 0; i < names.count; ++i) drawPDF(directory, images[names[i]], tiles[i], context);
    }
    localFrame = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    localSizing = sizing;
}

static void removeDecoration(void) {
    for (id observer in observers) [NSNotificationCenter.defaultCenter removeObserver:observer];
    observers = nil;
    if (decoration) {
        object(host, @"removeChildWindow:", decoration);
        ((void (*)(id, SEL))objc_msgSend)(decoration, NSSelectorFromString(@"close"));
    }
    if (titlebarAccessory) {
        NSArray *accessories = get(host, @"titlebarAccessoryViewControllers");
        NSUInteger index = [accessories indexOfObjectIdenticalTo:titlebarAccessory];
        if (index != NSNotFound) {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(host, NSSelectorFromString(@"removeTitlebarAccessoryViewControllerAtIndex:"), (NSInteger)index);
        }
        titlebarAccessory = nil;
    }
    decoration = nil;
    host = nil;
    artwork = nil;
    overlay = nil;
    bezel = nil;
    corners = nil;
    localFrame = nil;
    localSizing = nil;
}

void IOSUsePlayDeviceChromeUpdate(id hostWindow) {
    NSCParameterAssert(NSThread.isMainThread);
    if (updating) return;
    if (strcmp(getenv("IOS_USE_MAC_CHROME") ?: "on", "off") == 0 ||
        strcmp(getenv("IOS_USE_MAC_WINDOW_MODE") ?: "fixed", "resizable") == 0) {
        // A resizable App scene is not the entire device screen.
        removeDecoration();
        return;
    }
    if (host != hostWindow) removeDecoration();
    if (!hostWindow) return;
    if (!decoration) {
        host = hostWindow;
        loadLocalFrame();
        Class cls = NSClassFromString(@"IOSUsePlayChromeWindow");
        if (!cls) {
            cls = objc_allocateClassPair(NSClassFromString(@"NSWindow"), "IOSUsePlayChromeWindow", 0);
            objc_registerClassPair(cls);
        }
        decoration = ((id (*)(id, SEL, CGRect, NSUInteger, NSUInteger, BOOL))objc_msgSend)(
            [cls alloc], NSSelectorFromString(@"initWithContentRect:styleMask:backing:defer:"),
            CGRectMake(0, 0, 100, 100), 0, 2, NO);
        boolean(decoration, @"setReleasedWhenClosed:", NO);
        boolean(decoration, @"setOpaque:", NO);
        boolean(decoration, @"setHasShadow:", NO);
        boolean(decoration, @"setIgnoresMouseEvents:", YES);
        object(decoration, @"setBackgroundColor:", get(NSClassFromString(@"NSColor"), @"clearColor"));
        id content = get(decoration, @"contentView");
        boolean(content, @"setWantsLayer:", YES);
        CALayer *root = get(content, @"layer");
        artwork = [CALayer layer];
        bezel = [CAShapeLayer layer];
        corners = [CAShapeLayer layer];
        overlay = [CALayer layer];
        [root addSublayer:corners];
        [root addSublayer:artwork];
        [root addSublayer:bezel];
        [root addSublayer:overlay];
        ((void (*)(id, SEL, id, NSInteger))objc_msgSend)(host, NSSelectorFromString(@"addChildWindow:ordered:"), decoration, 1);
        observers = [NSMutableArray array];
        for (NSString *name in @[@"NSWindowDidMoveNotification", @"NSWindowDidResizeNotification",
                                @"NSWindowDidChangeBackingPropertiesNotification"]) {
            [observers addObject:[NSNotificationCenter.defaultCenter addObserverForName:name object:host
                queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
                    IOSUsePlayDeviceChromeUpdate(host);
                }]];
        }
        [observers addObject:[NSNotificationCenter.defaultCenter addObserverForName:@"NSWindowWillCloseNotification"
            object:host queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
                removeDecoration();
            }]];
    }
    id content = get(host, @"contentView");
    CGRect canvas = ((CGRect (*)(id, SEL, CGRect))objc_msgSend)(host,
        NSSelectorFromString(@"convertRectToScreen:"), rect(content, @"bounds"));
    CGFloat w = IOSUsePlayDeviceLogicalWidth, h = IOSUsePlayDeviceLogicalHeight;
    CGFloat scale = canvas.size.width / w;
    NSString *preset = @(IOSUsePlayDeviceCurrent()->name);
    BOOL outer = [preset isEqual:@"iphone-duo-outer"];
    BOOL inner = [preset isEqual:@"iphone-duo-inner"];
    BOOL tablet = IOSUsePlayDeviceUserInterfaceIdiom == 1;
    BOOL se = [preset isEqual:@"iphone-se"];
    CGFloat left = outer ? 20 : inner ? 16 : tablet ? 28 : 14;
    CGFloat right = outer || inner ? 16 : left;
    CGFloat top = outer ? 16 : inner ? 22 : se ? 76 : left;
    CGFloat bottom = outer || inner ? 16 : top;
    if (localFrame) {
        left = [localSizing[@"leftWidth"] doubleValue];
        right = [localSizing[@"rightWidth"] doubleValue];
        top = [localSizing[@"topHeight"] doubleValue];
        bottom = [localSizing[@"bottomHeight"] doubleValue];
    }
    // Reserve titlebar space above the bezel. Keep native traffic-light controls
    // outside the simulated screen rather than painting over their hit targets.
    updating = YES;
    if (!titlebarAccessory) {
        titlebarAccessory = [NSClassFromString(@"NSTitlebarAccessoryViewController") new];
        id view = ((id (*)(id, SEL, CGRect))objc_msgSend)([NSClassFromString(@"NSView") alloc],
            NSSelectorFromString(@"initWithFrame:"), CGRectMake(0, 0, 1, ceil(top * scale) + 4));
        object(titlebarAccessory, @"setView:", view);
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(titlebarAccessory, NSSelectorFromString(@"setLayoutAttribute:"), 4);
        object(host, @"addTitlebarAccessoryViewController:", titlebarAccessory);
    }
    updating = NO;
    CGRect frame = CGRectMake(canvas.origin.x - left * scale, canvas.origin.y - bottom * scale,
                             canvas.size.width + (left + right) * scale, canvas.size.height + (top + bottom) * scale);
    ((void (*)(id, SEL, CGRect, BOOL))objc_msgSend)(decoration, NSSelectorFromString(@"setFrame:display:"), frame, YES);
    CGRect bounds = CGRectMake(0, 0, w + left + right, h + top + bottom);
    CGRect screen = CGRectMake(left, bottom, w, h);
    CGFloat radius = outer ? 64 : inner ? 58 : tablet ? 18 : se ? 0 : 55;
    UIBezierPath *hole = [UIBezierPath bezierPathWithRoundedRect:screen cornerRadius:radius];
    if (outer) {
        // Hinge edge is nearly square; the outside edge stays rounded.
        hole = [UIBezierPath bezierPathWithRoundedRect:screen byRoundingCorners:UIRectCornerTopRight | UIRectCornerBottomRight
                                         cornerRadii:CGSizeMake(radius, radius)];
    }
    UIBezierPath *mask = [UIBezierPath bezierPathWithRect:bounds];
    [mask appendPath:hole];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (CALayer *layer in @[corners, artwork, bezel, overlay]) {
        layer.bounds = bounds;
        layer.anchorPoint = CGPointZero;
        layer.position = CGPointZero;
        layer.transform = CATransform3DMakeScale(scale, scale, 1);
    }
    // Cover the square App corners in the decoration only. Clipping the host
    // layer itself would also clip the full rectangular automation screenshot.
    UIBezierPath *cornerCover = [UIBezierPath bezierPathWithRect:screen];
    [cornerCover appendPath:hole];
    corners.path = cornerCover.CGPath;
    corners.fillRule = kCAFillRuleEvenOdd;
    id background = get(NSClassFromString(@"NSColor"), @"windowBackgroundColor");
    corners.fillColor = ((CGColorRef (*)(id, SEL))objc_msgSend)(background, NSSelectorFromString(@"CGColor"));
    if (outer || inner || localFrame) {
        NSString *variant = outer ? @"outer" : @"inner";
        artwork.contents = (__bridge id)(localFrame ?: image([NSString stringWithFormat:@"duo-%@-Frame", variant])).CGImage;
        overlay.contents = localFrame ? nil : (__bridge id)image([NSString stringWithFormat:@"duo-%@-Overlay", variant]).CGImage;
        CAShapeLayer *cutout = [CAShapeLayer layer];
        cutout.frame = bounds;
        cutout.path = mask.CGPath;
        cutout.fillRule = kCAFillRuleEvenOdd;
        artwork.mask = cutout;
        bezel.path = nil;
    } else {
        UIBezierPath *body = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(bounds, 2, 2)
                                                     cornerRadius:se ? 48 : radius + left - 2];
        [body appendPath:hole];
        bezel.path = body.CGPath;
        bezel.fillRule = kCAFillRuleEvenOdd;
        bezel.fillColor = [UIColor colorWithWhite:0.035 alpha:1].CGColor;
        bezel.strokeColor = [UIColor colorWithWhite:0.42 alpha:1].CGColor;
        bezel.lineWidth = 1.5;
        // These are original simple bezels; no Xcode artwork is required.
    }
    [CATransaction commit];
    BOOL visible = ((BOOL (*)(id, SEL))objc_msgSend)(host, NSSelectorFromString(@"isVisible"));
    BOOL minimized = ((BOOL (*)(id, SEL))objc_msgSend)(host, NSSelectorFromString(@"isMiniaturized"));
    BOOL decorationVisible = ((BOOL (*)(id, SEL))objc_msgSend)(decoration, NSSelectorFromString(@"isVisible"));
    if (visible && !minimized && !decorationVisible) object(decoration, @"orderFront:", nil);
}
