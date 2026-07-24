//
// IOSUsePlayRuntime
//
// Headless, automation-focused derivative of PlayTools concepts from
// https://github.com/PlayCover/PlayTools at
// d688f695e83bf080be9ad4b7346e914c7c343d96 (AGPL-3.0).
//

#import "IOSUsePlayRuntime.h"

#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <errno.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>

double IOSUsePlayRuntimeVersionNumber = 1.0;
const unsigned char IOSUsePlayRuntimeVersionString[] = "1.0.0";

#define IOS_USE_DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { \
        const void *replacement; \
        const void *replacee; \
    } _ios_use_interpose_##_replacee \
    __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(unsigned long)&_replacement, \
        (const void *)(unsigned long)&_replacee \
    };

extern uint32_t dyld_get_active_platform(void);

static NSDictionary<NSString *, id> *IOSUseProfile(void) {
    static NSDictionary<NSString *, id> *profile;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *path = [NSBundle.mainBundle.bundlePath
            stringByAppendingPathComponent:@"IOSUsePlayProfile.plist"];
        NSDictionary<NSString *, id> *candidate =
            [NSDictionary dictionaryWithContentsOfFile:path];
        NSNumber *logicalWidth = candidate[@"logicalWidth"];
        NSNumber *logicalHeight = candidate[@"logicalHeight"];
        NSNumber *nativeWidth = candidate[@"nativeWidth"];
        NSNumber *nativeHeight = candidate[@"nativeHeight"];
        NSNumber *scale = candidate[@"scale"];
        BOOL geometryValid =
            logicalWidth.doubleValue > 0 &&
            logicalHeight.doubleValue > 0 &&
            nativeWidth.doubleValue > 0 &&
            nativeHeight.doubleValue > 0 &&
            scale.doubleValue > 0 &&
            fabs(logicalWidth.doubleValue * scale.doubleValue -
                 nativeWidth.doubleValue) < 0.001 &&
            fabs(logicalHeight.doubleValue * scale.doubleValue -
                 nativeHeight.doubleValue) < 0.001;
        if (geometryValid &&
            [candidate[@"profileHash"] isKindOfClass:NSString.class] &&
            [candidate[@"helloPath"] isKindOfClass:NSString.class]) {
            profile = candidate;
        } else {
            profile = @{
                @"productType": @"iPhone16,2",
                @"hardwareTarget": @"A2849",
                @"logicalWidth": @430,
                @"logicalHeight": @932,
                @"nativeWidth": @1290,
                @"nativeHeight": @2796,
                @"scale": @3,
                @"profileHash": @"invalid-profile",
                @"helloPath": [NSTemporaryDirectory()
                    stringByAppendingPathComponent:@"ios-use-play-invalid.json"],
            };
            NSLog(@"[ios-use-play] invalid or missing IOSUsePlayProfile.plist");
        }
    });
    return profile;
}

static double IOSUseNumber(NSString *key) {
    return [IOSUseProfile()[key] doubleValue];
}

static const char *IOSUseCString(NSString *key) {
    NSString *value = IOSUseProfile()[key];
    return [value isKindOfClass:NSString.class] ? value.UTF8String : "";
}

static int IOSUseCopyCString(const char *value, void *buffer, size_t *size) {
    if (size == NULL) {
        errno = EINVAL;
        return -1;
    }
    size_t required = strlen(value) + 1;
    if (buffer == NULL) {
        *size = required;
        return 0;
    }
    if (*size < required) {
        *size = required;
        errno = ENOMEM;
        return -1;
    }
    memcpy(buffer, value, required);
    *size = required;
    return 0;
}

static uint32_t IOSUseActivePlatform(void) {
    return 2; // PLATFORM_IOS
}

static int IOSUseUname(struct utsname *value) {
    // dyld leaves references from the interposing image bound to the original
    // implementation, which is what makes a wrapper-style interpose possible.
    if (uname(value) != 0) {
        return -1;
    }
    const char *machine = IOSUseCString(@"productType");
    strlcpy(value->machine, machine, sizeof(value->machine));
    return 0;
}

static int IOSUseSysctlByName(
    const char *name,
    void *oldValue,
    size_t *oldLength,
    void *newValue,
    size_t newLength
) {
    if (strcmp(name, "hw.machine") == 0 ||
        strcmp(name, "hw.product") == 0 ||
        strcmp(name, "hw.model") == 0) {
        return IOSUseCopyCString(IOSUseCString(@"productType"), oldValue, oldLength);
    }
    if (strcmp(name, "hw.target") == 0) {
        return IOSUseCopyCString(IOSUseCString(@"hardwareTarget"), oldValue, oldLength);
    }
    return sysctlbyname(name, oldValue, oldLength, newValue, newLength);
}

static int IOSUseSysctl(
    int *name,
    u_int nameLength,
    void *oldValue,
    size_t *oldLength,
    void *newValue,
    size_t newLength
) {
    if (name != NULL && nameLength >= 2 && name[0] == CTL_HW) {
        if (name[1] == HW_MACHINE || name[1] == HW_MODEL) {
            return IOSUseCopyCString(IOSUseCString(@"productType"), oldValue, oldLength);
        }
    }
    return sysctl(name, nameLength, oldValue, oldLength, newValue, newLength);
}

IOS_USE_DYLD_INTERPOSE(IOSUseActivePlatform, dyld_get_active_platform)
IOS_USE_DYLD_INTERPOSE(IOSUseUname, uname)
IOS_USE_DYLD_INTERPOSE(IOSUseSysctlByName, sysctlbyname)
IOS_USE_DYLD_INTERPOSE(IOSUseSysctl, sysctl)

@interface IOSUsePlayHooks : NSObject
@end

@implementation IOSUsePlayHooks

- (CGRect)iosuse_screenBounds {
    return CGRectMake(0, 0, IOSUseNumber(@"logicalWidth"), IOSUseNumber(@"logicalHeight"));
}

- (CGRect)iosuse_nativeBounds {
    return CGRectMake(0, 0, IOSUseNumber(@"nativeWidth"), IOSUseNumber(@"nativeHeight"));
}

- (CGFloat)iosuse_scale {
    return IOSUseNumber(@"scale");
}

- (CGSize)iosuse_displaySize {
    return CGSizeMake(IOSUseNumber(@"logicalWidth"), IOSUseNumber(@"logicalHeight"));
}

- (long long)iosuse_orientation {
    return 0;
}

- (NSString *)iosuse_deviceModel {
    return @"iPhone";
}

- (NSInteger)iosuse_userInterfaceIdiom {
    return UIUserInterfaceIdiomPhone;
}

@end

static void IOSUseReplaceMethod(Class target, SEL selector, SEL replacement) {
    if (target == Nil || class_getInstanceMethod(target, selector) == NULL) {
        return;
    }
    Method hook = class_getInstanceMethod(IOSUsePlayHooks.class, replacement);
    if (hook == NULL) {
        return;
    }
    class_replaceMethod(
        target,
        selector,
        method_getImplementation(hook),
        method_getTypeEncoding(hook)
    );
}

static void IOSUseInstallGeometryHooks(void) {
    Class screen = objc_getClass("UIScreen");
    IOSUseReplaceMethod(screen, @selector(bounds), @selector(iosuse_screenBounds));
    IOSUseReplaceMethod(screen, @selector(nativeBounds), @selector(iosuse_nativeBounds));
    IOSUseReplaceMethod(screen, @selector(scale), @selector(iosuse_scale));
    IOSUseReplaceMethod(screen, @selector(nativeScale), @selector(iosuse_scale));

    Class sceneSettings = objc_getClass("FBSSceneSettings");
    IOSUseReplaceMethod(sceneSettings, @selector(bounds), @selector(iosuse_screenBounds));
    IOSUseReplaceMethod(
        sceneSettings,
        NSSelectorFromString(@"interfaceOrientation"),
        @selector(iosuse_orientation)
    );

    Class displayMode = objc_getClass("FBSDisplayMode");
    IOSUseReplaceMethod(displayMode, @selector(size), @selector(iosuse_displaySize));

    Class device = objc_getClass("UIDevice");
    IOSUseReplaceMethod(device, @selector(model), @selector(iosuse_deviceModel));
    IOSUseReplaceMethod(device, @selector(localizedModel), @selector(iosuse_deviceModel));
    IOSUseReplaceMethod(
        device,
        @selector(userInterfaceIdiom),
        @selector(iosuse_userInterfaceIdiom)
    );
}

typedef id (*IOSUseSendID)(id, SEL);
typedef NSUInteger (*IOSUseSendUnsignedInteger)(id, SEL);
typedef void (*IOSUseSendUnsignedIntegerArgument)(id, SEL, NSUInteger);
typedef void (*IOSUseSendSize)(id, SEL, CGSize);
typedef CGRect (*IOSUseSendRect)(id, SEL);

static BOOL IOSUseFixAppKitWindow(CGSize *effectiveSize) {
    static void *appKitHandle;
    static dispatch_once_t appKitOnce;
    dispatch_once(&appKitOnce, ^{
        appKitHandle = dlopen(
            "/System/Library/Frameworks/AppKit.framework/AppKit",
            RTLD_NOW | RTLD_LOCAL
        );
        if (appKitHandle == NULL) {
            NSLog(@"[ios-use-play] AppKit bridge load failed: %s", dlerror());
        }
    });
    Class applicationClass = NSClassFromString(@"NSApplication");
    if (applicationClass == Nil) {
        return NO;
    }
    id application = ((IOSUseSendID)objc_msgSend)(
        (id)applicationClass,
        NSSelectorFromString(@"sharedApplication")
    );
    NSArray *windows = ((IOSUseSendID)objc_msgSend)(
        application,
        NSSelectorFromString(@"windows")
    );
    if (![windows isKindOfClass:NSArray.class] || windows.count == 0) {
        NSMutableArray *bridgedWindows = [NSMutableArray array];
        SEL nsWindowSelector = NSSelectorFromString(@"nsWindow");
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) {
                continue;
            }
            for (UIWindow *uiWindow in ((UIWindowScene *)scene).windows) {
                if ([uiWindow respondsToSelector:nsWindowSelector]) {
                    id nsWindow = ((IOSUseSendID)objc_msgSend)(uiWindow, nsWindowSelector);
                    if (nsWindow != nil) {
                        [bridgedWindows addObject:nsWindow];
                    }
                }
            }
        }
        windows = bridgedWindows;
    }
    if (windows.count == 0) {
        return NO;
    }

    CGSize requested = CGSizeMake(
        IOSUseNumber(@"logicalWidth"),
        IOSUseNumber(@"logicalHeight")
    );
    id firstWindow = nil;
    for (id window in windows) {
        if (firstWindow == nil) {
            firstWindow = window;
        }
        ((IOSUseSendSize)objc_msgSend)(
            window,
            NSSelectorFromString(@"setContentMinSize:"),
            requested
        );
        ((IOSUseSendSize)objc_msgSend)(
            window,
            NSSelectorFromString(@"setContentMaxSize:"),
            requested
        );
        ((IOSUseSendSize)objc_msgSend)(
            window,
            NSSelectorFromString(@"setContentAspectRatio:"),
            requested
        );
        ((IOSUseSendSize)objc_msgSend)(
            window,
            NSSelectorFromString(@"setContentSize:"),
            requested
        );
        NSUInteger style = ((IOSUseSendUnsignedInteger)objc_msgSend)(
            window,
            NSSelectorFromString(@"styleMask")
        );
        style &= ~((NSUInteger)1 << 3);  // NSWindowStyleMaskResizable
        style &= ~((NSUInteger)1 << 14); // NSWindowStyleMaskFullScreen
        ((IOSUseSendUnsignedIntegerArgument)objc_msgSend)(
            window,
            NSSelectorFromString(@"setStyleMask:"),
            style
        );
    }

    id contentView = ((IOSUseSendID)objc_msgSend)(
        firstWindow,
        NSSelectorFromString(@"contentView")
    );
    if (contentView == nil) {
        return NO;
    }
    CGRect bounds = ((IOSUseSendRect)objc_msgSend)(
        contentView,
        NSSelectorFromString(@"bounds")
    );
    if (effectiveSize != NULL) {
        *effectiveSize = bounds.size;
    }
    return fabs(bounds.size.width - requested.width) < 0.01 &&
        fabs(bounds.size.height - requested.height) < 0.01;
}

static void IOSUseWriteHello(NSString *stage, CGSize windowSize) {
    UIScreen *screen = UIScreen.mainScreen;
    CGRect logical = screen.bounds;
    CGRect native = screen.nativeBounds;
    NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier ?: @"";
    NSDictionary *hello = @{
        @"schemaVersion": @1,
        @"pid": @(NSProcessInfo.processInfo.processIdentifier),
        @"bundleIdentifier": bundleIdentifier,
        @"profileHash": IOSUseProfile()[@"profileHash"] ?: @"",
        @"logicalWidth": @(logical.size.width),
        @"logicalHeight": @(logical.size.height),
        @"nativeWidth": @(native.size.width),
        @"nativeHeight": @(native.size.height),
        @"scale": @(screen.scale),
        @"windowWidth": @(windowSize.width),
        @"windowHeight": @(windowSize.height),
        @"stage": stage,
    };
    NSError *error;
    NSData *data = [NSJSONSerialization dataWithJSONObject:hello options:0 error:&error];
    NSString *path = IOSUseProfile()[@"helloPath"];
    if (data == nil || ![data writeToFile:path options:NSDataWritingAtomic error:&error]) {
        NSLog(@"[ios-use-play] hello write failed: %@", error.localizedDescription);
        return;
    }
    NSLog(
        @"[ios-use-play] hello pid=%d logical=%.0fx%.0f native=%.0fx%.0f scale=%.1f window=%.0fx%.0f",
        NSProcessInfo.processInfo.processIdentifier,
        logical.size.width,
        logical.size.height,
        native.size.width,
        native.size.height,
        screen.scale,
        windowSize.width,
        windowSize.height
    );
}

static BOOL IOSUseHelloWritten = NO;

static BOOL IOSUseTryApplyWindowAndReport(void) {
    if (IOSUseHelloWritten) {
        return YES;
    }
    CGSize effectiveSize = CGSizeZero;
    if (!IOSUseFixAppKitWindow(&effectiveSize)) {
        return NO;
    }
    IOSUseHelloWritten = YES;
    IOSUseWriteHello(@"window-fixed", effectiveSize);
    return YES;
}

static void IOSUseApplyWindowAndReport(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        (void)IOSUseTryApplyWindowAndReport();
    });
}

static void IOSUseScheduleWindowProbe(NSUInteger attempt) {
    static const NSUInteger maximumAttempts = 240;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            if (IOSUseTryApplyWindowAndReport()) {
                return;
            }
            if (attempt < maximumAttempts) {
                IOSUseScheduleWindowProbe(attempt + 1);
            } else {
                NSLog(@"[ios-use-play] window probe timed out after 60 seconds");
            }
        }
    );
}

__attribute__((constructor))
static void IOSUsePlayRuntimeInitialize(void) {
    @autoreleasepool {
        (void)IOSUseProfile();
        IOSUseInstallGeometryHooks();
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserverForName:@"NSWindowDidBecomeKeyNotification"
                           object:nil
                            queue:NSOperationQueue.mainQueue
                       usingBlock:^(__unused NSNotification *notification) {
            IOSUseApplyWindowAndReport();
        }];
        [center addObserverForName:UIApplicationDidBecomeActiveNotification
                           object:nil
                            queue:NSOperationQueue.mainQueue
                       usingBlock:^(__unused NSNotification *notification) {
            IOSUseApplyWindowAndReport();
        }];
        IOSUseScheduleWindowProbe(1);
        NSLog(@"[ios-use-play] runtime loaded profile=%@", IOSUseProfile()[@"profileHash"]);
    }
}
