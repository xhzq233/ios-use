#import "AppRegistry.h"

#import <objc/message.h>

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleId;
- (BOOL)openSensitiveURL:(NSURL *)url withOptions:(id)options;
@end

BOOL OpenApplicationWithBundleId(NSString *bundleId) {
    if (bundleId.length == 0) {
        return NO;
    }

    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (workspaceClass == Nil || ![workspaceClass respondsToSelector:@selector(defaultWorkspace)]) {
        return NO;
    }

    id workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, @selector(defaultWorkspace));
    if (workspace == nil) {
        return NO;
    }
    if (![workspace respondsToSelector:@selector(openApplicationWithBundleID:)]) {
        return NO;
    }
    return ((BOOL (*)(id, SEL, id))objc_msgSend)(workspace, @selector(openApplicationWithBundleID:), bundleId);
}

BOOL OpenURLViaLaunchServices(NSString *urlString) {
    if (urlString.length == 0) {
        return NO;
    }

    NSURL *url = [NSURL URLWithString:urlString];
    if (url == nil) {
        return NO;
    }

    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (workspaceClass == Nil || ![workspaceClass respondsToSelector:@selector(defaultWorkspace)]) {
        return NO;
    }

    id workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, @selector(defaultWorkspace));
    if (workspace == nil) {
        return NO;
    }
    if (![workspace respondsToSelector:@selector(openSensitiveURL:withOptions:)]) {
        return NO;
    }
    return ((BOOL (*)(id, SEL, id, id))objc_msgSend)(workspace, @selector(openSensitiveURL:withOptions:), url, nil);
}
