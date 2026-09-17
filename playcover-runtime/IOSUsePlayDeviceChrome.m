#import "IOSUsePlayDeviceChrome.h"
#import "IOSUsePlayDevice.h"
#import "IOSUsePlayDeviceConfiguration.h"
#import "IOSUsePlayStatusBar.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

static id host, decoration, nativeToolbar, bezelAccessory, bezelHeight;
static id modelSubtitle;
static id modelPicker, rotateButton, expandButton, hideButton;
static CALayer *artwork, *statusArtwork;
static BOOL statusBarHidden;
static NSString *statusImageKey;
static UIImage *statusImage;
static __weak UIView *observedStatusView;
static CAShapeLayer *modelChevron, *hostShape;
static id shapedRoot, originalHostBackground;
static CALayer *originalHostMask;
static BOOL originalHostOpaque;
static NSMutableArray *observers;
static UIImage *frameImage;
static UIEdgeInsets frameInsets;
static NSString *imageKey;
static BOOL updating;
static BOOL updateScheduled;
static id get(id value, NSString *name) { return ((id (*)(id, SEL))objc_msgSend)(value, NSSelectorFromString(name)); }
static CGRect rect(id value, NSString *name) { return ((CGRect (*)(id, SEL))objc_msgSend)(value, NSSelectorFromString(name)); }
static void boolean(id value, NSString *name, BOOL flag) { ((void (*)(id, SEL, BOOL))objc_msgSend)(value, NSSelectorFromString(name), flag); }
static void object(id value, NSString *name, id argument) { ((void (*)(id, SEL, id))objc_msgSend)(value, NSSelectorFromString(name), argument); }
static void integer(id value, NSString *name, NSInteger argument) { ((void (*)(id, SEL, NSInteger))objc_msgSend)(value, NSSelectorFromString(name), argument); }
static id view(NSString *className, CGRect frame) {
    return ((id (*)(id, SEL, CGRect))objc_msgSend)([NSClassFromString(className) alloc], NSSelectorFromString(@"initWithFrame:"), frame);
}

@interface IOSUsePlayDeviceChromeController : NSObject
- (void)selectModel:(id)sender;
- (void)rotate:(id)sender;
- (void)expand:(id)sender;
- (void)toggleStatusBar:(id)sender;
- (void)statusAppearanceChanged:(id<UITraitEnvironment>)environment previousTraitCollection:(UITraitCollection *)previous;
@end
static IOSUsePlayDeviceChromeController *controller;

static NSString *resources(void) {
    NSBundle *bundle = [NSBundle bundleForClass:IOSUsePlayDeviceChromeController.class];
    return [bundle.resourcePath stringByAppendingPathComponent:@"DeviceChrome"];
}
static CGPDFDocumentRef pdf(NSString *directory, NSString *name) {
    if (!name) return NULL;
    NSURL *url = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"pdf"]]];
    return CGPDFDocumentCreateWithURL((__bridge CFURLRef)url);
}
static CGSize pdfSize(NSString *directory, NSString *name) {
    CGPDFDocumentRef document = pdf(directory, name);
    if (!document) return CGSizeZero;
    CGPDFPageRef page = CGPDFDocumentGetPage(document, 1);
    CGSize size = page ? CGPDFPageGetBoxRect(page, kCGPDFMediaBox).size : CGSizeZero;
    CGPDFDocumentRelease(document);
    return size;
}
// Coordinates here are UIKit top-left coordinates; retain PDF aspect by using
// its original tile size, stretching only the one-pixel edge tiles.
static void drawPDF(NSString *directory, NSString *name, CGRect target) {
    CGPDFDocumentRef document = pdf(directory, name);
    if (!document) return;
    CGPDFPageRef page = CGPDFDocumentGetPage(document, 1);
    if (page) {
        CGContextRef context = UIGraphicsGetCurrentContext();
        CGContextSaveGState(context);
        // DeviceKit slices can contain artwork outside their PDF media box.
        // Match NSImage's slice clipping before stretching the edge tiles.
        CGContextClipToRect(context, target);
        CGContextTranslateCTM(context, target.origin.x, CGRectGetMaxY(target));
        CGContextScaleCTM(context, 1, -1);
        CGRect source = CGPDFPageGetBoxRect(page, kCGPDFMediaBox);
        // Edge PDFs are one pixel wide/tall. Fit each axis explicitly: the PDF
        // convenience transform can leave these slices centered at native size.
        CGContextScaleCTM(context, target.size.width/source.size.width, target.size.height/source.size.height);
        CGContextTranslateCTM(context, -source.origin.x, -source.origin.y);
        CGContextDrawPDFPage(context, page);
        CGContextRestoreGState(context);
    }
    CGPDFDocumentRelease(document);
}
static UIImage *png(NSString *name) {
    return [UIImage imageWithContentsOfFile:[resources() stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"png"]]];
}

static void loadFrame(void) {
    NSString *preset = @(IOSUsePlayDeviceCurrent()->name);
    int turns = IOSUsePlayDeviceQuarterTurns();
    NSString *key = [NSString stringWithFormat:@"%@-%d", preset, turns];
    if ([imageKey isEqual:key]) return;
    imageKey = key;
    frameImage = nil;
    CGFloat w = IOSUsePlayDeviceCurrent()->logicalWidth, h = IOSUsePlayDeviceCurrent()->logicalHeight;
    BOOL outer = [preset isEqual:@"iphone-duo-outer"], inner = [preset isEqual:@"iphone-duo-inner"];
    NSDictionary *models = @{@"iphone-se":@"phone", @"iphone-13":@"phone4", @"iphone-15-pro":@"phone9", @"iphone-15-pro-max":@"phone10", @"ipad-pro-11":@"tablet2"};
    NSString *directory = models[preset] ? [resources() stringByAppendingPathComponent:models[preset]] : nil;
    NSData *data = directory ? [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"chrome.json"]] : nil;
    NSDictionary *profile = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    NSDictionary *images = profile[@"images"], *sizing = images[@"sizing"], *padding = images[@"devicePadding"];
    if (outer || inner) {
        frameInsets = outer ? UIEdgeInsetsMake(16,20,16,16) : UIEdgeInsetsMake(22,16,16,16);
    } else if (sizing) {
        frameInsets = UIEdgeInsetsMake([sizing[@"topHeight"] doubleValue]+[padding[@"top"] doubleValue],
            [sizing[@"leftWidth"] doubleValue]+[padding[@"left"] doubleValue],
            [sizing[@"bottomHeight"] doubleValue]+[padding[@"bottom"] doubleValue],
            [sizing[@"rightWidth"] doubleValue]+[padding[@"right"] doubleValue]);
    } else {
        NSLog(@"[ios-use] Missing bundled device chrome for %@", preset);
        return;
    }
    CGSize size = CGSizeMake(w + frameInsets.left + frameInsets.right, h + frameInsets.top + frameInsets.bottom);
    CGRect screen = CGRectMake(frameInsets.left, frameInsets.top, w, h);
    UIGraphicsBeginImageContextWithOptions(size, NO, 2);
    CGContextRef context = UIGraphicsGetCurrentContext();
    if (outer || inner) {
        NSString *variant = outer ? @"outer" : @"inner";
        [png([NSString stringWithFormat:@"duo-%@-Frame",variant]) drawInRect:(CGRect){CGPointZero,size}];
        CGContextSetBlendMode(context, kCGBlendModeClear);
        UIBezierPath *hole = outer
            ? [UIBezierPath bezierPathWithRoundedRect:screen byRoundingCorners:UIRectCornerTopRight|UIRectCornerBottomRight cornerRadii:CGSizeMake(64,64)]
            : [UIBezierPath bezierPathWithRoundedRect:screen cornerRadius:58];
        [hole fill];
        CGContextSetBlendMode(context, kCGBlendModeNormal);
        [png([NSString stringWithFormat:@"duo-%@-Overlay",variant]) drawInRect:(CGRect){CGPointZero,size}];
    } else {
        [[UIColor colorWithWhite:0.12 alpha:1] setFill];
        UIRectFill(screen);
        CGRect body = CGRectMake([padding[@"left"] doubleValue], [padding[@"top"] doubleValue],
            w+[sizing[@"leftWidth"] doubleValue]+[sizing[@"rightWidth"] doubleValue],
            h+[sizing[@"topHeight"] doubleValue]+[sizing[@"bottomHeight"] doubleValue]);
        if (images[@"composite"]) drawPDF(directory,images[@"composite"],body);
        else {
            CGSize tl=pdfSize(directory,images[@"topLeft"]), tr=pdfSize(directory,images[@"topRight"]);
            CGSize bl=pdfSize(directory,images[@"bottomLeft"]), br=pdfSize(directory,images[@"bottomRight"]);
            CGFloat x=body.origin.x,y=body.origin.y,bw=body.size.width,bh=body.size.height;
            drawPDF(directory,images[@"topLeft"],CGRectMake(x,y,tl.width,tl.height));
            drawPDF(directory,images[@"topRight"],CGRectMake(x+bw-tr.width,y,tr.width,tr.height));
            drawPDF(directory,images[@"bottomLeft"],CGRectMake(x,y+bh-bl.height,bl.width,bl.height));
            drawPDF(directory,images[@"bottomRight"],CGRectMake(x+bw-br.width,y+bh-br.height,br.width,br.height));
            drawPDF(directory,images[@"top"],CGRectMake(x+tl.width,y,bw-tl.width-tr.width,tl.height));
            drawPDF(directory,images[@"bottom"],CGRectMake(x+bl.width,y+bh-bl.height,bw-bl.width-br.width,bl.height));
            drawPDF(directory,images[@"left"],CGRectMake(x,y+tl.height,tl.width,bh-tl.height-bl.height));
            drawPDF(directory,images[@"right"],CGRectMake(x+bw-tr.width,y+tr.height,tr.width,bh-tr.height-br.height));
        }
        for (NSDictionary *input in profile[@"inputs"]) {
            CGSize s=pdfSize(directory,input[@"image"]);
            NSDictionary *offset=input[@"offsets"][@"normal"];
            NSString *anchor=input[@"anchor"], *align=input[@"align"];
            CGFloat x=[offset[@"x"] doubleValue],y=[offset[@"y"] doubleValue];
            if ([anchor isEqual:@"left"]) { x+=body.origin.x-s.width; y+=body.origin.y; }
            else if ([anchor isEqual:@"right"]) { x+=CGRectGetMaxX(body); y+=body.origin.y; }
            else if ([anchor isEqual:@"top"]) { x+=body.origin.x; y+=body.origin.y-s.height; }
            else if ([anchor isEqual:@"bottom"]) { x+=body.origin.x; y+=CGRectGetMaxY(body); }
            if ([align isEqual:@"center"]) {
                if ([anchor isEqual:@"left"] || [anchor isEqual:@"right"]) y+=(body.size.height-s.height)/2;
                else x+=(body.size.width-s.width)/2;
            } else if ([align isEqual:@"trailing"]) {
                if ([anchor isEqual:@"left"] || [anchor isEqual:@"right"]) y+=body.size.height-s.height;
                else x+=body.size.width-s.width;
            }
            drawPDF(directory,input[@"image"],CGRectMake(x,y,s.width,s.height));
        }
        // Simulator's framebuffer mask defines the precise screen cutout.
        CGContextSetBlendMode(context,kCGBlendModeDestinationOut);
        if (pdfSize(directory,@"FramebufferMask").width > 0) drawPDF(directory,@"FramebufferMask",screen);
        else { [[UIColor blackColor] setFill]; UIRectFillUsingBlendMode(screen,kCGBlendModeDestinationOut); }
        CGContextSetBlendMode(context,kCGBlendModeNormal);
        // DeviceKit's framebuffer mask leaves the Dynamic Island to the
        // Simulator compositor. Keep this hardware cutout with the shell so
        // hiding the decorative status items never removes it.
        if ([preset isEqual:@"iphone-15-pro"] || [preset isEqual:@"iphone-15-pro-max"]) {
            [UIColor.blackColor setFill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(screen.origin.x+(w-125)/2,
                screen.origin.y+11.333,125,36.667) cornerRadius:18.333] fill];
        }
    }
    UIImage *portrait=UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (turns) {
        CGSize target = turns % 2 ? CGSizeMake(size.height,size.width) : size;
        UIGraphicsBeginImageContextWithOptions(target,NO,2);
        CGContextRef rotated=UIGraphicsGetCurrentContext();
        CGContextTranslateCTM(rotated,target.width/2,target.height/2);
        CGContextRotateCTM(rotated,turns*M_PI_2);
        CGContextTranslateCTM(rotated,-size.width/2,-size.height/2);
        [portrait drawAtPoint:CGPointZero];
        frameImage=UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        for (int i=0;i<turns;i++)
            frameInsets=UIEdgeInsetsMake(frameInsets.left,frameInsets.bottom,frameInsets.right,frameInsets.top);
    } else frameImage=portrait;
}

static void removeAccessory(id accessory) {
    NSArray *accessories=get(host,@"titlebarAccessoryViewControllers");
    NSUInteger index=[accessories indexOfObjectIdenticalTo:accessory];
    if (index!=NSNotFound) integer(host,@"removeTitlebarAccessoryViewControllerAtIndex:",index);
}
static void restoreHostShape(void) {
    if (!shapedRoot) return;
    object(get(shapedRoot,@"layer"),@"setMask:",originalHostMask);
    object(host,@"setBackgroundColor:",originalHostBackground);
    boolean(host,@"setOpaque:",originalHostOpaque);
    shapedRoot=nil;hostShape=nil;originalHostMask=nil;originalHostBackground=nil;
}
static id toolbarView(id parent, NSUInteger depth) {
    if ([NSStringFromClass([parent class]) isEqual:@"NSToolbarView"]) return parent;
    if (!depth) return nil;
    for (id child in get(parent,@"subviews")) { id found=toolbarView(child,depth-1);if(found)return found; }
    return nil;
}
BOOL IOSUsePlayDeviceChromeClipsCanvas(void) {
    return shapedRoot != nil && IOSUsePlayDeviceIsDuo();
}
static CGPathRef duoCanvasPath(CGRect canvas) CF_RETURNS_RETAINED {
    CGFloat radii[4]={58,58,58,58}; // top-left, top-right, bottom-right, bottom-left
    if (!IOSUsePlayDeviceIsDuoInner()) { radii[0]=7;radii[1]=64;radii[2]=64;radii[3]=7; }
    for (int q=0;q<IOSUsePlayDeviceQuarterTurns();q++) {
        CGFloat last=radii[3];for(int i=3;i>0;i--)radii[i]=radii[i-1];radii[0]=last;
    }
    CGFloat w=IOSUsePlayDeviceLogicalWidth,h=IOSUsePlayDeviceLogicalHeight;
    UIBezierPath *p=[UIBezierPath bezierPath];
    [p moveToPoint:CGPointMake(radii[0],0)];
    [p addLineToPoint:CGPointMake(w-radii[1],0)];
    [p addArcWithCenter:CGPointMake(w-radii[1],radii[1]) radius:radii[1] startAngle:-M_PI_2 endAngle:0 clockwise:YES];
    [p addLineToPoint:CGPointMake(w,h-radii[2])];
    [p addArcWithCenter:CGPointMake(w-radii[2],h-radii[2]) radius:radii[2] startAngle:0 endAngle:M_PI_2 clockwise:YES];
    [p addLineToPoint:CGPointMake(radii[3],h)];
    [p addArcWithCenter:CGPointMake(radii[3],h-radii[3]) radius:radii[3] startAngle:M_PI_2 endAngle:M_PI clockwise:YES];
    [p addLineToPoint:CGPointMake(0,radii[0])];
    [p addArcWithCenter:CGPointMake(radii[0],radii[0]) radius:radii[0] startAngle:M_PI endAngle:3*M_PI_2 clockwise:YES];
    [p closePath];
    CGAffineTransform transform=CGAffineTransformMake(canvas.size.width/w,0,0,-canvas.size.height/h,canvas.origin.x,CGRectGetMaxY(canvas));
    return CGPathCreateCopyByTransformingPath(p.CGPath,&transform);
}
static void shapeHost(void) {
    id content=get(host,@"contentView"),root=get(content,@"superview");
    id bar=toolbarView(root,4);
    if (!bar) return;
    if (!shapedRoot) {
        shapedRoot=root;originalHostBackground=get(host,@"backgroundColor");
        originalHostOpaque=((BOOL (*)(id,SEL))objc_msgSend)(host,NSSelectorFromString(@"isOpaque"));
        boolean(root,@"setWantsLayer:",YES);originalHostMask=get(get(root,@"layer"),@"mask");
        hostShape=[CAShapeLayer layer];object(get(root,@"layer"),@"setMask:",hostShape);
        boolean(host,@"setOpaque:",NO);
        object(host,@"setBackgroundColor:",get(NSClassFromString(@"NSColor"),@"clearColor"));
    }
    CGRect barRect=((CGRect (*)(id,SEL,CGRect,id))objc_msgSend)(root,NSSelectorFromString(@"convertRect:fromView:"),rect(bar,@"bounds"),bar);
    // Clip desktop presentation separately from the unmasked scene used by
    // CLI capture. A rectangular backing plate leaks outside the Duo bezel.
    barRect.origin.y+=0.5;barRect.size.height-=0.5;
    CGMutablePathRef path=CGPathCreateMutable();
    if (IOSUsePlayDeviceIsDuo()) {
        CGPathRef screen=duoCanvasPath(rect(content,@"frame"));
        CGPathAddPath(path,NULL,screen);CGPathRelease(screen);
    } else CGPathAddRect(path,NULL,rect(content,@"frame"));
    CGPathAddRoundedRect(path,NULL,barRect,7,7);
    hostShape.frame=rect(root,@"bounds");hostShape.path=path;
    CGPathRelease(path);
    ((void (*)(id,SEL))objc_msgSend)(host,NSSelectorFromString(@"invalidateShadow"));
}
static void removeFrame(void) {
    BOOL wasUpdating=updating;updating=YES;
    if (decoration) {
        object(host,@"removeChildWindow:",decoration);
        ((void (*)(id,SEL))objc_msgSend)(decoration,NSSelectorFromString(@"close"));
    }
    if (bezelAccessory) removeAccessory(bezelAccessory);
    decoration=nil; bezelAccessory=nil;bezelHeight=nil; artwork=nil;statusArtwork=nil;
    updating=wasUpdating;
}
static void resetHost(void) {
    restoreHostShape();
    removeFrame();
    if (nativeToolbar) object(host,@"setToolbar:",nil);
    for (id observer in observers) [NSNotificationCenter.defaultCenter removeObserver:observer];
    observers=nil; nativeToolbar=nil; modelPicker=nil; modelSubtitle=nil; rotateButton=nil; expandButton=nil;hideButton=nil;host=nil;
}
void IOSUsePlayDeviceChromeReset(void) {
    imageKey=nil;frameImage=nil;
    // Preserve the child-window identity during model/rotation changes. A new
    // window created halfway through Mission Control isn't part of the host's
    // existing window animation and can leave its shell detached on screen.
}
static void scheduleChromeUpdate(void) {
    if (updateScheduled) return;
    updateScheduled=YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        updateScheduled=NO;
        IOSUsePlayDeviceChromeUpdate(host);
    });
}
static id symbol(NSString *name, NSString *label) {
    id image=((id (*)(id,SEL,id,id))objc_msgSend)(NSClassFromString(@"NSImage"),NSSelectorFromString(@"imageWithSystemSymbolName:accessibilityDescription:"),name,label);
    // The wide eye symbol looks oversized at the square Rotate icon's size.
    // Keep the 32pt hit target, but give visibility its own optical size.
    BOOL visibility=[name isEqual:@"eye"] || [name isEqual:@"eye.slash"];
    id configuration=((id (*)(id,SEL,CGFloat,CGFloat,NSInteger))objc_msgSend)(NSClassFromString(@"NSImageSymbolConfiguration"),NSSelectorFromString(@"configurationWithPointSize:weight:scale:"),visibility ? 14.0 : 18.0,0.0,visibility ? 1 : 2);
    return ((id (*)(id,SEL,id))objc_msgSend)(image,NSSelectorFromString(@"imageWithSymbolConfiguration:"),configuration);
}
static id button(NSString *imageName, NSString *label, SEL action) {
    id control=view(@"NSButton",CGRectMake(0,0,32,32));
    boolean(control,@"setBordered:",NO);
    object(control,@"setTitle:",@"");
    integer(control,@"setImagePosition:",1);
    object(control,@"setImage:",symbol(imageName,label));
    object(control,@"setContentTintColor:",get(NSClassFromString(@"NSColor"),@"secondaryLabelColor"));
    object(control,@"setToolTip:",label);
    object(control,@"setAccessibilityLabel:",label);
    object(control,@"setTarget:",controller);
    ((void (*)(id,SEL,SEL))objc_msgSend)(control,NSSelectorFromString(@"setAction:"),action);
    return control;
}
static void installToolbar(void) {
    controller=controller ?: [IOSUsePlayDeviceChromeController new];
    nativeToolbar=((id (*)(id,SEL,id))objc_msgSend)([NSClassFromString(@"NSToolbar") alloc],NSSelectorFromString(@"initWithIdentifier:"),@"io.ios-use.device-toolbar");
    object(nativeToolbar,@"setDelegate:",controller);
    boolean(nativeToolbar,@"setAllowsUserCustomization:",NO);
    boolean(nativeToolbar,@"setAutosavesConfiguration:",NO);
    boolean(nativeToolbar,@"setShowsBaselineSeparator:",NO);
    integer(nativeToolbar,@"setDisplayMode:",2);
    object(host,@"setToolbar:",nativeToolbar);
    integer(host,@"setToolbarStyle:",3);
    integer(host,@"setTitleVisibility:",1);
}

void IOSUsePlayDeviceChromeRefreshAppearance(void) {
    NSCParameterAssert(NSThread.isMainThread);
    if (!statusArtwork) return;
    BOOL lightContent=IOSUsePlayStatusBarUsesLightContent();
    CGFloat backingScale=((CGFloat (*)(id,SEL))objc_msgSend)(host,NSSelectorFromString(@"backingScaleFactor"));
    CGSize pixels=CGSizeMake(round(statusArtwork.bounds.size.width*backingScale),round(statusArtwork.bounds.size.height*backingScale));
    NSString *key=[NSString stringWithFormat:@"%@-%d-%d-%.0fx%.0f",@(IOSUsePlayDeviceCurrent()->name),IOSUsePlayDeviceQuarterTurns(),lightContent,pixels.width,pixels.height];
    if (![statusImageKey isEqual:key]) {
        // Rasterize decoration once at its actual desktop size, not at device
        // 3x followed by another downsample into the smaller native window.
        statusImageKey=key;statusImage=IOSUsePlayStatusBarImage(lightContent,pixels);
    }
    [CATransaction begin];[CATransaction setDisableActions:YES];
    statusArtwork.contents=(__bridge id)statusImage.CGImage;
    statusArtwork.contentsScale=backingScale;
    statusArtwork.hidden=statusBarHidden;
    [CATransaction commit];
}

void IOSUsePlayDeviceChromeUpdate(id hostWindow) {
    NSCParameterAssert(NSThread.isMainThread);
    if (updating || !hostWindow) return;
    updating=YES;
    if (host!=hostWindow) {
        resetHost();host=hostWindow;
        installToolbar();
        observers=[NSMutableArray array];
        for (NSString *name in @[@"NSWindowDidMoveNotification",@"NSWindowDidResizeNotification",@"NSWindowDidChangeBackingPropertiesNotification"]) {
            [observers addObject:[NSNotificationCenter.defaultCenter addObserverForName:name object:host queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note){scheduleChromeUpdate();}]];
        }
        [observers addObject:[NSNotificationCenter.defaultCenter addObserverForName:@"NSWindowWillCloseNotification" object:host queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note){resetHost();}]];
    }
    NSDictionary *state=IOSUsePlayDeviceState();
    if (@available(iOS 17.0, *)) {
        for (UIWindow *window in get(host,@"uiWindows")) {
            UIView *root=window.rootViewController.view;
            if (!root || window.windowLevel != UIWindowLevelNormal) continue;
            if (root != observedStatusView) {
                observedStatusView=root;
                [root registerForTraitChanges:@[UITraitUserInterfaceStyle.class] withTarget:controller
                    action:@selector(statusAppearanceChanged:previousTraitCollection:)];
            }
            break;
        }
    }
    for (id item in get(modelPicker,@"itemArray")) {
        if ([get(item,@"representedObject") isEqual:state[@"preset"]]) { object(modelPicker,@"selectItem:",item);break; }
    }
    NSString *modelTitle=get(modelPicker,@"title");
    CGFloat titleWidth=[modelTitle sizeWithAttributes:@{NSFontAttributeName:get(modelPicker,@"font")}].width;
    BOOL duo=[state[@"preset"] isEqual:@"iphone-duo"];
    NSArray *items=get(nativeToolbar,@"items");
    NSUInteger expandIndex=NSNotFound;
    for (NSUInteger i=0;i<items.count;i++) if ([get(items[i],@"itemIdentifier") isEqual:@"expand"]) expandIndex=i;
    if (duo && expandIndex==NSNotFound) ((void (*)(id,SEL,id,NSUInteger))objc_msgSend)(nativeToolbar,NSSelectorFromString(@"insertItemWithItemIdentifier:atIndex:"),@"expand",items.count);
    if (!duo && expandIndex!=NSNotFound) integer(nativeToolbar,@"removeItemAtIndex:",expandIndex);
    for (id item in get(nativeToolbar,@"items")) {
        if ([get(item,@"itemIdentifier") isEqual:@"device"])
            ((void (*)(id,SEL,CGSize))objc_msgSend)(item,NSSelectorFromString(@"setMinSize:"),CGSizeMake(MAX(95,titleWidth+22),36));
    }
    modelChevron.position=CGPointMake(titleWidth+9,8);
    NSString *expandLabel=[state[@"expanded"] boolValue] ? @"Collapse" : @"Expand";
    object(expandButton,@"setToolTip:",expandLabel);object(expandButton,@"setAccessibilityLabel:",expandLabel);
    object(expandButton,@"setImage:",symbol([state[@"expanded"] boolValue] ? @"arrow.down.right.and.arrow.up.left" : @"arrow.up.left.and.arrow.down.right",expandLabel));
    integer(hideButton,@"setState:",statusBarHidden ? 1 : 0);
    object(hideButton,@"setToolTip:",statusBarHidden ? @"Show status bar" : @"Hide status bar");
    object(hideButton,@"setAccessibilityLabel:",statusBarHidden ? @"Show status bar" : @"Hide status bar");
    object(hideButton,@"setImage:",symbol(statusBarHidden ? @"eye.slash" : @"eye",@"Hide status bar"));
    object(hideButton,@"setContentTintColor:",get(NSClassFromString(@"NSColor"),statusBarHidden ? @"controlAccentColor" : @"secondaryLabelColor"));
    NSString *detail=[NSString stringWithFormat:@"%d × %d%@",IOSUsePlayDeviceLogicalWidth,IOSUsePlayDeviceLogicalHeight,
        duo ? ([state[@"expanded"] boolValue] ? @" · Expanded" : @" · Folded") : @""];
    object(modelSubtitle,@"setStringValue:",detail);
    if ([state[@"chrome"] isEqual:@"off"] || [state[@"windowMode"] isEqual:@"resizable"]) {
        restoreHostShape();removeFrame();updating=NO;return;
    }
    loadFrame();
    if (!frameImage) { updating=NO;return; }
    id content=get(host,@"contentView");
    CGRect canvas=((CGRect (*)(id,SEL,CGRect))objc_msgSend)(host,NSSelectorFromString(@"convertRectToScreen:"),rect(content,@"bounds"));
    CGFloat scale=canvas.size.width/IOSUsePlayDeviceLogicalWidth;
    CGFloat scaleY=canvas.size.height/IOSUsePlayDeviceLogicalHeight;
    BOOL createdFrame = !decoration;
    if (!decoration) {
        Class cls=NSClassFromString(@"IOSUsePlayChromeWindow");
        if (!cls) { cls=objc_allocateClassPair(NSClassFromString(@"NSWindow"),"IOSUsePlayChromeWindow",0);objc_registerClassPair(cls); }
        decoration=((id (*)(id,SEL,CGRect,NSUInteger,NSUInteger,BOOL))objc_msgSend)([cls alloc],NSSelectorFromString(@"initWithContentRect:styleMask:backing:defer:"),CGRectMake(0,0,100,100),0,2,NO);
        boolean(decoration,@"setReleasedWhenClosed:",NO);boolean(decoration,@"setOpaque:",NO);
        boolean(decoration,@"setHasShadow:",NO);boolean(decoration,@"setIgnoresMouseEvents:",YES);
        object(decoration,@"setBackgroundColor:",get(NSClassFromString(@"NSColor"),@"clearColor"));
        id decorationContent=get(decoration,@"contentView");boolean(decorationContent,@"setWantsLayer:",YES);
        artwork=[CALayer layer];object(get(decorationContent,@"layer"),@"addSublayer:",artwork);
        statusArtwork=[CALayer layer];object(get(decorationContent,@"layer"),@"addSublayer:",statusArtwork);
        ((void (*)(id,SEL,id,NSInteger))objc_msgSend)(host,NSSelectorFromString(@"addChildWindow:ordered:"),decoration,1);
        bezelAccessory=[NSClassFromString(@"NSTitlebarAccessoryViewController") new];
        CGFloat clearance=ceil(frameInsets.top*scaleY)+12;
        id spacer=view(@"NSView",CGRectMake(0,0,1,clearance));
        object(bezelAccessory,@"setView:",spacer);
        integer(bezelAccessory,@"setLayoutAttribute:",4);object(host,@"addTitlebarAccessoryViewController:",bezelAccessory);
        // AppKit re-enables autoresizing when attaching the accessory. Enable
        // its height constraint afterwards so tall bezels cannot cover the bar.
        boolean(spacer,@"setTranslatesAutoresizingMaskIntoConstraints:",NO);
        bezelHeight=((id (*)(id,SEL,CGFloat))objc_msgSend)(get(spacer,@"heightAnchor"),NSSelectorFromString(@"constraintEqualToConstant:"),clearance);
        boolean(bezelHeight,@"setActive:",YES);
    }
    ((void (*)(id,SEL,CGFloat))objc_msgSend)(bezelHeight,NSSelectorFromString(@"setConstant:"),ceil(frameInsets.top*scaleY)+12);
    ((void (*)(id,SEL))objc_msgSend)(get(content,@"superview"),NSSelectorFromString(@"layoutSubtreeIfNeeded"));
    canvas=((CGRect (*)(id,SEL,CGRect))objc_msgSend)(host,NSSelectorFromString(@"convertRectToScreen:"),rect(content,@"bounds"));
    scale=canvas.size.width/IOSUsePlayDeviceLogicalWidth;
    scaleY=canvas.size.height/IOSUsePlayDeviceLogicalHeight;
    CGRect frame=CGRectMake(canvas.origin.x-frameInsets.left*scale,canvas.origin.y-frameInsets.bottom*scaleY,
        canvas.size.width+(frameInsets.left+frameInsets.right)*scale,canvas.size.height+(frameInsets.top+frameInsets.bottom)*scaleY);
    ((void (*)(id,SEL,CGRect,BOOL))objc_msgSend)(decoration,NSSelectorFromString(@"setFrame:display:"),frame,YES);
    [CATransaction begin];[CATransaction setDisableActions:YES];
    CGRect actualFrame=rect(decoration,@"frame");
    artwork.frame=CGRectMake(frame.origin.x-actualFrame.origin.x,frame.origin.y-actualFrame.origin.y,frame.size.width,frame.size.height);
    artwork.contents=(__bridge id)frameImage.CGImage;
    IOSUsePlayDeviceRect status=IOSUsePlayDeviceStatusBarRect();
    CGRect statusFrame=CGRectMake(artwork.frame.origin.x+(frameInsets.left+status.x)*scale,
        artwork.frame.origin.y+(frameInsets.bottom+IOSUsePlayDeviceLogicalHeight-status.y-status.height)*scaleY,
        status.width*scale,status.height*scaleY);
    CGFloat backing=((CGFloat (*)(id,SEL))objc_msgSend)(host,NSSelectorFromString(@"backingScaleFactor"));
    statusArtwork.frame=CGRectMake(round(statusFrame.origin.x*backing)/backing,round(statusFrame.origin.y*backing)/backing,
        round(statusFrame.size.width*backing)/backing,round(statusFrame.size.height*backing)/backing);
    IOSUsePlayDeviceChromeRefreshAppearance();
    shapeHost();
    [CATransaction commit];
    if (createdFrame && ((BOOL (*)(id,SEL))objc_msgSend)(host,NSSelectorFromString(@"isVisible")) && !((BOOL (*)(id,SEL))objc_msgSend)(host,NSSelectorFromString(@"isMiniaturized"))) object(decoration,@"orderFront:",nil);
    updating=NO;
    if (createdFrame) scheduleChromeUpdate();
}

@implementation IOSUsePlayDeviceChromeController
- (NSArray *)toolbarDefaultItemIdentifiers:(__unused id)toolbar {
    return @[@"device",@"NSToolbarFlexibleSpaceItem",@"rotate",@"hide"];
}
- (NSArray *)toolbarAllowedItemIdentifiers:(__unused id)toolbar {
    return @[@"device",@"NSToolbarFlexibleSpaceItem",@"rotate",@"hide",@"expand"];
}
- (id)toolbar:(__unused id)toolbar itemForItemIdentifier:(NSString *)identifier willBeInsertedIntoToolbar:(__unused BOOL)inserted {
    id item=((id (*)(id,SEL,id))objc_msgSend)([NSClassFromString(@"NSToolbarItem") alloc],NSSelectorFromString(@"initWithItemIdentifier:"),identifier);
    id content;
    if ([identifier isEqual:@"device"]) {
        content=view(@"NSView",CGRectMake(0,0,168,36));
        modelPicker=((id (*)(id,SEL,CGRect,BOOL))objc_msgSend)([NSClassFromString(@"NSPopUpButton") alloc],NSSelectorFromString(@"initWithFrame:pullsDown:"),CGRectMake(-3,15,165,21),NO);
        NSArray *names=@[@"iPhone SE",@"iPhone 13",@"iPhone 15 Pro",@"iPhone 15 Pro Max",@"iPad Pro 11",@"iPhone Duo"];
        NSArray *models=@[@"iphone-se",@"iphone-13",@"iphone-15-pro",@"iphone-15-pro-max",@"ipad-pro-11",@"iphone-duo"];
        for (NSUInteger i=0;i<names.count;i++) {
            object(modelPicker,@"addItemWithTitle:",names[i]);
            object(get(modelPicker,@"lastItem"),@"setRepresentedObject:",models[i]);
        }
        boolean(modelPicker,@"setBordered:",NO);
        integer(get(modelPicker,@"cell"),@"setArrowPosition:",0);
        integer(get(modelPicker,@"cell"),@"setLineBreakMode:",4);
        integer(modelPicker,@"setFocusRingType:",1);
        integer(modelPicker,@"setAutoresizingMask:",2);
        id font=((id (*)(id,SEL,CGFloat))objc_msgSend)(NSClassFromString(@"NSFont"),NSSelectorFromString(@"boldSystemFontOfSize:"),13.0);
        object(modelPicker,@"setFont:",font);
        integer(modelPicker,@"setAlignment:",0);
        boolean(modelPicker,@"setWantsLayer:",YES);
        modelChevron=[CAShapeLayer layer];modelChevron.fillColor=UIColor.clearColor.CGColor;
        modelChevron.strokeColor=[UIColor colorWithWhite:0.75 alpha:1].CGColor;modelChevron.lineWidth=1.2;
        CGMutablePathRef chevron=CGPathCreateMutable();CGPathMoveToPoint(chevron,NULL,0,0);
        CGPathAddLineToPoint(chevron,NULL,3.5,4);CGPathAddLineToPoint(chevron,NULL,7,0);
        modelChevron.path=chevron;CGPathRelease(chevron);
        object(get(modelPicker,@"layer"),@"addSublayer:",modelChevron);
        object(modelPicker,@"setAccessibilityLabel:",@"Device model");
        object(modelPicker,@"setToolTip:",@"Change device model");
        object(modelPicker,@"setTarget:",self);
        ((void (*)(id,SEL,SEL))objc_msgSend)(modelPicker,NSSelectorFromString(@"setAction:"),@selector(selectModel:));
        object(content,@"addSubview:",modelPicker);
        modelSubtitle=((id (*)(id,SEL,id))objc_msgSend)(NSClassFromString(@"NSTextField"),NSSelectorFromString(@"labelWithString:"),@"");
        ((void (*)(id,SEL,CGRect))objc_msgSend)(modelSubtitle,NSSelectorFromString(@"setFrame:"),CGRectMake(0,0,166,15));
        id smallFont=((id (*)(id,SEL,CGFloat))objc_msgSend)(NSClassFromString(@"NSFont"),NSSelectorFromString(@"systemFontOfSize:"),10.0);
        object(modelSubtitle,@"setFont:",smallFont);
        object(modelSubtitle,@"setTextColor:",get(NSClassFromString(@"NSColor"),@"secondaryLabelColor"));
        integer(modelSubtitle,@"setAutoresizingMask:",2);
        integer(get(modelSubtitle,@"cell"),@"setLineBreakMode:",4);
        object(content,@"addSubview:",modelSubtitle);
        object(item,@"setLabel:",@"Device");
        ((void (*)(id,SEL,CGSize))objc_msgSend)(item,NSSelectorFromString(@"setMinSize:"),CGSizeMake(95,36));
        ((void (*)(id,SEL,CGSize))objc_msgSend)(item,NSSelectorFromString(@"setMaxSize:"),CGSizeMake(168,36));
    } else if ([identifier isEqual:@"rotate"]) {
        rotateButton=button(@"rotate.right",@"Rotate",@selector(rotate:));content=rotateButton;
        object(item,@"setLabel:",@"Rotate");
    } else if ([identifier isEqual:@"hide"]) {
        hideButton=button(@"eye",@"Hide status bar",@selector(toggleStatusBar:));content=hideButton;
        integer(hideButton,@"setButtonType:",1);
        object(item,@"setLabel:",@"Hide");
    } else if ([identifier isEqual:@"expand"]) {
        expandButton=button(@"arrow.up.left.and.arrow.down.right",@"Expand",@selector(expand:));content=expandButton;
        object(item,@"setLabel:",@"Expand / Collapse");
    } else return nil;
    object(item,@"setView:",content);
    return item;
}
- (void)apply:(NSDictionary *)changes {
    NSError *error=nil;
    if (!IOSUsePlayConfigureDevice(changes,&error)) NSLog(@"[ios-use] Device configuration failed: %@",error.localizedDescription);
}
- (void)selectModel:(id)sender { [self apply:@{@"preset":get(get(sender,@"selectedItem"),@"representedObject")}]; }
- (void)rotate:(__unused id)sender { [self apply:@{@"physicalOrientation":@(IOSUsePlayDevicePhysicalName((IOSUsePlayDevicePhysicalQuarterTurns()+1)%4))}]; }
- (void)expand:(__unused id)sender { [self apply:@{@"expanded":([IOSUsePlayDeviceState()[@"expanded"] boolValue] ? @NO : @YES)}]; }
- (void)toggleStatusBar:(__unused id)sender { statusBarHidden=!statusBarHidden;IOSUsePlayDeviceChromeUpdate(host); }
- (void)statusAppearanceChanged:(__unused id<UITraitEnvironment>)environment previousTraitCollection:(__unused UITraitCollection *)previous {
    dispatch_async(dispatch_get_main_queue(), ^{ IOSUsePlayDeviceChromeRefreshAppearance(); });
}
@end
