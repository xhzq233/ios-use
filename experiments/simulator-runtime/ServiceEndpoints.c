// Redirect selected service discovery; retain Apple's implementations.
#include <mach/mach.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <xpc/xpc.h>
#include <CoreFoundation/CoreFoundation.h>
#include "ServicePorts.h"

// Aliases allow use of these installed private symbols with the Simulator SDK.
extern xpc_connection_t original_mach_service(const char *, dispatch_queue_t, uint64_t)
    __asm__("_xpc_connection_create_mach_service");
extern xpc_connection_t original_service(const char *, dispatch_queue_t)
    __asm__("_xpc_connection_create");
extern void original_xpc_main(void (*)(xpc_connection_t)) __asm__("_xpc_main");
extern xpc_endpoint_t xpc_endpoint_create_mach_port_4sim(mach_port_t);
extern mach_port_t xpc_endpoint_copy_listener_port_4sim(xpc_endpoint_t);

static xpc_endpoint_t metalEndpoint, compilerEndpoint, surfaceEndpoint, trustEndpoint, tccEndpoint, photosEndpoint, launchServicesEndpoint, keychainEndpoint;
static struct {
    const char *name;
    xpc_connection_t listener;
    xpc_endpoint_t *endpoint;
    int registration;
    bool registered;
} runtimeServices[] = {
    {"com.apple.trustd", NULL, &trustEndpoint, RuntimeTrustReady, false},
    {"com.apple.tccd", NULL, &tccEndpoint, RuntimeTCCReady, false},
    {"com.apple.photos.service", NULL, &photosEndpoint, RuntimePhotosReady, false},
    {"com.apple.lsd.mapdb", NULL, &launchServicesEndpoint, RuntimeLaunchServicesReady, false},
    {"com.apple.securityd", NULL, &keychainEndpoint, RuntimeKeychainReady, false}
};
enum { runtimeServiceCount = sizeof(runtimeServices) / sizeof(runtimeServices[0]) };
static const char trustConnectionTag;
static pthread_once_t endpointsOnce = PTHREAD_ONCE_INIT;
static mach_port_t userNotificationPort;

static mach_port_t inheritedRendezvous(void) {
    mach_port_array_t ports = NULL;
    mach_msg_type_number_t count = 0;
    if (mach_ports_lookup(mach_task_self(), &ports, &count) || !count) exit(20);
    mach_port_t result = ports[0];
    for (mach_msg_type_number_t i = 1; i < count; ++i) mach_port_deallocate(mach_task_self(), ports[i]);
    vm_deallocate(mach_task_self(), (vm_address_t)ports, count * sizeof(mach_port_t));
    return result;
}

static void loadEndpoints(void) {
    mach_port_t rendezvous = inheritedRendezvous(), replyPort = MACH_PORT_NULL;
    if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &replyPort)) exit(20);
    mach_msg_header_t request = {0};
    request.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
    request.msgh_size = sizeof(request);
    request.msgh_remote_port = rendezvous;
    request.msgh_local_port = replyPort;
    request.msgh_id = 200;
    if (mach_msg(&request, MACH_SEND_MSG, sizeof(request), 0, 0, 0, 0)) exit(20);
    struct {
        mach_msg_header_t header;
        mach_msg_body_t body;
        mach_msg_port_descriptor_t ports[RuntimeEndpointCount];
        char trailer[512];
    } reply = {0};
    kern_return_t kr = mach_msg(&reply.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0,
                               sizeof(reply), replyPort, 5000, 0);
    if (kr || reply.header.msgh_id != 201 || reply.body.msgh_descriptor_count != RuntimeEndpointCount) exit(20);
    if (reply.ports[RuntimeMetal].name) metalEndpoint = xpc_endpoint_create_mach_port_4sim(reply.ports[RuntimeMetal].name);
    if (reply.ports[RuntimeCompiler].name) compilerEndpoint = xpc_endpoint_create_mach_port_4sim(reply.ports[RuntimeCompiler].name);
    if (reply.ports[RuntimeSurface].name) surfaceEndpoint = xpc_endpoint_create_mach_port_4sim(reply.ports[RuntimeSurface].name);
    if (reply.ports[RuntimeTrust].name) trustEndpoint = xpc_endpoint_create_mach_port_4sim(reply.ports[RuntimeTrust].name);
    if (reply.ports[RuntimeTCC].name) tccEndpoint = xpc_endpoint_create_mach_port_4sim(reply.ports[RuntimeTCC].name);
    if (reply.ports[RuntimePhotos].name) photosEndpoint = xpc_endpoint_create_mach_port_4sim(reply.ports[RuntimePhotos].name);
    if (reply.ports[RuntimeLaunchServices].name) launchServicesEndpoint = xpc_endpoint_create_mach_port_4sim(reply.ports[RuntimeLaunchServices].name);
    userNotificationPort = reply.ports[RuntimeUserNotification].name;
    if (reply.ports[RuntimeKeychain].name) keychainEndpoint = xpc_endpoint_create_mach_port_4sim(reply.ports[RuntimeKeychain].name);
    mach_port_mod_refs(mach_task_self(), replyPort, MACH_PORT_RIGHT_RECEIVE, -1);
    mach_port_deallocate(mach_task_self(), rendezvous);
}

mach_port_t IOSUseUserNotificationPort(void) {
    pthread_once(&endpointsOnce, loadEndpoints);
    return userNotificationPort;
}

static xpc_connection_t connectEndpoint(xpc_endpoint_t endpoint, dispatch_queue_t queue) {
    if (!endpoint) {
        // A dead anonymous endpoint reports a real connection failure. Do not
        // fall through to a booted Simulator or prevent the caller's CPU fallback.
        mach_port_t port = MACH_PORT_NULL;
        if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port)) exit(20);
        if (mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND)) exit(20);
        endpoint = xpc_endpoint_create_mach_port_4sim(port);
        mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
        fprintf(stderr, "[endpoint] disabled service: closed endpoint\n");
    }
    xpc_connection_t connection = xpc_connection_create_from_endpoint(endpoint);
    xpc_connection_set_target_queue(connection, queue);
    return connection;
}

static void registerService(xpc_connection_t listener, int messageID) {
    xpc_endpoint_t endpoint = xpc_endpoint_create(listener);
    struct {
        mach_msg_header_t header;
        mach_msg_body_t body;
        mach_msg_port_descriptor_t port;
    } registration = {0};
    registration.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
    registration.header.msgh_size = sizeof(registration);
    registration.header.msgh_remote_port = inheritedRendezvous();
    registration.header.msgh_id = messageID;
    registration.body.msgh_descriptor_count = 1;
    registration.port.name = xpc_endpoint_copy_listener_port_4sim(endpoint);
    registration.port.type = MACH_MSG_PORT_DESCRIPTOR;
    registration.port.disposition = MACH_MSG_TYPE_COPY_SEND;
    if (mach_msg(&registration.header, MACH_SEND_MSG, sizeof(registration), 0, 0, 0, 0)) exit(20);
}

// Security reconstructs its foreground-user connection using get_name(). An
// anonymous endpoint must retain its logical name or that reconstruction falls
// back to securityd. Security does not use the XPC context slot on these peers.
extern const char *original_name(xpc_connection_t) __asm__("_xpc_connection_get_name");
static const char *serviceName(xpc_connection_t connection) {
    if (xpc_connection_get_context(connection) == &trustConnectionTag) return "com.apple.trustd";
    return original_name(connection);
}

extern void original_activate(xpc_connection_t) __asm__("_xpc_connection_activate");
extern void original_resume(xpc_connection_t) __asm__("_xpc_connection_resume");
static void registerActivatedService(xpc_connection_t connection) {
    for (int i = 0; i < runtimeServiceCount; ++i) {
        if (connection != runtimeServices[i].listener || runtimeServices[i].registered) continue;
        runtimeServices[i].registered = true;
        registerService(connection, runtimeServices[i].registration);
        fprintf(stderr, "[endpoint] runtime %s ready\n", runtimeServices[i].name);
    }
}
static void activateService(xpc_connection_t connection) {
    original_activate(connection);
    registerActivatedService(connection);
}
static void resumeService(xpc_connection_t connection) {
    original_resume(connection);
    registerActivatedService(connection);
}

extern void SecSetCustomHomeURL(CFURLRef);
__attribute__((constructor)) static void configureSecurityHome(void) {
    const char *service = getenv("IOS_USE_RUNTIME_SERVICE");
    if (!service || (strcmp(service, "trust") && strcmp(service, "keychain"))) return;
    const char *home = getenv("CFFIXED_USER_HOME");
    if (!home) exit(20);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)home, strlen(home), true);
    SecSetCustomHomeURL(url);
    CFRelease(url);
}

static xpc_connection_t routeMachService(const char *name, dispatch_queue_t queue, uint64_t flags) {
    for (int i = 0; name && i < runtimeServiceCount; ++i) {
        if (strcmp(name, runtimeServices[i].name)) continue;
        if (flags & XPC_CONNECTION_MACH_SERVICE_LISTENER) {
            runtimeServices[i].listener = xpc_connection_create(NULL, queue);
            return runtimeServices[i].listener;
        }
        pthread_once(&endpointsOnce, loadEndpoints);
        xpc_endpoint_t endpoint = *runtimeServices[i].endpoint;
        fprintf(stderr, "[endpoint] %s -> %s\n", name, endpoint ? "standalone runtime service" : "disabled");
        xpc_connection_t connection = connectEndpoint(endpoint, queue);
        if (i == 0) xpc_connection_set_context(connection, (void *)&trustConnectionTag);
        return connection;
    }

    // The mapdb interface is sufficient for these type queries. Keep the
    // daemon's other listeners anonymous; no global launchd services are added.
    if (name && !strncmp(name, "com.apple.lsd.", 14) && (flags & XPC_CONNECTION_MACH_SERVICE_LISTENER)) {
        return xpc_connection_create(NULL, queue);
    }
    const char *service = getenv("IOS_USE_RUNTIME_SERVICE");
    if (service && !strcmp(service, "keychain") && (flags & XPC_CONNECTION_MACH_SERVICE_LISTENER)) {
        // Local SecItem operations need only securityd's main listener.
        return xpc_connection_create(NULL, queue);
    }
    const char *prefix = "com.apple.metal.simulator";
    size_t length = strlen(prefix);
    if (name && strncmp(name, prefix, length) == 0 && (name[length] == 0 || name[length] == '.')) {
        pthread_once(&endpointsOnce, loadEndpoints);
        fprintf(stderr, "[endpoint] Metal -> %s\n", metalEndpoint ? "standalone host" : "disabled");
        // MTLSimDriver itself selects the sim-to-host wire format on this connection.
        return connectEndpoint(metalEndpoint, queue);
    }
    if (name && strcmp(name, "com.apple.IOSurface.Remote") == 0) {
        pthread_once(&endpointsOnce, loadEndpoints);
        fprintf(stderr, "[endpoint] IOSurface -> %s\n", surfaceEndpoint ? "standalone host" : "disabled");
        return connectEndpoint(surfaceEndpoint, queue);
    }
    return original_mach_service(name, queue, flags);
}

static xpc_connection_t routeCompiler(const char *name, dispatch_queue_t queue) {
    if (name && strcmp(name, "com.apple.MTLCompilerService") == 0) {
        pthread_once(&endpointsOnce, loadEndpoints);
        fprintf(stderr, "[endpoint] compiler -> %s\n", compilerEndpoint ? "standalone runtime service" : "disabled");
        return connectEndpoint(compilerEndpoint, queue);
    }
    return original_service(name, queue);
}

static void standaloneXPCMain(void (*handler)(xpc_connection_t)) {
    dispatch_queue_t queue = dispatch_queue_create("iosuse.runtime-probe.compiler", DISPATCH_QUEUE_SERIAL);
    xpc_connection_t listener = xpc_connection_create(NULL, queue);
    xpc_connection_set_event_handler(listener, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_CONNECTION) {
            // Normal XPC instances isolate compiler state in separate processes.
            // Our single service must serialize requests across all connections:
            // parallel CoreAnimation specialization otherwise crashes in LLVM.
            xpc_connection_set_target_queue((xpc_connection_t)event, queue);
            handler((xpc_connection_t)event);
        }
    });
    xpc_connection_activate(listener);
    registerService(listener, RuntimeCompilerReady);
    fprintf(stderr, "[endpoint] runtime compiler ready\n");
    dispatch_main();
}

__attribute__((used, section("__DATA,__interpose"))) static const struct {
    const void *replacement;
    const void *original;
} replacements[] = {
    {(void *)serviceName, (void *)original_name},
    {(void *)activateService, (void *)original_activate},
    {(void *)resumeService, (void *)original_resume},
    {(void *)routeMachService, (void *)original_mach_service},
    {(void *)routeCompiler, (void *)original_service},
    {(void *)standaloneXPCMain, (void *)original_xpc_main}
};
