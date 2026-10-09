#import "WebBridgeTransport.h"

typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_ool_descriptor_t payload;
    mach_msg_port_descriptor_t reply;
    mach_msg_port_descriptor_t surface;
} WebBridgeMessage;

void IOSUseSendWebMessage(mach_port_t destination, NSDictionary *payload,
                         mach_port_t replyPort, IOSurfaceRef surface) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
    if (!data) { NSLog(@"[web-bridge] cannot encode message: %@", error); exit(171); }
    if (mach_port_mod_refs(mach_task_self(), destination, MACH_PORT_RIGHT_SEND, 1)) {
        fprintf(stderr, "[web-bridge] destination unavailable\n"); exit(171);
    }
    if (replyPort && mach_port_mod_refs(mach_task_self(), replyPort, MACH_PORT_RIGHT_SEND, 1)) {
        mach_port_deallocate(mach_task_self(), destination); exit(171);
    }
    mach_port_t surfacePort = surface ? IOSurfaceCreateMachPort(surface) : MACH_PORT_NULL;
    static dispatch_queue_t sendQueue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sendQueue = dispatch_queue_create("iosuse.web-bridge.send", DISPATCH_QUEUE_SERIAL); });
    dispatch_async(sendQueue, ^{
        WebBridgeMessage message = {0};
        message.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
        message.header.msgh_size = sizeof(message);
        message.header.msgh_remote_port = destination;
        message.header.msgh_id = IOSUseWebBridgeMessageID;
        message.body.msgh_descriptor_count = 3;
        message.payload.address = (void *)data.bytes;
        message.payload.size = (mach_msg_size_t)data.length;
        message.payload.copy = MACH_MSG_VIRTUAL_COPY;
        message.payload.type = MACH_MSG_OOL_DESCRIPTOR;
        message.reply.name = replyPort;
        message.reply.disposition = MACH_MSG_TYPE_COPY_SEND;
        message.reply.type = MACH_MSG_PORT_DESCRIPTOR;
        message.surface.name = surfacePort;
        message.surface.disposition = MACH_MSG_TYPE_COPY_SEND;
        message.surface.type = MACH_MSG_PORT_DESCRIPTOR;
        kern_return_t sent = mach_msg(&message.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT,
            sizeof(message), 0, MACH_PORT_NULL, 1000, MACH_PORT_NULL);
        // COPY_SEND leaves all sender rights owned here, on success or failure.
        if (surfacePort) mach_port_deallocate(mach_task_self(), surfacePort);
        if (replyPort) mach_port_deallocate(mach_task_self(), replyPort);
        mach_port_deallocate(mach_task_self(), destination);
        if (sent) { fprintf(stderr, "[web-bridge] message send failed=%d\n", sent); exit(171); }
    });
}

NSDictionary *IOSUseDecodeWebMessage(mach_msg_header_t *header,
                                    mach_port_t *replyPort, IOSurfaceRef *surface) {
    *replyPort = MACH_PORT_NULL; *surface = NULL;
    WebBridgeMessage *message = (void *)header;
    if (header->msgh_id != IOSUseWebBridgeMessageID || header->msgh_size != sizeof(*message) ||
        !(header->msgh_bits & MACH_MSGH_BITS_COMPLEX) || message->body.msgh_descriptor_count != 3 ||
        message->payload.type != MACH_MSG_OOL_DESCRIPTOR || message->reply.type != MACH_MSG_PORT_DESCRIPTOR ||
        message->surface.type != MACH_MSG_PORT_DESCRIPTOR) {
        mach_msg_destroy(header); return nil;
    }
    NSData *data = [NSData dataWithBytes:message->payload.address length:message->payload.size];
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if ([object isKindOfClass:NSDictionary.class]) {
        *replyPort = message->reply.name;
        message->reply.name = MACH_PORT_NULL;
        if (message->surface.name) *surface = IOSurfaceLookupFromMachPort(message->surface.name);
    } else object = nil;
    mach_msg_destroy(header);
    return object;
}
