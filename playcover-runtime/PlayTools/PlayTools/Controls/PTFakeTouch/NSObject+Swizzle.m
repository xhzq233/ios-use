//
//  NSObject+PrivateSwizzle.m
//  PlayTools
//
//  Created by siri on 06.10.2021.
//

#import "NSObject+Swizzle.h"
#import <objc/runtime.h>
#import "CoreGraphics/CoreGraphics.h"
#import "UIKit/UIKit.h"
#import "IOSUsePlayDevice.h"
#import "IOSUsePlayHookRegistry.h"
#import "IOSUsePlaySwiftBridge.h"
#import "PTFakeMetaTouch.h"
#import <VideoSubscriberAccount/VideoSubscriberAccount.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMotion/CoreMotion.h>
#import <GameController/GameController.h>
#include <string.h>

__attribute__((visibility("hidden")))
@interface PTSwizzleLoader : NSObject
@end

static NSString *IOSUsePlayOptionalHookIdentifier(
    Class targetClass,
    SEL selector
) {
    return [NSString stringWithFormat:
        @"playtools.optional.%@.%@",
        targetClass == Nil
            ? @"unavailable"
            : NSStringFromClass(targetClass),
        selector == NULL
            ? @"unavailable"
            : NSStringFromSelector(selector)];
}

static void IOSUsePlayInstallRequiredIdentityHook(
    NSString *identifier,
    Class targetClass,
    SEL targetSelector,
    SEL replacementSelector,
    BOOL requiresDirectOwner,
    BOOL requiresFirstUseBeforeReady
) {
    NSError *error = nil;
    if (!IOSUsePlayHookRegistryInstallMethodAlias(
            identifier,
            YES,
            @"objc-load",
            targetClass,
            targetSelector,
            NSObject.class,
            replacementSelector,
            requiresDirectOwner,
            requiresFirstUseBeforeReady,
            &error
        )) {
        NSLog(
            @"[ios-use-play] required identity hook %@ failed: %@",
            identifier,
            error.localizedDescription ?: @"unknown failure"
        );
    }
}

@implementation NSObject (Swizzle)

- (void) swizzleInstanceMethod:(SEL)origSelector withMethod:(SEL)newSelector
{
    Class cls = [self class];
    (void)IOSUsePlayHookRegistryInstallMethodAlias(
        IOSUsePlayOptionalHookIdentifier(cls, origSelector),
        NO,
        @"objc-load",
        cls,
        origSelector,
        NSObject.class,
        newSelector,
        NO,
        NO,
        NULL
    );
}

- (void) swizzleExchangeMethod:(SEL)origSelector withMethod:(SEL)newSelector
{
    [self
        swizzleInstanceMethod:origSelector
        withMethod:newSelector];
}

+ (void) swizzleClassMethod:(SEL)origSelector withMethod:(SEL)newSelector {
    Class targetClass = (Class)self;
    Class dispatchClass = object_getClass(targetClass);
    Method originalMethod =
        class_getClassMethod(targetClass, origSelector);
    Method swizzledMethod =
        class_getClassMethod(targetClass, newSelector);
    const char *originalTypes = originalMethod == NULL
        ? NULL
        : method_getTypeEncoding(originalMethod);
    const char *replacementTypes = swizzledMethod == NULL
        ? NULL
        : method_getTypeEncoding(swizzledMethod);
    BOOL ready =
        dispatchClass != Nil &&
        originalMethod != NULL &&
        swizzledMethod != NULL &&
        originalTypes != NULL &&
        replacementTypes != NULL &&
        strcmp(originalTypes, replacementTypes) == 0;
    if (ready) {
        IMP original = class_getMethodImplementation(
            dispatchClass,
            origSelector
        );
        IMP replacement =
            method_getImplementation(swizzledMethod);
        ready = original != NULL &&
            replacement != NULL &&
            original != replacement &&
            class_addMethod(
                dispatchClass,
                newSelector,
                original,
                originalTypes
            );
        if (ready) {
            class_replaceMethod(
                dispatchClass,
                origSelector,
                replacement,
                originalTypes
            );
            ready = class_getMethodImplementation(
                dispatchClass,
                origSelector
            ) == replacement;
        }
    }
    IOSUsePlayHookRegistryRecordState(
        IOSUsePlayOptionalHookIdentifier(
            targetClass,
            origSelector
        ),
        NO,
        @"objc-load",
        targetClass == Nil
            ? @"unavailable"
            : NSStringFromClass(targetClass),
        origSelector == NULL
            ? @"unavailable"
            : NSStringFromSelector(origSelector),
        originalTypes == NULL
            ? @"unavailable"
            : [NSString stringWithUTF8String:originalTypes],
        NO,
        ready,
        ready ? nil : @"optional class-method hook failed"
    );
}

- (BOOL) hook_prefersPointerLocked {
    return false;
}

- (CGRect) hook_frameDefault {
    return [PlayScreen frameDefault:[self hook_frameDefault]];
}

- (CGRect) hook_boundsDefault {
    return [PlayScreen boundsDefault:[self hook_boundsDefault]];
}

- (CGRect) hook_nativeBoundsDefault {
    return [PlayScreen nativeBoundsDefault:[self hook_nativeBoundsDefault]];
}

- (CGSize) hook_sizeDelfault {
    return [PlayScreen sizeAspectRatioDefault:[self hook_sizeDelfault]];
}


- (CGRect) hook_frame {
    IOSUsePlayHookRegistryRecordFirstUse(
        @"playtools.screen.scene-frame",
        self.class
    );
    return [PlayScreen frame:[self hook_frame]];
}

- (CGRect) hook_bounds {
    IOSUsePlayHookRegistryRecordFirstUse(
        @"playtools.screen.scene-bounds",
        self.class
    );
    return [PlayScreen bounds:[self hook_bounds]];
}

- (CGRect) hook_nativeBounds {
    IOSUsePlayHookRegistryRecordFirstUse(
        @"playtools.screen.native-bounds",
        self.class
    );
    return [PlayScreen nativeBounds:[self hook_nativeBounds]];
}

- (CGSize) hook_size {
    IOSUsePlayHookRegistryRecordFirstUse(
        @"playtools.screen.display-size",
        self.class
    );
    return [PlayScreen sizeAspectRatio:[self hook_size]];
}



- (UIDeviceOrientation)iosUsePlayDeviceOrientation {
    IOSUsePlayHookRegistryRecordFirstUse(
        @"playtools.device.orientation",
        self.class
    );
    return (UIDeviceOrientation)IOSUsePlayDeviceOrientation;
}

- (UIUserInterfaceIdiom)iosUsePlayUserInterfaceIdiom {
    NSString *identifier = [self isKindOfClass:UIDevice.class]
        ? @"playtools.device.idiom"
        : @"playtools.trait.idiom";
    IOSUsePlayHookRegistryRecordFirstUse(
        identifier,
        self.class
    );
    return (UIUserInterfaceIdiom)IOSUsePlayDeviceUserInterfaceIdiom;
}

- (NSString *)iosUsePlayDeviceModel {
    IOSUsePlayHookRegistryRecordFirstUse(
        @"playtools.device.model",
        self.class
    );
    return [NSString stringWithUTF8String:IOSUsePlayDeviceModel()];
}

- (NSString *)iosUsePlayDeviceLocalizedModel {
    IOSUsePlayHookRegistryRecordFirstUse(
        @"playtools.device.localized-model",
        self.class
    );
    return [NSString
        stringWithUTF8String:IOSUsePlayDeviceLocalizedModel()];
}

- (double) hook_nativeScale {
    IOSUsePlayHookRegistryRecordFirstUse(
        @"playtools.screen.native-scale",
        self.class
    );
    return [[PlaySettings shared] customScaler];
}

- (double) hook_scale {
    IOSUsePlayHookRegistryRecordFirstUse(
        @"playtools.screen.scale",
        self.class
    );
    // Return rounded value of [[PlaySettings shared] customScaler]
    // Even though it is a double return, this will only accept .0 value or apps will crash
    return round([[PlaySettings shared] customScaler]);
}

- (double) get_default_height {
    return [[UIScreen mainScreen] bounds].size.height;
    
}
- (double) get_default_width {
    return [[UIScreen mainScreen] bounds].size.width;
    
}

- (CGRect) hook_boundsResizable {
    return [PlayScreen boundsResizable:[self hook_boundsResizable]];
}

- (BOOL) hook_requiresFullScreen {
    return NO;
}

- (void) hook_setCurrentSubscription:(id)currentSubscription {
    // do nothing
}

- (NSString *)hook_stringByReplacingOccurrencesOfRegularExpressionPattern:(NSString *)pattern
                                                             withTemplate:(NSString *)template
                                                                  options:(NSRegularExpressionOptions)options
                                                                    range:(NSRange)range {
    // If the string is empty, return immediately to prevent a range out-of-bounds error.
    if ([(NSString*)self isEqualToString:@""]) {
        return @"";
    }
    return [self hook_stringByReplacingOccurrencesOfRegularExpressionPattern:pattern
                                                                withTemplate:template
                                                                     options:options
                                                                       range:range];
}

- (void)hook_requestRecordPermission:(void (^)(BOOL))response {
    BOOL granted = [[AVAudioSession sharedInstance] recordPermission] == AVAudioSessionRecordPermissionGranted;
    if (granted) {
        response(granted);
    } else {
        [self hook_requestRecordPermission:response];
    }
}

- (instancetype)hook_CMMotionManager_init {
    CMMotionManager *motionManager = (CMMotionManager *)[self hook_CMMotionManager_init];
    // The default update interval is 0, which may lead to excessive CPU usage
    motionManager.accelerometerUpdateInterval = 0.01;
    motionManager.deviceMotionUpdateInterval = 0.01;
    motionManager.gyroUpdateInterval = 0.01;
    return motionManager;
}

+ (id)hook_GCMouse_current {
    return nil;
}

+ (NSArray *)hook_GCMouse_mice {
    return @[];
}

+ (void)hook_Unity_KeyboardDelegate_Initialize {
    @try {
        [self hook_Unity_KeyboardDelegate_Initialize];
    }
    @catch (NSException *exception) {
        NSLog(@"Caught exception: %@, reason: %@", exception.name, exception.reason);
    }
}

bool menuWasCreated = false;
- (id) initWithRootMenuHook:(id)rootMenu {
    self = [self initWithRootMenuHook:rootMenu];
    if (!menuWasCreated) {
        [PlayCover initMenuWithMenu: self];
        menuWasCreated = TRUE;
    }
    return self;
}

@end

/*
 This class only exists to apply swizzles from the +load of a class that won't have any categories/extensions. The reason
 for not doing this in a C module initializer is that obj-c initialization happens before any __attribute__((constructor))
 is called. This way we can guarantee the hooks will be applied before [PlayCover launch] is called (in PlayLoader.m).
 
 Side note:
 While adding method replacements to NSObject does work, I'm not certain this doesn't (or won't) have any side effects. The
 way Apple does method swizzling internally is by creating a category of the swizzled class and adding the replacements there.
 This keeps all those replacements "local" to that class. Example:
 
 '''
 @interface FBSSceneSettings (Swizzle)
 -(CGRect) hook_frame {
    ...
 }
 @end
 
 Somewhere else:
 swizzle(FBSSceneSettings.class, @selector(frame), @selector(hook_frame);
 '''
 
 However, doing this would require generating @interface declarations (either with class-dump or by hand) which would add a lot
 of code and complexity. I'm not sure this trade-off is "worth it", at least at the time of writing.
 */

@implementation PTSwizzleLoader
+ (void)load {
    Class sceneSettingsClass;
    if (@available(iOS 17.1, *)) {
        sceneSettingsClass =
            objc_getClass("FBSSceneSettingsCore");
    } else {
        sceneSettingsClass =
            objc_getClass("FBSSceneSettings");
    }
    IOSUsePlayInstallRequiredIdentityHook(
        @"playtools.screen.scene-frame",
        sceneSettingsClass,
        @selector(frame),
        @selector(hook_frame),
        NO,
        NO
    );
    IOSUsePlayInstallRequiredIdentityHook(
        @"playtools.screen.scene-bounds",
        objc_getClass("FBSSceneSettings"),
        @selector(bounds),
        @selector(hook_bounds),
        NO,
        NO
    );
    IOSUsePlayInstallRequiredIdentityHook(
        @"playtools.screen.display-size",
        objc_getClass("FBSDisplayMode"),
        @selector(size),
        @selector(hook_size),
        NO,
        NO
    );
    IOSUsePlayInstallRequiredIdentityHook(
        @"playtools.screen.native-bounds",
        UIScreen.class,
        @selector(nativeBounds),
        @selector(hook_nativeBounds),
        YES,
        YES
    );
    IOSUsePlayInstallRequiredIdentityHook(
        @"playtools.screen.native-scale",
        UIScreen.class,
        @selector(nativeScale),
        @selector(hook_nativeScale),
        YES,
        YES
    );
    IOSUsePlayInstallRequiredIdentityHook(
        @"playtools.screen.scale",
        UIScreen.class,
        @selector(scale),
        @selector(hook_scale),
        YES,
        YES
    );
    
    [objc_getClass("_UIMenuBuilder") swizzleInstanceMethod:sel_getUid("initWithRootMenu:") withMethod:@selector(initWithRootMenuHook:)];
    [objc_getClass("IOSViewController") swizzleInstanceMethod:@selector(prefersPointerLocked) withMethod:@selector(hook_prefersPointerLocked)];
    IOSUsePlayInstallRequiredIdentityHook(
        @"playtools.device.orientation",
        UIDevice.class,
        @selector(orientation),
        @selector(iosUsePlayDeviceOrientation),
        YES,
        YES
    );
    IOSUsePlayInstallRequiredIdentityHook(
        @"playtools.device.idiom",
        UIDevice.class,
        @selector(userInterfaceIdiom),
        @selector(iosUsePlayUserInterfaceIdiom),
        YES,
        YES
    );
    IOSUsePlayInstallRequiredIdentityHook(
        @"playtools.device.model",
        UIDevice.class,
        @selector(model),
        @selector(iosUsePlayDeviceModel),
        YES,
        YES
    );
    IOSUsePlayInstallRequiredIdentityHook(
        @"playtools.device.localized-model",
        UIDevice.class,
        @selector(localizedModel),
        @selector(iosUsePlayDeviceLocalizedModel),
        YES,
        YES
    );
    IOSUsePlayInstallRequiredIdentityHook(
        @"playtools.trait.idiom",
        UITraitCollection.class,
        @selector(userInterfaceIdiom),
        @selector(iosUsePlayUserInterfaceIdiom),
        YES,
        YES
    );

    [objc_getClass("VSSubscriptionRegistrationCenter") swizzleInstanceMethod:@selector(setCurrentSubscription:) withMethod:@selector(hook_setCurrentSubscription:)];

    if (PlayInfo.isUnrealEngine) {
        // Fix NSRegularExpression crash when system language is set to Chinese
        CFStringEncoding encoding = CFStringGetSystemEncoding();
        if (encoding == kCFStringEncodingMacChineseSimp || encoding == kCFStringEncodingMacChineseTrad) {
            SEL origSelector = NSSelectorFromString(@"_stringByReplacingOccurrencesOfRegularExpressionPattern:withTemplate:options:range:");
            SEL newSelector = @selector(hook_stringByReplacingOccurrencesOfRegularExpressionPattern:withTemplate:options:range:);
            [objc_getClass("NSString") swizzleInstanceMethod:origSelector withMethod:newSelector];
        }
    }

    if ([[PlaySettings shared] checkMicPermissionSync]) {
        [objc_getClass("AVAudioSession") swizzleInstanceMethod:@selector(requestRecordPermission:) withMethod:@selector(hook_requestRecordPermission:)];
    }

    if ([[PlaySettings shared] limitMotionUpdateFrequency]) {
        [objc_getClass("CMMotionManager") swizzleInstanceMethod:@selector(init) withMethod:@selector(hook_CMMotionManager_init)];
    }

    if (([[PlaySettings shared] disableBuiltinMouse])) {
        [objc_getClass("GCMouse") swizzleClassMethod:@selector(current) withMethod:@selector(hook_GCMouse_current)];
        [objc_getClass("GCMouse") swizzleClassMethod:@selector(mice) withMethod:@selector(hook_GCMouse_mice)];
    }

    // Delay a frame to wait for some frameworks (such as UnityFramework) to load
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.01 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if ([[PlaySettings shared] ignoreUnityKeyboardInitializationError]) {
            [objc_getClass("KeyboardDelegate") swizzleClassMethod:NSSelectorFromString(@"Initialize") withMethod:@selector(hook_Unity_KeyboardDelegate_Initialize)];
        }
    });
}

@end
