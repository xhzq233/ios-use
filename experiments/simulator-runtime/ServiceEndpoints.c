// Redirect GPU and IOSurface service discovery; retain Apple's implementations.
#include <mach/mach.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <xpc/xpc.h>

// Aliases allow use of these installed private symbols with the Simulator SDK.
extern xpc_connection_t original_mach_service(const char *, dispatch_queue_t, uint64_t)
    __asm__("_xpc_connection_create_mach_service");
extern xpc_connection_t original_service(const char *, dispatch_queue_t)
    __asm__("_xpc_connection_create");
extern void original_xpc_main(void (*)(xpc_connection_t)) __asm__("_xpc_main");
extern xpc_endpoint_t xpc_endpoint_create_mach_port_4sim(mach_port_t);
extern mach_port_t xpc_endpoint_copy_listener_port_4sim(xpc_endpoint_t);

static xpc_endpoint_t metalEndpoint, compilerEndpoint, surfaceEndpoint;
static pthread_once_t endpointsOnce = PTHREAD_ONCE_INIT;

static mach_port_t inheritedRendezvous(void) {
    mach_port_array_t ports = NULL;
    mach_msg_type_number_t count = 0;
    if (mach_ports_lookup(mach_task_self(), &ports, &count) || !count) exit(20);
    mach_port_t result = ports[0];
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
        mach_msg_port_descriptor_t ports[3];
        char trailer[512];
    } reply = {0};
    kern_return_t kr = mach_msg(&reply.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0,
                               sizeof(reply), replyPort, 5000, 0);
    if (kr || reply.header.msgh_id != 201 || reply.body.msgh_descriptor_count != 3) exit(20);
    metalEndpoint = xpc_endpoint_create_mach_port_4sim(reply.ports[0].name);
    compilerEndpoint = xpc_endpoint_create_mach_port_4sim(reply.ports[1].name);
    surfaceEndpoint = xpc_endpoint_create_mach_port_4sim(reply.ports[2].name);
    mach_port_mod_refs(mach_task_self(), replyPort, MACH_PORT_RIGHT_RECEIVE, -1);
    mach_port_deallocate(mach_task_self(), rendezvous);
}

static xpc_connection_t connectEndpoint(xpc_endpoint_t endpoint, dispatch_queue_t queue) {
    xpc_connection_t connection = xpc_connection_create_from_endpoint(endpoint);
    xpc_connection_set_target_queue(connection, queue);
    return connection;
}

static xpc_connection_t routeMachService(const char *name, dispatch_queue_t queue, uint64_t flags) {
    const char *prefix = "com.apple.metal.simulator";
    size_t length = strlen(prefix);
    if (name && strncmp(name, prefix, length) == 0 && (name[length] == 0 || name[length] == '.')) {
        pthread_once(&endpointsOnce, loadEndpoints);
        fprintf(stderr, "[endpoint] Metal -> standalone host\n");
        // MTLSimDriver itself selects the sim-to-host wire format on this connection.
        return connectEndpoint(metalEndpoint, queue);
    }
    if (name && strcmp(name, "com.apple.IOSurface.Remote") == 0) {
        pthread_once(&endpointsOnce, loadEndpoints);
        fprintf(stderr, "[endpoint] IOSurface -> standalone host\n");
        return connectEndpoint(surfaceEndpoint, queue);
    }
    return original_mach_service(name, queue, flags);
}

static xpc_connection_t routeCompiler(const char *name, dispatch_queue_t queue) {
    if (name && strcmp(name, "com.apple.MTLCompilerService") == 0) {
        pthread_once(&endpointsOnce, loadEndpoints);
        fprintf(stderr, "[endpoint] compiler -> standalone runtime service\n");
        return connectEndpoint(compilerEndpoint, queue);
    }
    return original_service(name, queue);
}

static void standaloneXPCMain(void (*handler)(xpc_connection_t)) {
    dispatch_queue_t queue = dispatch_queue_create("iosuse.runtime-probe.compiler", DISPATCH_QUEUE_SERIAL);
    xpc_connection_t listener = xpc_connection_create(NULL, queue);
    xpc_connection_set_event_handler(listener, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_CONNECTION) handler((xpc_connection_t)event);
    });
    xpc_connection_activate(listener);
    xpc_endpoint_t endpoint = xpc_endpoint_create(listener);
    struct {
        mach_msg_header_t header;
        mach_msg_body_t body;
        mach_msg_port_descriptor_t port;
    } registration = {0};
    registration.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
    registration.header.msgh_size = sizeof(registration);
    registration.header.msgh_remote_port = inheritedRendezvous();
    registration.header.msgh_id = 300;
    registration.body.msgh_descriptor_count = 1;
    registration.port.name = xpc_endpoint_copy_listener_port_4sim(endpoint);
    registration.port.type = MACH_MSG_PORT_DESCRIPTOR;
    registration.port.disposition = MACH_MSG_TYPE_COPY_SEND;
    if (mach_msg(&registration.header, MACH_SEND_MSG, sizeof(registration), 0, 0, 0, 0)) exit(20);
    fprintf(stderr, "[endpoint] runtime compiler ready\n");
    dispatch_main();
}

__attribute__((used, section("__DATA,__interpose"))) static const struct {
    const void *replacement;
    const void *original;
} replacements[] = {
    {(void *)routeMachService, (void *)original_mach_service},
    {(void *)routeCompiler, (void *)original_service},
    {(void *)standaloneXPCMain, (void *)original_xpc_main}
};
