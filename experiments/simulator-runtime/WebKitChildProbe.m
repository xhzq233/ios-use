// Diagnostic child: Apple WebKit retains its own IPC and entitlement checks.
#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#import <xpc/xpc.h>
#import <mach/mach.h>
extern void ExtensionEventHandler(xpc_connection_t);
extern mach_port_t xpc_endpoint_copy_listener_port_4sim(xpc_endpoint_t);
int main(void) {
    @autoreleasepool {
        mach_port_array_t ports; mach_msg_type_number_t count;
        if (mach_ports_lookup(mach_task_self(), &ports, &count) || count < 3 || !ports[2]) return 120;
        xpc_connection_t listener = xpc_connection_create(NULL, dispatch_get_global_queue(0,0));
        xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
            if (xpc_get_type(peer) == XPC_TYPE_CONNECTION) ExtensionEventHandler(peer);
        });
        xpc_connection_activate(listener);
        struct { mach_msg_header_t header; mach_msg_body_t body; mach_msg_port_descriptor_t port; } msg = {0};
        msg.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
        msg.header.msgh_size = sizeof(msg); msg.header.msgh_remote_port = ports[2]; msg.header.msgh_id = 601;
        msg.body.msgh_descriptor_count = 1; msg.port.name = xpc_endpoint_copy_listener_port_4sim(xpc_endpoint_create(listener));
        msg.port.disposition = MACH_MSG_TYPE_MOVE_SEND; msg.port.type = MACH_MSG_PORT_DESCRIPTOR;
        if (mach_msg(&msg.header, MACH_SEND_MSG, sizeof(msg), 0, 0, 0, 0)) return 121;
        for (unsigned i = 0; i < count; i++) if (ports[i]) mach_port_deallocate(mach_task_self(), ports[i]);
        vm_deallocate(mach_task_self(), (vm_address_t)ports, count * sizeof(mach_port_t));
        fprintf(stderr, "[webkit-child] ready pid=%d\n", getpid());
        [NSTimer scheduledTimerWithTimeInterval:3600 repeats:YES block:^(NSTimer *timer) { (void)listener; }];
        [[NSRunLoop mainRunLoop] run];
        fprintf(stderr, "[webkit-child] run loop ended\n");
    }
}
