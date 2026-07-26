#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <MetalKit/MetalKit.h>
#import "IOSUsePlayDevice.h"
#import "IOSUsePlayWindowCompositor.h"
#import <dlfcn.h>
#import <string.h>
#import <unistd.h>

typedef int32_t CGSConnectionID;
typedef CGSConnectionID (*CGSMainConnectionIDFunction)(void);
typedef CFArrayRef _Nullable (*CGSHWCaptureWindowListFunction)(
    CGSConnectionID,
    const uint32_t *,
    uint32_t,
    uint32_t
);

enum {
    CGSHWIgnoreGlobalClipShape = 1U << 11,
    CGSHWBestResolution = 1U << 8,
    CGSHWFullSize = 1U << 19,
};

@interface MappingFixtureUIKitWindow : NSObject
@property(nonatomic, strong) id directWindow;
@property(nonatomic) BOOL keyWindow;
@end

@implementation MappingFixtureUIKitWindow
- (id)nsWindow {
    return self.directWindow;
}
@end

@interface MappingFixtureAppKitWindow : NSObject
@property(nonatomic, copy) NSArray *uiWindows;
@property(nonatomic) BOOL visible;
@property(nonatomic) NSInteger number;
@end

@implementation MappingFixtureAppKitWindow
@end

@interface OriginFixtureOverlayView : NSView
@end

@implementation OriginFixtureOverlayView
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGRect bounds = self.bounds;
    CGRect lower = bounds;
    lower.size.height = bounds.size.height / 2.0;
    [[NSColor colorWithSRGBRed:0.1
                         green:0.8
                          blue:0.2
                         alpha:1.0] setFill];
    NSRectFill(lower);
    CGRect upper = lower;
    upper.origin.y = CGRectGetMidY(bounds);
    [[NSColor colorWithSRGBRed:0.9
                         green:0.8
                          blue:0.1
                         alpha:1.0] setFill];
    NSRectFill(upper);
}
@end

static void PumpRunLoop(NSTimeInterval seconds) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([deadline timeIntervalSinceNow] > 0) {
        [NSRunLoop.currentRunLoop
            runMode:NSDefaultRunLoopMode
         beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
}

static BOOL RunMappingAndCountFixtures(void) {
    MappingFixtureUIKitWindow *uiWindow =
        [[MappingFixtureUIKitWindow alloc] init];
    MappingFixtureAppKitWindow *privateShortcut =
        [[MappingFixtureAppKitWindow alloc] init];
    MappingFixtureAppKitWindow *associatedHost =
        [[MappingFixtureAppKitWindow alloc] init];
    uiWindow.directWindow = privateShortcut;
    associatedHost.uiWindows = @[uiWindow];
    NSString *source;
    id resolved = IOSUsePlayResolveMappedWindow(
        uiWindow,
        @[associatedHost],
        nil,
        &source
    );
    BOOL associationWins =
        resolved == associatedHost &&
        [source isEqualToString:@"application.uiWindows"];
    resolved = IOSUsePlayResolveMappedWindow(
        uiWindow,
        @[],
        nil,
        &source
    );
    BOOL directFallback =
        resolved == privateShortcut &&
        [source isEqualToString:@"uiWindow.nsWindow"];
    uiWindow.directWindow = nil;
    resolved = IOSUsePlayResolveMappedWindow(
        uiWindow,
        @[],
        nil,
        &source
    );
    BOOL unmappedFails = resolved == nil && source == nil;
    MappingFixtureAppKitWindow *keyFallback =
        [[MappingFixtureAppKitWindow alloc] init];
    resolved = IOSUsePlayResolveMappedWindow(
        uiWindow,
        @[],
        keyFallback,
        &source
    );
    BOOL keyFallbackWorks =
        resolved == keyFallback &&
        [source isEqualToString:@"application.keyWindow"];

    MappingFixtureUIKitWindow *inactiveKey =
        [[MappingFixtureUIKitWindow alloc] init];
    inactiveKey.keyWindow = YES;
    MappingFixtureUIKitWindow *activeKey =
        [[MappingFixtureUIKitWindow alloc] init];
    activeKey.keyWindow = YES;
    NSDictionary *inactiveScene = @{
        @"identifier": @"scene-b",
        @"rank": @1,
        @"windows": @[inactiveKey],
    };
    NSDictionary *activeSceneZ = @{
        @"identifier": @"scene-z",
        @"rank": @0,
        @"windows": @[],
    };
    NSDictionary *activeSceneA = @{
        @"identifier": @"scene-a",
        @"rank": @0,
        @"windows": @[activeKey],
    };
    NSString *sceneFailure;
    NSArray *orderedScenes = IOSUsePlayOrderForegroundScenes(
        @[inactiveScene, activeSceneZ, activeSceneA],
        ^NSInteger(id scene) {
            return [scene[@"rank"] integerValue];
        },
        ^NSString *(id scene) {
            return scene[@"identifier"];
        },
        &sceneFailure
    );
    id primary = IOSUsePlaySelectPrimaryWindow(
        orderedScenes,
        ^NSArray *(id scene) {
            return scene[@"windows"];
        },
        ^BOOL(id window) {
            return ((MappingFixtureUIKitWindow *)window)
                .keyWindow;
        }
    );
    BOOL scenePolicyWorks =
        orderedScenes.count == 3 &&
        orderedScenes[0] == activeSceneA &&
        orderedScenes[1] == activeSceneZ &&
        orderedScenes[2] == inactiveScene &&
        primary == activeKey &&
        sceneFailure == nil;

    MappingFixtureAppKitWindow *main =
        [[MappingFixtureAppKitWindow alloc] init];
    main.visible = YES;
    main.number = 41;
    MappingFixtureAppKitWindow *visibleAlert =
        [[MappingFixtureAppKitWindow alloc] init];
    visibleAlert.visible = YES;
    visibleAlert.number = 42;
    MappingFixtureAppKitWindow *hiddenAlert =
        [[MappingFixtureAppKitWindow alloc] init];
    hiddenAlert.visible = NO;
    hiddenAlert.number = -1;
    NSString *unionFailure;
    NSArray *nativeUnion = IOSUsePlayUnionCaptureWindows(
        @[main],
        @[main, hiddenAlert, visibleAlert],
        ^BOOL(id window) {
            return ((MappingFixtureAppKitWindow *)window).visible;
        },
        ^NSInteger(id window) {
            return ((MappingFixtureAppKitWindow *)window).number;
        },
        &unionFailure
    );
    BOOL nativeAlertUnionWorks =
        nativeUnion.count == 2 &&
        nativeUnion[0] == main &&
        nativeUnion[1] == visibleAlert &&
        unionFailure == nil;

    CGRect logicalRect = CGRectZero;
    NSString *geometryFailure;
    BOOL cgPlacementWinsOverDivergentAppKitOrigin =
        IOSUsePlayValidateRelativeWindowGeometry(
            CGRectMake(590, 0, 430, 932),
            CGRectMake(590, 374, 430, 932),
            CGRectMake(675, 428, 260, 219),
            CGRectMake(675, 730, 260, 219),
            &logicalRect,
            &geometryFailure
        ) &&
        fabs(logicalRect.origin.x - 85) < 0.01 &&
        fabs(logicalRect.origin.y - 356) < 0.01 &&
        fabs(logicalRect.size.width - 260) < 0.01 &&
        fabs(logicalRect.size.height - 219) < 0.01;
    BOOL mismatchedSizeFails =
        !IOSUsePlayValidateRelativeWindowGeometry(
            CGRectMake(590, 0, 430, 932),
            CGRectMake(590, 374, 430, 932),
            CGRectMake(675, 428, 260, 218),
            CGRectMake(675, 730, 260, 219),
            NULL,
            &geometryFailure
        ) &&
        [geometryFailure containsString:@"size"];
    CGRect buttonLogicalRect = CGRectZero;
    NSString *buttonGeometryFailure = nil;
    BOOL buttonBottomLeftToTopLeftWorks =
        IOSUsePlayResolveLocalAppKitRect(
            logicalRect,
            CGRectMake(160, 20, 80, 30),
            &buttonLogicalRect,
            &buttonGeometryFailure
        ) &&
        fabs(buttonLogicalRect.origin.x - 245) < 0.01 &&
        fabs(buttonLogicalRect.origin.y - 525) < 0.01 &&
        fabs(buttonLogicalRect.size.width - 80) < 0.01 &&
        fabs(buttonLogicalRect.size.height - 30) < 0.01;
    IOSUsePlayWindowPlanEntry beforePlan[2] = {
        {
            .windowNumber = 42,
            .appKitFrame = CGRectMake(675, 341, 260, 219),
            .cgWindowBounds = CGRectMake(675, 410, 260, 219),
            .backingScale = 2,
        },
        {
            .windowNumber = 41,
            .appKitFrame = CGRectMake(590, 0, 430, 932),
            .cgWindowBounds = CGRectMake(590, 38, 430, 932),
            .backingScale = 2,
        },
    };
    IOSUsePlayWindowPlanEntry afterPlan[2] = {
        beforePlan[0],
        beforePlan[1],
    };
    NSString *planFailure;
    BOOL stablePlanWorks = IOSUsePlayWindowCapturePlansEqual(
        beforePlan,
        2,
        41,
        afterPlan,
        2,
        41,
        &planFailure
    );
    afterPlan[0].cgWindowBounds.origin.y += 1;
    BOOL changedPlanFails = !IOSUsePlayWindowCapturePlansEqual(
        beforePlan,
        2,
        41,
        afterPlan,
        2,
        41,
        &planFailure
    );
    afterPlan[0] = beforePlan[0];
    afterPlan[0].windowNumber += 1;
    BOOL changedWindowIdentityFails =
        !IOSUsePlayWindowCapturePlansEqual(
            beforePlan,
            2,
            41,
            afterPlan,
            2,
            41,
            &planFailure
        );

    CFArrayRef oneImage = (__bridge CFArrayRef)@[@1];
    NSString *countFailure;
    BOOL exactCount = IOSUsePlayValidateCapturedWindowCount(
        1,
        oneImage,
        &countFailure
    );
    BOOL missingCaptureFails =
        !IOSUsePlayValidateCapturedWindowCount(
            2,
            oneImage,
            &countFailure
        ) &&
        [countFailure containsString:
            @"requested 2 windows but returned 1 images"];
    BOOL passed = associationWins &&
        directFallback &&
        unmappedFails &&
        keyFallbackWorks &&
        scenePolicyWorks &&
        nativeAlertUnionWorks &&
        cgPlacementWinsOverDivergentAppKitOrigin &&
        mismatchedSizeFails &&
        buttonBottomLeftToTopLeftWorks &&
        stablePlanWorks &&
        changedPlanFails &&
        changedWindowIdentityFails &&
        exactCount &&
        missingCaptureFails;
    fprintf(
        stderr,
        "[cgshw-smoke] policy association=%d direct=%d key=%d "
        "unmapped=%d scenes=%d alert-union=%d cg-placement=%d "
        "size-mismatch=%d button=%d stable=%d changed=%d identity=%d "
        "count=%d missing=%d "
        "pass=%d\n",
        associationWins,
        directFallback,
        keyFallbackWorks,
        unmappedFails,
        scenePolicyWorks,
        nativeAlertUnionWorks,
        cgPlacementWinsOverDivergentAppKitOrigin,
        mismatchedSizeFails,
        buttonBottomLeftToTopLeftWorks,
        stablePlanWorks,
        changedPlanFails,
        changedWindowIdentityFails,
        exactCount,
        missingCaptureFails,
        passed
    );
    return passed;
}

static BOOL SampleCenter(CGImageRef image, uint8_t output[4]) {
    if (image == NULL ||
        CGImageGetWidth(image) == 0 ||
        CGImageGetHeight(image) == 0) {
        return NO;
    }
    uint8_t pixel[4] = {0};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    if (space == NULL) {
        return NO;
    }
    CGContextRef context = CGBitmapContextCreate(
        pixel,
        1,
        1,
        8,
        4,
        space,
        kCGBitmapByteOrder32Little |
            kCGImageAlphaPremultipliedFirst
    );
    CGColorSpaceRelease(space);
    if (context == NULL) {
        return NO;
    }
    CGContextDrawImage(context, CGRectMake(0, 0, 1, 1), image);
    CGContextRelease(context);
    memcpy(output, pixel, 4);
    return YES;
}

static BOOL SampleTopLeftPixel(
    CGImageRef image,
    size_t x,
    size_t y,
    uint8_t output[4]
) {
    if (image == NULL ||
        x >= CGImageGetWidth(image) ||
        y >= CGImageGetHeight(image)) {
        return NO;
    }
    CGImageRef pixel = CGImageCreateWithImageInRect(
        image,
        CGRectMake(x, y, 1, 1)
    );
    BOOL sampled = SampleCenter(pixel, output);
    if (pixel != NULL) {
        CGImageRelease(pixel);
    }
    return sampled;
}

static CGImageRef CaptureWindow(
    CGSHWCaptureWindowListFunction capture,
    CGSMainConnectionIDFunction mainConnection,
    CGWindowID windowID
) CF_RETURNS_RETAINED {
    uint32_t rawWindowID = windowID;
    CFArrayRef images = capture(
        mainConnection(),
        &rawWindowID,
        1,
        CGSHWIgnoreGlobalClipShape |
            CGSHWBestResolution |
            CGSHWFullSize
    );
    if (images == NULL || CFArrayGetCount(images) != 1) {
        if (images != NULL) {
            CFRelease(images);
        }
        return NULL;
    }
    CGImageRef image = (CGImageRef)CFArrayGetValueAtIndex(images, 0);
    if (image != NULL) {
        CGImageRetain(image);
    }
    CFRelease(images);
    return image;
}

static NSWindow *CreateWindowAtFrame(
    NSView *content,
    CGRect frame,
    Class windowClass
) {
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:NSWindowStyleMaskBorderless
                    backing:NSBackingStoreBuffered
                      defer:NO];
    if (windowClass != Nil && windowClass != NSWindow.class) {
        window = [[windowClass alloc]
            initWithContentRect:frame
                      styleMask:NSWindowStyleMaskBorderless
                        backing:NSBackingStoreBuffered
                          defer:NO];
    }
    window.opaque = YES;
    window.hasShadow = NO;
    window.contentView = content;
    [window orderFront:nil];
    [window displayIfNeeded];
    PumpRunLoop(0.15);
    return window;
}

static NSWindow *CreateWindow(NSView *content) {
    return CreateWindowAtFrame(
        content,
        NSMakeRect(
            100,
            100,
            IOSUsePlayDeviceLogicalWidth,
            IOSUsePlayDeviceLogicalHeight
        ),
        NSWindow.class
    );
}

static BOOL RunLayerSmoke(
    CGSHWCaptureWindowListFunction capture,
    CGSMainConnectionIDFunction mainConnection
) {
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(
        0,
        0,
        IOSUsePlayDeviceLogicalWidth,
        IOSUsePlayDeviceLogicalHeight
    )];
    view.wantsLayer = YES;
    view.layer.backgroundColor =
        NSColor.redColor.CGColor;
    NSWindow *window = CreateWindow(view);
    CGImageRef image = CaptureWindow(
        capture,
        mainConnection,
        (CGWindowID)window.windowNumber
    );
    uint8_t pixel[4] = {0};
    BOOL sampled = SampleCenter(image, pixel);
    size_t width = image == NULL ? 0 : CGImageGetWidth(image);
    size_t height = image == NULL ? 0 : CGImageGetHeight(image);
    BOOL passed = sampled &&
        pixel[3] > 240 &&
        pixel[2] > 220 &&
        pixel[1] < 30 &&
        pixel[0] < 30 &&
        width > 0 &&
        height > 0 &&
        fabs(
            (double)width / (double)height -
            (double)IOSUsePlayDeviceLogicalWidth /
                (double)IOSUsePlayDeviceLogicalHeight
        ) < 0.005;
    fprintf(
        stderr,
        "[cgshw-smoke] CALayer %zux%zu BGRA=[%u,%u,%u,%u] pass=%d\n",
        width,
        height,
        pixel[0],
        pixel[1],
        pixel[2],
        pixel[3],
        passed
    );
    if (image != NULL) {
        CGImageRelease(image);
    }
    [window orderOut:nil];
    return passed;
}

static BOOL OwnWindowMetadata(
    CGWindowID windowID,
    NSInteger *frontToBackIndex,
    CGRect *bounds
) {
    if (frontToBackIndex != NULL) {
        *frontToBackIndex = -1;
    }
    if (bounds != NULL) {
        *bounds = CGRectZero;
    }
    CFArrayRef raw = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly,
        kCGNullWindowID
    );
    if (raw == NULL) {
        return NO;
    }
    NSArray *entries = CFBridgingRelease(raw);
    pid_t processID = getpid();
    for (NSUInteger index = 0; index < entries.count; index += 1) {
        NSDictionary *entry = entries[index];
        NSNumber *owner =
            entry[(__bridge NSString *)kCGWindowOwnerPID];
        NSNumber *number =
            entry[(__bridge NSString *)kCGWindowNumber];
        if (owner.intValue == processID &&
            number.unsignedIntValue == windowID) {
            id rawBounds =
                entry[(__bridge NSString *)kCGWindowBounds];
            CGRect windowBounds = CGRectZero;
            if (![rawBounds isKindOfClass:NSDictionary.class] ||
                !CGRectMakeWithDictionaryRepresentation(
                    (__bridge CFDictionaryRef)rawBounds,
                    &windowBounds
                )) {
                return NO;
            }
            if (frontToBackIndex != NULL) {
                *frontToBackIndex = (NSInteger)index;
            }
            if (bounds != NULL) {
                *bounds = windowBounds;
            }
            return YES;
        }
    }
    return NO;
}

static BOOL PixelIsBlue(const uint8_t pixel[4]) {
    return pixel[3] > 240 &&
        pixel[0] > 180 &&
        pixel[1] < 70 &&
        pixel[2] < 70;
}

static BOOL PixelIsGreen(const uint8_t pixel[4]) {
    return pixel[3] > 240 &&
        pixel[1] > 150 &&
        pixel[0] < 100 &&
        pixel[2] < 100;
}

static BOOL PixelIsYellow(const uint8_t pixel[4]) {
    return pixel[3] > 240 &&
        pixel[1] > 150 &&
        pixel[2] > 150 &&
        pixel[0] < 100;
}

static BOOL RunOriginAndZOrderFixture(
    CGSHWCaptureWindowListFunction capture,
    CGSMainConnectionIDFunction mainConnection
) {
    CGRect screen = NSScreen.mainScreen.frame;
    CGRect baseFrame = CGRectMake(
        floor(CGRectGetMidX(screen) -
            IOSUsePlayDeviceLogicalWidth / 2.0),
        CGRectGetMinY(screen),
        IOSUsePlayDeviceLogicalWidth,
        IOSUsePlayDeviceLogicalHeight
    );
    if (!CGRectContainsRect(screen, baseFrame)) {
        fprintf(
            stderr,
            "[cgshw-smoke] screen cannot fit origin fixture\n"
        );
        return NO;
    }
    NSView *baseView = [[NSView alloc] initWithFrame:NSMakeRect(
        0,
        0,
        baseFrame.size.width,
        baseFrame.size.height
    )];
    baseView.wantsLayer = YES;
    baseView.layer.backgroundColor = NSColor.blueColor.CGColor;
    NSWindow *base = CreateWindowAtFrame(
        baseView,
        baseFrame,
        NSWindow.class
    );

    CGRect overlayFrame = CGRectMake(
        baseFrame.origin.x + 85,
        baseFrame.origin.y + 341,
        260,
        219
    );
    OriginFixtureOverlayView *overlayView =
        [[OriginFixtureOverlayView alloc] initWithFrame:NSMakeRect(
        0,
        0,
        overlayFrame.size.width,
        overlayFrame.size.height
    )];
    NSPanel *overlay = (NSPanel *)CreateWindowAtFrame(
        overlayView,
        overlayFrame,
        NSPanel.class
    );
    overlay.hidesOnDeactivate = NO;
    overlay.level = NSModalPanelWindowLevel;
    [base orderFrontRegardless];
    [overlay orderFrontRegardless];
    [base displayIfNeeded];
    [overlay displayIfNeeded];
    PumpRunLoop(0.15);

    NSInteger overlayOrder = -1;
    NSInteger baseOrder = -1;
    CGRect overlayCGBounds = CGRectZero;
    CGRect baseCGBounds = CGRectZero;
    BOOL overlayMetadataReady = OwnWindowMetadata(
        (CGWindowID)overlay.windowNumber,
        &overlayOrder,
        &overlayCGBounds
    );
    BOOL baseMetadataReady = OwnWindowMetadata(
        (CGWindowID)base.windowNumber,
        &baseOrder,
        &baseCGBounds
    );
    BOOL zOrderReady =
        overlayMetadataReady &&
        baseMetadataReady &&
        overlayOrder >= 0 &&
        baseOrder >= 0 &&
        overlayOrder < baseOrder;
    CGRect actualLogicalRect = CGRectZero;
    NSString *actualGeometryFailure = nil;
    BOOL relativeOriginReady =
        overlayMetadataReady &&
        baseMetadataReady &&
        IOSUsePlayValidateRelativeWindowGeometry(
            base.frame,
            baseCGBounds,
            overlay.frame,
            overlayCGBounds,
            &actualLogicalRect,
            &actualGeometryFailure
        ) &&
        fabs(actualLogicalRect.origin.x - 85) < 0.01 &&
        fabs(actualLogicalRect.origin.y - 372) < 0.01 &&
        fabs(actualLogicalRect.size.width - 260) < 0.01 &&
        fabs(actualLogicalRect.size.height - 219) < 0.01;
    uint32_t windowIDs[2] = {
        (uint32_t)overlay.windowNumber,
        (uint32_t)base.windowNumber,
    };
    // CGSHW coalesces a multi-window request into one image on current
    // macOS. Runtime intentionally requests one window at a time so each
    // requested native window has exactly one attributable capture.
    CFArrayRef batch = capture(
        mainConnection(),
        windowIDs,
        2,
        CGSHWIgnoreGlobalClipShape |
            CGSHWBestResolution |
            CGSHWFullSize
    );
    CFIndex batchCount =
        batch == NULL ? 0 : CFArrayGetCount(batch);
    if (batch != NULL) {
        CFRelease(batch);
    }
    CGImageRef frontImage = CaptureWindow(
        capture,
        mainConnection,
        (CGWindowID)overlay.windowNumber
    );
    CGImageRef backImage = CaptureWindow(
        capture,
        mainConnection,
        (CGWindowID)base.windowNumber
    );
    if (frontImage == NULL || backImage == NULL) {
        if (frontImage != NULL) {
            CGImageRelease(frontImage);
        }
        if (backImage != NULL) {
            CGImageRelease(backImage);
        }
        [overlay orderOut:nil];
        [base orderOut:nil];
        return NO;
    }
    uint8_t frontCenter[4] = {0};
    uint8_t frontTop[4] = {0};
    uint8_t frontBottom[4] = {0};
    uint8_t backCenter[4] = {0};
    BOOL sourceIdentityReady =
        SampleCenter(frontImage, frontCenter) &&
        SampleTopLeftPixel(
            frontImage,
            CGImageGetWidth(frontImage) / 2,
            CGImageGetHeight(frontImage) / 4,
            frontTop
        ) &&
        SampleTopLeftPixel(
            frontImage,
            CGImageGetWidth(frontImage) / 2,
            CGImageGetHeight(frontImage) * 3 / 4,
            frontBottom
        ) &&
        SampleCenter(backImage, backCenter) &&
        PixelIsYellow(frontTop) &&
        PixelIsGreen(frontBottom) &&
        PixelIsBlue(backCenter);

    IOSUsePlayWindowCapture sources[2] = {
        {
            .image = frontImage,
            .appKitFrame = overlay.frame,
            .deviceLogicalRect = actualLogicalRect,
            .backingScale = overlay.backingScaleFactor,
            .windowNumber = (uint32_t)overlay.windowNumber,
        },
        {
            .image = backImage,
            .appKitFrame = base.frame,
            .deviceLogicalRect = CGRectMake(
                0,
                0,
                IOSUsePlayDeviceLogicalWidth,
                IOSUsePlayDeviceLogicalHeight
            ),
            .backingScale = base.backingScaleFactor,
            .windowNumber = (uint32_t)base.windowNumber,
        },
    };
    NSArray<NSDictionary<NSString *, id> *> *evidence;
    NSString *failure;
    CGImageRef composite = IOSUsePlayCompositeWindowCaptures(
        sources,
        2,
        CGRectMake(
            0,
            0,
            IOSUsePlayDeviceLogicalWidth,
            IOSUsePlayDeviceLogicalHeight
        ),
        (uint32_t)base.windowNumber,
        &evidence,
        &failure
    );
    uint8_t topGap[4] = {0};
    uint8_t overlayTop[4] = {0};
    uint8_t overlayBottom[4] = {0};
    uint8_t outside[4] = {0};
    size_t scale = (size_t)IOSUsePlayDeviceScale;
    BOOL placementReady =
        composite != NULL &&
        SampleTopLeftPixel(
            composite,
            100 * scale,
            350 * scale,
            topGap
        ) &&
        SampleTopLeftPixel(
            composite,
            100 * scale,
            400 * scale,
            overlayTop
        ) &&
        SampleTopLeftPixel(
            composite,
            100 * scale,
            580 * scale,
            overlayBottom
        ) &&
        SampleTopLeftPixel(
            composite,
            20 * scale,
            20 * scale,
            outside
        ) &&
        PixelIsBlue(topGap) &&
        PixelIsYellow(overlayTop) &&
        PixelIsGreen(overlayBottom) &&
        PixelIsBlue(outside);
    NSDictionary *frontGeometry =
        evidence.count > 0 ? evidence[0] : @{};
    NSDictionary *logicalRect =
        frontGeometry[@"deviceLogicalRect"];
    BOOL evidenceReady =
        [frontGeometry[@"windowNumber"] unsignedIntValue] ==
            (uint32_t)overlay.windowNumber &&
        fabs([logicalRect[@"x"] doubleValue] - 85) < 0.01 &&
        fabs([logicalRect[@"y"] doubleValue] - 372) < 0.01 &&
        fabs([logicalRect[@"width"] doubleValue] - 260) < 0.01 &&
        fabs([logicalRect[@"height"] doubleValue] - 219) < 0.01;
    NSString *fingerprintFailure;
    NSDictionary *greenFingerprint =
        IOSUsePlayFingerprintCompositorImage(
            composite,
            CGRectMake(100, 580, 1, 1),
            &fingerprintFailure
        );
    NSDictionary *greenFingerprintAgain =
        IOSUsePlayFingerprintCompositorImage(
            composite,
            CGRectMake(100, 580, 1, 1),
            &fingerprintFailure
        );
    NSDictionary *blueFingerprint =
        IOSUsePlayFingerprintCompositorImage(
            composite,
            CGRectMake(20, 20, 1, 1),
            &fingerprintFailure
        );
    NSDictionary *invalidFingerprint =
        IOSUsePlayFingerprintCompositorImage(
            composite,
            CGRectMake(-1, 20, 1, 1),
            &fingerprintFailure
        );
    BOOL fingerprintReady =
        greenFingerprint != nil &&
        greenFingerprintAgain != nil &&
        blueFingerprint != nil &&
        [greenFingerprint[@"hash"]
            isEqual:greenFingerprintAgain[@"hash"]] &&
        ![greenFingerprint[@"hash"]
            isEqual:blueFingerprint[@"hash"]] &&
        [greenFingerprint[@"pixelWidth"]
            unsignedIntegerValue] == 3 &&
        [greenFingerprint[@"pixelHeight"]
            unsignedIntegerValue] == 3 &&
        invalidFingerprint == nil &&
        [fingerprintFailure containsString:
            @"completely inside"];

    IOSUsePlayWindowCapture offDevice[2] = {
        sources[0],
        sources[1],
    };
    offDevice[0].deviceLogicalRect.origin.x =
        IOSUsePlayDeviceLogicalWidth -
        offDevice[0].deviceLogicalRect.size.width +
        1;
    NSString *offDeviceFailure;
    CGImageRef invalid = IOSUsePlayCompositeWindowCaptures(
        offDevice,
        2,
        CGRectMake(
            0,
            0,
            IOSUsePlayDeviceLogicalWidth,
            IOSUsePlayDeviceLogicalHeight
        ),
        (uint32_t)base.windowNumber,
        NULL,
        &offDeviceFailure
    );
    BOOL offDeviceFails =
        invalid == NULL &&
        [offDeviceFailure containsString:@"outside"];
    if (invalid != NULL) {
        CGImageRelease(invalid);
    }
    BOOL passed = zOrderReady &&
        relativeOriginReady &&
        sourceIdentityReady &&
        placementReady &&
        evidenceReady &&
        fingerprintReady &&
        offDeviceFails;
    fprintf(
        stderr,
        "[cgshw-smoke] origin/z-order base=(%.0f,%.0f) "
        "orders=%ld/%ld batch-count=%ld relative-origin=%d sources=%d "
        "placement=%d evidence=%d fingerprint=%d "
        "off-device=%d frontBGRA=[%u,%u,%u,%u] "
        "topBGRA=[%u,%u,%u,%u] bottomBGRA=[%u,%u,%u,%u] "
        "pass=%d%s%s\n",
        baseFrame.origin.x,
        baseFrame.origin.y,
        (long)overlayOrder,
        (long)baseOrder,
        (long)batchCount,
        relativeOriginReady,
        sourceIdentityReady,
        placementReady,
        evidenceReady,
        fingerprintReady,
        offDeviceFails,
        frontCenter[0],
        frontCenter[1],
        frontCenter[2],
        frontCenter[3],
        topGap[0],
        topGap[1],
        topGap[2],
        topGap[3],
        overlayBottom[0],
        overlayBottom[1],
        overlayBottom[2],
        overlayBottom[3],
        passed,
        failure == nil && actualGeometryFailure == nil
            ? ""
            : " failure=",
        failure != nil
            ? failure.UTF8String
            : (actualGeometryFailure == nil
                ? ""
                : actualGeometryFailure.UTF8String)
    );
    if (composite != NULL) {
        CGImageRelease(composite);
    }
    CGImageRelease(frontImage);
    CGImageRelease(backImage);
    [overlay orderOut:nil];
    [base orderOut:nil];
    return passed;
}

static BOOL PresentMetalFrame(MTKView *view) {
    id<MTLDevice> device = view.device;
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<CAMetalDrawable> drawable = view.currentDrawable;
    MTLRenderPassDescriptor *descriptor =
        view.currentRenderPassDescriptor;
    if (queue == nil || drawable == nil || descriptor == nil) {
        return NO;
    }
    descriptor.colorAttachments[0].loadAction =
        MTLLoadActionClear;
    descriptor.colorAttachments[0].storeAction =
        MTLStoreActionStore;
    descriptor.colorAttachments[0].clearColor =
        MTLClearColorMake(0.8, 0.1, 0.2, 1.0);
    id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLRenderCommandEncoder> encoder =
        [command renderCommandEncoderWithDescriptor:descriptor];
    [encoder endEncoding];
    [command presentDrawable:drawable];
    [command commit];
    [command waitUntilCompleted];
    PumpRunLoop(0.05);
    return command.status == MTLCommandBufferStatusCompleted;
}

static BOOL RunMetalSmoke(
    CGSHWCaptureWindowListFunction capture,
    CGSMainConnectionIDFunction mainConnection
) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device == nil) {
        fprintf(stderr, "[cgshw-smoke] Metal device unavailable\n");
        return NO;
    }
    MTKView *view = [[MTKView alloc]
        initWithFrame:NSMakeRect(
            0,
            0,
            IOSUsePlayDeviceLogicalWidth,
            IOSUsePlayDeviceLogicalHeight
        )
              device:device];
    view.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    view.framebufferOnly = YES;
    view.paused = YES;
    view.enableSetNeedsDisplay = NO;
    NSWindow *window = CreateWindow(view);
    if (!PresentMetalFrame(view)) {
        [window orderOut:nil];
        fprintf(stderr, "[cgshw-smoke] Metal frame presentation failed\n");
        return NO;
    }
    CGImageRef image = CaptureWindow(
        capture,
        mainConnection,
        (CGWindowID)window.windowNumber
    );
    uint8_t pixel[4] = {0};
    BOOL sampled = SampleCenter(image, pixel);
    size_t width = image == NULL ? 0 : CGImageGetWidth(image);
    size_t height = image == NULL ? 0 : CGImageGetHeight(image);
    BOOL passed = sampled &&
        pixel[3] > 240 &&
        pixel[2] > 170 &&
        pixel[1] >= 10 &&
        pixel[1] < 70 &&
        pixel[0] >= 25 &&
        pixel[0] < 90 &&
        width > 0 &&
        height > 0 &&
        fabs(
            (double)width / (double)height -
            (double)IOSUsePlayDeviceLogicalWidth /
                (double)IOSUsePlayDeviceLogicalHeight
        ) < 0.005;
    fprintf(
        stderr,
        "[cgshw-smoke] Metal %zux%zu BGRA=[%u,%u,%u,%u] pass=%d\n",
        width,
        height,
        pixel[0],
        pixel[1],
        pixel[2],
        pixel[3],
        passed
    );
    if (image != NULL) {
        CGImageRelease(image);
    }
    [window orderOut:nil];
    return passed;
}

static BOOL HostContentCGWindowRect(
    NSWindow *window,
    NSView *contentView,
    CGRect *contentCGWindowRect
) {
    if (window == nil || contentView == nil || window.screen == nil) {
        return NO;
    }
    NSRect windowLocal = [contentView convertRect:contentView.bounds
                                           toView:nil];
    NSRect screenRect = [window convertRectToScreen:windowLocal];
    CGRect mainDisplayBounds = CGDisplayBounds(CGMainDisplayID());
    if (NSIsEmptyRect(screenRect) || CGRectIsEmpty(mainDisplayBounds)) {
        return NO;
    }
    CGRect resolved = CGRectMake(
        screenRect.origin.x,
        CGRectGetMaxY(mainDisplayBounds) - NSMaxY(screenRect),
        screenRect.size.width,
        screenRect.size.height
    );
    if (CGRectIsEmpty(resolved)) {
        return NO;
    }
    if (contentCGWindowRect != NULL) {
        *contentCGWindowRect = resolved;
    }
    return YES;
}

static BOOL RunSimulatorScaleHostCanvasSmoke(
    CGSHWCaptureWindowListFunction capture,
    CGSMainConnectionIDFunction mainConnection
) {
    NSScreen *screen = NSScreen.mainScreen;
    CGFloat requestedDisplayScale = 0.75;
    CGSize contentSize = CGSizeMake(
        IOSUsePlayDeviceLogicalWidth * requestedDisplayScale,
        IOSUsePlayDeviceLogicalHeight * requestedDisplayScale
    );
    if (screen == nil || screen.visibleFrame.size.width < contentSize.width ||
        screen.visibleFrame.size.height < contentSize.height) {
        fprintf(
            stderr,
            "[cgshw-smoke] screen cannot fit Simulator-scale host\n"
        );
        return NO;
    }
    NSRect contentRect = NSMakeRect(
        floor(NSMidX(screen.visibleFrame) - contentSize.width / 2.0),
        floor(NSMidY(screen.visibleFrame) - contentSize.height / 2.0),
        contentSize.width,
        contentSize.height
    );
    NSWindowStyleMask style = NSWindowStyleMaskTitled |
        NSWindowStyleMaskClosable |
        NSWindowStyleMaskMiniaturizable |
        NSWindowStyleMaskResizable;
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:contentRect
                  styleMask:style
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.title = @"Simulator Scale Host Smoke";
    window.contentAspectRatio = NSMakeSize(
        IOSUsePlayDeviceLogicalWidth,
        IOSUsePlayDeviceLogicalHeight
    );
    window.contentMinSize = NSMakeSize(
        IOSUsePlayDeviceLogicalWidth *
            IOSUsePlayHostCanvasMinimumDisplayScale,
        IOSUsePlayDeviceLogicalHeight *
            IOSUsePlayHostCanvasMinimumDisplayScale
    );
    window.movable = YES;
    NSView *hostContent = [[NSView alloc]
        initWithFrame:NSMakeRect(0, 0, contentSize.width, contentSize.height)];
    window.contentView = hostContent;
    [window setContentSize:contentSize];
    [window orderFront:nil];
    [window displayIfNeeded];
    PumpRunLoop(0.2);
    IOSUsePlayHostCanvasLayout layout;
    NSString *layoutFailure = nil;
    BOOL layoutReady = IOSUsePlayResolveHostCanvasLayout(
        hostContent.bounds,
        &layout,
        &layoutFailure
    );
    NSView *canvas = [[NSView alloc] initWithFrame:layout.canvasRect];
    canvas.bounds = NSMakeRect(
        0,
        0,
        IOSUsePlayDeviceLogicalWidth,
        IOSUsePlayDeviceLogicalHeight
    );
    canvas.wantsLayer = YES;
    canvas.layer.backgroundColor = NSColor.greenColor.CGColor;
    [hostContent addSubview:canvas];
    [window displayIfNeeded];
    PumpRunLoop(0.1);

    CGRect hostCGBounds = CGRectZero;
    CGRect contentCGBounds = CGRectZero;
    BOOL metadataReady = OwnWindowMetadata(
        (CGWindowID)window.windowNumber,
        NULL,
        &hostCGBounds
    );
    BOOL contentReady = HostContentCGWindowRect(
        window,
        hostContent,
        &contentCGBounds
    );
    CGRect canvasCGBounds = CGRectNull;
    NSString *canvasFailure = nil;
    BOOL canvasReady = layoutReady && contentReady &&
        IOSUsePlayResolveCanvasCGWindowRect(
            contentCGBounds,
            layout,
            &canvasCGBounds,
            &canvasFailure
        );
    CGImageRef raw = metadataReady && canvasReady
        ? CaptureWindow(
            capture,
            mainConnection,
            (CGWindowID)window.windowNumber
        )
        : NULL;
    CGRect logicalRect = CGRectNull;
    NSDictionary<NSString *, id> *cropEvidence = nil;
    NSString *cropFailure = nil;
    CGImageRef normalized = raw == NULL ? NULL :
        IOSUsePlayCropAndNormalizeCanvasCapture(
            raw,
            hostCGBounds,
            canvasCGBounds,
            layout.displayScale,
            &logicalRect,
            &cropEvidence,
            &cropFailure
        );
    uint8_t center[4] = {0};
    NSDictionary<NSString *, NSNumber *> *sourceCrop =
        cropEvidence[@"sourcePixelCropRect"];
    BOOL cropExcludesHost = [cropEvidence[@"canvasOnly"] boolValue] &&
        [cropEvidence[@"hostDecorationsExcluded"] boolValue] &&
        [sourceCrop[@"y"] doubleValue] > 0;
    BOOL singleScaleReady =
        fabs(canvas.bounds.size.width - IOSUsePlayDeviceLogicalWidth) < 0.01 &&
        fabs(canvas.bounds.size.height - IOSUsePlayDeviceLogicalHeight) < 0.01 &&
        fabs(canvas.frame.origin.x - layout.canvasRect.origin.x) < 0.01 &&
        fabs(canvas.frame.origin.y - layout.canvasRect.origin.y) < 0.01 &&
        fabs(canvas.frame.size.width - layout.canvasRect.size.width) < 0.01 &&
        fabs(canvas.frame.size.height - layout.canvasRect.size.height) < 0.01 &&
        fabs(layout.displayScale - requestedDisplayScale) < 0.01;
    CGFloat leftMargin =
        NSMinX(canvas.frame) - NSMinX(hostContent.bounds);
    CGFloat rightMargin =
        NSMaxX(hostContent.bounds) - NSMaxX(canvas.frame);
    CGFloat bottomMargin =
        NSMinY(canvas.frame) - NSMinY(hostContent.bounds);
    CGFloat topMargin =
        NSMaxY(hostContent.bounds) - NSMaxY(canvas.frame);
    BOOL centeredRoundingReady =
        leftMargin >= -0.01 && rightMargin >= -0.01 &&
        bottomMargin >= -0.01 && topMargin >= -0.01 &&
        fabs(leftMargin - rightMargin) < 0.01 &&
        fabs(bottomMargin - topMargin) < 0.01 &&
        leftMargin + rightMargin < 1 &&
        bottomMargin + topMargin < 1;
    CGFloat contentAspect =
        window.contentAspectRatio.width /
        window.contentAspectRatio.height;
    CGFloat deviceAspect =
        (CGFloat)IOSUsePlayDeviceLogicalWidth /
        (CGFloat)IOSUsePlayDeviceLogicalHeight;
    BOOL passed = layoutReady && metadataReady && contentReady &&
        canvasReady && raw != NULL && normalized != NULL &&
        CGRectEqualToRect(
            logicalRect,
            CGRectMake(
                0,
                0,
                IOSUsePlayDeviceLogicalWidth,
                IOSUsePlayDeviceLogicalHeight
            )
        ) &&
        CGImageGetWidth(normalized) == IOSUsePlayDeviceNativeWidth &&
        CGImageGetHeight(normalized) == IOSUsePlayDeviceNativeHeight &&
        SampleCenter(normalized, center) && PixelIsGreen(center) &&
        cropExcludesHost && singleScaleReady && centeredRoundingReady &&
        IOSUsePlayHostCanvasSpacerPoints == 0 &&
        window.opaque && !window.titlebarAppearsTransparent &&
        window.hasShadow &&
        window.titleVisibility == NSWindowTitleVisible &&
        fabs(contentAspect - deviceAspect) < 0.0001 &&
        (window.styleMask & NSWindowStyleMaskTitled) != 0 &&
        (window.styleMask & NSWindowStyleMaskResizable) != 0;
    fprintf(
        stderr,
        "[cgshw-smoke] simulator-scale-host raw=%zux%zu normalized=%zux%zu "
        "scale=%.3f crop-y=%.1f single-scale=%d centered-rounding=%d opaque=%d title=%d title-visible=%d resizable=%d "
        "host=(%.1f,%.1f,%.1f,%.1f) content=(%.1f,%.1f,%.1f,%.1f) "
        "canvas-cg=(%.1f,%.1f,%.1f,%.1f) logical=(%.1f,%.1f,%.1f,%.1f) pass=%d%s%s\n",
        raw == NULL ? 0 : CGImageGetWidth(raw),
        raw == NULL ? 0 : CGImageGetHeight(raw),
        normalized == NULL ? 0 : CGImageGetWidth(normalized),
        normalized == NULL ? 0 : CGImageGetHeight(normalized),
        layout.displayScale,
        [sourceCrop[@"y"] doubleValue],
        singleScaleReady,
        centeredRoundingReady,
        window.opaque,
        (window.styleMask & NSWindowStyleMaskTitled) != 0,
        window.titleVisibility == NSWindowTitleVisible,
        (window.styleMask & NSWindowStyleMaskResizable) != 0,
        hostCGBounds.origin.x,
        hostCGBounds.origin.y,
        hostCGBounds.size.width,
        hostCGBounds.size.height,
        contentCGBounds.origin.x,
        contentCGBounds.origin.y,
        contentCGBounds.size.width,
        contentCGBounds.size.height,
        canvasCGBounds.origin.x,
        canvasCGBounds.origin.y,
        canvasCGBounds.size.width,
        canvasCGBounds.size.height,
        logicalRect.origin.x,
        logicalRect.origin.y,
        logicalRect.size.width,
        logicalRect.size.height,
        passed,
        layoutFailure == nil && canvasFailure == nil && cropFailure == nil
            ? ""
            : " failure=",
        cropFailure != nil
            ? cropFailure.UTF8String
            : (canvasFailure != nil
                ? canvasFailure.UTF8String
                : (layoutFailure == nil ? "" : layoutFailure.UTF8String))
    );
    if (normalized != NULL) {
        CGImageRelease(normalized);
    }
    if (raw != NULL) {
        CGImageRelease(raw);
    }
    [window orderOut:nil];
    return passed;
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSApp.activationPolicy =
            NSApplicationActivationPolicyProhibited;
        void *skyLight = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_NOW | RTLD_LOCAL
        );
        void *scope = skyLight ?: RTLD_DEFAULT;
        CGSMainConnectionIDFunction mainConnection =
            (CGSMainConnectionIDFunction)dlsym(
                scope,
                "CGSMainConnectionID"
            );
        CGSHWCaptureWindowListFunction capture =
            (CGSHWCaptureWindowListFunction)dlsym(
                scope,
                "CGSHWCaptureWindowList"
            );
        if (capture == NULL) {
            capture = (CGSHWCaptureWindowListFunction)dlsym(
                scope,
                "SLSHWCaptureWindowList"
            );
        }
        BOOL preflight = CGPreflightScreenCaptureAccess();
        fprintf(
            stderr,
            "[cgshw-smoke] screen-recording-preflight=%d\n",
            preflight
        );
        const char *requireDenied = getenv(
            "IOS_USE_REQUIRE_SCREEN_RECORDING_DENIED"
        );
        BOOL enforceDenied =
            requireDenied == NULL ||
            strcmp(requireDenied, "0") != 0;
        if (enforceDenied && preflight) {
            fprintf(
                stderr,
                "[cgshw-smoke] Screen Recording is granted; "
                "cannot prove the denied-permission gate\n"
            );
            return 3;
        }
        if (mainConnection == NULL || capture == NULL) {
            fprintf(stderr, "[cgshw-smoke] CGSHW symbols unavailable\n");
            return 2;
        }
        BOOL mappingAndCount = RunMappingAndCountFixtures();
        BOOL layer = RunLayerSmoke(capture, mainConnection);
        BOOL originAndZOrder = RunOriginAndZOrderFixture(
            capture,
            mainConnection
        );
        BOOL metal = RunMetalSmoke(capture, mainConnection);
        BOOL simulatorScaleHost = RunSimulatorScaleHostCanvasSmoke(
            capture,
            mainConnection
        );
        BOOL postflight = CGPreflightScreenCaptureAccess();
        BOOL permissionStayedDenied =
            !enforceDenied || !postflight;
        fprintf(
            stderr,
            "[cgshw-smoke] screen-recording-postflight=%d unchanged=%d\n",
            postflight,
            permissionStayedDenied
        );
        if (!mappingAndCount ||
            !layer ||
            !originAndZOrder ||
            !metal ||
            !simulatorScaleHost ||
            !permissionStayedDenied) {
            return 1;
        }
        fprintf(
            stderr,
            "[cgshw-smoke] PASS permission-independent own-window pixels\n"
        );
        return 0;
    }
}
