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
- (void)removeDisplay:(id)display;
- (uint32_t)displayId;
- (uint32_t)contextId;
- (id)context;
- (CALayer *)layer;
- (void)setLayer:(CALayer *)layer;
- (void)setContextId:(uint32_t)identifier;
- (BOOL)waitForRenderingWithTimeout:(double)timeout;
- (void)setEnabled:(BOOL)enabled;
- (void)setBlanked:(BOOL)blanked;
- (NSString *)identifier;
- (id)CAContext;
- (double)level;
- (void)invalidate;
@end

static mach_port_t renderPort;
static id virtualDisplay, renderServer;
static unsigned displaySequence;
static dispatch_queue_t renderQueue;
static id (*originalContext)(id, SEL, NSDictionary *);
static void (*originalInvalidate)(id, SEL);
static void (*originalAttach)(id, SEL, id), (*originalDetach)(id, SEL, id);
static char hostingLayerKey;
@interface RuntimeSceneCanvas : NSObject
@property(nonatomic, strong) id context;
@property(nonatomic, strong) id display;
@property(nonatomic, copy) NSString *displayName;
@property(nonatomic, strong) CALayer *canvas;
@end
@implementation RuntimeSceneCanvas
@end
static NSMutableDictionary<NSString *, RuntimeSceneCanvas *> *scenes;
extern void IOSUseStreamContext(id context, NSString *sceneIdentifier, id display);
extern void IOSUseStopSceneStream(id context, id display);
void IOSUseReleaseSceneDisplay(id display) {
    if (display == virtualDisplay) return; // Keep UIKit's main refresh source alive.
    [display setEnabled:NO];
    [renderServer removeDisplay:display];
}
dispatch_queue_t IOSUseRenderQueue(void) { return renderQueue; }
NSUInteger IOSUseHostedContextCount(void) {
    NSUInteger count = 0;
    for (RuntimeSceneCanvas *scene in scenes.allValues) count += scene.canvas.sublayers.count;
    return count;
}

static void removeHostingLayer(id context) {
    [objc_getAssociatedObject(context, &hostingLayerKey) removeFromSuperlayer];
    objc_setAssociatedObject(context, &hostingLayerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void invalidateContext(id context, SEL selector) {
    removeHostingLayer(context);
    originalInvalidate(context, selector);
}
static id createContext(id cls, SEL selector, NSDictionary *options) {
    NSMutableDictionary *local = [options mutableCopy] ?: [NSMutableDictionary new];
    local[kCAContextPortNumber] = @(renderPort);
    local[kCAContextDisplayable] = @NO;
    // Context creation alone does not establish Scene ownership. UIKit attaches
    // window, transition and keyboard contexts through FBSScene layers below.
    return originalContext(cls, selector, local);
}

static void attachLayer(id fbsScene, SEL selector, id sceneLayer) {
    originalAttach(fbsScene, selector, sceneLayer);
    id context = [sceneLayer CAContext];
    if (!context) return;
    NSString *identifier = [fbsScene identifier];
    RuntimeSceneCanvas *scene = scenes[identifier];
    BOOL first = scene == nil;
    if (first) {
        scene = [RuntimeSceneCanvas new];
        scene.displayName = displaySequence++ == 0 ? @"LCD" : [NSString stringWithFormat:@"IOSUseScene-%u", displaySequence];
        scene.display = [scene.displayName isEqualToString:@"LCD"] ? virtualDisplay :
            [(NSObject *)[NSClassFromString(@"CAWindowServerVirtualDisplay") alloc] initWithOptions:@{
                @"kCAVirtualDisplayWidth": @1206, @"kCAVirtualDisplayHeight": @2622,
                @"kCAVirtualDisplayUpdateRate": @30, @"kCAVirtualDisplayName": scene.displayName}];
        if (scene.display != virtualDisplay) {
            [renderServer addDisplay:scene.display];
            [scene.display setEnabled:YES];
            [scene.display setBlanked:NO];
        }
        scene.context = originalContext(NSClassFromString(@"CAContext"), @selector(remoteContextWithOptions:), @{
            kCAContextPortNumber: @(renderPort), kCAContextDisplayId: @([scene.display displayId]),
            kCAContextDisplayName: scene.displayName, kCAContextDisplayable: @YES});
        scene.canvas = [CALayer layer];
        scene.canvas.frame = CGRectMake(0, 0, 1206, 2622);
        scene.canvas.backgroundColor = UIColor.blackColor.CGColor;
        [scene.context setLayer:scene.canvas];
        scenes[identifier] = scene;
    }
    removeHostingLayer(context);
    CALayer *host = [NSClassFromString(@"CALayerHost") new];
    [(NSObject *)host setContextId:[context contextId]];
    host.anchorPoint = CGPointZero;
    host.position = CGPointZero;
    host.bounds = CGRectMake(0, 0, 402, 874);
    host.transform = CATransform3DMakeScale(3, 3, 1);
    host.zPosition = [(NSObject *)sceneLayer level];
    [scene.canvas addSublayer:host];
    objc_setAssociatedObject(context, &hostingLayerKey, host, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    fprintf(stderr, "[local-compositor] scene=%u context=%u attached\n", [scene.context contextId], [context contextId]);
    if (first) IOSUseStreamContext(scene.context, identifier, scene.display);
}
static void detachLayer(id fbsScene, SEL selector, id sceneLayer) {
    removeHostingLayer([sceneLayer CAContext]);
    originalDetach(fbsScene, selector, sceneLayer);
}
void IOSUseRetireScene(NSString *identifier) {
    RuntimeSceneCanvas *scene = scenes[identifier];
    if (!scene) return;
    IOSUseStopSceneStream(scene.context, scene.display);
    [scenes removeObjectForKey:identifier];
}

__attribute__((constructor)) static void initializeCompositor(void) {
    scenes = [NSMutableDictionary new];
    renderPort = CARenderServerGetPort();
    if (!renderPort || !CARenderServerStart()) exit(39);
    // local=YES skips display discovery and launchd render-server registration.
    renderServer = [NSClassFromString(@"CAWindowServer") serverWithOptions:@{@"local": @YES}];
    virtualDisplay = [(NSObject *)[NSClassFromString(@"CAWindowServerVirtualDisplay") alloc] initWithOptions:@{
        @"kCAVirtualDisplayWidth": @1206, @"kCAVirtualDisplayHeight": @2622,
        @"kCAVirtualDisplayUpdateRate": @30, @"kCAVirtualDisplayName": @"LCD"}];
    if (!renderServer || !virtualDisplay) exit(39);
    [renderServer addDisplay:virtualDisplay];
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
    Method invalidate = class_getInstanceMethod(NSClassFromString(@"CAContext"), @selector(invalidate));
    originalInvalidate = (void *)method_setImplementation(invalidate, (IMP)invalidateContext);
    Class sceneClass = NSClassFromString(@"FBSScene");
    originalAttach = (void *)method_setImplementation(class_getInstanceMethod(sceneClass, @selector(attachLayer:)), (IMP)attachLayer);
    originalDetach = (void *)method_setImplementation(class_getInstanceMethod(sceneClass, @selector(detachLayer:)), (IMP)detachLayer);
}

// One-shot diagnostic, not a presentation loop. The caller owns the surface.
static void displayLayers(CALayer *layer) {
    [layer layoutIfNeeded];
    [layer displayIfNeeded];
    for (CALayer *child in layer.sublayers) displayLayers(child);
}

// Observe the server's already-published layers without flushing the client tree.
IOSurfaceRef IOSUseCopyPresentedWindowSurface(UIWindow *window) {
    // This display-wide diagnostic is deliberately limited to one Scene.
    // Multi-Scene E2E observes each independently filtered native window.
    if (scenes.count != 1) return NULL;
    size_t width = window.bounds.size.width, height = window.bounds.size.height;
    if (!width || !height) return NULL;
    IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)@{
        (id)kIOSurfaceWidth: @(width), (id)kIOSurfaceHeight: @(height),
        (id)kIOSurfaceBytesPerRow: @((width * 4 + 63) & ~63),
        (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA')});
    if (!surface) return NULL;
    uint32_t context = [[window.layer context] contextId];
    NSDictionary *options = @{
        kCASnapshotMode: kCASnapshotModeDisplay, kCASnapshotDisplayName: scenes.allValues.firstObject.displayName,
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
    BOOL acknowledged = [scenes.allValues.firstObject.context waitForRenderingWithTimeout:1];
    fprintf(stderr, "[local-compositor] display acknowledgement=%d\n", acknowledged);
    return IOSUseCopyPresentedWindowSurface(window);
}
