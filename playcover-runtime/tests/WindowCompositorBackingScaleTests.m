#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

#import "IOSUsePlayDevice.h"
#import "IOSUsePlayWindowCompositor.h"

#import <math.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>

typedef struct {
    uint8_t blue;
    uint8_t green;
    uint8_t red;
    uint8_t alpha;
} IOSUseFixtureColor;

static const IOSUseFixtureColor IOSUseFixtureCenterColor = {
    .blue = 190, .green = 160, .red = 120, .alpha = 255,
};
static const IOSUseFixtureColor IOSUseFixtureTopColor = {
    .blue = 0, .green = 0, .red = 255, .alpha = 255,
};
static const IOSUseFixtureColor IOSUseFixtureLeftColor = {
    .blue = 0, .green = 255, .red = 0, .alpha = 255,
};
static const IOSUseFixtureColor IOSUseFixtureRightColor = {
    .blue = 255, .green = 0, .red = 0, .alpha = 255,
};
static const IOSUseFixtureColor IOSUseFixtureBottomColor = {
    .blue = 255, .green = 255, .red = 255, .alpha = 255,
};
static const CGFloat IOSUseFixtureEdgeThickness = 24;

static void IOSUseFixtureFillPixelRect(
    uint8_t *pixels,
    size_t width,
    size_t height,
    size_t rowBytes,
    CGRect logicalRect,
    CGFloat backingScale,
    IOSUseFixtureColor color
) {
    size_t minX = (size_t)llround(CGRectGetMinX(logicalRect) * backingScale);
    size_t minY = (size_t)llround(CGRectGetMinY(logicalRect) * backingScale);
    size_t maxX = (size_t)llround(CGRectGetMaxX(logicalRect) * backingScale);
    size_t maxY = (size_t)llround(CGRectGetMaxY(logicalRect) * backingScale);
    minX = MIN(minX, width);
    minY = MIN(minY, height);
    maxX = MIN(maxX, width);
    maxY = MIN(maxY, height);
    for (size_t y = minY; y < maxY; y += 1) {
        uint8_t *row = pixels + y * rowBytes;
        for (size_t x = minX; x < maxX; x += 1) {
            uint8_t *pixel = row + x * 4;
            pixel[0] = color.blue;
            pixel[1] = color.green;
            pixel[2] = color.red;
            pixel[3] = color.alpha;
        }
    }
}

static CGImageRef IOSUseFixtureCreateSourceImage(
    CGSize logicalSize,
    CGFloat backingScale,
    BOOL edgeMarkers
) CF_RETURNS_RETAINED {
    size_t width = (size_t)llround(logicalSize.width * backingScale);
    size_t height = (size_t)llround(logicalSize.height * backingScale);
    size_t rowBytes = width * 4;
    uint8_t *pixels = calloc(height, rowBytes);
    if (pixels == NULL) {
        return NULL;
    }
    IOSUseFixtureFillPixelRect(
        pixels,
        width,
        height,
        rowBytes,
        CGRectMake(0, 0, logicalSize.width, logicalSize.height),
        backingScale,
        IOSUseFixtureCenterColor
    );
    if (edgeMarkers) {
        IOSUseFixtureFillPixelRect(
            pixels, width, height, rowBytes,
            CGRectMake(0, 0, logicalSize.width, IOSUseFixtureEdgeThickness),
            backingScale, IOSUseFixtureTopColor
        );
        IOSUseFixtureFillPixelRect(
            pixels, width, height, rowBytes,
            CGRectMake(
                0,
                logicalSize.height - IOSUseFixtureEdgeThickness,
                logicalSize.width,
                IOSUseFixtureEdgeThickness
            ),
            backingScale, IOSUseFixtureBottomColor
        );
        IOSUseFixtureFillPixelRect(
            pixels, width, height, rowBytes,
            CGRectMake(
                0,
                IOSUseFixtureEdgeThickness,
                IOSUseFixtureEdgeThickness,
                logicalSize.height - IOSUseFixtureEdgeThickness * 2
            ),
            backingScale, IOSUseFixtureLeftColor
        );
        IOSUseFixtureFillPixelRect(
            pixels, width, height, rowBytes,
            CGRectMake(
                logicalSize.width - IOSUseFixtureEdgeThickness,
                IOSUseFixtureEdgeThickness,
                IOSUseFixtureEdgeThickness,
                logicalSize.height - IOSUseFixtureEdgeThickness * 2
            ),
            backingScale, IOSUseFixtureRightColor
        );
    }
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (colorSpace == NULL) {
        free(pixels);
        return NULL;
    }
    CGContextRef context = CGBitmapContextCreate(
        pixels, width, height, 8, rowBytes, colorSpace,
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst
    );
    CGColorSpaceRelease(colorSpace);
    if (context == NULL) {
        free(pixels);
        return NULL;
    }
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    free(pixels);
    return image;
}

static BOOL IOSUseFixtureSampleTopLeftPixel(
    CGImageRef image,
    CGPoint logicalPoint,
    uint8_t output[4]
) {
    if (image == NULL) {
        return NO;
    }
    size_t x = (size_t)floor(logicalPoint.x * IOSUsePlayDeviceScale);
    size_t y = (size_t)floor(logicalPoint.y * IOSUsePlayDeviceScale);
    if (x >= CGImageGetWidth(image) || y >= CGImageGetHeight(image)) {
        return NO;
    }
    CGImageRef sample = CGImageCreateWithImageInRect(
        image, CGRectMake(x, y, 1, 1)
    );
    if (sample == NULL) {
        return NO;
    }
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (colorSpace == NULL) {
        CGImageRelease(sample);
        return NO;
    }
    uint8_t pixel[4] = {0};
    CGContextRef context = CGBitmapContextCreate(
        pixel, 1, 1, 8, 4, colorSpace,
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst
    );
    CGColorSpaceRelease(colorSpace);
    if (context == NULL) {
        CGImageRelease(sample);
        return NO;
    }
    CGContextDrawImage(context, CGRectMake(0, 0, 1, 1), sample);
    CGContextRelease(context);
    CGImageRelease(sample);
    memcpy(output, pixel, 4);
    return YES;
}

static BOOL IOSUseFixtureColorMatches(
    const uint8_t pixel[4],
    IOSUseFixtureColor expected
) {
    return pixel[0] == expected.blue &&
        pixel[1] == expected.green &&
        pixel[2] == expected.red &&
        pixel[3] == expected.alpha;
}

static BOOL IOSUseFixtureEvidenceMatches(
    NSDictionary<NSString *, id> *entry,
    CGFloat backingScale,
    size_t sourceWidth,
    size_t sourceHeight
) {
    NSDictionary<NSString *, NSNumber *> *logical = entry[@"deviceLogicalRect"];
    NSDictionary<NSString *, NSNumber *> *native = entry[@"destinationNativeRect"];
    return [entry[@"windowNumber"] unsignedIntValue] == 9001 &&
        fabs([entry[@"backingScaleFactor"] doubleValue] - backingScale) < 0.001 &&
        [entry[@"sourcePixelWidth"] unsignedLongLongValue] == sourceWidth &&
        [entry[@"sourcePixelHeight"] unsignedLongLongValue] == sourceHeight &&
        [entry[@"coversDevice"] boolValue] &&
        fabs([logical[@"x"] doubleValue]) < 0.001 &&
        fabs([logical[@"y"] doubleValue]) < 0.001 &&
        fabs([logical[@"width"] doubleValue] - IOSUsePlayDeviceLogicalWidth) < 0.001 &&
        fabs([logical[@"height"] doubleValue] - IOSUsePlayDeviceLogicalHeight) < 0.001 &&
        fabs([native[@"x"] doubleValue]) < 0.001 &&
        fabs([native[@"y"] doubleValue]) < 0.001 &&
        fabs([native[@"width"] doubleValue] - IOSUsePlayDeviceNativeWidth) < 0.001 &&
        fabs([native[@"height"] doubleValue] - IOSUsePlayDeviceNativeHeight) < 0.001;
}

static BOOL IOSUseFixtureResolveClick(
    CGFloat backingScale,
    CGPoint *logicalClick,
    CGFloat *logicalError
) {
    CGRect windowLogicalRect = CGRectZero;
    NSString *geometryFailure = nil;
    BOOL windowGeometryReady = IOSUsePlayValidateRelativeWindowGeometry(
        CGRectMake(640, 80, IOSUsePlayDeviceLogicalWidth, IOSUsePlayDeviceLogicalHeight),
        CGRectMake(640, 300, IOSUsePlayDeviceLogicalWidth, IOSUsePlayDeviceLogicalHeight),
        CGRectMake(900, 25, 260, 219),
        CGRectMake(725, 672, 260, 219),
        &windowLogicalRect,
        &geometryFailure
    );
    CGPoint backingPixel = CGPointMake(160 * backingScale, 20 * backingScale);
    CGPoint appKitPoint = CGPointMake(
        backingPixel.x / backingScale,
        backingPixel.y / backingScale
    );
    CGRect logicalProbe = CGRectZero;
    NSString *probeFailure = nil;
    BOOL probeReady = windowGeometryReady && IOSUsePlayResolveLocalAppKitRect(
        windowLogicalRect,
        CGRectMake(appKitPoint.x - 0.5, appKitPoint.y - 0.5, 1, 1),
        &logicalProbe,
        &probeFailure
    );
    CGPoint resolved = CGPointMake(
        CGRectGetMidX(logicalProbe), CGRectGetMidY(logicalProbe)
    );
    CGPoint expected = CGPointMake(245, 571);
    CGFloat error = hypot(resolved.x - expected.x, resolved.y - expected.y);
    if (logicalClick != NULL) {
        *logicalClick = resolved;
    }
    if (logicalError != NULL) {
        *logicalError = error;
    }
    return probeReady && geometryFailure == nil && probeFailure == nil &&
        error <= 0.5;
}

static BOOL IOSUseFixtureRejectsCroppedBaseFrame(CGFloat backingScale) {
    CGImageRef cropped = IOSUseFixtureCreateSourceImage(
        CGSizeMake(
            IOSUsePlayDeviceLogicalWidth,
            IOSUsePlayDeviceLogicalHeight - 2
        ),
        backingScale,
        NO
    );
    IOSUsePlayWindowCapture capture = {
        .image = cropped,
        .appKitFrame = CGRectMake(
            640,
            80,
            IOSUsePlayDeviceLogicalWidth,
            IOSUsePlayDeviceLogicalHeight - 2
        ),
        .deviceLogicalRect = CGRectMake(
            0,
            1,
            IOSUsePlayDeviceLogicalWidth,
            IOSUsePlayDeviceLogicalHeight - 2
        ),
        .backingScale = backingScale,
        .windowNumber = 9001,
    };
    NSString *failure = nil;
    CGImageRef composite = cropped == NULL ? NULL : IOSUsePlayCompositeWindowCaptures(
        &capture,
        1,
        CGRectMake(0, 0, IOSUsePlayDeviceLogicalWidth, IOSUsePlayDeviceLogicalHeight),
        9001,
        NULL,
        &failure
    );
    if (composite != NULL) {
        CGImageRelease(composite);
    }
    if (cropped != NULL) {
        CGImageRelease(cropped);
    }
    return composite == NULL &&
        [failure containsString:@"primary native window does not uniquely cover"];
}

static BOOL IOSUseFixtureRunScale(
    CGFloat backingScale,
    CGPoint *logicalClick
) {
    CGRect deviceFrame = CGRectMake(
        0, 0, IOSUsePlayDeviceLogicalWidth, IOSUsePlayDeviceLogicalHeight
    );
    CGImageRef base = IOSUseFixtureCreateSourceImage(
        deviceFrame.size, backingScale, YES
    );
    IOSUsePlayWindowCapture capture = {
        .image = base,
        .appKitFrame = CGRectMake(
            640, 80, IOSUsePlayDeviceLogicalWidth, IOSUsePlayDeviceLogicalHeight
        ),
        .deviceLogicalRect = deviceFrame,
        .backingScale = backingScale,
        .windowNumber = 9001,
    };
    NSArray<NSDictionary<NSString *, id> *> *evidence = nil;
    NSString *failure = nil;
    CGImageRef composite = base == NULL ? NULL : IOSUsePlayCompositeWindowCaptures(
        &capture, 1, deviceFrame, 9001, &evidence, &failure
    );
    size_t expectedSourceWidth = (size_t)llround(
        IOSUsePlayDeviceLogicalWidth * backingScale
    );
    size_t expectedSourceHeight = (size_t)llround(
        IOSUsePlayDeviceLogicalHeight * backingScale
    );
    BOOL fixedDeviceReady =
        IOSUsePlayDeviceLogicalWidth == 430 &&
        IOSUsePlayDeviceLogicalHeight == 932 &&
        IOSUsePlayDeviceNativeWidth == 1290 &&
        IOSUsePlayDeviceNativeHeight == 2796 &&
        IOSUsePlayDeviceScale == 3;
    BOOL outputGeometryReady = composite != NULL &&
        CGImageGetWidth(composite) == IOSUsePlayDeviceNativeWidth &&
        CGImageGetHeight(composite) == IOSUsePlayDeviceNativeHeight;
    BOOL evidenceReady = evidence.count == 1 && IOSUseFixtureEvidenceMatches(
        evidence.firstObject,
        backingScale,
        expectedSourceWidth,
        expectedSourceHeight
    );
    struct {
        CGPoint point;
        IOSUseFixtureColor color;
    } samples[] = {
        {CGPointMake(215, 12), IOSUseFixtureTopColor},
        {CGPointMake(12, 300), IOSUseFixtureLeftColor},
        {CGPointMake(418, 300), IOSUseFixtureRightColor},
        {CGPointMake(215, 500), IOSUseFixtureCenterColor},
        {CGPointMake(215, 920), IOSUseFixtureBottomColor},
    };
    BOOL edgePixelsReady = YES;
    for (NSUInteger index = 0; index < sizeof(samples) / sizeof(samples[0]); index += 1) {
        uint8_t pixel[4] = {0};
        edgePixelsReady &= IOSUseFixtureSampleTopLeftPixel(
            composite, samples[index].point, pixel
        ) && IOSUseFixtureColorMatches(pixel, samples[index].color);
    }
    CGFloat clickError = INFINITY;
    CGPoint click = CGPointMake(NAN, NAN);
    BOOL clickReady = IOSUseFixtureResolveClick(
        backingScale, &click, &clickError
    );
    if (logicalClick != NULL) {
        *logicalClick = click;
    }
    BOOL cropRejected = IOSUseFixtureRejectsCroppedBaseFrame(backingScale);
    BOOL passed = fixedDeviceReady && outputGeometryReady && evidenceReady &&
        edgePixelsReady && clickReady && cropRejected && failure == nil;
    fprintf(
        stderr,
        "[window-compositor-backing-scale] host=%.0fx logical=%ldx%ld native=%zux%zu full-frame=%d edge-pixels=%d crop-rejected=%d click=(%.3f,%.3f) error=%.3f pass=%d%s%s\n",
        backingScale,
        (long)IOSUsePlayDeviceLogicalWidth,
        (long)IOSUsePlayDeviceLogicalHeight,
        composite == NULL ? 0 : CGImageGetWidth(composite),
        composite == NULL ? 0 : CGImageGetHeight(composite),
        outputGeometryReady,
        edgePixelsReady,
        cropRejected,
        click.x,
        click.y,
        clickError,
        passed,
        failure == nil ? "" : " failure=",
        failure == nil ? "" : failure.UTF8String
    );
    if (composite != NULL) {
        CGImageRelease(composite);
    }
    if (base != NULL) {
        CGImageRelease(base);
    }
    return passed;
}

int main(void) {
    @autoreleasepool {
        CGPoint clickAt1x = CGPointZero;
        CGPoint clickAt2x = CGPointZero;
        BOOL scale1Ready = IOSUseFixtureRunScale(1, &clickAt1x);
        BOOL scale2Ready = IOSUseFixtureRunScale(2, &clickAt2x);
        CGFloat clickDrift = hypot(
            clickAt1x.x - clickAt2x.x,
            clickAt1x.y - clickAt2x.y
        );
        BOOL sizePredicateReady =
            IOSUsePlayAppKitCGWindowSizesMatch(
                CGRectMake(590, 0, 430, 932),
                CGRectMake(40, 374, 430, 932)
            ) &&
            !IOSUsePlayAppKitCGWindowSizesMatch(
                CGRectMake(590, 0, 429, 932),
                CGRectMake(40, 374, 430, 932)
            ) &&
            !IOSUsePlayAppKitCGWindowSizesMatch(
                CGRectMake(590, 0, 430, 931),
                CGRectMake(40, 374, 430, 932)
            );
        BOOL passed = scale1Ready &&
            scale2Ready &&
            clickDrift <= 0.5 &&
            sizePredicateReady;
        fprintf(
            stderr,
            "[window-compositor-backing-scale] host-scale "
            "click-drift=%.3f logical-point sizes=%d pass=%d\n",
            clickDrift,
            sizePredicateReady,
            passed
        );
        return passed ? 0 : 1;
    }
}
