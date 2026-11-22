// Supply the owned filesystem containers normally resolved through containermanagerd.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSURL *containerURL(id self, SEL cmd) {
    NSString *path = @"Library/LaunchServices";
    if (cmd == NSSelectorFromString(@"userContainerURL")) path = [path stringByAppendingPathComponent:@"User"];
    return [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:path] isDirectory:YES];
}

static NSURL *preferencesURL(id self, SEL cmd) {
    return [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences/com.apple.launchservices.secure.plist"]];
}

__attribute__((constructor)) static void configure(void) {
    const char *role = getenv("IOS_USE_RUNTIME_SERVICE");
    if (!role || strcmp(role, "launchservices")) return;
    for (NSString *path in @[@"Library/LaunchServices/User", @"Library/Preferences"]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:[NSHomeDirectory() stringByAppendingPathComponent:path]
                                withIntermediateDirectories:YES attributes:nil error:nil];
    }
    Class cls = NSClassFromString(@"_LSDefaults");
    method_setImplementation(class_getInstanceMethod(cls, NSSelectorFromString(@"systemContainerURL")), (IMP)containerURL);
    method_setImplementation(class_getInstanceMethod(cls, NSSelectorFromString(@"userContainerURL")), (IMP)containerURL);
    method_setImplementation(class_getInstanceMethod(cls, NSSelectorFromString(@"securePreferencesFileURL")), (IMP)preferencesURL);
    fprintf(stderr, "[launchservices-context] configured owned containers\n");
}
