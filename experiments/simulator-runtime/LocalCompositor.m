// An in-process CoreAnimation server and virtual display, using runtime Metal.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurfaceRef.h>
#import <objc/runtime.h>
#import <mach/mach.h>

extern bool CARenderServerStart(void);
extern mach_port_t CARenderServerGetPort(void);
extern bool CARenderServerSnapshot(mach_port_t, NSDictionary *);
extern NSString *const kCAContextPortNumber, *const kCAContextDisplayId, *const kCAContextDisplayName;
extern NSString *const kCAContextDisplayable;
extern NSString *const kCASnapshotMode, *const kCASnapshotDisplayName;
extern NSString *const kCASnapshotModeDisplay;
extern NSString *const kCASnapshotDestination;
extern NSString *const kCASnapshotOriginX, *const kCASnapshotOriginY, *const kCASnapshotTransform, *const kCASnapshotTimeOffset;

@interface NSObject (LocalCompositorAPI)
+ (void)updateDisplays;
+ (id)serverWithOptions:(NSDictionary *)options;
- (id)initWithOptions:(NSDictionary *)options;
- (void)addDisplay:(id)display;
- (uint32_t)displayId;
- (uint32_t)contextId;
- (id)context;
- (CALayer *)layer;
- (void)setLayer:(CALayer *)layer;
- (void)setContextId:(uint32_t)identifier;
- (BOOL)waitForRenderingWithTimeout:(double)timeout;
- (void)setEnabled:(BOOL)enabled;
- (void)setBlanked:(BOOL)blanked;
@end

static mach_port_t renderPort;
static id virtualDisplay;
static id presentationContext;
static CALayer *canvas;
static dispatch_queue_t renderQueue;
static id (*originalContext)(id, SEL, NSDictionary *);
extern void IOSUseStreamContext(id context);
id IOSUseVirtualDisplay(void) { return virtualDisplay; }
dispatch_queue_t IOSUseRenderQueue(void) { return renderQueue; }

static id createContext(id cls, SEL selector, NSDictionary *options) {
    NSMutableDictionary *local = [options mutableCopy] ?: [NSMutableDictionary new];
    local[kCAContextPortNumber] = @(renderPort);
    local[kCAContextDisplayable] = @NO;
    // UIKit produces non-displayable contexts normally embedded by its scene
    // host. A displayable parent supplies that hosting function locally, and
    // keeps CAContentStream's filter stable as the app creates more windows.
    BOOL first = presentationContext == nil;
    if (first) {
        presentationContext = originalContext(cls, selector, @{
            kCAContextPortNumber: @(renderPort), kCAContextDisplayId: @([virtualDisplay displayId]),
            kCAContextDisplayName: @"LCD", kCAContextDisplayable: @YES});
        canvas = [CALayer layer];
        canvas.frame = CGRectMake(0, 0, 1206, 2622);
        canvas.backgroundColor = UIColor.blackColor.CGColor;
        [presentationContext setLayer:canvas];
    }
    id context = originalContext(cls, selector, local);
    CALayer *host = [NSClassFromString(@"CALayerHost") new];
    [(NSObject *)host setContextId:[context contextId]];
    host.anchorPoint = CGPointZero;
    host.position = CGPointZero;
    host.bounds = CGRectMake(0, 0, 402, 874);
    host.transform = CATransform3DMakeScale(3, 3, 1);
    [canvas addSublayer:host];
    NSLog(@"[local-compositor] context=%u", [context contextId]);
    if (first) IOSUseStreamContext(presentationContext);
    return context;
}

__attribute__((constructor)) static void initializeCompositor(void) {
    renderPort = CARenderServerGetPort();
    if (!renderPort || !CARenderServerStart()) exit(39);
    // local=YES skips display discovery and launchd render-server registration.
    id server = [NSClassFromString(@"CAWindowServer") serverWithOptions:@{@"local": @YES}];
    virtualDisplay = [(NSObject *)[NSClassFromString(@"CAWindowServerVirtualDisplay") alloc] initWithOptions:@{
        @"kCAVirtualDisplayWidth": @1206, @"kCAVirtualDisplayHeight": @2622,
        @"kCAVirtualDisplayUpdateRate": @30, @"kCAVirtualDisplayName": @"LCD"}];
    if (!server || !virtualDisplay) exit(39);
    [server addDisplay:virtualDisplay];
    [virtualDisplay setEnabled:YES];
    [virtualDisplay setBlanked:NO];
    // CoreAnimation recognizes the LCD name as its main display. Invalidate
    // discovery cached before the local server existed so MTKView gets a real
    // CADisplay-backed refresh link through UIScreen.
    [NSClassFromString(@"CADisplay") updateDisplays];
    // VirtualServer owns the refresh loop; a second renderForTime timer races it.
    // The hosting layer maps UIKit points to the display's 3x device pixels.
    renderQueue = dispatch_queue_create("iosuse.runtime.render", DISPATCH_QUEUE_SERIAL);
    NSLog(@"[local-compositor] virtual display=%@", virtualDisplay);
    Method method = class_getClassMethod(NSClassFromString(@"CAContext"), @selector(remoteContextWithOptions:));
    originalContext = (void *)method_setImplementation(method, (IMP)createContext);
}

// One-shot diagnostic, not a presentation loop. The caller owns the surface.
static void displayLayers(CALayer *layer) {
    [layer layoutIfNeeded];
    [layer displayIfNeeded];
    for (CALayer *child in layer.sublayers) displayLayers(child);
}

// Observe the server's already-published layers without flushing the client tree.
IOSurfaceRef IOSUseCopyPresentedWindowSurface(UIWindow *window) {
    size_t width = window.bounds.size.width, height = window.bounds.size.height;
    if (!width || !height) return NULL;
    IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)@{
        (id)kIOSurfaceWidth: @(width), (id)kIOSurfaceHeight: @(height),
        (id)kIOSurfaceBytesPerRow: @((width * 4 + 63) & ~63),
        (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA')});
    if (!surface) return NULL;
    uint32_t context = [[window.layer context] contextId];
    NSDictionary *options = @{
        kCASnapshotMode: kCASnapshotModeDisplay, kCASnapshotDisplayName: @"LCD",
        kCASnapshotDestination: (__bridge id)surface, kCASnapshotOriginX: @0, kCASnapshotOriginY: @0,
        kCASnapshotTransform: [NSValue valueWithCATransform3D:CATransform3DMakeScale(1.0/3, 1.0/3, 1)], kCASnapshotTimeOffset: @0};
    __block BOOL rendered;
    dispatch_sync(renderQueue, ^{ rendered = CARenderServerSnapshot(renderPort, options); });
    fprintf(stderr, "[local-compositor] rendered=%d context=%u surface=%u\n", rendered, context, IOSurfaceGetID(surface));
    if (!rendered) { CFRelease(surface); return NULL; }
    return surface;
}

IOSurfaceRef IOSUseCopyWindowSurface(UIWindow *window) {
    for (UIWindow *candidate in UIApplication.sharedApplication.windows) {
        if (candidate.hidden) continue;
        [candidate layoutIfNeeded];
        displayLayers([[candidate.layer context] layer]);
    }
    [CATransaction flush];
    // Flush sends asynchronously. A bounded wait lets the server consume the
    // first submission; headless display acknowledgement can still time out.
    // The callers validate the snapshot pixels independently of this result.
    BOOL acknowledged = [presentationContext waitForRenderingWithTimeout:1];
    fprintf(stderr, "[local-compositor] display acknowledgement=%d\n", acknowledged);
    return IOSUseCopyPresentedWindowSurface(window);
}
