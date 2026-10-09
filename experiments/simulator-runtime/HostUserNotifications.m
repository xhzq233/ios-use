// Present the runtime's CFUserNotification Mach requests in the native host.
// CF notification objects, callbacks, and permission decisions remain in tccd.
#import <AppKit/AppKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <mach/mach.h>

@interface RuntimeUserNotification : NSObject
@property(nonatomic) mach_port_t reply;
@property(nonatomic) uint32_t flags;
@property(nonatomic, strong) NSDictionary *contents;
@end
@implementation RuntimeUserNotification
- (void)dealloc { if (_reply) mach_port_deallocate(mach_task_self(), _reply); }
@end

static CFMachPortRef notificationPort;
static NSMutableArray<RuntimeUserNotification *> *pending;
static RuntimeUserNotification *active;
static NSAlert *alert;
static BOOL stopping;
static void showNext(void);

@interface RuntimeNotificationPresenter : NSObject <NSWindowDelegate>
- (void)choose:(NSButton *)button;
@end
static RuntimeNotificationPresenter *presenter;

NSWindow *IOSUseUserNotificationWindow(void) { return alert.window; }

static void sendResponse(RuntimeUserNotification *request, uint32_t flags) {
    if (!request.reply) return;
    mach_msg_base_t response = {0};
    response.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
    response.header.msgh_size = sizeof(response);
    response.header.msgh_remote_port = request.reply;
    response.header.msgh_id = flags;
    kern_return_t sent = mach_msg(&response.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT,
                                  sizeof(response), 0, 0, 100, 0);
    if (sent) mach_msg_destroy(&response.header);
    request.reply = MACH_PORT_NULL;
    fprintf(stderr, "[host-prompt] response=%u sent=%d\n", flags, sent);
}

static void dismissActive(uint32_t response) {
    sendResponse(active, response);
    [alert.window orderOut:nil];
    alert.window.delegate = nil;
    active = nil; alert = nil;
    dispatch_async(dispatch_get_main_queue(), ^{ showNext(); });
}

@implementation RuntimeNotificationPresenter
- (void)choose:(NSButton *)button { dismissActive((uint32_t)button.tag); }
- (BOOL)windowShouldClose:(NSWindow *)window { dismissActive(3); return NO; }
@end

static void presentActive(void) {
    alert = [NSAlert new];
    alert.messageText = active.contents[@"AlertHeader"] ?: @"Application request";
    id message = active.contents[@"AlertMessage"];
    alert.informativeText = [message isKindOfClass:NSArray.class] ? [message componentsJoinedByString:@"\n"] : (message ?: @"");
    NSArray *keys = @[@"DefaultButtonTitle", @"AlternateButtonTitle", @"OtherButtonTitle"];
    for (NSUInteger index = 0; index < keys.count; index++) {
        NSString *title = active.contents[keys[index]];
        if (!title && index == 0 && !(active.flags & (1U << 5))) title = @"OK";
        if (!title) continue;
        NSButton *button = [alert addButtonWithTitle:title];
        button.keyEquivalent = @"";
        button.tag = index;
        button.target = presenter;
        button.action = @selector(choose:);
        // This response opens a Photos selection extension in SpringBoard.
        // Do not report a selection that this host cannot actually present.
        if (index == 1 && [active.contents[@"SBUserNotificationExtensionIdentifier"]
                isEqual:@"com.apple.mobileslideshow.PhotosTCCNotificationExtension"]) {
            button.enabled = NO;
            button.toolTip = @"Limited photo selection is not available in this experimental host.";
        }
    }
    if (!alert.buttons.count) { dismissActive(3); return; }
    [alert layout];
    alert.window.delegate = presenter;
    fprintf(stderr, "[host-prompt] showing buttons=%lu size=%.0fx%.0f\n", (unsigned long)alert.buttons.count,
            alert.window.contentView.bounds.size.width, alert.window.contentView.bounds.size.height);
    for (NSButton *button in alert.buttons) {
        NSRect rect = [button convertRect:button.bounds toView:alert.window.contentView];
        fprintf(stderr, "[host-prompt] button=%ld enabled=%d title=%s center=%.1f,%.1f\n",
                (long)button.tag, button.enabled, button.title.UTF8String, NSMidX(rect),
                alert.window.contentView.bounds.size.height - NSMidY(rect));
    }
    [alert.window center];
    [alert.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

static void showNext(void) {
    if (active || !pending.count || stopping) return;
    active = pending.firstObject;
    [pending removeObjectAtIndex:0];
    presentActive();
}

static void receiveNotification(CFMachPortRef port, void *bytes, CFIndex size, void *info) {
    mach_msg_base_t *message = bytes;
    if (size < sizeof(mach_msg_header_t)) return;
    if (size < sizeof(*message) || message->header.msgh_size < sizeof(*message) ||
        message->header.msgh_size > size || (message->header.msgh_bits & MACH_MSGH_BITS_COMPLEX)) {
        mach_msg_destroy(&message->header);
        return;
    }
    NSData *data = [NSData dataWithBytes:(uint8_t *)bytes + sizeof(*message)
                                 length:message->header.msgh_size - sizeof(*message)];
    NSDictionary *contents = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
    if (![contents isKindOfClass:NSDictionary.class]) { mach_msg_destroy(&message->header); return; }
    uint32_t flags = message->header.msgh_id;
    NSNumber *token = contents[@"Token"];
    if (flags & ((1U << 3) | (1U << 4))) {
        RuntimeUserNotification *request = [active.contents[@"Token"] isEqual:token] ? active : nil;
        if (!request) for (RuntimeUserNotification *candidate in pending)
            if ([candidate.contents[@"Token"] isEqual:token]) { request = candidate; break; }
        if (flags & (1U << 3)) {
            if (request == active && active) dismissActive(3);
            else if (request) { sendResponse(request, 3); [pending removeObject:request]; }
        } else if (request) {
            NSMutableDictionary *updated = [request.contents mutableCopy];
            [updated addEntriesFromDictionary:contents];
            request.contents = updated;
            if (request == active) {
                [alert.window orderOut:nil];
                alert.window.delegate = nil;
                presentActive();
            }
        }
        mach_msg_destroy(&message->header);
        return;
    }
    RuntimeUserNotification *request = [RuntimeUserNotification new];
    request.reply = message->header.msgh_remote_port;
    message->header.msgh_remote_port = MACH_PORT_NULL;
    request.contents = contents;
    request.flags = flags;
    [pending addObject:request];
    fprintf(stderr, "[host-prompt] request flags=%u extension=%d\n", flags, contents[@"SBUserNotificationExtensionIdentifier"] != nil);
    dispatch_async(dispatch_get_main_queue(), ^{ showNext(); });
    double timeout = [contents[@"Timeout"] doubleValue];
    if (timeout > 0) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            if (request == active) dismissActive(3);
            else if ([pending containsObject:request]) { sendResponse(request, 3); [pending removeObject:request]; }
        });
}

mach_port_t IOSUseCreateUserNotificationPort(void) {
    pending = [NSMutableArray new];
    presenter = [RuntimeNotificationPresenter new];
    notificationPort = CFMachPortCreate(NULL, receiveNotification, NULL, NULL);
    if (!notificationPort) return MACH_PORT_NULL;
    CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(NULL, notificationPort, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
    CFRelease(source);
    return CFMachPortGetPort(notificationPort);
}

void IOSUseStopUserNotifications(void) {
    stopping = YES;
    [pending removeAllObjects];
    if (active) {
        [alert.window orderOut:nil];
        alert.window.delegate = nil;
        active = nil; alert = nil;
    }
    if (notificationPort) { CFMachPortInvalidate(notificationPort); CFRelease(notificationPort); notificationPort = NULL; }
}
