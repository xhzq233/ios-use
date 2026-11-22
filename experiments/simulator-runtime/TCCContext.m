// Supply app metadata and the host's prompt transport. Runtime tccd still owns
// CFUserNotification objects, callbacks, and authorization decisions.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach/mach.h>

@interface NSObject (TCCIdentityAPI)
- (NSString *)identifier;
@end

static NSBundle *app;
static id (*originalDisplayName)(id, SEL);
static mach_port_t (*notificationPort)(void);

extern kern_return_t originalLookup2(mach_port_t, const char *, mach_port_t *, pid_t, uint64_t) __asm__("_bootstrap_look_up2");
static kern_return_t notificationLookup(mach_port_t bootstrap, const char *name, mach_port_t *port, pid_t target, uint64_t flags) {
    if (notificationPort && !strcmp(name, "com.apple.SBUserNotification")) {
        mach_port_t destination = notificationPort();
        if (destination) {
            kern_return_t result = mach_port_mod_refs(mach_task_self(), destination, MACH_PORT_RIGHT_SEND, 1);
            if (!result) *port = destination;
            return result;
        }
    }
    return originalLookup2(bootstrap, name, port, target, flags);
}
__attribute__((used, section("__DATA,__interpose")))
static const struct { const void *replacement; const void *original; } notificationInterpose = {
    (const void *)&notificationLookup, (const void *)&originalLookup2
};

static id displayName(id self, SEL cmd) {
    id result = originalDisplayName(self, cmd);
    if (!result && [[self identifier] isEqual:app.bundleIdentifier]) {
        result = [app objectForInfoDictionaryKey:@"CFBundleDisplayName"]
            ?: [app objectForInfoDictionaryKey:@"CFBundleName"];
        NSLog(@"[tcc-context] supplied app display name=%@", result);
    }
    return result;
}

__attribute__((constructor)) static void configure(void) {
    const char *service = getenv("IOS_USE_RUNTIME_SERVICE");
    const char *path = getenv("IOS_USE_RUNTIME_APP_PATH");
    if (!service || strcmp(service, "tcc") || !path) return;
    notificationPort = dlsym(RTLD_DEFAULT, "IOSUseUserNotificationPort");
    app = [NSBundle bundleWithPath:@(path)];
    Method method = class_getInstanceMethod(NSClassFromString(@"TCCDAccessIdentity"), @selector(displayName));
    if (method) originalDisplayName = (void *)method_setImplementation(method, (IMP)displayName);
}
