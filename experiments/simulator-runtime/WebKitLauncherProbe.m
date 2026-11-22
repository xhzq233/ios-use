// Linked only into the WebKit diagnostic; this is not a usable app adapter.
// Ordinary owned children cannot claim ExtensionKit capability grants.
#import <Foundation/Foundation.h>
#import <BrowserEngineKit/BrowserEngineKit.h>
#import <objc/runtime.h>
#import <mach/mach.h>
#import <spawn.h>
#import <sys/wait.h>
#import <dlfcn.h>
extern xpc_endpoint_t xpc_endpoint_create_mach_port_4sim(mach_port_t);
static void launch(id, SEL, NSString *, void (^)(void), void (^)(id, NSError *));
@interface RuntimeWebProcess : NSObject
@property(nonatomic) pid_t pid;
@property(nonatomic, strong) xpc_endpoint_t endpoint;
@end
@implementation RuntimeWebProcess
- (xpc_connection_t)makeLibXPCConnectionError:(NSError **)error {
    return xpc_connection_create_from_endpoint(self.endpoint);
}
- (id)grantCapability:(id)capability error:(NSError **)error invalidationHandler:(id)handler {
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOTSUP userInfo:nil];
    return nil; // Ordinary owned processes have no ExtensionKit capability grant.
}
- (id)grantCapability:(id)capability error:(NSError **)error { return [self grantCapability:capability error:error invalidationHandler:nil]; }
- (id)createVisibilityPropagationInteraction { return nil; }
- (void)invalidate {
    pid_t pid;
    @synchronized(self) { pid = self.pid; self.pid = 0; }
    if (!pid) return;
    kill(pid, SIGTERM);
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        int status;
        for (int i = 0; i < 20; i++) { if (waitpid(pid, &status, WNOHANG) != 0) return; usleep(100000); }
        kill(pid, SIGKILL); while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    });
}
- (void)invalidateWithReason:(NSString *)reason { [self invalidate]; }
- (void)dealloc { [self invalidate]; }
@end
static void launch(id cls, SEL sel, NSString *identifier, void (^interrupt)(void), void (^completion)(id, NSError *)) {
    static dispatch_queue_t queue; static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("iosuse.webkit.launch", DISPATCH_QUEUE_SERIAL); });
    dispatch_async(queue, ^{
        Dl_info location; dladdr(launch, &location);
        NSString *path = [[@(location.dli_fname) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"WebKitChild"];
        NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
        env[@"DYLD_INSERT_LIBRARIES"] = [env[@"DYLD_INSERT_LIBRARIES"] componentsSeparatedByString:@":"].firstObject;
        NSArray *keys = env.allKeys; char **values = calloc(keys.count + 1, sizeof(char *));
        for (NSUInteger i = 0; i < keys.count; i++) values[i] = strdup([[NSString stringWithFormat:@"%@=%@", keys[i], env[keys[i]]] UTF8String]);
        mach_port_t rendezvous = MACH_PORT_NULL;
        if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &rendezvous) ||
            mach_port_insert_right(mach_task_self(), rendezvous, rendezvous, MACH_MSG_TYPE_MAKE_SEND)) exit(122);
        mach_port_array_t old = NULL; mach_msg_type_number_t count = 0;
        if (mach_ports_lookup(mach_task_self(), &old, &count) || (count > 2 && old[2])) exit(122);
        mach_port_t ports[] = {count > 0 ? old[0] : 0, count > 1 ? old[1] : 0, rendezvous};
        int rc = mach_ports_register(mach_task_self(), ports, 3);
        pid_t pid = 0; char *argv[] = {(char *)path.UTF8String, NULL};
        if (!rc) rc = posix_spawn(&pid, path.UTF8String, NULL, NULL, argv, values);
        if (mach_ports_register(mach_task_self(), old, count)) exit(122);
        for (unsigned i = 0; i < count; i++) if (old[i]) mach_port_deallocate(mach_task_self(), old[i]);
        vm_deallocate(mach_task_self(), (vm_address_t)old, count * sizeof(mach_port_t));
        for (NSUInteger i = 0; i < keys.count; i++) free(values[i]); free(values);
        struct { mach_msg_header_t header; mach_msg_body_t body; mach_msg_port_descriptor_t port; char trailer[512]; } msg = {0};
        if (!rc) rc = mach_msg(&msg.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(msg), rendezvous, 10000, 0);
        mach_port_deallocate(mach_task_self(), rendezvous);
        mach_port_mod_refs(mach_task_self(), rendezvous, MACH_PORT_RIGHT_RECEIVE, -1);
        if (rc || msg.header.msgh_id != 601) {
            if (pid) { kill(pid, SIGKILL); waitpid(pid, NULL, 0); }
            completion(nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:rc ?: EIO userInfo:nil]); return;
        }
        dispatch_async(dispatch_get_global_queue(0, 0), ^{ siginfo_t status = {0}; waitid(P_PID, pid, &status, WEXITED | WNOWAIT); fprintf(stderr, "[webkit-child] exit code=%d status=%d\n", status.si_code, status.si_status); });
        RuntimeWebProcess *process = [RuntimeWebProcess new]; process.pid = pid;
        process.endpoint = xpc_endpoint_create_mach_port_4sim(msg.port.name);
        // The Simulator endpoint takes ownership of this received right.
        fprintf(stderr, "[webkit-launch] %s pid=%d\n", identifier.UTF8String, pid);
        completion(process, nil);
    });
}
__attribute__((constructor)) static void install(void) {
    NSArray *classes = @[@"BEWebContentProcess", @"BENetworkingProcess", @"BERenderingProcess"];
    NSArray *selectors = @[@"webContentProcessWithBundleID:interruptionHandler:completion:", @"networkProcessWithBundleID:interruptionHandler:completion:", @"renderingProcessWithBundleID:interruptionHandler:completion:"];
    for (NSUInteger i = 0; i < classes.count; i++) {
        Method method = class_getClassMethod(NSClassFromString(classes[i]), NSSelectorFromString(selectors[i]));
        if (!method) { fprintf(stderr, "[webkit-launch] unsupported launcher API\n"); exit(122); }
        method_setImplementation(method, (IMP)launch);
    }
}
