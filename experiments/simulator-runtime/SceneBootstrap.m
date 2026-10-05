// Delivers local scenes through FrontBoardServices; UIKit invokes the app delegates.
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
+ (id)diffFromSettings:(id)before toSettings:(id)after;
- (void)sceneID:(id)identifier updateWithSettingsDiff:(id)diff
    transitionContext:(id)transition completion:(void (^)(id))completion;
- (void)sceneID:(id)identifier destroyWithTransitionContext:(id)transition completion:(void (^)(id))completion;
@end

static id localClient, localWorkspace, localDisplay;
static CGRect localFrame;
// Owned by the workspace queue, like FBSWorkspaceScenesClient itself.
static NSMutableDictionary<NSString *, NSDictionary *> *localScenes;

static void createScene(NSString *suffix) {
    NSString *identifier = [NSString stringWithFormat:@"sceneID:%@-%@", NSBundle.mainBundle.bundleIdentifier, suffix];
    if (localScenes[identifier]) return;
    id specification = [NSClassFromString(@"UIApplicationSceneSpecification") specification];
    id parameters = [NSClassFromString(@"FBSMutableSceneParameters") parametersForSpecification:specification];
    id settings = [[parameters settings] mutableCopy];
    [settings setValue:@YES forKey:@"foreground"];
    [settings setValue:[NSValue valueWithCGRect:localFrame] forKey:@"frame"];
    [settings setValue:@1 forKey:@"interfaceOrientation"];
    [parameters setSettings:settings];
    [parameters setDisplay:localDisplay];
    id identity = [NSClassFromString(@"FBSSceneIdentity") identityForIdentifier:identifier workspaceIdentifier:@"FBSceneManager"];
    localScenes[identifier] = @{@"identity": identity, @"settings": [settings copy]};
    [localClient createSceneWithIdentity:identity parameters:parameters transitionContext:nil completion:^(id result) {
        NSLog(@"[scene-bootstrap] scene creation completion: %@", result);
    }];
}

// Diagnostic entry point. Public UIApplication session activation requests
// still need a workspace host; this exercises the real session/delegate path.
void IOSUseCreateAdditionalScene(NSString *suffix) {
    if (!localClient || !suffix.length) return;
    [[localWorkspace machQueue] performAsync:^{ createScene(suffix); }];
}

void IOSUseSetSceneForeground(NSString *identifier, BOOL foreground) {
    if (!localClient) return;
    [[localWorkspace machQueue] performAsync:^{
        NSDictionary *record = localScenes[identifier];
        if (!record || [record[@"closing"] boolValue]) return;
        id settings = [record[@"settings"] mutableCopy];
        [settings setValue:@(foreground) forKey:@"foreground"];
        id diff = [NSClassFromString(@"FBSSceneSettingsDiff") diffFromSettings:record[@"settings"] toSettings:settings];
        localScenes[identifier] = @{@"identity": record[@"identity"], @"settings": [settings copy]};
        [localClient sceneID:record[@"identity"] updateWithSettingsDiff:diff transitionContext:nil completion:^(id result) {
            NSLog(@"[scene-bootstrap] foreground=%d completion=%@", foreground, result);
        }];
    }];
}

void IOSUseDestroyScene(NSString *identifier) {
    if (!localClient) return;
    [[localWorkspace machQueue] performAsync:^{
        NSDictionary *record = localScenes[identifier];
        if (!record || [record[@"closing"] boolValue]) return;
        NSMutableDictionary *closing = [record mutableCopy];
        closing[@"closing"] = @YES;
        localScenes[identifier] = closing;
        [localClient sceneID:record[@"identity"] destroyWithTransitionContext:nil completion:^(id result) {
            dispatch_async(dispatch_get_main_queue(), ^{
                void (*retireWeb)(NSString *) = dlsym(RTLD_DEFAULT, "IOSUseRetireWebViewsForScene");
                if (retireWeb) retireWeb(identifier);
                void (*retire)(NSString *) = dlsym(RTLD_DEFAULT, "IOSUseRetireScene");
                if (retire) retire(identifier);
                // A same-name replacement must not attach to the old canvas or
                // be removed by this older destruction completion.
                [[localWorkspace machQueue] performAsync:^{ [localScenes removeObjectForKey:identifier]; }];
            });
            NSLog(@"[scene-bootstrap] scene destruction completion: %@", result);
        }];
    }];
}

static void (*originalMakeKeyAndVisible)(UIWindow *, SEL);
static void showLegacyWindow(UIWindow *window, SEL selector) {
    if (!window.windowScene) {
        NSMutableArray<UIWindowScene *> *scenes = [NSMutableArray new];
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:UIWindowScene.class]) [scenes addObject:(UIWindowScene *)scene];
        }
        // Adopt a legacy AppDelegate window only with an unambiguous owner.
        if (scenes.count == 1) window.windowScene = scenes.firstObject;
    }
    originalMakeKeyAndVisible(window, selector);
}

__attribute__((constructor)) static void installSceneBootstrap(void) {
    Method show = class_getInstanceMethod(NSClassFromString(@"UIWindow"), @selector(makeKeyAndVisible));
    originalMakeKeyAndVisible = (void *)method_setImplementation(show, (IMP)showLegacyWindow);
    // Diagnostic delay lets UIKit register its workspace source; not a readiness API.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        id workspace = [UIApplication.sharedApplication _workspace];
        id (*localEndpoint)(void) = dlsym(RTLD_DEFAULT, "IOSUseLocalSceneEndpoint");
        if (localEndpoint) [workspace _registerSourceEndpoint:localEndpoint()];
        id (*displayProvider)(void) = dlsym(RTLD_DEFAULT, "IOSUseLocalDisplayConfiguration");
        id display = displayProvider ? displayProvider() : [UIScreen.mainScreen valueForKey:@"_displayConfiguration"];
        CGRect frame = displayProvider ? [display bounds] : UIScreen.mainScreen.bounds;
        [[workspace machQueue] performAsync:^{
            Ivar sourcesIvar = class_getInstanceVariable(object_getClass(workspace), "_queue_identifierToScenesSource");
            if (!sourcesIvar) { NSLog(@"[scene-bootstrap] workspace layout is unsupported"); return; }
            NSDictionary *sources = object_getIvar(workspace, sourcesIvar);
            id client = sources.count == 1 ? sources.allValues.firstObject : nil;
            if (![client isKindOfClass:NSClassFromString(@"FBSWorkspaceScenesClient")] || [[client scenes] count]) {
                NSLog(@"[scene-bootstrap] expected one empty scene source"); return;
            }
            localClient = client; localWorkspace = workspace;
            localDisplay = display; localFrame = frame;
            localScenes = [NSMutableDictionary new];
            createScene(@"default");
        }];
    });
}
