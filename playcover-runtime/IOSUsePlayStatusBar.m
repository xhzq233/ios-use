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

UIImage *IOSUsePlayStatusBarImage(BOOL lightContent) {
    IOSUsePlayDeviceRect frame = IOSUsePlayDeviceStatusBarRect();
    if (frame.height == 0) return nil;
    UIColor *color = lightContent ? UIColor.whiteColor : UIColor.blackColor;
    UIImage *wifi = glyph(@"wifi",color), *cell = glyph(@"cellular",color), *battery = glyph(@"battery",color);
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(frame.width,frame.height),NO,IOSUsePlayDeviceScale);
    if (IOSUsePlayDeviceHasSideStatusBar()) {
        // Duo's circular status cluster, from Apple Tech Talk 111466 (7:00).
        // This drawing and its placement are a visual preview, not iOS 27 UI.
        BOOL left = IOSUsePlayDeviceStatusBarOnLeft();
        CGFloat x = left ? 48 : frame.width-48;
        int turns = IOSUsePlayDeviceQuarterTurns();
        BOOL cameraAbove = !IOSUsePlayDeviceIsDuoInner() && (turns == 0 || turns == 3);
        CGFloat timeY = cameraAbove ? 93 : 30, centerY = timeY+37;
        drawTime(x,timeY,16,color,YES);
        UIBezierPath *ring = [UIBezierPath bezierPathWithArcCenter:CGPointMake(x,centerY) radius:18.5
            startAngle:M_PI_4 endAngle:3*M_PI_4 clockwise:NO];
        ring.lineWidth=2.6;ring.lineCapStyle=kCGLineCapRound;[color setStroke];[ring stroke];
        drawGlyph(wifi,x-wifi.size.width/2,centerY);
        [color setFill];
        for (int i=0;i<4;i++) {
            CGFloat dx=(i-1.5)*7.5, y=centerY+18.5+(i==1 || i==2 ? 2 : 0);
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(x+dx-1.6,y-1.6,3.2,3.2)] fill];
        }
    } else {
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
