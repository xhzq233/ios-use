// Diagnostic for one scene: uses a local host when linked, otherwise an existing service namespace.
// Delivers a local scene through FrontBoardServices without calling AppDelegate.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

@interface NSObject (SceneBootstrapAPI)
- (id)_workspace;
- (void)_registerSourceEndpoint:(id)endpoint;
- (CGRect)bounds;
- (id)machQueue;
- (void)performAsync:(void (^)(void))block;
- (id)scenes;
+ (id)specification;
+ (id)parametersForSpecification:(id)specification;
- (id)settings;
- (void)setSettings:(id)settings;
- (void)setDisplay:(id)display;
+ (id)identityForIdentifier:(NSString *)identifier workspaceIdentifier:(NSString *)workspace;
- (void)createSceneWithIdentity:(id)identity parameters:(id)parameters
             transitionContext:(id)transition completion:(void (^)(id))completion;
@end

__attribute__((constructor)) static void installSceneBootstrap(void) {
    // Give UIKit's workspace endpoint monitor time to register its scene source.
    // This delay is specific to the diagnostic, not an application readiness API.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        id workspace = [UIApplication.sharedApplication _workspace];
        id (*localEndpoint)(void) = dlsym(RTLD_DEFAULT, "IOSUseLocalSceneEndpoint");
        if (localEndpoint) [workspace _registerSourceEndpoint:localEndpoint()];
        id (*localDisplay)(void) = dlsym(RTLD_DEFAULT, "IOSUseLocalDisplayConfiguration");
        id display = localDisplay ? localDisplay() : [UIScreen.mainScreen valueForKey:@"_displayConfiguration"];
        CGRect frame = localDisplay ? [display bounds] : UIScreen.mainScreen.bounds;
        NSString *identifier = [@"sceneID:" stringByAppendingFormat:@"%@-default",
                                NSBundle.mainBundle.bundleIdentifier];
        [[workspace machQueue] performAsync:^{
            Ivar sourcesIvar = class_getInstanceVariable(object_getClass(workspace),
                                                        "_queue_identifierToScenesSource");
            if (!sourcesIvar) {
                NSLog(@"[scene-bootstrap] workspace layout is unsupported");
                return;
            }
            NSDictionary *sources = object_getIvar(workspace, sourcesIvar);
            // Keys are FBSWorkspaceScenesClientIdentifier objects, not service-name strings.
            id client = sources.count == 1 ? sources.allValues.firstObject : nil;
            if (![client isKindOfClass:NSClassFromString(@"FBSWorkspaceScenesClient")] || [[client scenes] count]) {
                NSLog(@"[scene-bootstrap] expected one empty scene source");
                return;
            }
            id specification = [NSClassFromString(@"UIApplicationSceneSpecification") specification];
            id parameters = [NSClassFromString(@"FBSMutableSceneParameters")
                             parametersForSpecification:specification];
            id settings = [[parameters settings] mutableCopy];
            [settings setValue:@YES forKey:@"foreground"];
            [settings setValue:[NSValue valueWithCGRect:frame] forKey:@"frame"];
            [settings setValue:@1 forKey:@"interfaceOrientation"];
            [parameters setSettings:settings];
            [parameters setDisplay:display];
            // A workspace identifier is required to construct the scene identity token.
            id identity = [NSClassFromString(@"FBSSceneIdentity")
                           identityForIdentifier:identifier workspaceIdentifier:@"FBSceneManager"];
            NSLog(@"[scene-bootstrap] delivering local scene creation");
            [client createSceneWithIdentity:identity parameters:parameters transitionContext:nil
                                 completion:^(id result) {
                NSLog(@"[scene-bootstrap] scene completion: %@", result);
            }];
        }];
    });
}
