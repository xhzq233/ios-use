#import "IOSUsePlayStatusBar.h"
#import "IOSUsePlayDevice.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>

static void setInteger(id object, NSString *name, NSInteger value) {
    ((void (*)(id,SEL,NSInteger))objc_msgSend)(object,NSSelectorFromString(name),value);
}
static void setColor(id object, NSString *name, UIColor *color) {
    ((void (*)(id,SEL,id))objc_msgSend)(object,NSSelectorFromString(name),color);
}

static UIImage *glyph(NSString *kind, UIColor *color) {
    NSDictionary *classes = @{@"wifi":@"_UIStatusBarWifiSignalView",
        @"cellular":@"_UIStatusBarCellularSignalView", @"battery":@"_UIStatusBarBatteryView"};
    // These are UIKit's own status glyphs, including their stroke geometry.
    // An unset iconSize asserts; set it before asking for intrinsicContentSize.
    @try {
        UIView *v = [[NSClassFromString(classes[kind]) alloc] initWithFrame:CGRectMake(0,0,30,20)];
        if (v) {
            setInteger(v,@"setIconSize:",2);
            setInteger(v,@"setRounded:",YES);
            if ([kind isEqual:@"battery"]) {
                ((void (*)(id,SEL,double))objc_msgSend)(v,NSSelectorFromString(@"setChargePercent:"),1.0);
                setColor(v,@"setFillColor:",color);
                setColor(v,@"setBodyColor:",[color colorWithAlphaComponent:0.4]);
                setColor(v,@"setPinColor:",[color colorWithAlphaComponent:0.4]);
            } else {
                NSInteger bars = [kind isEqual:@"wifi"] ? 3 : 4;
                setInteger(v,@"setSignalMode:",2); // Normal signal, rather than searching dots.
                setInteger(v,@"setNumberOfBars:",bars);
                setInteger(v,@"setNumberOfActiveBars:",bars);
                setColor(v,@"setActiveColor:",color);
                setColor(v,@"setInactiveColor:",[color colorWithAlphaComponent:0.3]);
            }
            CGSize size = v.intrinsicContentSize;
            v.frame = (CGRect){CGPointZero,size};
            [v layoutIfNeeded];
            UIGraphicsBeginImageContextWithOptions(size,NO,IOSUsePlayDeviceScale);
            [v.layer renderInContext:UIGraphicsGetCurrentContext()];
            UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
            return image;
        }
    } @catch (NSException *exception) {
        NSLog(@"[ios-use] Status glyph %@ unavailable: %@",kind,exception.reason);
    }
    // New host UIKit versions may replace private glyph classes.
    NSString *symbol = [kind isEqual:@"battery"] ? @"battery.100percent" : ([kind isEqual:@"cellular"] ? @"cellularbars" : @"wifi");
    return [[UIImage systemImageNamed:symbol withConfiguration:
        [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold]]
        imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal];
}

BOOL IOSUsePlayStatusBarUsesLightContent(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden || window.windowLevel != UIWindowLevelNormal) continue;
            UIViewController *vc = window.rootViewController;
            while (vc.presentedViewController) vc = vc.presentedViewController;
            while (vc.childViewControllerForStatusBarStyle) vc = vc.childViewControllerForStatusBarStyle;
            UIStatusBarStyle style = vc.preferredStatusBarStyle;
            if (style == UIStatusBarStyleLightContent) return YES;
            if (style == UIStatusBarStyleDarkContent) return NO;
            return vc.view.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
        }
    }
    return NO;
}

static void drawGlyph(UIImage *image, CGFloat x, CGFloat centerY) {
    [image drawAtPoint:CGPointMake(x,centerY-image.size.height/2)];
}
static void drawSizedGlyph(UIImage *image, CGFloat x, CGFloat centerY, CGSize size) {
    [image drawInRect:CGRectMake(x,centerY-size.height/2,size.width,size.height)];
}
static void drawTime(CGFloat x, CGFloat centerY, CGFloat size, UIColor *color, BOOL centered) {
    NSDictionary *attributes = @{NSFontAttributeName:[UIFont systemFontOfSize:size weight:UIFontWeightSemibold],NSForegroundColorAttributeName:color};
    CGSize bounds = [@"9:41" sizeWithAttributes:attributes];
    [@"9:41" drawAtPoint:CGPointMake(centered ? x-bounds.width/2 : x,centerY-bounds.height/2) withAttributes:attributes];
}
static void drawDuoCluster(BOOL lightContent, CGRect frame) {
    static CGPDFDocumentRef black, white;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSBundle *bundle = [NSBundle bundleForClass:NSClassFromString(@"IOSUsePlayDeviceChromeController")];
        NSString *directory = [bundle.resourcePath stringByAppendingPathComponent:@"DeviceChrome"];
        black = CGPDFDocumentCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:
            [directory stringByAppendingPathComponent:@"duo-status-black.pdf"]]);
        white = CGPDFDocumentCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:
            [directory stringByAppendingPathComponent:@"duo-status-white.pdf"]]);
    });
    CGPDFDocumentRef document = lightContent ? white : black;
    if (!document) return;
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSaveGState(context);
    CGContextTranslateCTM(context,frame.origin.x,CGRectGetMaxY(frame));
    CGContextScaleCTM(context,frame.size.width/46,-frame.size.height/46);
    CGContextDrawPDFPage(context,CGPDFDocumentGetPage(document,1));
    CGContextRestoreGState(context);
}

UIImage *IOSUsePlayStatusBarImage(BOOL lightContent, CGSize pixelSize) {
    IOSUsePlayDeviceRect frame = IOSUsePlayDeviceStatusBarRect();
    if (frame.height == 0) return nil;
    UIColor *color = lightContent ? UIColor.whiteColor : UIColor.blackColor;
    UIGraphicsBeginImageContextWithOptions(pixelSize,NO,1);
    CGContextScaleCTM(UIGraphicsGetCurrentContext(),pixelSize.width/frame.width,pixelSize.height/frame.height);
    if (IOSUsePlayDeviceHasSideStatusBar()) {
        // Apple's iOS 27 UI Kit: 48x86 component, time at (0,11), Ring at
        // (1,35) sized 46x46. Import the original paths instead of video pixels.
        BOOL left = IOSUsePlayDeviceStatusBarOnLeft();
        CGFloat x = left ? 48 : frame.width-48;
        int turns = IOSUsePlayDeviceQuarterTurns();
        BOOL cameraAbove = !IOSUsePlayDeviceIsDuoInner() && (turns == 0 || turns == 3);
        // Outer portrait and inner landscape Tab Bar examples place the
        // component at y=72 and y=24 respectively. Runtime layout may vary.
        CGFloat top = cameraAbove ? 72 : 24;
        UIFont *bold = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
        UIFont *font = [UIFont fontWithDescriptor:
            [bold.fontDescriptor fontDescriptorWithDesign:UIFontDescriptorSystemDesignRounded] size:16];
        NSDictionary *attributes = @{NSFontAttributeName:font,NSForegroundColorAttributeName:color};
        CGFloat textWidth = [@"9:41" sizeWithAttributes:attributes].width;
        [@"9:41" drawAtPoint:CGPointMake(x-textWidth/2,top+11) withAttributes:attributes];
        drawDuoCluster(lightContent,CGRectMake(x-23,top+35,46,46));
    } else {
        UIImage *wifi = glyph(@"wifi",color), *cell = glyph(@"cellular",color), *battery = glyph(@"battery",color);
        CGFloat w=frame.width, centerY=frame.height/2.0;
        BOOL tablet=IOSUsePlayDeviceUserInterfaceIdiom == 1 || IOSUsePlayDeviceIsDuoInner();
        BOOL duoPortrait=IOSUsePlayDeviceIsDuoInner();
        BOOL homeButton=strcmp(IOSUsePlayDeviceCurrent()->name,"iphone-se")==0;
        BOOL island=!tablet && IOSUsePlayDeviceCurrent()->safeAreaTop >= 59;
        // Logical-point positions measured against Simulator screenshots. The
        // island phones use larger glyphs and more trailing clearance.
        CGSize batterySize=(island || tablet) ? CGSizeMake(27.5,13) : battery.size;
        CGSize wifiSize=island ? CGSizeMake(17,12.33) : (tablet ? CGSizeMake(14,10) : wifi.size);
        CGSize cellSize=island ? CGSizeMake(19.33,12.33) : cell.size;
        CGFloat margin=duoPortrait ? 32 : (tablet ? 15 : (homeButton ? 6 : (island ? 32.67 : 18)));
        CGFloat gap=island ? 7.33 : (tablet ? 4.5 : 6);
        CGFloat batteryX=w-margin-batterySize.width;
        drawSizedGlyph(battery,batteryX,centerY,batterySize);
        if (homeButton) {
            drawTime(w/2,centerY,12,color,YES);
            drawGlyph(cell,6,centerY);drawGlyph(wifi,12+cell.size.width,centerY);
        } else {
            CGFloat wifiX=batteryX-gap-wifiSize.width;
            drawSizedGlyph(wifi,wifiX,centerY,wifiSize);
            if (!tablet) drawSizedGlyph(cell,wifiX-gap-cellSize.width,centerY,cellSize);
            CGFloat timeX=duoPortrait ? 32 : (tablet ? 16 : (island ? w*0.137 : 35));
            drawTime(timeX,centerY,tablet ? 14 : (island ? 17 : 16),color,NO);
        }
    }
    UIImage *result=UIGraphicsGetImageFromCurrentImageContext();UIGraphicsEndImageContext();
    return result;
}
