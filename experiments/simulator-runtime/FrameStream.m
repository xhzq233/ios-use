// Runtime CA -> shared IOSurface -> native window. No per-frame CPU readback.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurfaceRef.h>
#import <dlfcn.h>
#import "WindowMessage.h"

extern id IOSUseVirtualDisplay(void);
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
- (IOSurfaceRef)surface;
- (BOOL)releaseSurface:(IOSurfaceRef)surface error:(NSError **)error;
@end

static dispatch_queue_t streamQueue;
static id stream;
static NSMutableDictionary *pendingFrames;
static mach_port_t brokerPort;

void IOSUseReleaseFrame(uint32_t identifier) {
    if (!streamQueue) return;
    dispatch_async(streamQueue, ^{
        id frame = pendingFrames[@(identifier)];
        if (!frame) return;
        NSError *error = nil;
        if (![stream releaseSurface:[frame surface] error:&error]) NSLog(@"[stream] release failed: %@", error);
        [pendingFrames removeObjectForKey:@(identifier)];
    });
}

void IOSUseStreamContext(id context) {
    if (!getenv("IOS_USE_RUNTIME_PRESENT") || !context) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Serialize our stream operations and diagnostic snapshots. The virtual
        // display owns its refresh loop; we do not add another rendering timer.
        streamQueue = IOSUseRenderQueue();
        pendingFrames = [NSMutableDictionary new];
        mach_port_array_t ports = NULL;
        mach_msg_type_number_t count = 0;
        if (mach_ports_lookup(mach_task_self(), &ports, &count) || !count) exit(46);
        brokerPort = ports[0];
        vm_deallocate(mach_task_self(), (vm_address_t)ports, count * sizeof(mach_port_t));
    });
    // The compositor supplies one stable parent context. UIKit assigns child
    // roots after remoteContextWithOptions: returns. Starting
    // a stream before the first presented surface crashes VirtualServer.
    dispatch_async(dispatch_get_main_queue(), ^{
        [CATransaction flush];
        dispatch_async(streamQueue, ^{
            uint32_t identifier = [context contextId];
            if (![context layer] || ![context waitForRenderingWithTimeout:2]) {
                fprintf(stderr, "[stream] initial context has not rendered\n");
                exit(46);
            }
            NSError *error = nil;
            id options = [NSClassFromString(@"CAContentStreamOptions") new];
            [options setValue:@([IOSUseVirtualDisplay() displayId]) forKey:@"targetDisplayId"];
            [options setValue:@((uint32_t)'BGRA') forKey:@"pixelFormat"];
            [options setValue:[NSValue valueWithCGSize:CGSizeMake(804, 1748)] forKey:@"frameSize"];
            [options setValue:[NSValue valueWithCGRect:CGRectMake(0, 0, 1206, 2622)] forKey:@"sourceRect"];
            [options setValue:[NSValue valueWithCGRect:CGRectMake(0, 0, 804, 1748)] forKey:@"destinationRect"];
            [options setValue:@YES forKey:@"alwaysScaleToFit"];
            [options setValue:@3 forKey:@"queueDepth"];
            [options setValue:@(1.0 / 30) forKey:@"minimumFrameTime"];
            stream = [NSClassFromString(@"CAContentStream") contentStreamWithOptions:options queue:streamQueue
                handler:^(id owner, id frame) {
                    IOSurfaceRef surface = [frame surface];
                    if (!surface) return; // Unchanged/idle notifications carry no image.
                    uint32_t surfaceID = IOSurfaceGetID(surface);
                    pendingFrames[@(surfaceID)] = frame;
                    mach_port_t (*touchPort)(void) = dlsym(RTLD_DEFAULT, "IOSUseTouchPort");
                    IOSUseWindowFrameMessage message = {0};
                    message.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
                    message.header.msgh_size = sizeof(message);
                    message.header.msgh_remote_port = brokerPort;
                    message.header.msgh_id = IOSUseWindowFrame;
                    message.body.msgh_descriptor_count = 2;
                    message.surface.name = IOSurfaceCreateMachPort(surface);
                    message.surface.disposition = MACH_MSG_TYPE_MOVE_SEND;
                    message.surface.type = MACH_MSG_PORT_DESCRIPTOR;
                    message.input.name = touchPort ? touchPort() : MACH_PORT_NULL;
                    message.input.disposition = MACH_MSG_TYPE_COPY_SEND;
                    message.input.type = MACH_MSG_PORT_DESCRIPTOR;
                    message.surfaceID = surfaceID;
                    kern_return_t sent = mach_msg(&message.header, MACH_SEND_MSG, sizeof(message), 0, 0, 0, 0);
                    if (sent) {
                        mach_msg_destroy(&message.header);
                        [owner releaseSurface:surface error:NULL];
                        [pendingFrames removeObjectForKey:@(surfaceID)];
                        fprintf(stderr, "[stream] frame handoff failed: %d\n", sent);
                        exit(47);
                    }
                    static unsigned frames;
                    if (++frames == 1 || frames % 30 == 0) {
                        fprintf(stderr, "[stream] frames=%u outstanding=%lu\n", frames, (unsigned long)pendingFrames.count);
                    }
                } error:&error];
            if (!stream || ![stream setIncludedContexts:@[@(identifier)] error:&error] || ![stream start:&error]) {
                NSLog(@"[stream] start failed: %@", error);
                exit(46);
            }
        });
    });
}
