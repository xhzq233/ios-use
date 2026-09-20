// Route libnotify to an owned runtime notifyd, without a launchd namespace.
#include <mach/mach.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <xpc/xpc.h>
#include <Block.h>
#include "ServicePorts.h"

#define BOOTSTRAP_UNKNOWN_SERVICE 1102
extern kern_return_t original_checkin(mach_port_t, const char *, mach_port_t *) __asm__("_bootstrap_check_in");
extern kern_return_t original_lookup(mach_port_t, const char *, mach_port_t *, pid_t, uint64_t) __asm__("_bootstrap_look_up2");
extern int original_shm(const char *, int, ...) __asm__("_shm_open");

static kern_return_t checkin(mach_port_t bootstrap, const char *name, mach_port_t *port) {
    if (strcmp(name, "com.apple.system.notification_center")) return original_checkin(bootstrap, name, port);
    kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, port);
    if (kr) return kr;
    kr = mach_port_insert_right(mach_task_self(), *port, *port, MACH_MSG_TYPE_MAKE_SEND);
    if (kr) return kr;
    mach_port_array_t ports = NULL;
    mach_msg_type_number_t count = 0;
    kr = mach_ports_lookup(mach_task_self(), &ports, &count);
    if (kr || !count) return KERN_FAILURE;
    struct {
        mach_msg_header_t header;
        mach_msg_body_t body;
        mach_msg_port_descriptor_t port;
    } message = {0};
    message.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
    message.header.msgh_size = sizeof(message);
    message.header.msgh_remote_port = ports[0];
    message.header.msgh_id = RuntimeNotifyReady;
    message.body.msgh_descriptor_count = 1;
    message.port.name = *port;
    message.port.type = MACH_MSG_PORT_DESCRIPTOR;
    message.port.disposition = MACH_MSG_TYPE_COPY_SEND;
    kr = mach_msg(&message.header, MACH_SEND_MSG, sizeof(message), 0, 0, 0, 0);
    for (unsigned i = 0; i < count; ++i) mach_port_deallocate(mach_task_self(), ports[i]);
    vm_deallocate(mach_task_self(), (vm_address_t)ports, count * sizeof(mach_port_t));
    fprintf(stderr, "[endpoint] runtime notify ready=%d\n", kr);
    return kr;
}

static kern_return_t lookup(mach_port_t bootstrap, const char *name, mach_port_t *port, pid_t pid, uint64_t flags) {
    if (strcmp(name, "com.apple.system.notification_center")) return original_lookup(bootstrap, name, port, pid, flags);
    mach_port_array_t ports = NULL;
    mach_msg_type_number_t count = 0;
    kern_return_t kr = mach_ports_lookup(mach_task_self(), &ports, &count);
    if (kr) return kr;
    *port = count > 1 ? ports[1] : MACH_PORT_NULL;
    for (unsigned i = 0; i < count; ++i) {
        if (i != 1) mach_port_deallocate(mach_task_self(), ports[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)ports, count * sizeof(mach_port_t));
    return *port ? KERN_SUCCESS : BOOTSTRAP_UNKNOWN_SERVICE;
}

static int sharedMemory(const char *name, int flags, mode_t mode) {
    const char *isolated = getenv("IOS_USE_RUNTIME_NOTIFY_SHM");
    if (isolated && !strcmp(name, "apple.shm.notification_center")) name = isolated;
    return original_shm(name, flags, mode);
}

// There are no launchd-triggered subscriptions in this harness. Deliver the
// empty initial list so notifyd starts its actual Mach server. Direct client
// registrations, posting, shared state, and callbacks remain Apple's code.
// The installed runtime's publisher handler uses action 2 for this barrier;
// see Apple's Libnotify/notifyd/notifyd.c for the corresponding startup flow.
typedef void (^PublisherHandler)(unsigned, uint64_t, xpc_object_t);
extern void *original_publisher_create(const char *, dispatch_queue_t) __asm__("_xpc_event_publisher_create");
extern void original_publisher_handler(void *, PublisherHandler) __asm__("_xpc_event_publisher_set_handler");
extern void original_publisher_activate(void *) __asm__("_xpc_event_publisher_activate");
static void *publisher;
static dispatch_queue_t publisherQueue;
static PublisherHandler publisherHandler;

static void *createPublisher(const char *name, dispatch_queue_t queue) {
    void *result = original_publisher_create(name, queue);
    const char *service = getenv("IOS_USE_RUNTIME_SERVICE");
    if (service && !strcmp(service, "notify") && !strcmp(name, "com.apple.notifyd.matching")) {
        publisher = result;
        publisherQueue = queue;
    }
    return result;
}

static void setPublisherHandler(void *object, PublisherHandler handler) {
    if (object != publisher) { original_publisher_handler(object, handler); return; }
    publisherHandler = Block_copy(handler);
}

static void activatePublisher(void *object) {
    if (object != publisher) { original_publisher_activate(object); return; }
    dispatch_async(publisherQueue, ^{
        publisherHandler(2, 0, NULL);
        fprintf(stderr, "[endpoint] notify empty launch subscriptions ready\n");
    });
}

__attribute__((used, section("__DATA,__interpose"))) static const struct {
    const void *replacement;
    const void *original;
} replacements[] = {
    {(void *)createPublisher, (void *)original_publisher_create},
    {(void *)setPublisherHandler, (void *)original_publisher_handler},
    {(void *)activatePublisher, (void *)original_publisher_activate},
    {(void *)checkin, (void *)original_checkin},
    {(void *)lookup, (void *)original_lookup},
    {(void *)sharedMemory, (void *)original_shm}
};
