// Research harness for an installed Simulator runtime; private APIs are intentional.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <dlfcn.h>
#import <errno.h>
#import <signal.h>
#import <mach/mach.h>
#import <spawn.h>
#import <sys/wait.h>
#import <xpc/xpc.h>

extern void xpc_connection_enable_sim2host_4sim(xpc_connection_t);
extern mach_port_t xpc_endpoint_copy_listener_port_4sim(xpc_endpoint_t);

@interface NSObject (IOSurfaceRemoteServerAPI)
- (instancetype)initWithListener:(xpc_connection_t)listener options:(NSDictionary *)options;
@end

static void stopCompiler(pid_t pid) {
    kill(pid, SIGTERM);
    while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
}

static void serveEndpoints(mach_port_t rendezvous, mach_port_t metal, mach_port_t compiler, mach_port_t surface) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (;;) {
            struct { mach_msg_header_t header; char trailer[512]; } request = {0};
            kern_return_t kr = mach_msg(&request.header, MACH_RCV_MSG, 0,
                                       sizeof(request), rendezvous, 0, 0);
            if (kr) return;
            struct {
                mach_msg_header_t header;
                mach_msg_body_t body;
                mach_msg_port_descriptor_t ports[3];
            } reply = {0};
            reply.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0)
                | MACH_MSGH_BITS_COMPLEX;
            reply.header.msgh_size = sizeof(reply);
            reply.header.msgh_remote_port = request.header.msgh_remote_port;
            reply.header.msgh_id = 201;
            reply.body.msgh_descriptor_count = 3;
            mach_port_t endpoints[] = {metal, compiler, surface};
            for (int i = 0; i < 3; ++i) {
                reply.ports[i].name = endpoints[i];
                reply.ports[i].disposition = MACH_MSG_TYPE_COPY_SEND;
                reply.ports[i].type = MACH_MSG_PORT_DESCRIPTOR;
            }
            kr = mach_msg(&reply.header, MACH_SEND_MSG, sizeof(reply), 0, 0, 0, 0);
            printf("[broker] endpoint handoff=%d\n", kr);
        }
    });
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 5 && argc != 6) {
            fprintf(stderr, "usage: broker runtime-root client shim isolated-home [metallib]\n");
            return 2;
        }
        setbuf(stdout, NULL);
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) return 3;
        printf("[broker] gpu=%s\n", device.name.UTF8String);
        void *framework = dlopen("/System/Library/PrivateFrameworks/MTLSimImplementation.framework/Versions/A/MTLSimImplementation", RTLD_NOW);
        if (!framework) { fprintf(stderr, "%s\n", dlerror()); return 3; }
        void (*initialize)(xpc_connection_t, uint64_t, void *) =
            dlsym(framework, "init_with_xpc_connection");
        if (!initialize) { fprintf(stderr, "%s\n", dlerror()); return 3; }

        dispatch_queue_t queue = dispatch_queue_create("iosuse.runtime-probe.metal", DISPATCH_QUEUE_SERIAL);
        xpc_connection_t listener = xpc_connection_create(NULL, queue);
        // Both ends must select the Simulator-to-host XPC wire format before activation.
        xpc_connection_enable_sim2host_4sim(listener);
        initialize(listener, device.registryID, NULL);
        xpc_endpoint_t endpoint = xpc_endpoint_create(listener);
        mach_port_t metalPort = xpc_endpoint_copy_listener_port_4sim(endpoint);

        dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_NOW);
        xpc_connection_t surfaceListener = xpc_connection_create(NULL, NULL);
        xpc_connection_enable_sim2host_4sim(surfaceListener);
        __attribute__((objc_precise_lifetime)) id surfaceServer =
            [[NSClassFromString(@"IOSurfaceRemoteServer") alloc] initWithListener:surfaceListener options:@{}];
        if (!surfaceServer) return 3;
        xpc_endpoint_t surfaceEndpoint = xpc_endpoint_create(surfaceListener);
        mach_port_t surfacePort = xpc_endpoint_copy_listener_port_4sim(surfaceEndpoint);
        printf("[broker] IOSurface remote server ready\n");

        mach_port_t rendezvous = MACH_PORT_NULL;
        kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &rendezvous);
        if (kr) return 4;
        kr = mach_port_insert_right(mach_task_self(), rendezvous, rendezvous, MACH_MSG_TYPE_MAKE_SEND);
        if (kr) return 4;
        // The children inherit this send right, so no launchd service is registered.
        kr = mach_ports_register(mach_task_self(), &rendezvous, 1);
        if (kr) return 4;

        NSDictionary *environment = @{
            @"PATH": @"/usr/bin:/bin",
            @"DYLD_ROOT_PATH": @(argv[1]),
            @"SIMULATOR_ROOT": @(argv[1]),
            @"IPHONE_SIMULATOR_ROOT": @(argv[1]),
            @"CFFIXED_USER_HOME": @(argv[4]),
            @"SIMULATOR_SHARED_RESOURCES_DIRECTORY": @(argv[4]),
            @"IPHONE_SHARED_RESOURCES_DIRECTORY": @(argv[4]),
            @"DYLD_INSERT_LIBRARIES": @(argv[3]),
            // Enables libxpc's Simulator behavior; this name is never registered.
            @"XPC_SIMULATOR_LAUNCHD_NAME": @"io.iosuse.runtime-probe.standalone"
        };
        char **childEnvironment = calloc(environment.count + 1, sizeof(char *));
        int index = 0;
        for (NSString *key in environment) {
            childEnvironment[index++] = strdup([[NSString stringWithFormat:@"%@=%@", key, environment[key]] UTF8String]);
        }
        NSString *compilerPath = [@(argv[1]) stringByAppendingPathComponent:
            @"System/Library/Frameworks/Metal.framework/XPCServices/MTLCompilerService.xpc/MTLCompilerService"];
        char *compilerArguments[] = {(char *)compilerPath.UTF8String, NULL};
        pid_t compilerPID = 0;
        int rc = posix_spawn(&compilerPID, compilerPath.UTF8String, NULL, NULL,
                             compilerArguments, childEnvironment);
        printf("[broker] compiler spawn=%d pid=%d\n", rc, compilerPID);
        if (rc) return 5;

        struct {
            mach_msg_header_t header;
            mach_msg_body_t body;
            mach_msg_port_descriptor_t port;
            char trailer[512];
        } registration = {0};
        kr = mach_msg(&registration.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0,
                      sizeof(registration), rendezvous, 10000, 0);
        if (kr || registration.header.msgh_id != 300 || registration.body.msgh_descriptor_count != 1) {
            fprintf(stderr, "[broker] compiler registration failed: %d\n", kr);
            stopCompiler(compilerPID);
            return 6;
        }
        serveEndpoints(rendezvous, metalPort, registration.port.name, surfacePort);
        char *clientArguments[] = {argv[2], argc == 6 ? argv[5] : NULL, NULL};
        pid_t clientPID = 0;
        rc = posix_spawn(&clientPID, argv[2], NULL, NULL, clientArguments, childEnvironment);
        for (int i = 0; childEnvironment[i]; ++i) free(childEnvironment[i]);
        free(childEnvironment);
        printf("[broker] client spawn=%d pid=%d\n", rc, clientPID);
        if (rc) { stopCompiler(compilerPID); return 7; }
        int status = 0;
        pid_t waited;
        do { waited = waitpid(clientPID, &status, 0); } while (waited < 0 && errno == EINTR);
        stopCompiler(compilerPID);
        printf("[broker] client status=%d\n", status);
        return waited > 0 && WIFEXITED(status) ? WEXITSTATUS(status) : 8;
    }
}
