//
// IOSUsePlayRuntime
//
// Headless, automation-focused derivative of PlayTools concepts from
// https://github.com/PlayCover/PlayTools at
// d688f695e83bf080be9ad4b7346e914c7c343d96 (AGPL-3.0).
//

#import "IOSUsePlayRuntime.h"
#import "IOSUsePlayRuntimeSocket.h"

#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <unistd.h>

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

static void IOSUseInstallGeometryHooks(void);

@implementation IOSUsePlayHooks

+ (void)load {
    @autoreleasepool {
        IOSUseInstallGeometryHooks();
    }
}

- (CGRect)iosuse_screenBounds {
    return CGRectMake(0, 0, IOSUseNumber(@"logicalWidth"), IOSUseNumber(@"logicalHeight"));
}

- (CGRect)iosuse_sceneFrame {
    return CGRectMake(0, 0, IOSUseNumber(@"logicalHeight"), IOSUseNumber(@"logicalWidth"));
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

- (UIDeviceOrientation)iosuse_deviceOrientation {
    return UIDeviceOrientationPortrait;
}

- (NSString *)iosuse_deviceModel {
    return @"iPhone";
}

- (NSInteger)iosuse_userInterfaceIdiom {
    return UIUserInterfaceIdiomPhone;
}

@end

static NSMutableDictionary<NSString *, NSValue *> *
    IOSUseOriginalImplementations;

static BOOL IOSUseReplaceMethod(Class target, SEL selector, SEL replacement) {
    Method originalMethod =
        target == Nil ? NULL : class_getInstanceMethod(target, selector);
    if (originalMethod == NULL) {
        return NO;
    }
    Method hook = class_getInstanceMethod(IOSUsePlayHooks.class, replacement);
    if (hook == NULL) {
        return NO;
    }
    IMP hookImplementation = method_getImplementation(hook);
    if (method_getImplementation(originalMethod) == hookImplementation) {
        return YES;
    }
    const char *originalEncoding = method_getTypeEncoding(originalMethod);
    const char *hookEncoding = method_getTypeEncoding(hook);
    if (originalEncoding == NULL ||
        hookEncoding == NULL ||
        strcmp(originalEncoding, hookEncoding) != 0) {
        NSLog(
            @"[ios-use-play] refusing ABI-mismatched hook %@.%@",
            NSStringFromClass(target),
            NSStringFromSelector(selector)
        );
        return NO;
    }
    if (IOSUseOriginalImplementations == nil) {
        IOSUseOriginalImplementations = [NSMutableDictionary dictionary];
    }
    NSString *key = [NSString stringWithFormat:
        @"%@.%@",
        NSStringFromClass(target),
        NSStringFromSelector(selector)
    ];
    if (IOSUseOriginalImplementations[key] == nil) {
        IOSUseOriginalImplementations[key] = [NSValue valueWithPointer:
            method_getImplementation(originalMethod)
        ];
    }
    class_replaceMethod(
        target,
        selector,
        hookImplementation,
        originalEncoding
    );
    return YES;
}

static NSString *IOSUseSceneFrameHookTarget = @"unavailable";
static BOOL IOSUseSceneBoundsHookInstalled = NO;
static BOOL IOSUseDisplaySizeHookInstalled = NO;
static BOOL IOSUseScreenHooksInstalled = NO;
static BOOL IOSUseDeviceOrientationHookInstalled = NO;

static void IOSUseInstallGeometryHooks(void) {
    @synchronized (IOSUsePlayHooks.class) {
        NSString *previousFrameTarget = IOSUseSceneFrameHookTarget;
        Class screen = objc_getClass("UIScreen");
        BOOL boundsInstalled = IOSUseReplaceMethod(
            screen,
            @selector(bounds),
            @selector(iosuse_screenBounds)
        );
        BOOL nativeBoundsInstalled = IOSUseReplaceMethod(
            screen,
            @selector(nativeBounds),
            @selector(iosuse_nativeBounds)
        );
        BOOL scaleInstalled = IOSUseReplaceMethod(
            screen,
            @selector(scale),
            @selector(iosuse_scale)
        );
        BOOL nativeScaleInstalled = IOSUseReplaceMethod(
            screen,
            @selector(nativeScale),
            @selector(iosuse_scale)
        );
        IOSUseScreenHooksInstalled =
            boundsInstalled &&
            nativeBoundsInstalled &&
            scaleInstalled &&
            nativeScaleInstalled;

        Class sceneSettings = objc_getClass("FBSSceneSettings");
        IOSUseSceneBoundsHookInstalled = IOSUseReplaceMethod(
            sceneSettings,
            @selector(bounds),
            @selector(iosuse_screenBounds)
        );
        Class sceneSettingsCore = objc_getClass("FBSSceneSettingsCore");
        if (IOSUseReplaceMethod(
                sceneSettingsCore,
                NSSelectorFromString(@"frame"),
                @selector(iosuse_sceneFrame)
            )) {
            IOSUseSceneFrameHookTarget = @"FBSSceneSettingsCore";
        } else if (IOSUseReplaceMethod(
                       sceneSettings,
                       NSSelectorFromString(@"frame"),
                       @selector(iosuse_sceneFrame)
                   )) {
            IOSUseSceneFrameHookTarget = @"FBSSceneSettings";
        }

        Class displayMode = objc_getClass("FBSDisplayMode");
        IOSUseDisplaySizeHookInstalled = IOSUseReplaceMethod(
            displayMode,
            @selector(size),
            @selector(iosuse_displaySize)
        );

        Class device = objc_getClass("UIDevice");
        IOSUseReplaceMethod(device, @selector(model), @selector(iosuse_deviceModel));
        IOSUseReplaceMethod(
            device,
            @selector(localizedModel),
            @selector(iosuse_deviceModel)
        );
        IOSUseReplaceMethod(
            device,
            @selector(userInterfaceIdiom),
            @selector(iosuse_userInterfaceIdiom)
        );
        IOSUseDeviceOrientationHookInstalled = IOSUseReplaceMethod(
            device,
            @selector(orientation),
            @selector(iosuse_deviceOrientation)
        );
        if (![previousFrameTarget isEqualToString:IOSUseSceneFrameHookTarget]) {
            NSLog(
                @"[ios-use-play] geometry hooks sceneFrameTarget=%@",
                IOSUseSceneFrameHookTarget
            );
        }
    }
}

NSDictionary<NSString *, id> *IOSUsePlayRuntimeHookDiagnostics(void) {
    return @{
        @"installPhase": @"+load+runtime-retry",
        @"screen": @(IOSUseScreenHooksInstalled),
        @"sceneBounds": @(IOSUseSceneBoundsHookInstalled),
        @"sceneFrameTarget": IOSUseSceneFrameHookTarget,
        @"sceneFrame": @{
            @"width": @(IOSUseNumber(@"logicalHeight")),
            @"height": @(IOSUseNumber(@"logicalWidth")),
        },
        @"displaySize": @(IOSUseDisplaySizeHookInstalled),
        @"deviceOrientation": @(IOSUseDeviceOrientationHookInstalled),
        @"deviceOrientationValue": @(UIDeviceOrientationPortrait),
    };
}

typedef id (*IOSUseSendID)(id, SEL);
typedef BOOL (*IOSUseSendBool)(id, SEL);
typedef NSUInteger (*IOSUseSendUnsignedInteger)(id, SEL);
typedef void (*IOSUseSendUnsignedIntegerArgument)(id, SEL, NSUInteger);
typedef void (*IOSUseSendSize)(id, SEL, CGSize);
typedef CGRect (*IOSUseSendRect)(id, SEL);

static UIWindow *IOSUseKeyUIKitWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) {
                return window;
            }
        }
    }
    return nil;
}

static id IOSUseSelectedAppKitWindow(UIWindow *keyUIKitWindow) {
    SEL nsWindowSelector = NSSelectorFromString(@"nsWindow");
    if ([keyUIKitWindow respondsToSelector:nsWindowSelector]) {
        id bridgedWindow = ((IOSUseSendID)objc_msgSend)(
            keyUIKitWindow,
            nsWindowSelector
        );
        if (bridgedWindow != nil) {
            return bridgedWindow;
        }
    }

    Class applicationClass = NSClassFromString(@"NSApplication");
    if (applicationClass == Nil) {
        return nil;
    }
    id application = ((IOSUseSendID)objc_msgSend)(
        (id)applicationClass,
        NSSelectorFromString(@"sharedApplication")
    );
    SEL windowsSelector = NSSelectorFromString(@"windows");
    SEL uiWindowsSelector = NSSelectorFromString(@"uiWindows");
    if (keyUIKitWindow != nil &&
        application != nil &&
        [application respondsToSelector:windowsSelector]) {
        id candidateWindows = ((IOSUseSendID)objc_msgSend)(
            application,
            windowsSelector
        );
        if ([candidateWindows isKindOfClass:NSArray.class]) {
            for (id candidateWindow in (NSArray *)candidateWindows) {
                if (![candidateWindow respondsToSelector:uiWindowsSelector]) {
                    continue;
                }
                id uiWindows = ((IOSUseSendID)objc_msgSend)(
                    candidateWindow,
                    uiWindowsSelector
                );
                if ([uiWindows isKindOfClass:NSArray.class] &&
                    [(NSArray *)uiWindows containsObject:keyUIKitWindow]) {
                    return candidateWindow;
                }
            }
        }
    }
    SEL keyWindowSelector = NSSelectorFromString(@"keyWindow");
    if (application != nil &&
        [application respondsToSelector:keyWindowSelector]) {
        return ((IOSUseSendID)objc_msgSend)(application, keyWindowSelector);
    }
    return nil;
}

static BOOL IOSUseFixSceneSizeRestrictions(
    UIWindow *window,
    CGSize requested
) {
    UIWindowScene *scene = window.windowScene;
    SEL restrictionsSelector = NSSelectorFromString(@"sizeRestrictions");
    if (scene == nil || ![scene respondsToSelector:restrictionsSelector]) {
        return NO;
    }
    id restrictions = ((IOSUseSendID)objc_msgSend)(
        scene,
        restrictionsSelector
    );
    SEL minimumSelector = NSSelectorFromString(@"setMinimumSize:");
    SEL maximumSelector = NSSelectorFromString(@"setMaximumSize:");
    if (restrictions == nil ||
        ![restrictions respondsToSelector:minimumSelector] ||
        ![restrictions respondsToSelector:maximumSelector]) {
        return NO;
    }
    ((IOSUseSendSize)objc_msgSend)(
        restrictions,
        minimumSelector,
        requested
    );
    ((IOSUseSendSize)objc_msgSend)(
        restrictions,
        maximumSelector,
        requested
    );
    return YES;
}

static BOOL IOSUseFixAppKitWindow(CGSize *effectiveSize) {
    CGSize requested = CGSizeMake(
        IOSUseNumber(@"logicalWidth"),
        IOSUseNumber(@"logicalHeight")
    );
    UIWindow *keyUIKitWindow = IOSUseKeyUIKitWindow();
    if (keyUIKitWindow == nil ||
        !IOSUseFixSceneSizeRestrictions(keyUIKitWindow, requested)) {
        return NO;
    }

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
    id window = IOSUseSelectedAppKitWindow(keyUIKitWindow);
    if (window == nil) {
        return NO;
    }

    SEL contentMinSizeSelector = NSSelectorFromString(@"setContentMinSize:");
    SEL contentMaxSizeSelector = NSSelectorFromString(@"setContentMaxSize:");
    SEL contentAspectRatioSelector =
        NSSelectorFromString(@"setContentAspectRatio:");
    SEL contentSizeSelector = NSSelectorFromString(@"setContentSize:");
    SEL sharingTypeSelector = NSSelectorFromString(@"setSharingType:");
    if ([window respondsToSelector:contentMinSizeSelector]) {
        ((IOSUseSendSize)objc_msgSend)(
            window,
            contentMinSizeSelector,
            CGSizeZero
        );
    }
    if ([window respondsToSelector:contentMaxSizeSelector]) {
        ((IOSUseSendSize)objc_msgSend)(
            window,
            contentMaxSizeSelector,
            requested
        );
    }
    if ([window respondsToSelector:contentAspectRatioSelector]) {
        ((IOSUseSendSize)objc_msgSend)(
            window,
            contentAspectRatioSelector,
            requested
        );
    }
    if ([window respondsToSelector:contentSizeSelector]) {
        ((IOSUseSendSize)objc_msgSend)(
            window,
            contentSizeSelector,
            requested
        );
    }
    if ([window respondsToSelector:sharingTypeSelector]) {
        ((IOSUseSendUnsignedIntegerArgument)objc_msgSend)(
            window,
            sharingTypeSelector,
            1 // NSWindowSharingReadOnly
        );
    }

    SEL styleMaskSelector = NSSelectorFromString(@"styleMask");
    SEL setStyleMaskSelector = NSSelectorFromString(@"setStyleMask:");
    if ([window respondsToSelector:styleMaskSelector] &&
        [window respondsToSelector:setStyleMaskSelector]) {
        NSUInteger style = ((IOSUseSendUnsignedInteger)objc_msgSend)(
            window,
            styleMaskSelector
        );
        style &= ~((NSUInteger)1 << 3);  // NSWindowStyleMaskResizable
        style &= ~((NSUInteger)1 << 14); // NSWindowStyleMaskFullScreen
        ((IOSUseSendUnsignedIntegerArgument)objc_msgSend)(
            window,
            setStyleMaskSelector,
            style
        );
    }

    SEL contentViewSelector = NSSelectorFromString(@"contentView");
    if (![window respondsToSelector:contentViewSelector]) {
        return NO;
    }
    id contentView = ((IOSUseSendID)objc_msgSend)(
        window,
        contentViewSelector
    );
    SEL boundsSelector = NSSelectorFromString(@"bounds");
    if (contentView == nil ||
        ![contentView respondsToSelector:boundsSelector]) {
        return NO;
    }
    CGRect bounds = ((IOSUseSendRect)objc_msgSend)(
        contentView,
        boundsSelector
    );
    SEL contentLayoutRectSelector =
        NSSelectorFromString(@"contentLayoutRect");
    CGRect contentLayoutRect =
        [window respondsToSelector:contentLayoutRectSelector]
            ? ((IOSUseSendRect)objc_msgSend)(
                window,
                contentLayoutRectSelector
            )
            : CGRectZero;
    if (effectiveSize != NULL) {
        *effectiveSize = bounds.size;
    }
    SEL sharingTypeGetter = NSSelectorFromString(@"sharingType");
    BOOL sharingReady =
        [window respondsToSelector:sharingTypeGetter] &&
        ((IOSUseSendUnsignedInteger)objc_msgSend)(
            window,
            sharingTypeGetter
        ) == 1;
    BOOL positive =
        bounds.size.width > 0 &&
        bounds.size.height > 0 &&
        contentLayoutRect.size.width > 0 &&
        contentLayoutRect.size.height > 0;
    CGFloat widthTolerance = fmax(
        1.0,
        fmax(bounds.size.width, contentLayoutRect.size.width) * 0.01
    );
    CGFloat heightTolerance = fmax(
        1.0,
        fmax(bounds.size.height, contentLayoutRect.size.height) * 0.01
    );
    BOOL contentMatchesLayout =
        fabs(bounds.size.width - contentLayoutRect.size.width) <= widthTolerance &&
        fabs(bounds.size.height - contentLayoutRect.size.height) <= heightTolerance;
    CGFloat scaleX = bounds.size.width / requested.width;
    CGFloat scaleY = bounds.size.height / requested.height;
    CGFloat scaleTolerance = fmax(scaleX, scaleY) * 0.01;
    BOOL uniform =
        positive &&
        contentMatchesLayout &&
        scaleX > 0 &&
        scaleY > 0 &&
        scaleX <= 1.0 &&
        scaleY <= 1.0 &&
        fabs(scaleX - scaleY) <= scaleTolerance;
    return sharingReady && uniform;
}

static BOOL IOSUseSecureHelloFile(NSString *path) {
    const char *filePath = path.fileSystemRepresentation;
    struct stat pathStatus;
    if (lstat(filePath, &pathStatus) != 0) {
        NSLog(
            @"[ios-use-play] hello security failed stage=lstat errno=%d",
            errno
        );
        return NO;
    }
    if (S_ISLNK(pathStatus.st_mode) ||
        !S_ISREG(pathStatus.st_mode) ||
        pathStatus.st_uid != geteuid()) {
        NSLog(@"[ios-use-play] hello security failed stage=ownership");
        return NO;
    }

    int fileDescriptor = open(filePath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fileDescriptor < 0) {
        NSLog(
            @"[ios-use-play] hello security failed stage=open errno=%d",
            errno
        );
        return NO;
    }
    struct stat openedStatus;
    BOOL secure = fstat(fileDescriptor, &openedStatus) == 0 &&
        S_ISREG(openedStatus.st_mode) &&
        openedStatus.st_uid == geteuid() &&
        openedStatus.st_dev == pathStatus.st_dev &&
        openedStatus.st_ino == pathStatus.st_ino &&
        fchmod(fileDescriptor, 0600) == 0 &&
        fstat(fileDescriptor, &openedStatus) == 0 &&
        (openedStatus.st_mode & 0777) == 0600;
    int savedErrno = errno;
    close(fileDescriptor);
    if (!secure) {
        NSLog(
            @"[ios-use-play] hello security failed stage=chmod errno=%d",
            savedErrno
        );
    }
    return secure;
}

static BOOL IOSUseWriteHello(NSString *stage, CGSize windowSize) {
    UIScreen *screen = UIScreen.mainScreen;
    CGRect logical = screen.bounds;
    CGRect native = screen.nativeBounds;
    NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier ?: @"";
    NSMutableDictionary<NSString *, id> *hello = [@{
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
    } mutableCopy];
    [hello addEntriesFromDictionary:IOSUsePlayRuntimeSocketIdentity()];
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:hello options:0 error:&error];
    NSString *path = IOSUseProfile()[@"helloPath"];
    if (data == nil || ![data writeToFile:path options:NSDataWritingAtomic error:&error]) {
        NSLog(@"[ios-use-play] hello write failed: %@", error.localizedDescription);
        return NO;
    }
    if (!IOSUseSecureHelloFile(path)) {
        return NO;
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
    return YES;
}

static BOOL IOSUseHelloWritten = NO;

static BOOL IOSUseTryApplyWindowAndReport(void) {
    IOSUseInstallGeometryHooks();
    CGSize effectiveSize = CGSizeZero;
    if (!IOSUseFixAppKitWindow(&effectiveSize)) {
        return NO;
    }
    if (!IOSUseHelloWritten) {
        if (!IOSUseWriteHello(@"window-configured", effectiveSize)) {
            return NO;
        }
        IOSUseHelloWritten = YES;
    }
    return YES;
}

static void IOSUseScheduleWindowProbe(NSUInteger attempt);

static void IOSUseApplyWindowAndReport(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!IOSUseTryApplyWindowAndReport()) {
            IOSUseScheduleWindowProbe(1);
        }
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
        NSDictionary<NSString *, id> *profile = IOSUseProfile();
        IOSUseInstallGeometryHooks();
        IOSUsePlayRuntimeStartSocket(profile);
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
