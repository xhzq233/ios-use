// Registration-only peer for the single-app experiment; does not inject input.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <xpc/xpc.h>
#import <unistd.h>

@interface NSObject (LocalInputAPI)
- (id)initWithXPCDictionary:(xpc_object_t)dictionary;
+ (id)connectionWithEndpoint:(id)endpoint;
@end

static id (*originalConnection)(id, SEL, NSString *);

static BOOL acceptRegistration(xpc_object_t event) {
    if (xpc_get_type(event) != XPC_TYPE_DICTIONARY) return NO;
    xpc_object_t batch = xpc_dictionary_get_value(event, "bsxpc_BATCH");
    if (batch && xpc_get_type(batch) == XPC_TYPE_ARRAY) {
        return xpc_array_apply(batch, ^bool(size_t index, xpc_object_t request) { return acceptRegistration(request); });
    }
    const char *operation = xpc_dictionary_get_string(event, "bsxpc");
    const char *selector = xpc_dictionary_get_string(event, "bsxpc_SEL");
    if (operation && strcmp(operation, "connect") == 0) return YES;
    if (selector && strcmp(selector, "submitRuleChanges:") == 0) {
        // No delivery result is returned by this notification. UIKit can register
        // its window; routing these rules and delivering HID events remain work.
        fprintf(stderr, "[local-input] received delivery rule registration\n");
        return YES;
    }
    fprintf(stderr, "[local-input] unsupported request: %s\n", operation ?: selector ?: "unknown");
    return NO;
}

static id connectionForService(id factory, SEL selector, NSString *service) {
    if (![service isEqualToString:@"BKHIDEventDeliveryManager"]) return originalConnection(factory, selector, service);
    static xpc_connection_t listener;
    static id endpoint;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        listener = xpc_connection_create(NULL, NULL);
        xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
            if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) return;
            xpc_connection_set_event_handler(peer, ^(xpc_object_t event) {
                if (xpc_get_type(event) != XPC_TYPE_DICTIONARY) return;
                if (!acceptRegistration(event)) { xpc_connection_cancel(peer); return; }
                xpc_object_t reply = xpc_dictionary_create_reply(event);
                if (reply) xpc_connection_send_message(peer, reply);
            });
            xpc_connection_activate(peer);
        });
        xpc_connection_activate(listener);
        xpc_object_t dictionary = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_value(dictionary, "e", xpc_endpoint_create(listener));
        xpc_dictionary_set_string(dictionary, "s", service.UTF8String);
        xpc_dictionary_set_string(dictionary, "t", "iosuse.input-registration");
        xpc_dictionary_set_int64(dictionary, "p", getpid());
        endpoint = [[NSClassFromString(@"BSServiceConnectionEndpoint") alloc] initWithXPCDictionary:dictionary];
    });
    return [NSClassFromString(@"BSServiceConnection") connectionWithEndpoint:endpoint];
}

__attribute__((constructor)) static void initializeInput(void) {
    Method method = class_getInstanceMethod(NSClassFromString(@"BKSHIDServiceConnectionFactory"), @selector(clientConnectionForServiceWithName:));
    originalConnection = (void *)method_setImplementation(method, (IMP)connectionForService);
}
