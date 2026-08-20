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

static BOOL IOSUseHostCanvasTestNativeMapping(void) {
    CGRect content = CGRectMake(5, 7, 331, 718);
    CGPoint logicalPoint = CGPointMake(NAN, NAN);
    CGRect logicalRect = CGRectNull;
    NSString *pointFailure = nil;
    NSString *rectFailure = nil;
    NSString *outsideFailure = nil;
    BOOL pointReady = IOSUsePlayMapHostContentPointToDevice(
        content,
        CGPointMake(
            CGRectGetMinX(content) + content.size.width * 0.5,
            CGRectGetMinY(content) + content.size.height * 0.75
        ),
        &logicalPoint,
        &pointFailure
    );
    CGRect expectedLogicalRect = CGRectMake(20, 100, 100, 50);
    CGFloat hostMinimumX = CGRectGetMinX(content) +
        expectedLogicalRect.origin.x /
            IOSUsePlayDeviceLogicalWidth * content.size.width;
    CGFloat hostMaximumY = CGRectGetMaxY(content) -
        expectedLogicalRect.origin.y /
            IOSUsePlayDeviceLogicalHeight * content.size.height;
    CGRect hostRect = CGRectMake(
        hostMinimumX,
        hostMaximumY -
            expectedLogicalRect.size.height /
                IOSUsePlayDeviceLogicalHeight * content.size.height,
        expectedLogicalRect.size.width /
            IOSUsePlayDeviceLogicalWidth * content.size.width,
        expectedLogicalRect.size.height /
            IOSUsePlayDeviceLogicalHeight * content.size.height
    );
    BOOL rectReady = IOSUsePlayMapHostContentRectToDevice(
        content,
        hostRect,
        &logicalRect,
        &rectFailure
    );
    CGPoint ignored = CGPointZero;
    BOOL outsideRejected = !IOSUsePlayMapHostContentPointToDevice(
        content,
        CGPointMake(CGRectGetMaxX(content) + 1, CGRectGetMidY(content)),
        &ignored,
        &outsideFailure
    );
    BOOL passed = pointReady && pointFailure == nil &&
        IOSUseHostCanvasTestApproximatelyEqual(
            logicalPoint.x,
            IOSUsePlayDeviceLogicalWidth * 0.5
        ) &&
        IOSUseHostCanvasTestApproximatelyEqual(
            logicalPoint.y,
            IOSUsePlayDeviceLogicalHeight * 0.25
        ) &&
        rectReady && rectFailure == nil &&
        IOSUseHostCanvasTestRectEquals(
            logicalRect,
            expectedLogicalRect
        ) &&
        outsideRejected && outsideFailure != nil;
    return IOSUseHostCanvasTestRequire(
        passed,
        [NSString stringWithFormat:
            @"native Catalyst content mapping failed: %@ / %@ / %@",
            pointFailure ?: @"point",
            rectFailure ?: @"rect",
            outsideFailure ?: @"outside accepted"
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


int main(int argc, const char *argv[]) {
    @autoreleasepool {
        (void)argv;
        if (argc != 1) {
            fprintf(stderr, "usage: HostCanvasContractTests\n");
            return 2;
        }
        BOOL nativeMapping =
            IOSUseHostCanvasTestNativeMapping();
        BOOL multiScreen =
            IOSUseHostCanvasTestDisplayCoordinateTransforms();
        CGRect logicalFrame = CGRectNull;
        NSString *frameFailure = nil;
        BOOL nativeFrame = IOSUsePlayResolveCGWindowRectInCanvas(
            CGRectMake(50, 100, 331, 718),
            CGRectMake(50, 100, 331, 718),
            2,
            &logicalFrame,
            &frameFailure
        ) && IOSUseHostCanvasTestRectEquals(
            logicalFrame,
            CGRectMake(
                0,
                0,
                IOSUsePlayDeviceLogicalWidth,
                IOSUsePlayDeviceLogicalHeight
            )
        );
        BOOL crop1x = IOSUseHostCanvasTestCropAtBackingScale(1);
        BOOL crop2x = IOSUseHostCanvasTestCropAtBackingScale(2);
        BOOL fractionalCrop =
            IOSUseHostCanvasTestRejectsNonAlignedCrop();
        BOOL quantizedSource =
            IOSUseHostCanvasTestAcceptsQuantizedSourceExtent();
        BOOL missingEdgePixel =
            IOSUseHostCanvasTestDoesNotStretchMissingEdgePixel();
        BOOL passed = nativeMapping && multiScreen && nativeFrame &&
            crop1x && crop2x && fractionalCrop &&
            quantizedSource && missingEdgePixel;
        fprintf(
            stderr,
            "[host-canvas-contract] native-map=%d multiscreen=%d "
            "native-frame=%d crop1x=%d crop2x=%d fractional=%d "
            "quantized-source=%d missing-edge=%d pass=%d\n",
            nativeMapping,
            multiScreen,
            nativeFrame,
            crop1x,
            crop2x,
            fractionalCrop,
            quantizedSource,
            missingEdgePixel,
            passed
        );
        return passed ? 0 : 1;
    }
}
