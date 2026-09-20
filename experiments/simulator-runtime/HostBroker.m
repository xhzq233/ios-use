// Research harness for an installed Simulator runtime; private APIs are intentional.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <dlfcn.h>
#import <errno.h>
#import <signal.h>
#import <mach/mach.h>
#import <spawn.h>
#import <sys/mman.h>
#import <sys/wait.h>
#import <unistd.h>
#import <xpc/xpc.h>
#import "WindowMessage.h"
#import "ServicePorts.h"

extern void IOSUseShowSurface(mach_port_t port, mach_port_t input, uint32_t identifier);
extern int IOSUseRunHostWindow(pid_t client, NSString *home);
extern BOOL IOSUseHostWindowClosedNormally(void);
extern mach_port_t IOSUseCreateUserNotificationPort(void);

extern void xpc_connection_enable_sim2host_4sim(xpc_connection_t);
extern mach_port_t xpc_endpoint_copy_listener_port_4sim(xpc_endpoint_t);

@interface NSObject (IOSurfaceRemoteServerAPI)
- (instancetype)initWithListener:(xpc_connection_t)listener options:(NSDictionary *)options;
@end

static void removeNotifyStorage(void) {
    char name[32];
    snprintf(name, sizeof(name), "iosuse.notify.%d", getpid());
    shm_unlink(name);
}

static void stopService(pid_t pid, const char *name) {
    if (pid <= 0) return;
    kill(pid, SIGTERM);
    int status = 0;
    pid_t waited = 0;
    // trustd can retain background XPC transactions after its client exits.
    // Give it a short flush window, then reclaim this owned child explicitly.
    for (int attempt = 0; attempt < 20; ++attempt) {
        waited = waitpid(pid, &status, WNOHANG);
        if (waited == pid || (waited < 0 && errno != EINTR)) break;
        usleep(100000);
    }
    if (waited == 0 || (waited < 0 && errno == EINTR)) {
        fprintf(stderr, "[broker] %s still active after SIGTERM; terminating owned child\n", name);
        kill(pid, SIGKILL);
        while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    }
    printf("[broker] %s status=%d\n", name, status);
}

static void serveEndpoints(mach_port_t rendezvous, mach_port_t metal, mach_port_t compiler, mach_port_t surface, mach_port_t trust, mach_port_t tcc, mach_port_t photos, mach_port_t launchServices, mach_port_t notification, mach_port_t keychain) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (;;) {
            struct { mach_msg_header_t header; char trailer[512]; } request = {0};
            kern_return_t kr = mach_msg(&request.header, MACH_RCV_MSG, 0,
                                       sizeof(request), rendezvous, 0, 0);
            if (kr) return;
            if (request.header.msgh_id == IOSUseWindowFrame) {
                IOSUseWindowFrameMessage *frame = (void *)&request;
                IOSUseShowSurface(frame->surface.name, frame->input.name, frame->surfaceID);
                continue;
            }
            struct {
                mach_msg_header_t header;
                mach_msg_body_t body;
                mach_msg_port_descriptor_t ports[RuntimeEndpointCount];
            } reply = {0};
            reply.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0)
                | MACH_MSGH_BITS_COMPLEX;
            reply.header.msgh_size = sizeof(reply);
            reply.header.msgh_remote_port = request.header.msgh_remote_port;
            reply.header.msgh_id = 201;
            reply.body.msgh_descriptor_count = RuntimeEndpointCount;
            mach_port_t endpoints[] = {metal, compiler, surface, trust, tcc, photos, launchServices, notification, keychain};
            for (int i = 0; i < RuntimeEndpointCount; ++i) {
                reply.ports[i].name = endpoints[i];
                reply.ports[i].disposition = MACH_MSG_TYPE_COPY_SEND;
                reply.ports[i].type = MACH_MSG_PORT_DESCRIPTOR;
            }
            kr = mach_msg(&reply.header, MACH_SEND_MSG, sizeof(reply), 0, 0, 0, 0);
            printf("[broker] endpoint handoff=%d\n", kr);
        }
    });
}

static char **copyEnvironment(NSDictionary *environment) {
    char **result = calloc(environment.count + 1, sizeof(char *));
    int index = 0;
    for (NSString *key in environment) {
        result[index++] = strdup([[NSString stringWithFormat:@"%@=%@", key, environment[key]] UTF8String]);
    }
    return result;
}

static void freeEnvironment(char **environment) {
    for (int i = 0; environment[i]; ++i) free(environment[i]);
    free(environment);
}

static mach_port_t startService(NSString *name, NSString *path, NSDictionary *environment,
                                mach_port_t rendezvous, int messageID, pid_t *pid) {
    NSMutableDictionary *serviceEnvironment = [environment mutableCopy];
    serviceEnvironment[@"IOS_USE_RUNTIME_SERVICE"] = name;
    NSString *adapters = environment[@"DYLD_INSERT_LIBRARIES"];
    NSString *directory = [adapters stringByDeletingLastPathComponent];
    if ([name isEqual:@"notify"]) {
        // notifyd only needs the C/Mach transport, not UIKit or TCC metadata.
        serviceEnvironment[@"DYLD_INSERT_LIBRARIES"] = [directory stringByAppendingPathComponent:@"notify-transport.dylib"];
    } else if ([name isEqual:@"launchservices"]) {
        serviceEnvironment[@"DYLD_INSERT_LIBRARIES"] = [adapters stringByAppendingFormat:@":%@",
            [directory stringByAppendingPathComponent:@"launchservices-context.dylib"]];
    } else if ([name isEqual:@"tcc"]) {
        serviceEnvironment[@"DYLD_INSERT_LIBRARIES"] = [adapters stringByAppendingFormat:@":%@",
            [directory stringByAppendingPathComponent:@"tcc-context.dylib"]];
    }
    char **env = copyEnvironment(serviceEnvironment);
    char *arguments[] = {(char *)path.UTF8String,
        [name isEqual:@"notify"] ? "-shm" : NULL,
        (char *)[environment[@"IOS_USE_RUNTIME_NOTIFY_SHM"] UTF8String], NULL};
    int rc = posix_spawn(pid, path.UTF8String, NULL, NULL, arguments, env);
    freeEnvironment(env);
    printf("[broker] %s spawn=%d pid=%d\n", name.UTF8String, rc, *pid);
    if (rc) return MACH_PORT_NULL;
    struct {
        mach_msg_header_t header;
        mach_msg_body_t body;
        mach_msg_port_descriptor_t port;
        char trailer[512];
    } registration = {0};
    kern_return_t kr = mach_msg(&registration.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0,
                               sizeof(registration), rendezvous, 10000, 0);
    if (kr || registration.header.msgh_id != messageID || registration.body.msgh_descriptor_count != 1) {
        fprintf(stderr, "[broker] %s registration failed: %d\n", name.UTF8String, kr);
        return MACH_PORT_NULL;
    }
    return registration.port.name;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 6) {
            fprintf(stderr, "usage: broker runtime-root client shim isolated-home services-csv [client-args...]\n");
            return 2;
        }
        setbuf(stdout, NULL);
        NSArray<NSString *> *services = strlen(argv[5]) ? [@(argv[5]) componentsSeparatedByString:@","] : @[];
        for (NSString *service in services) {
            if (![@[@"metal", @"compiler", @"iosurface", @"trust", @"tcc", @"photos", @"notify", @"launchservices", @"keychain"] containsObject:service]) {
                fprintf(stderr, "unknown service: %s\n", service.UTF8String);
                return 2;
            }
        }
        printf("[broker] services=[%s]\n", argv[5]);
        mach_port_t metalPort = MACH_PORT_NULL, surfacePort = MACH_PORT_NULL, compilerPort = MACH_PORT_NULL, trustPort = MACH_PORT_NULL, tccPort = MACH_PORT_NULL, photosPort = MACH_PORT_NULL, launchServicesPort = MACH_PORT_NULL;
        mach_port_t keychainPort = MACH_PORT_NULL;
        __attribute__((objc_precise_lifetime)) xpc_connection_t metalListener = NULL;
        __attribute__((objc_precise_lifetime)) id surfaceServer = nil;
        BOOL sharedLinearTextures = NO;
        if ([services containsObject:@"metal"]) {
            id<MTLDevice> device = MTLCreateSystemDefaultDevice();
            if (!device) return 3;
            printf("[broker] gpu=%s\n", device.name.UTF8String);
            sharedLinearTextures = device.hasUnifiedMemory && [device supportsFamily:MTLGPUFamilyApple1];
            void *framework = dlopen("/System/Library/PrivateFrameworks/MTLSimImplementation.framework/Versions/A/MTLSimImplementation", RTLD_NOW);
            if (!framework) { fprintf(stderr, "%s\n", dlerror()); return 3; }
            void (*initialize)(xpc_connection_t, uint64_t, void *) = dlsym(framework, "init_with_xpc_connection");
            if (!initialize) { fprintf(stderr, "%s\n", dlerror()); return 3; }
            dispatch_queue_t queue = dispatch_queue_create("iosuse.runtime-probe.metal", DISPATCH_QUEUE_SERIAL);
            metalListener = xpc_connection_create(NULL, queue);
            // Both ends select the Simulator-to-host XPC wire format before activation.
            xpc_connection_enable_sim2host_4sim(metalListener);
            initialize(metalListener, device.registryID, NULL);
            metalPort = xpc_endpoint_copy_listener_port_4sim(xpc_endpoint_create(metalListener));
        }
        if ([services containsObject:@"iosurface"]) {
            dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_NOW);
            xpc_connection_t listener = xpc_connection_create(NULL, NULL);
            xpc_connection_enable_sim2host_4sim(listener);
            surfaceServer = [[NSClassFromString(@"IOSurfaceRemoteServer") alloc] initWithListener:listener options:@{}];
            if (!surfaceServer) return 3;
            surfacePort = xpc_endpoint_copy_listener_port_4sim(xpc_endpoint_create(listener));
            printf("[broker] IOSurface remote server ready\n");
        }

        mach_port_t rendezvous = MACH_PORT_NULL;
        kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &rendezvous);
        if (kr) return 4;
        kr = mach_port_insert_right(mach_task_self(), rendezvous, rendezvous, MACH_MSG_TYPE_MAKE_SEND);
        if (kr) return 4;
        // Children inherit this send right; no launchd service is registered.
        kr = mach_ports_register(mach_task_self(), &rendezvous, 1);
        if (kr) return 4;

        NSMutableDictionary *environment = [@{
            @"PATH": @"/usr/bin:/bin",
            @"DYLD_ROOT_PATH": @(argv[1]),
            @"SIMULATOR_ROOT": @(argv[1]),
            @"IPHONE_SIMULATOR_ROOT": @(argv[1]),
            @"CFFIXED_USER_HOME": @(argv[4]),
            @"HOME": @(argv[4]), // tccd reads getenv("HOME") directly.
            @"IOS_USE_RUNTIME_APP_PATH": [@(argv[2]) stringByDeletingLastPathComponent],
            @"SIMULATOR_LOG_ROOT": @(argv[4]),
            @"IOS_USE_RUNTIME_NOTIFY_SHM": [NSString stringWithFormat:@"iosuse.notify.%d", getpid()],
            @"SIMULATOR_SHARED_RESOURCES_DIRECTORY": @(argv[4]),
            @"IPHONE_SHARED_RESOURCES_DIRECTORY": @(argv[4]),
            @"DYLD_INSERT_LIBRARIES": @(argv[3]),
            // Enables Simulator libxpc behavior; this name is never registered.
            @"XPC_SIMULATOR_LAUNCHD_NAME": @"io.iosuse.runtime-probe.standalone"
        } mutableCopy];
        NSString *versionPath = [@(argv[1]) stringByAppendingPathComponent:@"System/Library/CoreServices/SystemVersion.plist"];
        NSDictionary *version = [NSDictionary dictionaryWithContentsOfFile:versionPath];
        if (!version[@"ProductVersion"] || !version[@"ProductBuildVersion"]) {
            fprintf(stderr, "[broker] runtime SystemVersion.plist is incomplete\n");
            return 4;
        }
        environment[@"SIMULATOR_RUNTIME_VERSION"] = version[@"ProductVersion"];
        environment[@"SIMULATOR_RUNTIME_BUILD_VERSION"] = version[@"ProductBuildVersion"];
        // CoreSimulator's existing cache belongs to this host build and runtime.
        // Supplying its location does not require a running Simulator or service.
        NSString *runtimeContents = [[@(argv[1]) stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
        NSDictionary *runtimeInfo = [NSDictionary dictionaryWithContentsOfFile:[runtimeContents stringByAppendingPathComponent:@"Info.plist"]];
        NSDictionary *hostVersion = [NSDictionary dictionaryWithContentsOfFile:@"/System/Library/CoreServices/SystemVersion.plist"];
        NSString *runtimeID = runtimeInfo[@"CFBundleIdentifier"], *hostBuild = hostVersion[@"ProductBuildVersion"];
        if (runtimeID && hostBuild) {
            NSString *cache = [NSString stringWithFormat:@"/Library/Developer/CoreSimulator/Caches/dyld/%@/%@.%@",
                              hostBuild, runtimeID, version[@"ProductBuildVersion"]];
            if ([[NSFileManager defaultManager] isReadableFileAtPath:[cache stringByAppendingPathComponent:@"dyld_sim_shared_cache_arm64"]]) {
                environment[@"DYLD_SHARED_CACHE_DIR"] = cache;
                printf("[broker] runtime shared cache=%s\n", cache.UTF8String);
            }
        }
        if (!environment[@"DYLD_SHARED_CACHE_DIR"])
            printf("[broker] no matching external runtime cache; retaining dyld defaults\n");
        NSString *temporary = [@(argv[4]) stringByAppendingPathComponent:@"tmp"];
        NSError *directoryError = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtPath:temporary withIntermediateDirectories:YES
                attributes:nil error:&directoryError]) {
            NSLog(@"[broker] cannot create isolated temporary directory: %@", directoryError);
            return 4;
        }
        environment[@"TMPDIR"] = [temporary stringByAppendingString:@"/"];
        pid_t notifyPID = 0;
        if ([services containsObject:@"notify"]) {
            atexit(removeNotifyStorage);
            NSString *path = [@(argv[1]) stringByAppendingPathComponent:@"usr/sbin/notifyd"];
            mach_port_t port = startService(@"notify", path, environment, rendezvous, RuntimeNotifyReady, &notifyPID);
            if (!port) { stopService(notifyPID, "notify"); return 6; }
            // libnotify uses Mach IPC rather than XPC endpoints. Hand its send
            // right directly to later children, including runtime services that
            // subscribe before their own XPC listener has started.
            mach_port_t inherited[] = {rendezvous, port};
            if (mach_ports_register(mach_task_self(), inherited, 2)) {
                stopService(notifyPID, "notify"); return 6;
            }
        }
        const struct {
            const char *name, *path;
            int registration;
            mach_port_t *port;
        } children[] = {
            {"compiler", "System/Library/Frameworks/Metal.framework/XPCServices/MTLCompilerService.xpc/MTLCompilerService", RuntimeCompilerReady, &compilerPort},
            {"trust", "usr/libexec/trustd", RuntimeTrustReady, &trustPort},
            {"tcc", "System/Library/PrivateFrameworks/TCC.framework/Support/tccd", RuntimeTCCReady, &tccPort},
            {"launchservices", "usr/libexec/lsd", RuntimeLaunchServicesReady, &launchServicesPort},
            {"photos", "System/Library/Frameworks/AssetsLibrary.framework/Support/assetsd", RuntimePhotosReady, &photosPort},
            // securityd starts resolving its TCC peer immediately after exposing
            // its listener. Start it last so endpoint serving can begin next.
            {"keychain", "usr/libexec/securityd", RuntimeKeychainReady, &keychainPort}
        };
        enum { childCount = sizeof(children) / sizeof(children[0]) };
        pid_t childPIDs[childCount] = {0};
        for (int i = 0; i < childCount; ++i) {
            if (![services containsObject:@(children[i].name)]) continue;
            NSString *path = [@(argv[1]) stringByAppendingPathComponent:@(children[i].path)];
            *children[i].port = startService(@(children[i].name), path, environment, rendezvous, children[i].registration, &childPIDs[i]);
            if (!*children[i].port) {
                for (int j = i; j >= 0; --j) stopService(childPIDs[j], children[j].name);
                stopService(notifyPID, "notify");
                return 6;
            }
        }
        mach_port_t notificationPort = getenv("IOS_USE_RUNTIME_PRESENT") && [services containsObject:@"tcc"]
            ? IOSUseCreateUserNotificationPort() : MACH_PORT_NULL;
        serveEndpoints(rendezvous, metalPort, compilerPort, surfacePort, trustPort, tccPort, photosPort, launchServicesPort, notificationPort, keychainPort);
        // UIKit adapters belong only in the app, never in runtime services.
        const char *clientLibraries = getenv("IOS_USE_RUNTIME_CLIENT_LIBRARIES");
        if (sharedLinearTextures) environment[@"IOS_USE_RUNTIME_SHARED_LINEAR_TEXTURES"] = @"1";
        if (clientLibraries && *clientLibraries) {
            environment[@"DYLD_INSERT_LIBRARIES"] = [@(argv[3]) stringByAppendingFormat:@":%s", clientLibraries];
            // Match LocalDisplay's iPhone 16 Pro profile. CMCapture requires the
            // product class even when an app only enumerates camera capability.
            environment[@"SIMULATOR_MODEL_IDENTIFIER"] = @"iPhone17,1";
            environment[@"SIMULATOR_PRODUCT_CLASS"] = @"D93";
            // CADisplayLink and other CA clients also need the local server;
            // supplying only remoteContextWithOptions' port is insufficient.
            environment[@"CA_FORCE_LOCAL_SERVER"] = @"1";
        }
        BOOL present = getenv("IOS_USE_RUNTIME_PRESENT") != NULL;
        if (present) {
            environment[@"IOS_USE_RUNTIME_PRESENT"] = @"1";
            environment[@"CA_FORCE_LOCAL_SERVER"] = @"1";
        }
        const char *tap = getenv("IOS_USE_RUNTIME_TAP");
        if (tap && !present) environment[@"IOS_USE_RUNTIME_TAP"] = @(tap);
        char **clientEnvironment = copyEnvironment(environment);
        char **clientArguments = calloc(argc - 4, sizeof(char *));
        clientArguments[0] = argv[2];
        for (int i = 6; i < argc; ++i) clientArguments[i - 5] = argv[i];
        pid_t clientPID = 0;
        int rc = posix_spawn(&clientPID, argv[2], NULL, NULL, clientArguments, clientEnvironment);
        freeEnvironment(clientEnvironment);
        free(clientArguments);
        printf("[broker] client spawn=%d pid=%d\n", rc, clientPID);
        if (rc) {
            for (int i = childCount - 1; i >= 0; --i) stopService(childPIDs[i], children[i].name);
            stopService(notifyPID, "notify"); return 7;
        }
        int status = 0;
        pid_t waited = clientPID;
        if (present) {
            status = IOSUseRunHostWindow(clientPID, @(argv[4]));
        } else {
            do { waited = waitpid(clientPID, &status, 0); } while (waited < 0 && errno == EINTR);
        }
        for (int i = childCount - 1; i >= 0; --i) stopService(childPIDs[i], children[i].name);
        stopService(notifyPID, "notify");
        printf("[broker] client status=%d\n", status);
        if (present && IOSUseHostWindowClosedNormally() && WIFSIGNALED(status) && WTERMSIG(status) == SIGTERM) return 0;
        return waited > 0 && WIFEXITED(status) ? WEXITSTATUS(status) : 8;
    }
}
