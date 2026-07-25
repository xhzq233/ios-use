#import "IOSUsePlayRuntimeScreenshot.h"

#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <stdatomic.h>

static const NSTimeInterval IOSUseScreenshotMainThreadTimeoutSeconds = 12.0;
static const NSUInteger IOSUseScreenshotMaximumJPEGBytes = 11 * 1024 * 1024;
// Leave a full MiB for the response envelope and Runtime identity under the
// transport's strict 16 MiB frame limit.
static const NSUInteger IOSUseScreenshotMaximumBase64Bytes = 15 * 1024 * 1024;
static const CGFloat IOSUseScreenshotGeometryTolerance = 0.01;
static atomic_bool IOSUseScreenshotInFlight = false;

typedef id (*IOSUseScreenshotSendID)(id, SEL);
typedef NSInteger (*IOSUseScreenshotSendInteger)(id, SEL);
typedef CGRect (*IOSUseScreenshotSendRect)(id, SEL);
typedef CGImageRef _Nullable (*IOSUseCGWindowListCreateImageFunction)(
    CGRect,
    uint32_t,
    uint32_t,
    uint32_t
);
typedef CFTypeRef _Nullable (*IOSUsePrivateCreateUIImageFunction)(void);
typedef CGImageRef _Nullable (*IOSUsePrivateCreateCGImageFunction)(void);

typedef NS_ENUM(uint32_t, IOSUseCGWindowListOption) {
    IOSUseCGWindowListOptionIncludingWindow = 1U << 3,
};

typedef NS_ENUM(uint32_t, IOSUseCGWindowImageOption) {
    IOSUseCGWindowImageBoundsIgnoreFraming = 1U << 0,
    IOSUseCGWindowImageBestResolution = 1U << 3,
};

static void IOSUseSetScreenshotFailure(
    NSString *code,
    NSString *message,
    NSString **failureCode,
    NSString **failureMessage
) {
    if (failureCode != NULL) {
        *failureCode = code;
    }
    if (failureMessage != NULL) {
        *failureMessage = message;
    }
}

static BOOL IOSUseScreenshotNumber(
    id value,
    CGFloat *result
) {
    if (![value isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
        return NO;
    }
    double number = ((NSNumber *)value).doubleValue;
    if (!isfinite(number) || number <= 0) {
        return NO;
    }
    if (result != NULL) {
        *result = (CGFloat)number;
    }
    return YES;
}

static BOOL IOSUseScreenshotProfile(
    NSDictionary<NSString *, id> *profile,
    CGSize *logicalSize,
    CGSize *pixelSize,
    CGFloat *scale
) {
    CGFloat logicalWidth = 0;
    CGFloat logicalHeight = 0;
    CGFloat nativeWidth = 0;
    CGFloat nativeHeight = 0;
    CGFloat profileScale = 0;
    if (!IOSUseScreenshotNumber(profile[@"logicalWidth"], &logicalWidth) ||
        !IOSUseScreenshotNumber(profile[@"logicalHeight"], &logicalHeight) ||
        !IOSUseScreenshotNumber(profile[@"nativeWidth"], &nativeWidth) ||
        !IOSUseScreenshotNumber(profile[@"nativeHeight"], &nativeHeight) ||
        !IOSUseScreenshotNumber(profile[@"scale"], &profileScale)) {
        return NO;
    }
    if (nativeWidth > 8192 ||
        nativeHeight > 8192 ||
        nativeWidth * nativeHeight > 40 * 1024 * 1024 ||
        fabs(logicalWidth * profileScale - nativeWidth) > 0.5 ||
        fabs(logicalHeight * profileScale - nativeHeight) > 0.5 ||
        fabs(nativeWidth - round(nativeWidth)) > 0.001 ||
        fabs(nativeHeight - round(nativeHeight)) > 0.001) {
        return NO;
    }
    if (logicalSize != NULL) {
        *logicalSize = CGSizeMake(logicalWidth, logicalHeight);
    }
    if (pixelSize != NULL) {
        *pixelSize = CGSizeMake(nativeWidth, nativeHeight);
    }
    if (scale != NULL) {
        *scale = profileScale;
    }
    return YES;
}

static NSArray<UIWindow *> *IOSUseScreenshotCandidateWindows(void) {
    UIApplication *application = UIApplication.sharedApplication;
    NSMutableArray<UIWindow *> *foreground = [NSMutableArray array];
    NSMutableArray<UIWindow *> *other = [NSMutableArray array];
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        NSArray<UIWindow *> *windows = ((UIWindowScene *)scene).windows;
        NSMutableArray<UIWindow *> *destination =
            scene.activationState == UISceneActivationStateForegroundActive
                ? foreground
                : other;
        for (UIWindow *window in windows) {
            if (!window.hidden &&
                window.alpha > 0 &&
                window.bounds.size.width > 0 &&
                window.bounds.size.height > 0) {
                [destination addObject:window];
            }
        }
    }
    NSComparator frontToBack = ^NSComparisonResult(
        UIWindow *left,
        UIWindow *right
    ) {
        if (left.isKeyWindow != right.isKeyWindow) {
            return left.isKeyWindow ? NSOrderedAscending : NSOrderedDescending;
        }
        if (left.windowLevel > right.windowLevel) {
            return NSOrderedAscending;
        }
        if (left.windowLevel < right.windowLevel) {
            return NSOrderedDescending;
        }
        return NSOrderedSame;
    };
    [foreground sortUsingComparator:frontToBack];
    [other sortUsingComparator:frontToBack];
    [foreground addObjectsFromArray:other];
    return foreground;
}

static UIWindow *IOSUseScreenshotUIKitWindow(void) {
    return IOSUseScreenshotCandidateWindows().firstObject;
}

static id IOSUseScreenshotAppKitWindow(UIWindow *uiWindow) {
    if (uiWindow == nil) {
        return nil;
    }
    static void *appKitHandle;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        appKitHandle = dlopen(
            "/System/Library/Frameworks/AppKit.framework/AppKit",
            RTLD_NOW | RTLD_LOCAL
        );
    });
    if (appKitHandle == NULL) {
        return nil;
    }

    SEL nsWindowSelector = NSSelectorFromString(@"nsWindow");
    if ([uiWindow respondsToSelector:nsWindowSelector]) {
        id bridged = ((IOSUseScreenshotSendID)objc_msgSend)(
            uiWindow,
            nsWindowSelector
        );
        if (bridged != nil) {
            return bridged;
        }
    }

    Class applicationClass = NSClassFromString(@"NSApplication");
    SEL sharedApplicationSelector =
        NSSelectorFromString(@"sharedApplication");
    if (applicationClass == Nil ||
        ![(id)applicationClass
            respondsToSelector:sharedApplicationSelector]) {
        return nil;
    }
    id application = ((IOSUseScreenshotSendID)objc_msgSend)(
        (id)applicationClass,
        sharedApplicationSelector
    );
    SEL windowsSelector = NSSelectorFromString(@"windows");
    SEL uiWindowsSelector = NSSelectorFromString(@"uiWindows");
    if ([application respondsToSelector:windowsSelector]) {
        id windows = ((IOSUseScreenshotSendID)objc_msgSend)(
            application,
            windowsSelector
        );
        if ([windows isKindOfClass:NSArray.class]) {
            for (id candidate in (NSArray *)windows) {
                if (![candidate respondsToSelector:uiWindowsSelector]) {
                    continue;
                }
                id uiWindows = ((IOSUseScreenshotSendID)objc_msgSend)(
                    candidate,
                    uiWindowsSelector
                );
                if ([uiWindows isKindOfClass:NSArray.class] &&
                    [(NSArray *)uiWindows containsObject:uiWindow]) {
                    return candidate;
                }
            }
        }
    }
    SEL keyWindowSelector = NSSelectorFromString(@"keyWindow");
    if ([application respondsToSelector:keyWindowSelector]) {
        return ((IOSUseScreenshotSendID)objc_msgSend)(
            application,
            keyWindowSelector
        );
    }
    return nil;
}

static BOOL IOSUseScreenshotApproximatelyUniform(
    CGFloat first,
    CGFloat second
) {
    CGFloat largest = fmax(fabs(first), fabs(second));
    return largest > 0 &&
        fabs(first - second) / largest <=
            IOSUseScreenshotGeometryTolerance;
}

static CGImageRef _Nullable IOSUseScreenshotCropAppKitContent(
    CGImageRef image,
    CGRect windowFrame,
    CGRect contentLayoutRect
) CF_RETURNS_RETAINED {
    if (image == NULL ||
        windowFrame.size.width <= 0 ||
        windowFrame.size.height <= 0 ||
        contentLayoutRect.size.width <= 0 ||
        contentLayoutRect.size.height <= 0) {
        return NULL;
    }
    CGFloat imageWidth = (CGFloat)CGImageGetWidth(image);
    CGFloat imageHeight = (CGFloat)CGImageGetHeight(image);
    CGFloat contentScaleX = imageWidth / contentLayoutRect.size.width;
    CGFloat contentScaleY = imageHeight / contentLayoutRect.size.height;
    if (IOSUseScreenshotApproximatelyUniform(
            contentScaleX,
            contentScaleY
        )) {
        return CGImageCreateCopy(image);
    }

    CGFloat windowScaleX = imageWidth / windowFrame.size.width;
    CGFloat windowScaleY = imageHeight / windowFrame.size.height;
    if (!IOSUseScreenshotApproximatelyUniform(
            windowScaleX,
            windowScaleY
        )) {
        return NULL;
    }
    CGFloat tolerance = 0.5;
    if (CGRectGetMinX(contentLayoutRect) < -tolerance ||
        CGRectGetMinY(contentLayoutRect) < -tolerance ||
        CGRectGetMaxX(contentLayoutRect) >
            windowFrame.size.width + tolerance ||
        CGRectGetMaxY(contentLayoutRect) >
            windowFrame.size.height + tolerance) {
        return NULL;
    }
    CGFloat minimumX = fmax(
        0,
        floor(CGRectGetMinX(contentLayoutRect) * windowScaleX)
    );
    CGFloat minimumY = fmax(
        0,
        floor(
            (windowFrame.size.height -
             CGRectGetMaxY(contentLayoutRect)) * windowScaleY
        )
    );
    CGFloat maximumX = fmin(
        imageWidth,
        ceil(CGRectGetMaxX(contentLayoutRect) * windowScaleX)
    );
    CGFloat maximumY = fmin(
        imageHeight,
        ceil(
            (windowFrame.size.height -
             CGRectGetMinY(contentLayoutRect)) * windowScaleY
        )
    );
    if (maximumX <= minimumX || maximumY <= minimumY) {
        return NULL;
    }
    return CGImageCreateWithImageInRect(
        image,
        CGRectMake(
            minimumX,
            minimumY,
            maximumX - minimumX,
            maximumY - minimumY
        )
    );
}

static BOOL IOSUseScreenshotImageHasUsablePixels(CGImageRef image) {
    if (image == NULL ||
        CGImageGetWidth(image) == 0 ||
        CGImageGetHeight(image) == 0) {
        return NO;
    }
    enum {
        sampleWidth = 32,
        sampleHeight = 32,
    };
    uint8_t pixels[sampleWidth * sampleHeight * 4];
    memset(pixels, 0, sizeof(pixels));
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (colorSpace == NULL) {
        return NO;
    }
    CGContextRef context = CGBitmapContextCreate(
        pixels,
        sampleWidth,
        sampleHeight,
        8,
        sampleWidth * 4,
        colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
    );
    CGColorSpaceRelease(colorSpace);
    if (context == NULL) {
        return NO;
    }
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextDrawImage(
        context,
        CGRectMake(0, 0, sampleWidth, sampleHeight),
        image
    );
    CGContextRelease(context);

    NSUInteger visible = 0;
    for (NSUInteger index = 0;
         index < sampleWidth * sampleHeight;
         index++) {
        const uint8_t *pixel = pixels + (index * 4);
        if (pixel[3] <= 2) {
            continue;
        }
        visible += 1;
    }
    return visible >= (sampleWidth * sampleHeight) / 20;
}

static BOOL IOSUseScreenshotImageMatchesLogicalAspect(
    CGImageRef image,
    CGSize logicalSize
) {
    if (image == NULL ||
        logicalSize.width <= 0 ||
        logicalSize.height <= 0) {
        return NO;
    }
    CGFloat width = (CGFloat)CGImageGetWidth(image);
    CGFloat height = (CGFloat)CGImageGetHeight(image);
    if (width <= 0 || height <= 0) {
        return NO;
    }
    CGFloat imageAspect = width / height;
    CGFloat logicalAspect = logicalSize.width / logicalSize.height;
    CGFloat largest = fmax(fabs(imageAspect), fabs(logicalAspect));
    return largest > 0 &&
        fabs(imageAspect - logicalAspect) / largest <=
            IOSUseScreenshotGeometryTolerance;
}

static UIImage *IOSUseScreenshotNormalizeImage(
    UIImage *image,
    CGSize logicalSize,
    CGFloat scale
) {
    if (image == nil ||
        logicalSize.width <= 0 ||
        logicalSize.height <= 0 ||
        scale <= 0 ||
        !IOSUseScreenshotImageHasUsablePixels(image.CGImage) ||
        !IOSUseScreenshotImageMatchesLogicalAspect(
            image.CGImage,
            logicalSize
        )) {
        return nil;
    }
    UIGraphicsImageRendererFormat *format =
        [UIGraphicsImageRendererFormat defaultFormat];
    format.opaque = YES;
    format.scale = scale;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc]
            initWithSize:logicalSize
            format:format];
    return [renderer imageWithActions:^(
        UIGraphicsImageRendererContext *context
    ) {
        [UIColor.blackColor setFill];
        [context fillRect:(CGRect){CGPointZero, logicalSize}];
        [image drawInRect:(CGRect){CGPointZero, logicalSize}];
    }];
}

static UIImage *IOSUseScreenshotCGWindow(
    UIWindow *uiWindow,
    CGSize logicalSize,
    CGFloat scale,
    NSString **failure
) {
    id appKitWindow = IOSUseScreenshotAppKitWindow(uiWindow);
    SEL windowNumberSelector = NSSelectorFromString(@"windowNumber");
    SEL frameSelector = NSSelectorFromString(@"frame");
    SEL contentLayoutRectSelector =
        NSSelectorFromString(@"contentLayoutRect");
    if (appKitWindow == nil ||
        ![appKitWindow respondsToSelector:windowNumberSelector] ||
        ![appKitWindow respondsToSelector:frameSelector] ||
        ![appKitWindow respondsToSelector:contentLayoutRectSelector]) {
        if (failure != NULL) {
            *failure = @"AppKit window bridge is unavailable";
        }
        return nil;
    }
    NSInteger windowNumber =
        ((IOSUseScreenshotSendInteger)objc_msgSend)(
            appKitWindow,
            windowNumberSelector
        );
    CGRect windowFrame = ((IOSUseScreenshotSendRect)objc_msgSend)(
        appKitWindow,
        frameSelector
    );
    CGRect contentLayoutRect =
        ((IOSUseScreenshotSendRect)objc_msgSend)(
            appKitWindow,
            contentLayoutRectSelector
        );
    if (windowNumber <= 0 ||
        windowNumber > UINT32_MAX ||
        windowFrame.size.width <= 0 ||
        windowFrame.size.height <= 0 ||
        contentLayoutRect.size.width <= 0 ||
        contentLayoutRect.size.height <= 0) {
        if (failure != NULL) {
            *failure = @"AppKit window geometry is invalid";
        }
        return nil;
    }

    IOSUseCGWindowListCreateImageFunction createImage =
        (IOSUseCGWindowListCreateImageFunction)dlsym(
            RTLD_DEFAULT,
            "CGWindowListCreateImage"
        );
    if (createImage == NULL) {
        if (failure != NULL) {
            *failure = @"CGWindowListCreateImage is unavailable";
        }
        return nil;
    }
    CGImageRef windowImage = createImage(
        CGRectNull,
        IOSUseCGWindowListOptionIncludingWindow,
        (uint32_t)windowNumber,
        IOSUseCGWindowImageBoundsIgnoreFraming |
            IOSUseCGWindowImageBestResolution
    );
    if (windowImage == NULL) {
        if (failure != NULL) {
            *failure = @"CGWindowListCreateImage returned no image";
        }
        return nil;
    }
    CGImageRef contentImage = IOSUseScreenshotCropAppKitContent(
        windowImage,
        windowFrame,
        contentLayoutRect
    );
    CGImageRelease(windowImage);
    if (contentImage == NULL) {
        if (failure != NULL) {
            *failure = @"CGWindow image geometry does not match the AppKit window";
        }
        return nil;
    }
    BOOL usable = IOSUseScreenshotImageHasUsablePixels(contentImage);
    UIImage *captured = usable
        ? [UIImage imageWithCGImage:contentImage]
        : nil;
    CGImageRelease(contentImage);
    if (captured == nil) {
        if (failure != NULL) {
            *failure = @"CGWindow image is empty or visually degenerate";
        }
        return nil;
    }
    return IOSUseScreenshotNormalizeImage(
        captured,
        logicalSize,
        scale
    );
}

static UIImage *IOSUseScreenshotPrivateUIKit(
    CGSize logicalSize,
    CGFloat scale,
    NSString **source,
    NSString **failure
) {
    IOSUsePrivateCreateUIImageFunction createUIImage =
        (IOSUsePrivateCreateUIImageFunction)dlsym(
            RTLD_DEFAULT,
            "_UICreateScreenUIImage"
        );
    if (createUIImage != NULL) {
        UIImage *image = nil;
        @try {
            CFTypeRef retainedImage = createUIImage();
            image = CFBridgingRelease(retainedImage);
        } @catch (NSException *exception) {
            if (failure != NULL) {
                *failure = [NSString stringWithFormat:
                    @"_UICreateScreenUIImage raised %@",
                    exception.name
                ];
            }
        }
        UIImage *normalized = IOSUseScreenshotNormalizeImage(
            image,
            logicalSize,
            scale
        );
        if (normalized != nil) {
            if (source != NULL) {
                *source = @"_UICreateScreenUIImage";
            }
            return normalized;
        }
        if (failure != NULL) {
            *failure =
                @"_UICreateScreenUIImage returned invalid pixels or geometry";
        }
    }

    IOSUsePrivateCreateCGImageFunction createCGImage =
        (IOSUsePrivateCreateCGImageFunction)dlsym(
            RTLD_DEFAULT,
            "UICreateScreenImage"
        );
    if (createCGImage != NULL) {
        UIImage *image = nil;
        @try {
            CGImageRef retainedImage = createCGImage();
            if (retainedImage != NULL) {
                image = [UIImage imageWithCGImage:retainedImage];
                CGImageRelease(retainedImage);
            }
        } @catch (NSException *exception) {
            if (failure != NULL) {
                *failure = [NSString stringWithFormat:
                    @"UICreateScreenImage raised %@",
                    exception.name
                ];
            }
        }
        UIImage *normalized = IOSUseScreenshotNormalizeImage(
            image,
            logicalSize,
            scale
        );
        if (normalized != nil) {
            if (source != NULL) {
                *source = @"UICreateScreenImage";
            }
            return normalized;
        }
        if (failure != NULL) {
            *failure =
                @"UICreateScreenImage returned invalid pixels or geometry";
        }
    }
    if (failure != NULL && *failure == nil) {
        *failure = @"private UIKit screen-image symbols are unavailable";
    }
    return nil;
}

static BOOL IOSUseScreenshotViewTreeContainsMetal(UIView *root) {
    Class metalLayerClass = NSClassFromString(@"CAMetalLayer");
    if (root == nil || metalLayerClass == Nil) {
        return NO;
    }
    NSMutableArray<UIView *> *pending =
        [NSMutableArray arrayWithObject:root];
    NSUInteger visited = 0;
    @try {
        while (pending.count > 0 && visited < 10000) {
            UIView *view = pending.lastObject;
            [pending removeLastObject];
            visited += 1;
            if ([view.layer isKindOfClass:metalLayerClass]) {
                return YES;
            }
            [pending addObjectsFromArray:view.subviews];
        }
    } @catch (__unused NSException *exception) {
        // Getter overrides in the target App are outside our control. Treat an
        // uninspectable hierarchy as potentially Metal-backed.
        return YES;
    }
    return pending.count > 0;
}

static UIImage *IOSUseScreenshotDrawHierarchy(
    UIWindow *window,
    CGSize logicalSize,
    CGFloat scale,
    BOOL *complete,
    NSString **failure
) {
    if (window == nil) {
        if (failure != NULL) {
            *failure = @"no foreground UIKit window is available";
        }
        return nil;
    }
    CGRect windowBounds = window.bounds;
    if (windowBounds.size.width <= 0 ||
        windowBounds.size.height <= 0 ||
        !IOSUseScreenshotApproximatelyUniform(
            windowBounds.size.width / logicalSize.width,
            windowBounds.size.height / logicalSize.height
        )) {
        if (failure != NULL) {
            *failure =
                @"UIKit window geometry does not match the runtime profile";
        }
        return nil;
    }
    UIGraphicsImageRendererFormat *format =
        [UIGraphicsImageRendererFormat defaultFormat];
    format.opaque = NO;
    format.scale = scale;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc]
            initWithSize:logicalSize
            format:format];
    __block BOOL drewHierarchy = NO;
    UIImage *image = [renderer imageWithActions:^(
        __unused UIGraphicsImageRendererContext *context
    ) {
        drewHierarchy = [window drawViewHierarchyInRect:
            (CGRect){CGPointZero, logicalSize}
            afterScreenUpdates:YES];
    }];
    UIImage *normalized = IOSUseScreenshotNormalizeImage(
        image,
        logicalSize,
        scale
    );
    if (complete != NULL) {
        *complete =
            drewHierarchy &&
            !IOSUseScreenshotViewTreeContainsMetal(window);
    }
    if (!drewHierarchy || normalized == nil) {
        if (failure != NULL) {
            *failure = drewHierarchy
                ? @"drawViewHierarchy returned invalid pixels or geometry"
                : @"drawViewHierarchy reported incomplete rendering";
        }
        return nil;
    }
    return normalized;
}

static NSDictionary<NSString *, id> *IOSUseScreenshotPayloadOnMain(
    NSDictionary<NSString *, id> *profile,
    NSString **failureCode,
    NSString **failureMessage
) {
    NSCAssert(
        NSThread.isMainThread,
        @"in-process screenshot capture must run on the main thread"
    );
    CGSize logicalSize = CGSizeZero;
    CGSize pixelSize = CGSizeZero;
    CGFloat scale = 0;
    if (!IOSUseScreenshotProfile(
            profile,
            &logicalSize,
            &pixelSize,
            &scale
        )) {
        IOSUseSetScreenshotFailure(
            @"invalid_profile",
            @"runtime screenshot profile geometry is invalid",
            failureCode,
            failureMessage
        );
        return nil;
    }

    UIWindow *window = IOSUseScreenshotUIKitWindow();
    NSMutableArray<NSString *> *failures = [NSMutableArray array];
    NSString *attemptFailure = nil;
    NSString *source = @"cgwindow-self";
    BOOL complete = YES;
    UIImage *image = IOSUseScreenshotCGWindow(
        window,
        logicalSize,
        scale,
        &attemptFailure
    );
    if (image == nil) {
        [failures addObject:[NSString stringWithFormat:
            @"cgwindow-self: %@",
            attemptFailure ?: @"capture failed"
        ]];
        attemptFailure = nil;
        image = IOSUseScreenshotPrivateUIKit(
            logicalSize,
            scale,
            &source,
            &attemptFailure
        );
    }
    if (image == nil) {
        [failures addObject:[NSString stringWithFormat:
            @"private-uikit: %@",
            attemptFailure ?: @"capture failed"
        ]];
        attemptFailure = nil;
        source = @"draw-view-hierarchy";
        image = IOSUseScreenshotDrawHierarchy(
            window,
            logicalSize,
            scale,
            &complete,
            &attemptFailure
        );
    }
    if (image == nil) {
        [failures addObject:[NSString stringWithFormat:
            @"draw-view-hierarchy: %@",
            attemptFailure ?: @"capture failed"
        ]];
        IOSUseSetScreenshotFailure(
            @"screenshot_unavailable",
            [NSString stringWithFormat:
                @"all in-process screenshot strategies failed (%@)",
                [failures componentsJoinedByString:@"; "]
            ],
            failureCode,
            failureMessage
        );
        return nil;
    }

    CGImageRef finalImage = image.CGImage;
    NSUInteger finalWidth =
        finalImage == NULL ? 0 : CGImageGetWidth(finalImage);
    NSUInteger finalHeight =
        finalImage == NULL ? 0 : CGImageGetHeight(finalImage);
    if (finalWidth != (NSUInteger)llround(pixelSize.width) ||
        finalHeight != (NSUInteger)llround(pixelSize.height) ||
        !IOSUseScreenshotImageHasUsablePixels(finalImage)) {
        IOSUseSetScreenshotFailure(
            @"invalid_screenshot",
            @"normalized screenshot pixels do not match the runtime profile",
            failureCode,
            failureMessage
        );
        return nil;
    }
    NSData *jpeg = UIImageJPEGRepresentation(image, 0.9);
    if (jpeg.length == 0 ||
        jpeg.length > IOSUseScreenshotMaximumJPEGBytes) {
        IOSUseSetScreenshotFailure(
            @"screenshot_too_large",
            @"normalized screenshot JPEG is empty or exceeds 11 MiB",
            failureCode,
            failureMessage
        );
        return nil;
    }
    NSString *base64 = [jpeg base64EncodedStringWithOptions:0];
    if (base64.length == 0 ||
        [base64 lengthOfBytesUsingEncoding:NSUTF8StringEncoding] >
            IOSUseScreenshotMaximumBase64Bytes) {
        IOSUseSetScreenshotFailure(
            @"screenshot_too_large",
            @"base64 screenshot exceeds the 15 MiB payload limit",
            failureCode,
            failureMessage
        );
        return nil;
    }
    return @{
        @"jpegBase64": base64,
        @"pixelWidth": @(finalWidth),
        @"pixelHeight": @(finalHeight),
        @"logicalWidth": @(logicalSize.width),
        @"logicalHeight": @(logicalSize.height),
        @"scale": @(scale),
        @"source": source,
        @"complete": @(complete),
    };
}

NSDictionary<NSString *, id> *IOSUsePlayRuntimeScreenshotCommand(
    NSDictionary<NSString *, id> *profile,
    NSString **failureCode,
    NSString **failureMessage
) {
    if (failureCode != NULL) {
        *failureCode = nil;
    }
    if (failureMessage != NULL) {
        *failureMessage = nil;
    }
    bool expected = false;
    if (!atomic_compare_exchange_strong(
            &IOSUseScreenshotInFlight,
            &expected,
            true
        )) {
        IOSUseSetScreenshotFailure(
            @"screenshot_busy",
            @"another in-process screenshot capture is already running",
            failureCode,
            failureMessage
        );
        return nil;
    }

    if (NSThread.isMainThread) {
        NSDictionary<NSString *, id> *result = nil;
        @try {
            result = IOSUseScreenshotPayloadOnMain(
                profile,
                failureCode,
                failureMessage
            );
        } @catch (NSException *exception) {
            IOSUseSetScreenshotFailure(
                @"screenshot_exception",
                [NSString stringWithFormat:
                    @"in-process screenshot raised %@",
                    exception.name
                ],
                failureCode,
                failureMessage
            );
        } @finally {
            atomic_store(&IOSUseScreenshotInFlight, false);
        }
        return result;
    }

    __block NSDictionary<NSString *, id> *result;
    __block NSString *blockFailureCode;
    __block NSString *blockFailureMessage;
    dispatch_semaphore_t completion = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            @try {
                result = IOSUseScreenshotPayloadOnMain(
                    profile,
                    &blockFailureCode,
                    &blockFailureMessage
                );
            } @catch (NSException *exception) {
                blockFailureCode = @"screenshot_exception";
                blockFailureMessage = [NSString stringWithFormat:
                    @"in-process screenshot raised %@",
                    exception.name
                ];
            } @finally {
                atomic_store(&IOSUseScreenshotInFlight, false);
                dispatch_semaphore_signal(completion);
            }
        }
    });
    dispatch_time_t deadline = dispatch_time(
        DISPATCH_TIME_NOW,
        (int64_t)(
            IOSUseScreenshotMainThreadTimeoutSeconds * NSEC_PER_SEC
        )
    );
    if (dispatch_semaphore_wait(completion, deadline) != 0) {
        IOSUseSetScreenshotFailure(
            @"main_thread_timeout",
            @"in-process screenshot capture exceeded the main-thread deadline",
            failureCode,
            failureMessage
        );
        return nil;
    }
    if (result == nil) {
        IOSUseSetScreenshotFailure(
            blockFailureCode ?: @"screenshot_unavailable",
            blockFailureMessage ?: @"in-process screenshot capture failed",
            failureCode,
            failureMessage
        );
    }
    return result;
}
