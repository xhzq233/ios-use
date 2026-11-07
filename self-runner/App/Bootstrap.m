#import "Bootstrap.h"
#import <dlfcn.h>
#import <objc/message.h>

static BOOL fail(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"IOSUseSelfRunner" code:1
                                     userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}
BOOL SRLoadXCTest(NSError **error) {
    for (NSString *name in @[@"XCTest", @"XCTestCore", @"XCTAutomationSupport", @"XCUIAutomation"]) {
        BOOL loaded = NO;
        NSMutableArray<NSString *> *failures = [NSMutableArray new];
        for (NSString *root in @[@"/System/Developer/Library/Frameworks", @"/System/Developer/Library/PrivateFrameworks", @"/Developer/Library/Frameworks", @"/Developer/Library/PrivateFrameworks"]) {
            NSString *path = [NSString stringWithFormat:@"%@/%@.framework/%@", root, name, name];
            if (dlopen(path.UTF8String, RTLD_NOW | RTLD_GLOBAL)) { loaded = YES; break; }
            const char *detail = dlerror();
            if (detail) [failures addObject:[NSString stringWithUTF8String:detail]];
        }
        if ([name isEqualToString:@"XCTest"] && !loaded)
            return fail(error, [NSString stringWithFormat:@"XCTest could not be loaded from the mounted DDI: %@", [failures componentsJoinedByString:@"; "]]);
    }
    return YES;
}
BOOL SRInitializeXCTest(NSError **error) {
    @try {
        Class configurationClass = NSClassFromString(@"XCTestConfiguration");
        SEL setActive = NSSelectorFromString(@"setActiveTestConfiguration:");
        if (!configurationClass || ![configurationClass respondsToSelector:setActive])
            return fail(error, @"XCTest UI configuration is unavailable");
        id configuration = [configurationClass new];
        [configuration setValue:@YES forKey:@"initializeForUITesting"];
        [configuration setValue:@YES forKey:@"testsMustRunOnMainThread"];
        [configuration setValue:@NO forKey:@"reportResultsToIDE"];
        NSString *identifier = [NSProcessInfo processInfo].environment[@"XCTestSessionIdentifier"];
        if (identifier) [configuration setValue:[[NSUUID alloc] initWithUUIDString:identifier] forKey:@"sessionIdentifier"];
        ((void (*)(id, SEL, id))objc_msgSend)(configurationClass, setActive, configuration);
        Class cls = NSClassFromString(@"XCTRunnerDaemonSession");
        SEL initiate = NSSelectorFromString(@"initiateSharedSessionWithCompletion:");
        if (!cls || ![cls respondsToSelector:initiate]) return fail(error, @"XCTest daemon session initialization is unavailable");
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block id failure = nil;
        ((void (*)(id, SEL, id))objc_msgSend)(cls, initiate, ^(id result) {
            if ([result isKindOfClass:[NSError class]]) failure = result;
            dispatch_semaphore_signal(sem);
        });
        if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_SEC)))
            return fail(error, @"XCTest daemon registration timed out after 90 seconds");
        if (failure) return fail(error, [failure localizedDescription]);
        SEL shared = NSSelectorFromString(@"sharedSession");
        id session = ((id (*)(id, SEL))objc_msgSend)(cls, shared);
        SEL enable = NSSelectorFromString(@"enableAutomationModeWithError:");
        if (!session || ![session respondsToSelector:enable]) return fail(error, @"Automation mode is unavailable");
        NSError *underlying = nil;
        BOOL ok = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(session, enable, &underlying);
        if (!ok || underlying) return fail(error, underlying.localizedDescription ?: @"Automation mode was refused");
        return YES;
    } @catch (NSException *exception) { return fail(error, exception.reason ?: @"XCTest initialization exception"); }
}
BOOL SRLoadRuntime(NSError **error) {
    NSString *path = [[NSBundle mainBundle].privateFrameworksPath stringByAppendingPathComponent:@"IOSUseSelfRunnerRuntime.framework/IOSUseSelfRunnerRuntime"];
    if (!dlopen(path.UTF8String, RTLD_NOW | RTLD_GLOBAL))
        return fail(error, [NSString stringWithUTF8String:dlerror() ?: "Could not load automation runtime"]);
    return YES;
}
NSDictionary *SRExecute(NSString *command, NSDictionary *arguments, NSError **error) {
    @try {
        Class cls = NSClassFromString(@"IOSUseSelfRunnerDriver");
        SEL execute = NSSelectorFromString(@"execute:arguments:error:");
        if (!cls || ![cls respondsToSelector:execute]) { fail(error, @"Automation runtime is not loaded"); return nil; }
        return ((id (*)(id, SEL, id, id, NSError **))objc_msgSend)(cls, execute, command, arguments, error);
    } @catch (NSException *exception) { fail(error, exception.reason ?: @"Automation exception"); return nil; }
}
void SRStopAutomation(void) {
    @try {
        Class cls = NSClassFromString(@"XCTRunnerDaemonSession");
        id session = [cls respondsToSelector:NSSelectorFromString(@"sharedSession")] ? ((id (*)(id, SEL))objc_msgSend)(cls, NSSelectorFromString(@"sharedSession")) : nil;
        SEL disable = NSSelectorFromString(@"disableAutomationModeWithError:");
        if ([session respondsToSelector:disable]) {
            NSError *error = nil;
            ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(session, disable, &error);
        }
    } @catch (NSException *exception) { NSLog(@"[session] stop: %@", exception.reason); }
}
