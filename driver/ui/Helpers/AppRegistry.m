#import "AppRegistry.h"

#import <objc/message.h>

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleId;
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
