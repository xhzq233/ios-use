// Runtime CA -> shared IOSurface -> one native window per FrontBoard Scene.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurfaceRef.h>
#import <dlfcn.h>
#import "WindowMessage.h"

extern void IOSUseReleaseSceneDisplay(id display);
extern dispatch_queue_t IOSUseRenderQueue(void);
@interface NSObject (RuntimeStreamAPI)
- (uint32_t)displayId;
- (uint32_t)contextId;
- (CALayer *)layer;
- (BOOL)waitForRenderingWithTimeout:(double)timeout;
+ (id)contentStreamWithOptions:(id)options queue:(dispatch_queue_t)queue
                      handler:(void (^)(id, id))handler error:(NSError **)error;
- (BOOL)setIncludedContexts:(NSArray *)contexts error:(NSError **)error;
- (BOOL)start:(NSError **)error;
- (BOOL)stop:(NSError **)error;
- (void)invalidate;
- (IOSurfaceRef)surface;
- (BOOL)releaseSurface:(IOSurfaceRef)surface error:(NSError **)error;
@end

@interface RuntimeSceneStream : NSObject
@property(nonatomic, strong) id stream;
@property(nonatomic, strong) id display;
@property(nonatomic, strong) NSMutableDictionary *pending;
@property(nonatomic, strong) dispatch_source_t receiver;
@property(nonatomic) uint32_t token;
@property(nonatomic) BOOL closing;
@property(nonatomic) unsigned frames;
@end
@implementation RuntimeSceneStream
@end
static dispatch_queue_t streamQueue;
static NSMutableDictionary<NSNumber *, RuntimeSceneStream *> *streams;
static mach_port_t brokerPort;

static void finishClosing(RuntimeSceneStream *scene) {
    if (!scene.closing || scene.pending.count) return;
    NSError *error = nil;
    if (scene.stream && ![scene.stream stop:&error]) NSLog(@"[stream] stop failed: %@", error);
    scene.stream = nil;
    IOSUseReleaseSceneDisplay(scene.display);
    scene.display = nil;
    dispatch_source_cancel(scene.receiver);
    scene.receiver = nil;
    [streams removeObjectForKey:@(scene.token)];
    fprintf(stderr, "[stream] scene=%u retired after all frame returns\n", scene.token);
}
static void releaseFrame(RuntimeSceneStream *scene, uint32_t identifier) {
    id frame = scene.pending[@(identifier)];
    if (!frame) return;
    NSError *error = nil;
    if (![scene.stream releaseSurface:[frame surface] error:&error]) NSLog(@"[stream] release failed: %@", error);
    [scene.pending removeObjectForKey:@(identifier)];
    finishClosing(scene);
}

void IOSUseStopSceneStream(id context, id display) {
    // Match startup's main -> render queue ordering, including a close requested
    // in the same run-loop turn as the first context attach.
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_async(IOSUseRenderQueue(), ^{
            uint32_t sceneID = [context contextId];
            RuntimeSceneStream *scene = streams[@(sceneID)];
            if (!scene) { [context invalidate]; IOSUseReleaseSceneDisplay(display); return; }
            if (scene.closing) return;
            scene.closing = YES;
            [context invalidate];
            IOSUseWindowSceneClosedMessage message = {0};
            message.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
            message.header.msgh_size = sizeof(message);
            message.header.msgh_remote_port = brokerPort;
            message.header.msgh_id = IOSUseWindowSceneClosed;
            message.sceneID = sceneID;
            mach_msg(&message.header, MACH_SEND_MSG, sizeof(message), 0, 0, 0, 0);
            // The host can still own surfaces from this stream. Retire the stream
            // only after AppKit returns those frames, including transactions in flight.
            finishClosing(scene);
        });
    });
}

void IOSUseStreamContext(id context, NSString *sceneIdentifier, id display) {
    if (!getenv("IOS_USE_RUNTIME_PRESENT") || !context) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        streamQueue = IOSUseRenderQueue();
        streams = [NSMutableDictionary new];
        mach_port_array_t ports = NULL;
        mach_msg_type_number_t count = 0;
        if (mach_ports_lookup(mach_task_self(), &ports, &count) || !count) exit(46);
        brokerPort = ports[0];
        for (unsigned i = 1; i < count; i++) if (ports[i]) mach_port_deallocate(mach_task_self(), ports[i]);
        vm_deallocate(mach_task_self(), (vm_address_t)ports, count * sizeof(mach_port_t));
    });
    dispatch_async(dispatch_get_main_queue(), ^{
        [CATransaction flush];
        dispatch_async(streamQueue, ^{
            RuntimeSceneStream *scene = [RuntimeSceneStream new];
            scene.token = [context contextId];
            scene.display = display;
            scene.pending = [NSMutableDictionary new];
            streams[@(scene.token)] = scene;
            mach_port_t port = MACH_PORT_NULL;
            if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port) ||
                mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND)) exit(46);
            scene.receiver = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, port, 0, streamQueue);
            __weak RuntimeSceneStream *weakScene = scene;
            dispatch_source_set_event_handler(scene.receiver, ^{
                RuntimeSceneStream *owner = weakScene;
                struct { IOSUseWindowSceneStateMessage message; char trailer[512]; } packet = {0};
                kern_return_t result = mach_msg(&packet.message.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT,
                    0, sizeof(packet), port, 0, 0);
                if (result) return;
                mach_msg_header_t *header = &packet.message.header;
                if (!(header->msgh_bits & MACH_MSGH_BITS_COMPLEX) && header->msgh_id == IOSUseWindowRelease &&
                    header->msgh_size == sizeof(IOSUseWindowReleaseMessage)) {
                    releaseFrame(owner, ((IOSUseWindowReleaseMessage *)header)->surfaceID);
                } else if (!(header->msgh_bits & MACH_MSGH_BITS_COMPLEX) && header->msgh_id == IOSUseWindowSceneState &&
                           header->msgh_size == sizeof(IOSUseWindowSceneStateMessage)) {
                    BOOL foreground = packet.message.foreground != 0;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        void (*setForeground)(NSString *, BOOL) = dlsym(RTLD_DEFAULT, "IOSUseSetSceneForeground");
                        if (setForeground) setForeground(sceneIdentifier, foreground);
                    });
                } else if (!(header->msgh_bits & MACH_MSGH_BITS_COMPLEX) && header->msgh_id == IOSUseWindowSceneClose &&
                           header->msgh_size == sizeof(mach_msg_header_t)) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        void (*destroy)(NSString *) = dlsym(RTLD_DEFAULT, "IOSUseDestroyScene");
                        if (destroy) destroy(sceneIdentifier);
                    });
                } else mach_msg_destroy(header);
            });
            dispatch_source_set_cancel_handler(scene.receiver, ^{
                mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
                mach_port_deallocate(mach_task_self(), port);
            });
            dispatch_resume(scene.receiver);
            if (![context layer]) { fprintf(stderr, "[stream] initial context has no layer\n"); exit(46); }
            [context waitForRenderingWithTimeout:2];
            NSError *error = nil;
            id options = [NSClassFromString(@"CAContentStreamOptions") new];
            [options setValue:@([display displayId]) forKey:@"targetDisplayId"];
            [options setValue:@((uint32_t)'BGRA') forKey:@"pixelFormat"];
            [options setValue:[NSValue valueWithCGSize:CGSizeMake(804, 1748)] forKey:@"frameSize"];
            [options setValue:[NSValue valueWithCGRect:CGRectMake(0, 0, 1206, 2622)] forKey:@"sourceRect"];
            [options setValue:[NSValue valueWithCGRect:CGRectMake(0, 0, 804, 1748)] forKey:@"destinationRect"];
            [options setValue:@YES forKey:@"alwaysScaleToFit"];
            [options setValue:@3 forKey:@"queueDepth"];
            [options setValue:@(1.0 / 30) forKey:@"minimumFrameTime"];
            scene.stream = [NSClassFromString(@"CAContentStream") contentStreamWithOptions:options queue:streamQueue
                handler:^(id owner, id frame) {
                    RuntimeSceneStream *state = weakScene;
                    IOSurfaceRef surface = [frame surface];
                    if (!surface) return;
                    if (!state || state.closing) { [owner releaseSurface:surface error:NULL]; return; }
                    uint32_t surfaceID = IOSurfaceGetID(surface);
                    state.pending[@(surfaceID)] = frame;
                    mach_port_t (*touchPort)(void) = dlsym(RTLD_DEFAULT, "IOSUseTouchPort");
                    IOSUseWindowFrameMessage message = {0};
                    message.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
                    message.header.msgh_size = sizeof(message);
                    message.header.msgh_remote_port = brokerPort;
                    message.header.msgh_id = IOSUseWindowFrame;
                    message.body.msgh_descriptor_count = 3;
                    message.surface.name = IOSurfaceCreateMachPort(surface);
                    message.surface.disposition = MACH_MSG_TYPE_MOVE_SEND;
                    message.surface.type = MACH_MSG_PORT_DESCRIPTOR;
                    message.release.name = port;
                    message.release.disposition = MACH_MSG_TYPE_COPY_SEND;
                    message.release.type = MACH_MSG_PORT_DESCRIPTOR;
                    message.input.name = touchPort ? touchPort() : MACH_PORT_NULL;
                    message.input.disposition = MACH_MSG_TYPE_COPY_SEND;
                    message.input.type = MACH_MSG_PORT_DESCRIPTOR;
                    message.surfaceID = surfaceID;
                    message.sceneID = state.token;
                    kern_return_t sent = mach_msg(&message.header, MACH_SEND_MSG, sizeof(message), 0, 0, 0, 0);
                    if (sent) {
                        mach_msg_destroy(&message.header);
                        [owner releaseSurface:surface error:NULL];
                        [state.pending removeObjectForKey:@(surfaceID)];
                        fprintf(stderr, "[stream] frame handoff failed: %d\n", sent); exit(47);
                    }
                    if (++state.frames == 1 || state.frames % 30 == 0)
                        fprintf(stderr, "[stream] scene=%u frames=%u outstanding=%lu\n", state.token, state.frames, (unsigned long)state.pending.count);
                } error:&error];
            if (!scene.stream || ![scene.stream setIncludedContexts:@[@(scene.token)] error:&error] || ![scene.stream start:&error]) {
                NSLog(@"[stream] start failed: %@", error); exit(46);
            }
        });
    });
}
