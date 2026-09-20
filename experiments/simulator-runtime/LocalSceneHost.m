// Minimal anonymous FrontBoard workspace peer for the single-scene diagnostic.
#import <Foundation/Foundation.h>
#import <xpc/xpc.h>
#import <unistd.h>

@interface NSObject (LocalSceneEndpointAPI)
- (id)initWithXPCDictionary:(xpc_object_t)dictionary;
@end

static BOOL acceptsRequest(xpc_object_t event) {
    if (xpc_get_type(event) != XPC_TYPE_DICTIONARY) return NO;
    xpc_object_t batch = xpc_dictionary_get_value(event, "bsxpc_BATCH");
    if (batch && xpc_get_type(batch) == XPC_TYPE_ARRAY) {
        return xpc_array_apply(batch, ^bool(size_t index, xpc_object_t request) {
            return acceptsRequest(request);
        });
    }
    const char *operation = xpc_dictionary_get_string(event, "bsxpc");
    const char *selector = xpc_dictionary_get_string(event, "bsxpc_SEL");
    BOOL connect = operation && strcmp(operation, "connect") == 0;
    BOOL handshake = selector && strcmp(selector, "handshakeWithRemnants:") == 0;
    BOOL update = selector && strcmp(selector, "sceneID:didUpdateClientSettingsWithDiff:transitionContext:completion:") == 0;
    fprintf(stderr, "[local-scene] %s\n", operation ?: selector ?: "unknown message");
    return connect || handshake || update;
}

id IOSUseLocalSceneEndpoint(void) {
    static xpc_connection_t listener;
    listener = xpc_connection_create(NULL, NULL);
    xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
        if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) return;
        xpc_connection_set_event_handler(peer, ^(xpc_object_t event) {
            if (xpc_get_type(event) != XPC_TYPE_DICTIONARY) return;
            if (!acceptsRequest(event)) {
                fprintf(stderr, "[local-scene] unsupported request; closing peer\n");
                xpc_connection_cancel(peer);
                return;
            }
            // The local host accepts connection setup and client settings notifications.
            // No application-launch, rendering, or lifecycle result is fabricated here.
            xpc_object_t reply = xpc_dictionary_create_reply(event);
            if (reply) xpc_connection_send_message(peer, reply);
        });
        xpc_connection_activate(peer);
    });
    xpc_connection_activate(listener);
    // BoardServices' own decoder wraps our anonymous endpoint. These field names
    // come from the installed runtime's initWithXPCDictionary: implementation.
    xpc_object_t dictionary = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_value(dictionary, "e", xpc_endpoint_create(listener));
    xpc_dictionary_set_string(dictionary, "s", "com.apple.frontboard.workspace-service");
    xpc_dictionary_set_string(dictionary, "t", "iosuse.local-scene");
    xpc_dictionary_set_int64(dictionary, "p", getpid());
    return [[NSClassFromString(@"BSServiceConnectionEndpoint") alloc] initWithXPCDictionary:dictionary];
}
