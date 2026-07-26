#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

#import "IOSUsePlayDevice.h"
#import "IOSUsePlayWindowCompositor.h"

#import <math.h>
#import <stdint.h>
#import <stdlib.h>

static const CGFloat IOSUseHostCanvasTestTolerance = 0.01;

static BOOL IOSUseHostCanvasTestApproximatelyEqual(
    CGFloat lhs,
    CGFloat rhs
) {
    return fabs(lhs - rhs) <= IOSUseHostCanvasTestTolerance;
}

static BOOL IOSUseHostCanvasTestRectEquals(CGRect lhs, CGRect rhs) {
    return IOSUseHostCanvasTestApproximatelyEqual(lhs.origin.x, rhs.origin.x) &&
        IOSUseHostCanvasTestApproximatelyEqual(lhs.origin.y, rhs.origin.y) &&
        IOSUseHostCanvasTestApproximatelyEqual(lhs.size.width, rhs.size.width) &&
        IOSUseHostCanvasTestApproximatelyEqual(lhs.size.height, rhs.size.height);
}

static BOOL IOSUseHostCanvasTestRequire(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(
            stderr,
            "[host-canvas-contract] %s\n",
            message.UTF8String
        );
    }
    return condition;
}

static BOOL IOSUseHostCanvasTestLayout(
    CGRect bounds,
    CGFloat expectedScale,
    CGRect expectedCanvas,
    IOSUsePlayHostCanvasLayout *layout
) {
    NSString *failure = nil;
    IOSUsePlayHostCanvasLayout resolved;
    BOOL ready = IOSUsePlayResolveHostCanvasLayout(
        bounds,
        &resolved,
        &failure
    );
    BOOL passed = ready && failure == nil &&
        IOSUseHostCanvasTestApproximatelyEqual(
            resolved.displayScale,
            expectedScale
        ) &&
        IOSUseHostCanvasTestApproximatelyEqual(
            resolved.inverseDisplayScale,
            1.0 / expectedScale
        ) &&
        IOSUseHostCanvasTestApproximatelyEqual(
            resolved.transparentSpacer,
            IOSUsePlayHostCanvasSpacerPoints
        ) &&
        IOSUseHostCanvasTestRectEquals(
            resolved.canvasRect,
            expectedCanvas
        ) &&
        IOSUseHostCanvasTestApproximatelyEqual(
            CGRectGetMaxY(resolved.canvasRect) +
                IOSUsePlayHostCanvasSpacerPoints,
            CGRectGetMaxY(bounds)
        );
    if (layout != NULL) {
        *layout = resolved;
    }
    return IOSUseHostCanvasTestRequire(
        passed,
        [NSString stringWithFormat:
            @"layout %.0fx%.0f did not preserve a fixed canvas: %@",
            bounds.size.width,
            bounds.size.height,
            failure ?: @"unexpected geometry"
        ]
    );
}

static BOOL IOSUseHostCanvasTestInitialHostFit(void) {
    // Model a titled host whose AppKit frame decoration is 28pt tall. The
    // smallest visible frame that can fit the title bar plus a half-scale
    // canvas must resolve to the explicit 215 x 474pt content minimum.
    CGSize decoration = CGSizeMake(0, 28);
    CGSize visibleMinimumFrame = CGSizeMake(215, 502);
    CGSize resolvedContent = CGSizeZero;
    NSString *failure = nil;
    BOOL minimumReady = IOSUsePlayResolveHostInitialContentSize(
        visibleMinimumFrame,
        decoration,
        &resolvedContent,
        &failure
    );
    CGSize resultingFrame = CGSizeMake(
        resolvedContent.width + decoration.width,
        resolvedContent.height + decoration.height
    );
    NSString *tooSmallFailure = nil;
    BOOL tooSmallRejected = !IOSUsePlayResolveHostInitialContentSize(
        CGSizeMake(214.9, 502),
        decoration,
        NULL,
        &tooSmallFailure
    ) && tooSmallFailure != nil;
    CGSize preferredContent = CGSizeZero;
    BOOL preferredReady = IOSUsePlayResolveHostInitialContentSize(
        CGSizeMake(1200, 1200),
        decoration,
        &preferredContent,
        NULL
    );
    BOOL passed = minimumReady && failure == nil &&
        IOSUseHostCanvasTestApproximatelyEqual(resolvedContent.width, 215) &&
        IOSUseHostCanvasTestApproximatelyEqual(resolvedContent.height, 474) &&
        resultingFrame.width <= visibleMinimumFrame.width +
            IOSUseHostCanvasTestTolerance &&
        resultingFrame.height <= visibleMinimumFrame.height +
            IOSUseHostCanvasTestTolerance &&
        tooSmallRejected && preferredReady &&
        IOSUseHostCanvasTestApproximatelyEqual(preferredContent.width, 430) &&
        IOSUseHostCanvasTestApproximatelyEqual(preferredContent.height, 940);
    return IOSUseHostCanvasTestRequire(
        passed,
        @"initial titled host fit does not preserve the half-scale canvas minimum"
    );
}

static BOOL IOSUseHostCanvasTestRoundTrip(
    IOSUsePlayHostCanvasLayout layout,
    CGPoint logicalPoint
) {
    CGPoint hostPoint = CGPointZero;
    CGPoint roundTrip = CGPointZero;
    NSString *forwardFailure = nil;
    NSString *inverseFailure = nil;
    BOOL forward = IOSUsePlayMapCanvasPointToHostContent(
        layout,
        logicalPoint,
        &hostPoint,
        &forwardFailure
    );
    BOOL inverse = forward && IOSUsePlayMapHostContentPointToCanvas(
        layout,
        hostPoint,
        &roundTrip,
        &inverseFailure
    );
    CGFloat error = hypot(
        roundTrip.x - logicalPoint.x,
        roundTrip.y - logicalPoint.y
    );
    return IOSUseHostCanvasTestRequire(
        inverse && error <= 0.5,
        [NSString stringWithFormat:
            @"host/canvas round trip failed (%.3f): %@ %@",
            error,
            forwardFailure ?: @"",
            inverseFailure ?: @""
        ]
    );
}

static CGImageRef IOSUseHostCanvasTestCreateRawCapture(
    size_t sourceWidth,
    size_t sourceHeight,
    CGRect greenPixelRect
) CF_RETURNS_RETAINED {
    const size_t rowBytes = sourceWidth * 4;
    uint8_t *pixels = calloc(sourceHeight, rowBytes);
    if (pixels == NULL) {
        return NULL;
    }
    // Native source starts red everywhere: title bar, transparent 8pt gap,
    // and any other host decoration must be excluded by the crop.
    for (size_t y = 0; y < sourceHeight; y += 1) {
        for (size_t x = 0; x < sourceWidth; x += 1) {
            uint8_t *pixel = pixels + y * rowBytes + x * 4;
            pixel[0] = 0;
            pixel[1] = 0;
            pixel[2] = 255;
            pixel[3] = 255;
        }
    }
    NSInteger minimumX = MAX(0, (NSInteger)greenPixelRect.origin.x);
    NSInteger minimumY = MAX(0, (NSInteger)greenPixelRect.origin.y);
    NSInteger maximumX = MIN(
        (NSInteger)sourceWidth,
        (NSInteger)CGRectGetMaxX(greenPixelRect)
    );
    NSInteger maximumY = MIN(
        (NSInteger)sourceHeight,
        (NSInteger)CGRectGetMaxY(greenPixelRect)
    );
    for (NSInteger y = minimumY; y < maximumY; y += 1) {
        for (NSInteger x = minimumX; x < maximumX; x += 1) {
            uint8_t *pixel = pixels + y * rowBytes + x * 4;
            pixel[0] = 0;
            pixel[1] = 255;
            pixel[2] = 0;
            pixel[3] = 255;
        }
    }
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = colorSpace == NULL ? NULL : CGBitmapContextCreate(
        pixels,
        sourceWidth,
        sourceHeight,
        8,
        rowBytes,
        colorSpace,
        kCGBitmapByteOrder32Little |
            kCGImageAlphaPremultipliedFirst
    );
    if (colorSpace != NULL) {
        CGColorSpaceRelease(colorSpace);
    }
    CGImageRef image = context == NULL
        ? NULL
        : CGBitmapContextCreateImage(context);
    if (context != NULL) {
        CGContextRelease(context);
    }
    free(pixels);
    return image;
}

static CGImageRef IOSUseHostCanvasTestCreateRawHostCapture(
    CGFloat backingScale
) CF_RETURNS_RETAINED {
    const size_t sourceWidth = (size_t)llround(430 * backingScale);
    const size_t sourceHeight = (size_t)llround(970 * backingScale);
    const size_t canvasMinimumY = (size_t)llround(38 * backingScale);
    return IOSUseHostCanvasTestCreateRawCapture(
        sourceWidth,
        sourceHeight,
        CGRectMake(
            0,
            canvasMinimumY,
            sourceWidth,
            sourceHeight - canvasMinimumY
        )
    );
}

static BOOL IOSUseHostCanvasTestSampleIsGreen(
    CGImageRef image,
    size_t pixelX,
    size_t pixelY
) {
    if (image == NULL || pixelX >= CGImageGetWidth(image) ||
        pixelY >= CGImageGetHeight(image)) {
        return NO;
    }
    CGImageRef pixelImage = CGImageCreateWithImageInRect(
        image,
        CGRectMake(pixelX, pixelY, 1, 1)
    );
    if (pixelImage == NULL) {
        return NO;
    }
    uint8_t pixel[4] = {0};
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = colorSpace == NULL ? NULL : CGBitmapContextCreate(
        pixel,
        1,
        1,
        8,
        4,
        colorSpace,
        kCGBitmapByteOrder32Little |
            kCGImageAlphaPremultipliedFirst
    );
    if (colorSpace != NULL) {
        CGColorSpaceRelease(colorSpace);
    }
    if (context != NULL) {
        CGContextDrawImage(context, CGRectMake(0, 0, 1, 1), pixelImage);
        CGContextRelease(context);
    }
    CGImageRelease(pixelImage);
    return context != NULL && pixel[0] < 8 && pixel[1] > 247 &&
        pixel[2] < 8 && pixel[3] > 247;
}

static BOOL IOSUseHostCanvasTestCropAtBackingScale(
    CGFloat backingScale
) {
    CGRect sourceBounds = CGRectMake(10, 20, 430, 970);
    CGRect canvasBounds = CGRectMake(10, 58, 430, 932);
    CGImageRef source = IOSUseHostCanvasTestCreateRawHostCapture(
        backingScale
    );
    CGRect logicalRect = CGRectNull;
    NSDictionary<NSString *, id> *evidence = nil;
    NSString *failure = nil;
    CGImageRef normalized = source == NULL
        ? NULL
        : IOSUsePlayCropAndNormalizeCanvasCapture(
            source,
            sourceBounds,
            canvasBounds,
            1,
            &logicalRect,
            &evidence,
            &failure
        );
    NSDictionary<NSString *, NSNumber *> *sourceCrop =
        evidence[@"sourcePixelCropRect"];
    size_t expectedCropY = (size_t)llround(38 * backingScale);
    size_t expectedCropHeight = (size_t)llround(932 * backingScale);
    BOOL cropEvidenceReady =
        [evidence[@"canvasOnly"] boolValue] &&
        [evidence[@"hostDecorationsExcluded"] boolValue] &&
        [evidence[@"normalizedPixelWidth"] unsignedLongLongValue] ==
            IOSUsePlayDeviceNativeWidth &&
        [evidence[@"normalizedPixelHeight"] unsignedLongLongValue] ==
            IOSUsePlayDeviceNativeHeight &&
        [sourceCrop[@"x"] unsignedLongLongValue] == 0 &&
        [sourceCrop[@"y"] unsignedLongLongValue] == expectedCropY &&
        [sourceCrop[@"width"] unsignedLongLongValue] ==
            (size_t)llround(430 * backingScale) &&
        [sourceCrop[@"height"] unsignedLongLongValue] ==
            expectedCropHeight;
    BOOL pixelsAreCanvasOnly =
        IOSUseHostCanvasTestSampleIsGreen(normalized, 0, 0) &&
        IOSUseHostCanvasTestSampleIsGreen(
            normalized,
            IOSUsePlayDeviceNativeWidth / 2,
            IOSUsePlayDeviceNativeHeight / 2
        ) &&
        IOSUseHostCanvasTestSampleIsGreen(
            normalized,
            IOSUsePlayDeviceNativeWidth - 1,
            IOSUsePlayDeviceNativeHeight - 1
        );
    BOOL passed = normalized != NULL && failure == nil &&
        IOSUseHostCanvasTestRectEquals(
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
        cropEvidenceReady && pixelsAreCanvasOnly;
    if (normalized != NULL) {
        CGImageRelease(normalized);
    }
    if (source != NULL) {
        CGImageRelease(source);
    }
    return IOSUseHostCanvasTestRequire(
        passed,
        [NSString stringWithFormat:
            @"%.0fx raw host crop leaked decoration or lost fixed canvas: %@",
            backingScale,
            failure ?: @"unexpected crop result"
        ]
    );
}

static BOOL IOSUseHostCanvasTestFractionalCropExcludesDecorations(void) {
    // At 2x backing, the target canvas starts 0.25pt into the native source:
    // 38.25pt * 2 == 76.5px.  An outward crop would include red pixel row 76
    // (and the corresponding left/right edge); the canvas-only contract must
    // instead crop inward to row 77 and preserve only green target pixels.
    CGRect sourceBounds = CGRectMake(10, 20, 431, 971);
    CGRect canvasBounds = CGRectMake(10.25, 58.25, 430, 932);
    CGImageRef source = IOSUseHostCanvasTestCreateRawCapture(
        862,
        1942,
        CGRectMake(1, 77, 859, 1863)
    );
    CGRect logicalRect = CGRectNull;
    NSDictionary<NSString *, id> *evidence = nil;
    NSString *failure = nil;
    CGImageRef normalized = source == NULL
        ? NULL
        : IOSUsePlayCropAndNormalizeCanvasCapture(
            source,
            sourceBounds,
            canvasBounds,
            1,
            &logicalRect,
            &evidence,
            &failure
        );
    NSDictionary<NSString *, NSNumber *> *sourceCrop =
        evidence[@"sourcePixelCropRect"];
    BOOL cropEvidenceReady =
        [evidence[@"canvasOnly"] boolValue] &&
        [evidence[@"hostDecorationsExcluded"] boolValue] &&
        [sourceCrop[@"x"] integerValue] == 1 &&
        [sourceCrop[@"y"] integerValue] == 77 &&
        [sourceCrop[@"width"] integerValue] == 859 &&
        [sourceCrop[@"height"] integerValue] == 1863;
    BOOL pixelsAreCanvasOnly =
        IOSUseHostCanvasTestSampleIsGreen(normalized, 0, 0) &&
        IOSUseHostCanvasTestSampleIsGreen(
            normalized,
            IOSUsePlayDeviceNativeWidth - 1,
            0
        ) &&
        IOSUseHostCanvasTestSampleIsGreen(
            normalized,
            0,
            IOSUsePlayDeviceNativeHeight - 1
        ) &&
        IOSUseHostCanvasTestSampleIsGreen(
            normalized,
            IOSUsePlayDeviceNativeWidth - 1,
            IOSUsePlayDeviceNativeHeight - 1
        );
    BOOL passed = normalized != NULL && failure == nil &&
        IOSUseHostCanvasTestRectEquals(
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
        cropEvidenceReady && pixelsAreCanvasOnly;
    if (normalized != NULL) {
        CGImageRelease(normalized);
    }
    if (source != NULL) {
        CGImageRelease(source);
    }
    return IOSUseHostCanvasTestRequire(
        passed,
        [NSString stringWithFormat:
            @"fractional canvas crop leaked decoration or rounded outward: %@",
            failure ?: @"unexpected crop result"
        ]
    );
}

static BOOL IOSUseHostCanvasTestTypedJSONRect(id value) {
    if (![value isKindOfClass:NSDictionary.class]) {
        return NO;
    }
    NSDictionary *rect = value;
    for (NSString *key in @[@"x", @"y", @"width", @"height"]) {
        id number = rect[key];
        if (![number isKindOfClass:NSNumber.class] ||
            !isfinite([(NSNumber *)number doubleValue])) {
            return NO;
        }
    }
    return YES;
}

static BOOL IOSUseHostCanvasTestUnavailableCaptureSchema(void) {
    // `geometry.host` is optional to old clients, but newer typed Runtime
    // clients decode it whenever it is present. A failed WindowServer capture
    // therefore still needs every nonoptional frame/number/bool/string field;
    // zero rectangles are an explicitly unhealthy sentinel, while the real
    // capture error remains available for status diagnostics.
    NSDictionary<NSString *, NSNumber *> *zeroRect = @{
        @"x": @0,
        @"y": @0,
        @"width": @0,
        @"height": @0,
    };
    NSDictionary<NSString *, id> *host = @{
        @"status": @"geometry-mismatch",
        @"hostPolicy": @NO,
        @"frame": zeroRect,
        @"contentBounds": zeroRect,
        @"canvasRect": zeroRect,
        @"canvasBounds": zeroRect,
        @"displayScale": @0,
        @"inverseDisplayScale": @0,
        @"transparentSpacer": @0,
        @"transparent": @NO,
        @"publicTitleBar": @NO,
        @"titleVisible": @NO,
        @"resizable": @NO,
        @"title": @"",
        @"titleExpected": @"",
        @"capture": @{
            @"ready": @NO,
            @"error": @"WindowServer canvas metadata is unavailable",
            @"hostContentCGWindowRect": zeroRect,
            @"hostCGWindowBounds": zeroRect,
            @"canvasCGWindowRect": zeroRect,
            @"hostWindowNumber": NSNull.null,
        },
    };
    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:host
                                                    options:0
                                                      error:&jsonError];
    id decoded = data == nil
        ? nil
        : [NSJSONSerialization JSONObjectWithData:data
                                           options:0
                                             error:&jsonError];
    NSDictionary *decodedHost = [decoded isKindOfClass:NSDictionary.class]
        ? decoded
        : nil;
    NSDictionary *capture = [decodedHost[@"capture"]
        isKindOfClass:NSDictionary.class]
        ? decodedHost[@"capture"]
        : nil;
    BOOL typed = jsonError == nil && decodedHost != nil &&
        [decodedHost[@"status"] isKindOfClass:NSString.class] &&
        [decodedHost[@"hostPolicy"] isKindOfClass:NSNumber.class] &&
        IOSUseHostCanvasTestTypedJSONRect(decodedHost[@"frame"]) &&
        IOSUseHostCanvasTestTypedJSONRect(decodedHost[@"contentBounds"]) &&
        IOSUseHostCanvasTestTypedJSONRect(decodedHost[@"canvasRect"]) &&
        IOSUseHostCanvasTestTypedJSONRect(decodedHost[@"canvasBounds"]) &&
        [decodedHost[@"displayScale"] isKindOfClass:NSNumber.class] &&
        [decodedHost[@"inverseDisplayScale"] isKindOfClass:NSNumber.class] &&
        [decodedHost[@"transparentSpacer"] isKindOfClass:NSNumber.class] &&
        [decodedHost[@"transparent"] isKindOfClass:NSNumber.class] &&
        [decodedHost[@"publicTitleBar"] isKindOfClass:NSNumber.class] &&
        [decodedHost[@"titleVisible"] isKindOfClass:NSNumber.class] &&
        [decodedHost[@"resizable"] isKindOfClass:NSNumber.class] &&
        [decodedHost[@"title"] isKindOfClass:NSString.class] &&
        [decodedHost[@"titleExpected"] isKindOfClass:NSString.class] &&
        capture != nil && ![capture[@"ready"] boolValue] &&
        [capture[@"error"] isEqualToString:
            @"WindowServer canvas metadata is unavailable"] &&
        IOSUseHostCanvasTestTypedJSONRect(
            capture[@"hostContentCGWindowRect"]
        ) &&
        IOSUseHostCanvasTestTypedJSONRect(capture[@"hostCGWindowBounds"]) &&
        IOSUseHostCanvasTestTypedJSONRect(capture[@"canvasCGWindowRect"]) &&
        capture[@"hostWindowNumber"] == NSNull.null;
    return IOSUseHostCanvasTestRequire(
        typed,
        @"unavailable canvas capture must retain a typed Runtime host schema and error"
    );
}

static BOOL IOSUseHostCanvasTestSourceContract(
    NSString *bridgePath,
    NSString *runtimePath,
    NSString *socketPath
) {
    NSError *error = nil;
    NSString *bridge = [NSString stringWithContentsOfFile:bridgePath
                                                  encoding:NSUTF8StringEncoding
                                                     error:&error];
    if (bridge == nil) {
        return IOSUseHostCanvasTestRequire(
            NO,
            [NSString stringWithFormat:
                @"could not read AppKit bridge: %@",
                error.localizedDescription
            ]
        );
    }
    NSString *runtime = [NSString stringWithContentsOfFile:runtimePath
                                                   encoding:NSUTF8StringEncoding
                                                      error:&error];
    NSString *socket = [NSString stringWithContentsOfFile:socketPath
                                                  encoding:NSUTF8StringEncoding
                                                     error:&error];
    BOOL bridgeReady =
        [bridge containsString:@"IOSUseBridgeInstallHostCanvas"] &&
        [bridge containsString:@"IOSUseBridgeUpdateHostCanvasLayout"] &&
        [bridge containsString:@"IOSUseBridgeLockSceneToFixedCanvas"] &&
        [bridge containsString:@"UIWindowSceneGeometryPreferencesMac"] &&
        [bridge containsString:@"requestGeometryUpdateWithPreferences"] &&
        [bridge containsString:@"scene.sizeRestrictions.minimumSize = fixed;"] &&
        [bridge containsString:@"scene.sizeRestrictions.maximumSize = fixed;"] &&
        [bridge containsString:@"waiting-for-scene-geometry"] &&
        [bridge containsString:@"IOSUseBridgeSceneGeometryStatePending"] &&
        [bridge containsString:
            @"sceneGeometryState != IOSUseBridgeSceneGeometryStateReady"] &&
        [bridge containsString:@"IOSUseBridgeHostTitle"] &&
        [bridge containsString:@"CFBundleDisplayName"] &&
        [bridge containsString:@"CFBundleName"] &&
        [bridge containsString:@"@\"setOpaque:\", NO"] &&
        [bridge containsString:@"@\"setTitlebarAppearsTransparent:\", YES"] &&
        [bridge containsString:@"NSWindowDidResizeNotification"] &&
        [bridge containsString:@"NSWindowDidChangeBackingPropertiesNotification"] &&
        [bridge containsString:@"IOSUsePlayResolveHostInitialContentSize"] &&
        [bridge containsString:@"IOSUsePlayMapHostContentPointToCanvas"] &&
        [bridge containsString:
            @"IOSUseBridgeAppKitScreenRectToCanvasLogicalRect"] &&
        [bridge containsString:@"convertRectFromScreen:"] &&
        [bridge containsString:@"convertRectToScreen:"] &&
        [bridge containsString:@"IOSUsePlayMapHostContentRectToCanvas"] &&
        [bridge containsString:@"CGDisplayBounds(CGMainDisplayID())"] &&
        [bridge containsString:@"targetHitTest"];
    BOOL runtimeReady = runtime != nil &&
        [runtime containsString:@"canvasCaptureGeometryWithError"] &&
        [runtime containsString:@"IOSUsePlayCropAndNormalizeCanvasCapture"] &&
        [runtime containsString:@"compositor_canvas_crop_failed"] &&
        [runtime containsString:@"@\"hostDecorationsExcluded\": @YES"];
    BOOL socketReady = socket != nil &&
        [socket containsString:@"IOSUseHostGeometry"] &&
        [socket containsString:@"IOSUseHostGeometryReady"] &&
        [socket containsString:@"@\"host\": hostGeometry"] &&
        [socket containsString:@"@\"status\": [window[@\"status\"]"] &&
        [socket containsString:@"IOSUseSocketStableBool(window[@\"hostPolicy\"])"] &&
        [socket containsString:@"@\"titleExpected\""] &&
        [socket containsString:@"@\"canvasCGWindowRect\""] &&
        [socket containsString:@"@\"titleVisible\""] &&
        [socket containsString:@"IOSUseSocketContainsRect"] &&
        [socket containsString:@"@\"hostWindowNumber\""] &&
        [socket containsString:@"captureErrorIsNull"] &&
        [socket containsString:@"IOSUseSocketZeroRect"] &&
        [socket containsString:@"IOSUseSocketStableRect"] &&
        [socket containsString:@"IOSUseSocketStableFiniteNumber"] &&
        [socket containsString:@"IOSUseSocketStableCaptureError"] &&
        [socket containsString:@"captureDiagnosticsAreComplete"] &&
        [socket containsString:
            @"canvas capture diagnostics are unavailable"] &&
        [socket containsString:@"@\"error\": captureError"] &&
        [socket containsString:@"@\"ready\": @(captureReady)"] &&
        [socket containsString:@"host-geometry-mismatch"];
    return IOSUseHostCanvasTestRequire(
        bridgeReady && runtimeReady && socketReady,
        @"transparent host, canvas-only screenshot, or status diagnostics are incomplete"
    );
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 4) {
            fprintf(
                stderr,
                "usage: HostCanvasContractTests <AppKitBridge.m> "
                "<RuntimeScreenshot.m> <RuntimeSocket.m>\n"
            );
            return 2;
        }
        IOSUsePlayHostCanvasLayout unitLayout;
        IOSUsePlayHostCanvasLayout resizedLayout;
        IOSUsePlayHostCanvasLayout minimumLayout;
        BOOL unitReady = IOSUseHostCanvasTestLayout(
            CGRectMake(0, 0, 430, 940),
            1,
            CGRectMake(0, 0, 430, 932),
            &unitLayout
        );
        BOOL resizeReady = IOSUseHostCanvasTestLayout(
            CGRectMake(0, 0, 1075, 1406),
            1.5,
            CGRectMake(215, 0, 645, 1398),
            &resizedLayout
        );
        BOOL minimumReady = IOSUseHostCanvasTestLayout(
            CGRectMake(0, 0, 215, 474),
            0.5,
            CGRectMake(0, 0, 215, 466),
            &minimumLayout
        );
        BOOL initialFitReady = IOSUseHostCanvasTestInitialHostFit();
        NSString *undersizedFailure = nil;
        BOOL undersizedRejected = !IOSUsePlayResolveHostCanvasLayout(
            CGRectMake(0, 0, 214.9, 474),
            NULL,
            &undersizedFailure
        ) && undersizedFailure != nil;
        BOOL unitRoundTrip = IOSUseHostCanvasTestRoundTrip(
            unitLayout,
            CGPointMake(215.25, 466.75)
        );
        BOOL resizedRoundTrip = IOSUseHostCanvasTestRoundTrip(
            resizedLayout,
            CGPointMake(13.5, 901.25)
        );
        CGPoint ignoredPoint = CGPointZero;
        NSString *gapFailure = nil;
        NSString *marginFailure = nil;
        BOOL gapRejected = !IOSUsePlayMapHostContentPointToCanvas(
            resizedLayout,
            CGPointMake(
                CGRectGetMidX(resizedLayout.canvasRect),
                CGRectGetMaxY(resizedLayout.hostContentBounds) - 4
            ),
            &ignoredPoint,
            &gapFailure
        ) && gapFailure != nil;
        BOOL marginRejected = !IOSUsePlayMapHostContentPointToCanvas(
            resizedLayout,
            CGPointMake(10, CGRectGetMidY(resizedLayout.canvasRect)),
            &ignoredPoint,
            &marginFailure
        ) && marginFailure != nil;
        CGRect resizedCanvasCG = CGRectNull;
        NSString *canvasCGFailure = nil;
        BOOL canvasCGReady = IOSUsePlayResolveCanvasCGWindowRect(
            CGRectMake(50, 100, 1075, 1406),
            resizedLayout,
            &resizedCanvasCG,
            &canvasCGFailure
        ) && IOSUseHostCanvasTestRectEquals(
            resizedCanvasCG,
            CGRectMake(265, 108, 645, 1398)
        );
        CGRect fullLogical = CGRectNull;
        NSString *fullLogicalFailure = nil;
        BOOL fullLogicalReady = canvasCGReady &&
            IOSUsePlayResolveCGWindowRectInCanvas(
                resizedCanvasCG,
                resizedCanvasCG,
                resizedLayout.displayScale,
                &fullLogical,
                &fullLogicalFailure
            ) && IOSUseHostCanvasTestRectEquals(
                fullLogical,
                CGRectMake(0, 0, 430, 932)
            );
        CGRect accessibilityHostRect = CGRectMake(
            245,
            1173,
            150,
            75
        );
        CGRect accessibilityLogicalRect = CGRectNull;
        NSString *accessibilityFailure = nil;
        BOOL accessibilityTransformReady =
            IOSUsePlayMapHostContentRectToCanvas(
                resizedLayout,
                accessibilityHostRect,
                &accessibilityLogicalRect,
                &accessibilityFailure
            ) && IOSUseHostCanvasTestRectEquals(
                accessibilityLogicalRect,
                CGRectMake(20, 100, 100, 50)
            );
        CGRect alertButtonHostRect = CGRectMake(
            365,
            1008,
            90,
            45
        );
        CGRect alertButtonLogicalRect = CGRectNull;
        NSString *alertButtonFailure = nil;
        BOOL alertButtonTransformReady =
            IOSUsePlayMapHostContentRectToCanvas(
                resizedLayout,
                alertButtonHostRect,
                &alertButtonLogicalRect,
                &alertButtonFailure
            ) && IOSUseHostCanvasTestRectEquals(
                alertButtonLogicalRect,
                CGRectMake(100, 230, 60, 30)
            );
        CGRect secondaryAppKitScreenRect = CGRectMake(100, 950, 200, 100);
        CGRect secondaryCGWindowRect = CGRectNull;
        NSString *secondaryDisplayFailure = nil;
        BOOL multiScreenTransformReady =
            IOSUsePlayResolveAppKitScreenRectInCGWindowCoordinates(
                secondaryAppKitScreenRect,
                CGRectMake(0, 0, 1440, 900),
                &secondaryCGWindowRect,
                &secondaryDisplayFailure
            ) && IOSUseHostCanvasTestRectEquals(
                secondaryCGWindowRect,
                CGRectMake(100, -150, 200, 100)
        );
        BOOL crop1x = IOSUseHostCanvasTestCropAtBackingScale(1);
        BOOL crop2x = IOSUseHostCanvasTestCropAtBackingScale(2);
        BOOL fractionalCrop =
            IOSUseHostCanvasTestFractionalCropExcludesDecorations();
        BOOL unavailableCaptureSchema =
            IOSUseHostCanvasTestUnavailableCaptureSchema();
        BOOL sourceContract = IOSUseHostCanvasTestSourceContract(
            [NSString stringWithUTF8String:argv[1]],
            [NSString stringWithUTF8String:argv[2]],
            [NSString stringWithUTF8String:argv[3]]
        );
        BOOL passed = unitReady && resizeReady && minimumReady &&
            initialFitReady &&
            undersizedRejected && unitRoundTrip && resizedRoundTrip &&
            gapRejected && marginRejected && canvasCGReady &&
            fullLogicalReady && accessibilityTransformReady &&
            alertButtonTransformReady && multiScreenTransformReady &&
            crop1x && crop2x && fractionalCrop &&
            unavailableCaptureSchema && sourceContract;
        fprintf(
            stderr,
            "[host-canvas-contract] scale1=%d resize=%d min=%d initial-fit=%d gap=%d margin=%d cg=%d ax=%d alert=%d multiscreen=%d crop1x=%d crop2x=%d fractional=%d unavailable-schema=%d source=%d pass=%d\n",
            unitReady,
            resizeReady,
            minimumReady,
            initialFitReady,
            gapRejected,
            marginRejected,
            canvasCGReady && fullLogicalReady,
            accessibilityTransformReady,
            alertButtonTransformReady,
            multiScreenTransformReady,
            crop1x,
            crop2x,
            fractionalCrop,
            unavailableCaptureSchema,
            sourceContract,
            passed
        );
        return passed ? 0 : 1;
    }
}
