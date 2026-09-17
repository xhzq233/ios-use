#import "IOSUsePlayCanvasCapture.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

@interface CALayer (IOSUseCanvasHosting)
@property(nonatomic) uint32_t contextId;
@property(nonatomic) BOOL preservesFlip;
@property(nonatomic) BOOL inheritsSecurity;
@end

static id get(id object, NSString *selector) {
    return ((id (*)(id,SEL))objc_msgSend)(object,NSSelectorFromString(selector));
}
static CGRect rect(id object, NSString *selector) {
    return ((CGRect (*)(id,SEL))objc_msgSend)(object,NSSelectorFromString(selector));
}
static void setBool(id object, NSString *selector, BOOL value) {
    ((void (*)(id,SEL,BOOL))objc_msgSend)(object,NSSelectorFromString(selector),value);
}
static void setObject(id object, NSString *selector, id value) {
    ((void (*)(id,SEL,id))objc_msgSend)(object,NSSelectorFromString(selector),value);
}

static CALayer *mirrorLayer(CALayer *source, NSUInteger *contexts) {
    BOOL hosting=[source isKindOfClass:NSClassFromString(@"CALayerHost")];
    CALayer *copy=hosting ? [NSClassFromString(@"CALayerHost") layer] : [CALayer layer];
    copy.bounds=source.bounds;copy.position=source.position;
    copy.anchorPoint=source.anchorPoint;copy.transform=source.transform;
    copy.sublayerTransform=source.sublayerTransform;
    copy.geometryFlipped=source.geometryFlipped;
    copy.contentsScale=source.contentsScale;copy.contents=source.contents;
    copy.contentsGravity=source.contentsGravity;copy.contentsRect=source.contentsRect;
    copy.opacity=source.opacity;copy.hidden=source.hidden;
    copy.masksToBounds=source.masksToBounds;
    if (hosting) {
        copy.contextId=source.contextId;
        // UIKit's hosted tree needs this flag as well as geometryFlipped;
        // omitting it reverses layout and clips individual text layers.
        copy.preservesFlip=source.preservesFlip;
        copy.inheritsSecurity=source.inheritsSecurity;
        if (source.contextId) *contexts+=1;
    }
    for (CALayer *child in source.sublayers) [copy addSublayer:mirrorLayer(child,contexts)];
    return copy;
}

id IOSUsePlayCreateCanvasCaptureWindow(id sourceWindow) {
    NSCParameterAssert(NSThread.isMainThread);
    id sourceContent=get(sourceWindow,@"contentView");
    CALayer *sourceLayer=get(sourceContent,@"layer");
    if (!sourceLayer) return nil;
    NSUInteger contexts=0;
    CALayer *canvas=mirrorLayer(sourceLayer,&contexts);
    if (!contexts) return nil;
    Class cls=NSClassFromString(@"IOSUsePlayCanvasCaptureWindow");
    if (!cls) {
        cls=objc_allocateClassPair(NSClassFromString(@"NSWindow"),"IOSUsePlayCanvasCaptureWindow",0);
        objc_registerClassPair(cls);
    }
    // Keep the original native window size, including the unused titlebar
    // area, so the existing canvas crop and scale calculations stay valid.
    CGRect frame=rect(sourceWindow,@"frame");
    id screen=get(sourceWindow,@"screen");
    if (screen) frame.origin=rect(screen,@"frame").origin;
    id window=((id (*)(id,SEL,CGRect,NSUInteger,NSUInteger,BOOL))objc_msgSend)([cls alloc],
        NSSelectorFromString(@"initWithContentRect:styleMask:backing:defer:"),frame,0,2,NO);
    setBool(window,@"setReleasedWhenClosed:",NO);
    setBool(window,@"setHasShadow:",NO);setBool(window,@"setOpaque:",NO);
    setBool(window,@"setIgnoresMouseEvents:",YES);
    setObject(window,@"setBackgroundColor:",get(NSClassFromString(@"NSColor"),@"clearColor"));
    // An on-screen backing store is required for first capture. Keep the
    // window below the desktop, absent from Mission Control and window cycling.
    ((void (*)(id,SEL,NSInteger))objc_msgSend)(window,NSSelectorFromString(@"setLevel:"),
        CGWindowLevelForKey(kCGDesktopWindowLevelKey)-1);
    ((void (*)(id,SEL,NSUInteger))objc_msgSend)(window,NSSelectorFromString(@"setCollectionBehavior:"),(1U<<3)|(1U<<6));
    id content=get(window,@"contentView");setBool(content,@"setWantsLayer:",YES);
    // The source subtree starts below the native root's rounded display mask.
    // It references the SAME CA context, including Web/Metal surfaces; there
    // is no drawViewHierarchy, screenshot polling, or second App render here.
    [get(content,@"layer") addSublayer:canvas];
    setObject(window,@"orderBack:",nil);
    [CATransaction flush];
    return window;
}
