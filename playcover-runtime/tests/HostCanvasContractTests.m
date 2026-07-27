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
    CGFloat backingScale,
    CGFloat expectedScale,
    CGRect expectedCanvas,
    IOSUsePlayHostCanvasLayout *layout
) {
    NSString *failure = nil;
    IOSUsePlayHostCanvasLayout resolved = {0};
    BOOL ready = IOSUsePlayResolveHostCanvasLayout(
        bounds,
        backingScale,
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
        IOSUseHostCanvasTestRectEquals(
            resolved.canvasRect,
            expectedCanvas
        ) &&
        IOSUseHostCanvasTestApproximatelyEqual(
            resolved.backingScaleFactor,
            backingScale
        ) &&
        IOSUseHostCanvasTestApproximatelyEqual(
            resolved.halfPixelTolerance,
            0.5 / backingScale
        ) &&
        IOSUseHostCanvasTestApproximatelyEqual(
            CGRectGetMidX(resolved.canvasRect),
            CGRectGetMidX(bounds)
        ) &&
        IOSUseHostCanvasTestApproximatelyEqual(
            CGRectGetMidY(resolved.canvasRect),
            CGRectGetMidY(bounds)
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

static BOOL IOSUseHostCanvasTestResizeRounding(void) {
    IOSUsePlayHostCanvasLayout layout = {0};
    NSString *failure = nil;
    BOOL ready = IOSUsePlayResolveHostCanvasLayout(
        CGRectMake(0, 0, 400, 867),
        2,
        &layout,
        &failure
    );
    CGFloat expectedHeight =
        400.0 * IOSUsePlayDeviceLogicalHeight /
        IOSUsePlayDeviceLogicalWidth;
    CGFloat bottomMargin = CGRectGetMinY(layout.canvasRect);
    CGFloat topMargin = 867.0 - CGRectGetMaxY(layout.canvasRect);
    BOOL passed = ready && failure == nil &&
        IOSUseHostCanvasTestApproximatelyEqual(
            layout.displayScale,
            400.0 / IOSUsePlayDeviceLogicalWidth
        ) &&
        IOSUseHostCanvasTestApproximatelyEqual(
            layout.canvasRect.size.width,
            400
        ) &&
        IOSUseHostCanvasTestApproximatelyEqual(
            layout.canvasRect.size.height,
            expectedHeight
        ) &&
        fabs(bottomMargin - topMargin) <=
            IOSUseHostCanvasTestTolerance &&
        bottomMargin >= 0 && topMargin >= 0 &&
        bottomMargin + topMargin < 1;
    return IOSUseHostCanvasTestRequire(
        passed,
        [NSString stringWithFormat:
            @"400x867 resize rounding was not centered below 1pt: %@",
            failure ?: @"unexpected geometry"
        ]
    );
}

static BOOL IOSUseHostCanvasTestBootstrapAspectTarget(void) {
    IOSUsePlayHostCanvasLayout initial = {0};
    IOSUsePlayHostCanvasLayout restored = {0};
    IOSUsePlayHostCanvasLayout normalized = {0};
    NSString *initialFailure = nil;
    NSString *initialQuantizationFailure = nil;
    NSString *restoredFailure = nil;
    NSString *restoredQuantizationFailure = nil;
    NSString *lowScaleFailure = nil;
    NSString *lowScaleQuantizationFailure = nil;
    NSString *normalizedFailure = nil;
    NSString *normalizedQuantizationFailure = nil;
    BOOL initialReady = IOSUsePlayResolveHostCanvasLayout(
        CGRectMake(0, 0, 422, 916),
        2,
        &initial,
        &initialFailure
    );
    CGFloat verticalSurplus =
        916.0 - initial.canvasRect.size.height;
    BOOL initialRequiresNormalization = initialReady &&
        !IOSUsePlayHostCanvasFitsPixelQuantizedContent(
            initial,
            &initialQuantizationFailure
        );
    BOOL restoredReady = IOSUsePlayResolveHostCanvasLayout(
        CGRectMake(0, 0, 422, 915),
        2,
        &restored,
        &restoredFailure
    );
    CGFloat restoredVerticalSurplus =
        915.0 - restored.canvasRect.size.height;
    BOOL restoredIsPixelQuantized = restoredReady &&
        IOSUsePlayHostCanvasFitsPixelQuantizedContent(
            restored,
            &restoredQuantizationFailure
        );
    IOSUsePlayHostCanvasLayout lowScale = {0};
    BOOL lowScaleReady = IOSUsePlayResolveHostCanvasLayout(
        CGRectMake(0, 0, 218, 473),
        2,
        &lowScale,
        &lowScaleFailure
    );
    BOOL lowScaleIsPixelQuantized = lowScaleReady &&
        IOSUsePlayHostCanvasFitsPixelQuantizedContent(
            lowScale,
            &lowScaleQuantizationFailure
        );
    CGRect normalizedBounds = CGRectMake(
        0,
        0,
        initial.canvasRect.size.width,
        initial.canvasRect.size.height
    );
    BOOL normalizedReady = initialReady &&
        IOSUsePlayResolveHostCanvasLayout(
            normalizedBounds,
            2,
            &normalized,
            &normalizedFailure
        );
    BOOL normalizedIsPixelQuantized = normalizedReady &&
        IOSUsePlayHostCanvasFitsPixelQuantizedContent(
            normalized,
            &normalizedQuantizationFailure
        );
    BOOL passed = initialReady && initialFailure == nil &&
        verticalSurplus > 0.5 &&
        initialRequiresNormalization &&
        initialQuantizationFailure != nil &&
        restoredReady && restoredFailure == nil &&
        restoredVerticalSurplus > restored.halfPixelTolerance &&
        restoredVerticalSurplus <=
            restored.halfPixelTolerance * 2 &&
        restoredIsPixelQuantized &&
        restoredQuantizationFailure == nil &&
        lowScaleReady && lowScaleFailure == nil &&
        lowScaleIsPixelQuantized &&
        lowScaleQuantizationFailure == nil &&
        normalizedReady && normalizedFailure == nil &&
        normalizedIsPixelQuantized &&
        normalizedQuantizationFailure == nil &&
        IOSUseHostCanvasTestRectEquals(
            normalized.canvasRect,
            normalizedBounds
        ) &&
        IOSUseHostCanvasTestApproximatelyEqual(
            normalized.displayScale,
            initial.displayScale
        );
    return IOSUseHostCanvasTestRequire(
        passed,
        [NSString stringWithFormat:
            @"2x bootstrap/restored aspect quantization was invalid: "
             "%@ / %@ / %@ / %@",
            initialFailure ?: @"initial geometry",
            initialQuantizationFailure ?: @"initial accepted",
            restoredFailure ?: @"restored geometry",
            normalizedFailure ?: @"normalized geometry"
        ]
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

static BOOL IOSUseHostCanvasTestDisplayCoordinateTransforms(void) {
    CGRect mainDisplayBounds = CGRectMake(0, 0, 1440, 900);
    CGRect aboveMain = CGRectNull;
    CGRect belowAndLeft = CGRectNull;
    CGRect mainDisplay = CGRectNull;
    NSString *aboveFailure = nil;
    NSString *belowFailure = nil;
    NSString *mainFailure = nil;
    BOOL aboveReady =
        IOSUsePlayResolveAppKitScreenRectInCGWindowCoordinates(
            CGRectMake(100, 950, 200, 100),
            mainDisplayBounds,
            &aboveMain,
            &aboveFailure
        );
    BOOL belowReady =
        IOSUsePlayResolveAppKitScreenRectInCGWindowCoordinates(
            CGRectMake(-1280, -900, 1280, 800),
            mainDisplayBounds,
            &belowAndLeft,
            &belowFailure
        );
    BOOL mainReady =
        IOSUsePlayResolveAppKitScreenRectInCGWindowCoordinates(
            CGRectMake(0, 0, 1440, 900),
            mainDisplayBounds,
            &mainDisplay,
            &mainFailure
        );
    BOOL passed = aboveReady && belowReady && mainReady &&
        IOSUseHostCanvasTestRectEquals(
            aboveMain,
            CGRectMake(100, -150, 200, 100)
        ) &&
        IOSUseHostCanvasTestRectEquals(
            belowAndLeft,
            CGRectMake(-1280, 1000, 1280, 800)
        ) &&
        IOSUseHostCanvasTestRectEquals(
            mainDisplay,
            mainDisplayBounds
        );
    return IOSUseHostCanvasTestRequire(
        passed,
        [NSString stringWithFormat:
            @"multi-display AppKit/CG coordinate transforms failed: %@ / %@ / %@",
            aboveFailure ?: @"above geometry",
            belowFailure ?: @"below geometry",
            mainFailure ?: @"main geometry"
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
    // Native source starts red everywhere: the system title bar and any other
    // host decoration must be excluded by the crop.
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
            backingScale,
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

static BOOL IOSUseHostCanvasTestRejectsNonAlignedCrop(void) {
    // At 2x backing, the target canvas starts 0.25pt into the native source:
    // 38.25pt * 2 == 76.5px. There is no exact source-pixel boundary, so
    // accepting this crop could round outward into host decoration.
    CGRect sourceBounds = CGRectMake(10, 20, 431, 971);
    CGRect canvasBounds = CGRectMake(10.25, 58.25, 430, 932);
    CGImageRef source = IOSUseHostCanvasTestCreateRawCapture(
        862,
        1942,
        CGRectMake(1, 77, 860, 1864)
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
            2,
            &logicalRect,
            &evidence,
            &failure
        );
    BOOL passed = normalized == NULL && evidence == nil &&
        CGRectIsNull(logicalRect) &&
        [failure containsString:@"backing-pixel aligned"];
    if (normalized != NULL) {
        CGImageRelease(normalized);
    }
    if (source != NULL) {
        CGImageRelease(source);
    }
    return IOSUseHostCanvasTestRequire(
        passed,
        [NSString stringWithFormat:
            @"fractional canvas crop did not fail closed: %@",
            failure ?: @"non-aligned crop accepted"
        ]
    );
}

static BOOL IOSUseHostCanvasTestAcceptsQuantizedSourceExtent(void) {
    // CGWindow may quantize a logical extent by half of one source pixel and
    // may place the window at a fractional global point. Cropping is relative
    // to the returned source raster, so neither condition may reject a
    // full-source, exactly aligned canvas.
    CGRect sourceBounds = CGRectMake(10.25, 20.25, 430.25, 932.5);
    CGFloat displayScale =
        sourceBounds.size.width / IOSUsePlayDeviceLogicalWidth;
    CGImageRef source = IOSUseHostCanvasTestCreateRawCapture(
        860,
        1865,
        CGRectMake(0, 0, 860, 1865)
    );
    CGRect logicalRect = CGRectNull;
    NSDictionary<NSString *, id> *evidence = nil;
    NSString *failure = nil;
    CGImageRef normalized = source == NULL
        ? NULL
        : IOSUsePlayCropAndNormalizeCanvasCapture(
            source,
            sourceBounds,
            sourceBounds,
            displayScale,
            2,
            &logicalRect,
            &evidence,
            &failure
        );
    NSDictionary<NSString *, NSNumber *> *sourceCrop =
        evidence[@"sourcePixelCropRect"];
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
        [sourceCrop[@"x"] integerValue] == 0 &&
        [sourceCrop[@"y"] integerValue] == 0 &&
        [sourceCrop[@"width"] integerValue] == 860 &&
        [sourceCrop[@"height"] integerValue] == 1865 &&
        IOSUseHostCanvasTestSampleIsGreen(normalized, 0, 0) &&
        IOSUseHostCanvasTestSampleIsGreen(
            normalized,
            IOSUsePlayDeviceNativeWidth - 1,
            IOSUsePlayDeviceNativeHeight - 1
        );
    if (normalized != NULL) {
        CGImageRelease(normalized);
    }
    if (source != NULL) {
        CGImageRelease(source);
    }
    return IOSUseHostCanvasTestRequire(
        passed,
        [NSString stringWithFormat:
            @"half-pixel source quantization was rejected: %@",
            failure ?: @"unexpected crop result"
        ]
    );
}

static BOOL IOSUseHostCanvasTestDoesNotStretchMissingEdgePixel(void) {
    CGRect canvasBounds = CGRectMake(0, 0, 430, 932);
    CGRect sourceBounds = CGRectMake(0, 0, 429.5, 932);
    CGImageRef source = IOSUseHostCanvasTestCreateRawCapture(
        859,
        1864,
        CGRectMake(0, 0, 859, 1864)
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
            2,
            &logicalRect,
            &evidence,
            &failure
        );
    NSDictionary<NSString *, NSNumber *> *sourceCrop =
        evidence[@"sourcePixelCropRect"];
    BOOL passed = normalized != NULL && failure == nil &&
        IOSUseHostCanvasTestRectEquals(
            logicalRect,
            CGRectMake(0, 0, 429.5, 932)
        ) &&
        CGImageGetWidth(normalized) == 1289 &&
        CGImageGetHeight(normalized) == IOSUsePlayDeviceNativeHeight &&
        [sourceCrop[@"width"] integerValue] == 859 &&
        [sourceCrop[@"height"] integerValue] == 1864;
    if (normalized != NULL) {
        CGImageRelease(normalized);
    }
    if (source != NULL) {
        CGImageRelease(source);
    }
    return IOSUseHostCanvasTestRequire(
        passed,
        [NSString stringWithFormat:
            @"one missing backing pixel was stretched to a full frame: %@",
            failure ?: @"unexpected full-frame result"
        ]
    );
}

static BOOL IOSUseHostCanvasTestRestoredQuantizedWindow(
    CGFloat contentWidthPoints,
    CGFloat contentHeightPoints,
    CGFloat backingScale
) {
    CGRect contentBounds = CGRectMake(
        0,
        0,
        contentWidthPoints,
        contentHeightPoints
    );
    IOSUsePlayHostCanvasLayout layout = {0};
    NSString *layoutFailure = nil;
    BOOL layoutReady = IOSUsePlayResolveHostCanvasLayout(
        contentBounds,
        backingScale,
        &layout,
        &layoutFailure
    );
    CGFloat expectedScale =
        contentBounds.size.width / IOSUsePlayDeviceLogicalWidth;
    CGFloat expectedIdealHeight =
        IOSUsePlayDeviceLogicalHeight * expectedScale;
    CGRect expectedPixelCanvas = contentBounds;
    CGFloat hostHeight = contentHeightPoints + 28;
    CGRect hostCGWindowBounds = CGRectMake(
        40,
        10,
        contentWidthPoints,
        hostHeight
    );
    CGRect hostContentCGWindowRect = CGRectMake(
        40,
        38,
        contentWidthPoints,
        contentHeightPoints
    );
    CGRect canvasCGWindowRect = CGRectNull;
    NSString *projectionFailure = nil;
    BOOL projectionReady = layoutReady &&
        IOSUsePlayResolveCanvasCGWindowRect(
            hostContentCGWindowRect,
            layout,
            &canvasCGWindowRect,
            &projectionFailure
        );

    size_t sourceWidth =
        (size_t)llround(contentWidthPoints * backingScale);
    size_t sourceHeight =
        (size_t)llround(hostHeight * backingScale);
    size_t titleBarHeight = (size_t)llround(28 * backingScale);
    size_t contentHeight =
        (size_t)llround(contentHeightPoints * backingScale);
    CGImageRef source = IOSUseHostCanvasTestCreateRawCapture(
        sourceWidth,
        sourceHeight,
        CGRectMake(
            0,
            titleBarHeight,
            sourceWidth,
            contentHeight
        )
    );
    CGRect logicalRect = CGRectNull;
    NSDictionary<NSString *, id> *evidence = nil;
    NSString *cropFailure = nil;
    CGImageRef normalized =
        source == NULL || !projectionReady
        ? NULL
        : IOSUsePlayCropAndNormalizeCanvasCapture(
            source,
            hostCGWindowBounds,
            canvasCGWindowRect,
            expectedScale,
            backingScale,
            &logicalRect,
            &evidence,
            &cropFailure
        );
    NSDictionary<NSString *, NSNumber *> *sourceCrop =
        evidence[@"sourcePixelCropRect"];
    CGPoint inputLogicalPoint = CGPointMake(NAN, NAN);
    NSString *inputFailure = nil;
    BOOL inputReady = layoutReady &&
        IOSUsePlayMapHostContentPointToCanvas(
            layout,
            CGPointMake(0, 0),
            &inputLogicalPoint,
            &inputFailure
        );
    CGRect accessibilityLogicalRect = CGRectNull;
    NSString *accessibilityFailure = nil;
    BOOL accessibilityReady = layoutReady &&
        IOSUsePlayMapHostContentRectToCanvas(
            layout,
            contentBounds,
            &accessibilityLogicalRect,
            &accessibilityFailure
        );
    BOOL edgePixelsAreCanvasOnly =
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
        ) &&
        IOSUseHostCanvasTestSampleIsGreen(
            normalized,
            IOSUsePlayDeviceNativeWidth / 2,
            0
        ) &&
        IOSUseHostCanvasTestSampleIsGreen(
            normalized,
            IOSUsePlayDeviceNativeWidth / 2,
            IOSUsePlayDeviceNativeHeight - 1
        ) &&
        IOSUseHostCanvasTestSampleIsGreen(
            normalized,
            0,
            IOSUsePlayDeviceNativeHeight / 2
        ) &&
        IOSUseHostCanvasTestSampleIsGreen(
            normalized,
            IOSUsePlayDeviceNativeWidth - 1,
            IOSUsePlayDeviceNativeHeight / 2
        );
    BOOL passed = layoutReady && layoutFailure == nil &&
        IOSUseHostCanvasTestApproximatelyEqual(
            layout.canvasRect.size.height,
            expectedIdealHeight
        ) &&
        IOSUseHostCanvasTestRectEquals(
            layout.backingPixelCanvasRect,
            expectedPixelCanvas
        ) &&
        projectionReady && projectionFailure == nil &&
        IOSUseHostCanvasTestRectEquals(
            canvasCGWindowRect,
            hostContentCGWindowRect
        ) &&
        normalized != NULL && cropFailure == nil &&
        [sourceCrop[@"x"] integerValue] == 0 &&
        [sourceCrop[@"y"] unsignedLongLongValue] == titleBarHeight &&
        [sourceCrop[@"width"] unsignedLongLongValue] == sourceWidth &&
        [sourceCrop[@"height"] unsignedLongLongValue] == contentHeight &&
        edgePixelsAreCanvasOnly &&
        inputReady && inputFailure == nil &&
        IOSUseHostCanvasTestApproximatelyEqual(
            inputLogicalPoint.x,
            0
        ) &&
        IOSUseHostCanvasTestApproximatelyEqual(
            inputLogicalPoint.y,
            IOSUsePlayDeviceLogicalHeight
        ) &&
        accessibilityReady && accessibilityFailure == nil &&
        IOSUseHostCanvasTestRectEquals(
            accessibilityLogicalRect,
            CGRectMake(
                0,
                0,
                IOSUsePlayDeviceLogicalWidth,
                IOSUsePlayDeviceLogicalHeight
            )
        ) &&
        IOSUseHostCanvasTestRectEquals(
            logicalRect,
            CGRectMake(
                0,
                0,
                IOSUsePlayDeviceLogicalWidth,
                IOSUsePlayDeviceLogicalHeight
            )
        );
    if (normalized != NULL) {
        CGImageRelease(normalized);
    }
    if (source != NULL) {
        CGImageRelease(source);
    }
    return IOSUseHostCanvasTestRequire(
        passed,
        [NSString stringWithFormat:
            @"restored %.0fx%.0f window lost %.0fx backing pixels: "
             "%@ / %@ / %@",
            contentWidthPoints,
            contentHeightPoints,
            backingScale,
            layoutFailure ?: @"layout",
            projectionFailure ?: @"projection",
            cropFailure ?: @"crop"
        ]
    );
}

static BOOL IOSUseHostCanvasTestHalfPixelBoundary(void) {
    IOSUsePlayHostCanvasLayout layout = {0};
    NSString *layoutFailure = nil;
    BOOL layoutReady = IOSUsePlayResolveHostCanvasLayout(
        CGRectMake(0, 0, 316, 685),
        2,
        &layout,
        &layoutFailure
    );
    CGRect accepted = CGRectNull;
    CGRect rejected = CGRectNull;
    NSString *acceptedFailure = nil;
    NSString *rejectedFailure = nil;
    BOOL atBoundaryAccepted = layoutReady &&
        IOSUsePlayResolveCanvasCGWindowRect(
            CGRectMake(40, 38, 316, 685.25),
            layout,
            &accepted,
            &acceptedFailure
        );
    BOOL overBoundaryRejected = layoutReady &&
        !IOSUsePlayResolveCanvasCGWindowRect(
            CGRectMake(40, 38, 316, 685.2501),
            layout,
            &rejected,
            &rejectedFailure
        );
    NSString *invalidScaleFailure = nil;
    BOOL invalidScaleRejected = !IOSUsePlayResolveHostCanvasLayout(
        CGRectMake(0, 0, 316, 685),
        0,
        NULL,
        &invalidScaleFailure
    );
    return IOSUseHostCanvasTestRequire(
        layoutReady && layoutFailure == nil &&
            atBoundaryAccepted && acceptedFailure == nil &&
            overBoundaryRejected && rejectedFailure != nil &&
            invalidScaleRejected && invalidScaleFailure != nil,
        [NSString stringWithFormat:
            @"half-backing-pixel boundary was not fail-closed: %@ / %@ / %@",
            layoutFailure ?: @"layout",
            rejectedFailure ?: @"over-boundary accepted",
            invalidScaleFailure ?: @"invalid backing scale accepted"
        ]
    );
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        (void)argv;
        if (argc != 1) {
            fprintf(
                stderr,
                "usage: HostCanvasContractTests\n"
            );
            return 2;
        }
        IOSUsePlayHostCanvasLayout unitLayout;
        IOSUsePlayHostCanvasLayout resizedLayout;
        IOSUsePlayHostCanvasLayout minimumLayout;
        BOOL unitReady = IOSUseHostCanvasTestLayout(
            CGRectMake(0, 0, 430, 932),
            1,
            1,
            CGRectMake(0, 0, 430, 932),
            &unitLayout
        );
        BOOL resizeReady = IOSUseHostCanvasTestLayout(
            CGRectMake(0, 0, 645, 1398),
            2,
            1.5,
            CGRectMake(0, 0, 645, 1398),
            &resizedLayout
        );
        BOOL minimumReady = IOSUseHostCanvasTestLayout(
            CGRectMake(0, 0, 215, 466),
            1,
            0.5,
            CGRectMake(0, 0, 215, 466),
            &minimumLayout
        );
        BOOL resizeRoundingReady =
            IOSUseHostCanvasTestResizeRounding();
        BOOL bootstrapAspectReady =
            IOSUseHostCanvasTestBootstrapAspectTarget();
        NSString *undersizedFailure = nil;
        BOOL undersizedRejected = !IOSUsePlayResolveHostCanvasLayout(
            CGRectMake(0, 0, 214.9, 466),
            1,
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
        NSString *outsideFailure = nil;
        BOOL outsideRejected = !IOSUsePlayMapHostContentPointToCanvas(
            resizedLayout,
            CGPointMake(
                CGRectGetMaxX(resizedLayout.hostContentBounds) + 1,
                CGRectGetMidY(resizedLayout.hostContentBounds)
            ),
            &ignoredPoint,
            &outsideFailure
        ) && outsideFailure != nil;
        CGRect resizedCanvasCG = CGRectNull;
        NSString *canvasCGFailure = nil;
        BOOL canvasCGReady = IOSUsePlayResolveCanvasCGWindowRect(
            CGRectMake(50, 100, 645, 1398),
            resizedLayout,
            &resizedCanvasCG,
            &canvasCGFailure
        ) && IOSUseHostCanvasTestRectEquals(
            resizedCanvasCG,
            CGRectMake(50, 100, 645, 1398)
        );
        CGRect fullLogical = CGRectNull;
        NSString *fullLogicalFailure = nil;
        BOOL fullLogicalReady = canvasCGReady &&
            IOSUsePlayResolveCGWindowRectInCanvas(
                resizedCanvasCG,
                resizedCanvasCG,
                resizedLayout.displayScale,
                resizedLayout.backingScaleFactor,
                &fullLogical,
                &fullLogicalFailure
            ) && IOSUseHostCanvasTestRectEquals(
                fullLogical,
                CGRectMake(0, 0, 430, 932)
        );
        CGRect accessibilityHostRect = CGRectMake(
            30,
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
            150,
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
        BOOL multiScreenTransformReady =
            IOSUseHostCanvasTestDisplayCoordinateTransforms();
        BOOL crop1x = IOSUseHostCanvasTestCropAtBackingScale(1);
        BOOL crop2x = IOSUseHostCanvasTestCropAtBackingScale(2);
        BOOL fractionalCrop =
            IOSUseHostCanvasTestRejectsNonAlignedCrop();
        BOOL quantizedSource =
            IOSUseHostCanvasTestAcceptsQuantizedSourceExtent();
        BOOL missingEdgePixel =
            IOSUseHostCanvasTestDoesNotStretchMissingEdgePixel();
        BOOL restored1x =
            IOSUseHostCanvasTestRestoredQuantizedWindow(
                316,
                685,
                1
            );
        BOOL restored2x =
            IOSUseHostCanvasTestRestoredQuantizedWindow(
                316,
                685,
                2
            );
        BOOL restored422x915 =
            IOSUseHostCanvasTestRestoredQuantizedWindow(
                422,
                915,
                2
            );
        BOOL restored218x473 =
            IOSUseHostCanvasTestRestoredQuantizedWindow(
                218,
                473,
                2
            );
        BOOL halfPixelBoundary =
            IOSUseHostCanvasTestHalfPixelBoundary();
        BOOL passed = unitReady && resizeReady && minimumReady &&
            resizeRoundingReady && bootstrapAspectReady &&
            undersizedRejected && unitRoundTrip && resizedRoundTrip &&
            outsideRejected && canvasCGReady &&
            fullLogicalReady && accessibilityTransformReady &&
            alertButtonTransformReady && multiScreenTransformReady &&
            crop1x && crop2x && fractionalCrop &&
            quantizedSource && missingEdgePixel &&
            restored1x && restored2x && restored422x915 &&
            restored218x473 && halfPixelBoundary;
        fprintf(
            stderr,
            "[host-canvas-contract] scale1=%d resize=%d min=%d rounding=%d bootstrap=%d outside=%d cg=%d ax=%d alert=%d multiscreen=%d crop1x=%d crop2x=%d fractional=%d quantized-source=%d missing-edge=%d restored1x=%d restored2x=%d restored422x915=%d restored218x473=%d half-pixel=%d pass=%d\n",
            unitReady,
            resizeReady,
            minimumReady,
            resizeRoundingReady,
            bootstrapAspectReady,
            outsideRejected,
            canvasCGReady && fullLogicalReady,
            accessibilityTransformReady,
            alertButtonTransformReady,
            multiScreenTransformReady,
            crop1x,
            crop2x,
            fractionalCrop,
            quantizedSource,
            missingEdgePixel,
            restored1x,
            restored2x,
            restored422x915,
            restored218x473,
            halfPixelBoundary,
            passed
        );
        return passed ? 0 : 1;
    }
}
