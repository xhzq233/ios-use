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

static const IOSUseFixtureColor IOSUseFixtureBaseColor = {
    .blue = 190,
    .green = 160,
    .red = 120,
    .alpha = 255,
};
static const IOSUseFixtureColor IOSUseFixtureTimeColor = {
    .blue = 0,
    .green = 0,
    .red = 255,
    .alpha = 255,
};
static const IOSUseFixtureColor IOSUseFixtureGlyphColor = {
    .blue = 0,
    .green = 255,
    .red = 0,
    .alpha = 255,
};
static const IOSUseFixtureColor IOSUseFixtureIslandColor = {
    .blue = 0,
    .green = 0,
    .red = 0,
    .alpha = 255,
};
static const IOSUseFixtureColor IOSUseFixtureHomeColor = {
    .blue = 255,
    .green = 255,
    .red = 255,
    .alpha = 255,
};

static CGRect IOSUseFixtureDynamicIslandRect(void) {
    return CGRectMake(
        (IOSUsePlayDeviceLogicalWidth -
            IOSUsePlayDeviceDynamicIslandWidth) / 2.0,
        IOSUsePlayDeviceDynamicIslandTop,
        IOSUsePlayDeviceDynamicIslandWidth,
        IOSUsePlayDeviceDynamicIslandHeight
    );
}

static CGRect IOSUseFixtureHomeIndicatorRect(void) {
    return CGRectMake(
        (IOSUsePlayDeviceLogicalWidth -
            IOSUsePlayDeviceHomeIndicatorWidth) / 2.0,
        IOSUsePlayDeviceLogicalHeight -
            IOSUsePlayDeviceHomeIndicatorBottom -
            IOSUsePlayDeviceHomeIndicatorHeight,
        IOSUsePlayDeviceHomeIndicatorWidth,
        IOSUsePlayDeviceHomeIndicatorHeight
    );
}

static void IOSUseFixtureFillPixelRect(
    uint8_t *pixels,
    size_t width,
    size_t height,
    size_t rowBytes,
    CGRect logicalRect,
    CGFloat backingScale,
    IOSUseFixtureColor color
) {
    size_t minX = (size_t)llround(
        CGRectGetMinX(logicalRect) * backingScale
    );
    size_t minY = (size_t)llround(
        CGRectGetMinY(logicalRect) * backingScale
    );
    size_t maxX = (size_t)llround(
        CGRectGetMaxX(logicalRect) * backingScale
    );
    size_t maxY = (size_t)llround(
        CGRectGetMaxY(logicalRect) * backingScale
    );
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
    CGFloat backingScale,
    BOOL systemChrome
) CF_RETURNS_RETAINED {
    size_t width = (size_t)llround(
        IOSUsePlayDeviceLogicalWidth * backingScale
    );
    size_t height = (size_t)llround(
        IOSUsePlayDeviceLogicalHeight * backingScale
    );
    size_t rowBytes = width * 4;
    uint8_t *pixels = calloc(height, rowBytes);
    if (pixels == NULL) {
        return NULL;
    }
    if (systemChrome) {
        IOSUseFixtureFillPixelRect(
            pixels,
            width,
            height,
            rowBytes,
            CGRectMake(24, 16, 72, 20),
            backingScale,
            IOSUseFixtureTimeColor
        );
        IOSUseFixtureFillPixelRect(
            pixels,
            width,
            height,
            rowBytes,
            CGRectMake(326, 16, 80, 20),
            backingScale,
            IOSUseFixtureGlyphColor
        );
        IOSUseFixtureFillPixelRect(
            pixels,
            width,
            height,
            rowBytes,
            IOSUseFixtureDynamicIslandRect(),
            backingScale,
            IOSUseFixtureIslandColor
        );
        IOSUseFixtureFillPixelRect(
            pixels,
            width,
            height,
            rowBytes,
            IOSUseFixtureHomeIndicatorRect(),
            backingScale,
            IOSUseFixtureHomeColor
        );
    } else {
        IOSUseFixtureFillPixelRect(
            pixels,
            width,
            height,
            rowBytes,
            CGRectMake(
                0,
                0,
                IOSUsePlayDeviceLogicalWidth,
                IOSUsePlayDeviceLogicalHeight
            ),
            backingScale,
            IOSUseFixtureBaseColor
        );
    }

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (colorSpace == NULL) {
        free(pixels);
        return NULL;
    }
    CGContextRef context = CGBitmapContextCreate(
        pixels,
        width,
        height,
        8,
        rowBytes,
        colorSpace,
        kCGBitmapByteOrder32Little |
            kCGImageAlphaPremultipliedFirst
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
    size_t x = (size_t)floor(
        logicalPoint.x * IOSUsePlayDeviceScale
    );
    size_t y = (size_t)floor(
        logicalPoint.y * IOSUsePlayDeviceScale
    );
    if (x >= CGImageGetWidth(image) ||
        y >= CGImageGetHeight(image)) {
        return NO;
    }
    CGImageRef sample = CGImageCreateWithImageInRect(
        image,
        CGRectMake(x, y, 1, 1)
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
        pixel,
        1,
        1,
        8,
        4,
        colorSpace,
        kCGBitmapByteOrder32Little |
            kCGImageAlphaPremultipliedFirst
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
    uint32_t windowNumber,
    CGFloat backingScale,
    size_t sourceWidth,
    size_t sourceHeight
) {
    NSDictionary<NSString *, NSNumber *> *appKit =
        entry[@"appKitFrame"];
    NSDictionary<NSString *, NSNumber *> *logical =
        entry[@"deviceLogicalRect"];
    NSDictionary<NSString *, NSNumber *> *native =
        entry[@"destinationNativeRect"];
    return [entry[@"windowNumber"] unsignedIntValue] ==
            windowNumber &&
        fabs(
            [entry[@"backingScaleFactor"] doubleValue] -
                backingScale
        ) < 0.001 &&
        [entry[@"sourcePixelWidth"] unsignedLongLongValue] ==
            sourceWidth &&
        [entry[@"sourcePixelHeight"] unsignedLongLongValue] ==
            sourceHeight &&
        [entry[@"coversDevice"] boolValue] &&
        fabs(
            [appKit[@"width"] doubleValue] -
                IOSUsePlayDeviceLogicalWidth
        ) < 0.001 &&
        fabs(
            [appKit[@"height"] doubleValue] -
                IOSUsePlayDeviceLogicalHeight
        ) < 0.001 &&
        fabs([logical[@"x"] doubleValue]) < 0.001 &&
        fabs([logical[@"y"] doubleValue]) < 0.001 &&
        fabs(
            [logical[@"width"] doubleValue] -
                IOSUsePlayDeviceLogicalWidth
        ) < 0.001 &&
        fabs(
            [logical[@"height"] doubleValue] -
                IOSUsePlayDeviceLogicalHeight
        ) < 0.001 &&
        fabs([native[@"x"] doubleValue]) < 0.001 &&
        fabs([native[@"y"] doubleValue]) < 0.001 &&
        fabs(
            [native[@"width"] doubleValue] -
                IOSUsePlayDeviceNativeWidth
        ) < 0.001 &&
        fabs(
            [native[@"height"] doubleValue] -
                IOSUsePlayDeviceNativeHeight
        ) < 0.001;
}

static BOOL IOSUseFixtureResolveClick(
    CGFloat backingScale,
    CGPoint *logicalClick,
    CGFloat *logicalError
) {
    CGRect windowLogicalRect = CGRectZero;
    NSString *geometryFailure = nil;
    BOOL windowGeometryReady =
        IOSUsePlayValidateRelativeWindowGeometry(
            CGRectMake(
                640,
                80,
                IOSUsePlayDeviceLogicalWidth,
                IOSUsePlayDeviceLogicalHeight
            ),
            CGRectMake(
                640,
                300,
                IOSUsePlayDeviceLogicalWidth,
                IOSUsePlayDeviceLogicalHeight
            ),
            CGRectMake(900, 25, 260, 219),
            CGRectMake(725, 672, 260, 219),
            &windowLogicalRect,
            &geometryFailure
        );

    // The corresponding backing pixel changes with the host display, while
    // NSEvent/AppKit window geometry remains point-based. Normalize the
    // synthetic backing observation before exercising the production
    // bottom-left AppKit -> top-left UIKit logical transform.
    CGPoint backingPixel = CGPointMake(
        160 * backingScale,
        20 * backingScale
    );
    CGPoint appKitPoint = CGPointMake(
        backingPixel.x / backingScale,
        backingPixel.y / backingScale
    );
    CGRect logicalProbe = CGRectZero;
    NSString *probeFailure = nil;
    BOOL probeReady =
        windowGeometryReady &&
        IOSUsePlayResolveLocalAppKitRect(
            windowLogicalRect,
            CGRectMake(
                appKitPoint.x - 0.5,
                appKitPoint.y - 0.5,
                1,
                1
            ),
            &logicalProbe,
            &probeFailure
        );
    CGPoint resolved = CGPointMake(
        CGRectGetMidX(logicalProbe),
        CGRectGetMidY(logicalProbe)
    );
    CGPoint expected = CGPointMake(245, 571);
    CGFloat error = hypot(
        resolved.x - expected.x,
        resolved.y - expected.y
    );
    if (logicalClick != NULL) {
        *logicalClick = resolved;
    }
    if (logicalError != NULL) {
        *logicalError = error;
    }
    return probeReady &&
        geometryFailure == nil &&
        probeFailure == nil &&
        fabs(windowLogicalRect.origin.x - 85) < 0.001 &&
        fabs(windowLogicalRect.origin.y - 372) < 0.001 &&
        fabs(windowLogicalRect.size.width - 260) < 0.001 &&
        fabs(windowLogicalRect.size.height - 219) < 0.001 &&
        error <= 0.5;
}

static BOOL IOSUseFixtureRunScale(
    CGFloat backingScale,
    CGPoint *logicalClick
) {
    CGImageRef chrome = IOSUseFixtureCreateSourceImage(
        backingScale,
        YES
    );
    CGImageRef base = IOSUseFixtureCreateSourceImage(
        backingScale,
        NO
    );
    CGRect deviceFrame = CGRectMake(
        0,
        0,
        IOSUsePlayDeviceLogicalWidth,
        IOSUsePlayDeviceLogicalHeight
    );
    IOSUsePlayWindowCapture captures[2] = {
        {
            .image = chrome,
            .appKitFrame = CGRectMake(
                640,
                80,
                IOSUsePlayDeviceLogicalWidth,
                IOSUsePlayDeviceLogicalHeight
            ),
            .deviceLogicalRect = deviceFrame,
            .backingScale = backingScale,
            .windowNumber = 9002,
        },
        {
            .image = base,
            .appKitFrame = CGRectMake(
                640,
                80,
                IOSUsePlayDeviceLogicalWidth,
                IOSUsePlayDeviceLogicalHeight
            ),
            .deviceLogicalRect = deviceFrame,
            .backingScale = backingScale,
            .windowNumber = 9001,
        },
    };
    NSArray<NSDictionary<NSString *, id> *> *evidence = nil;
    NSString *failure = nil;
    CGImageRef composite =
        chrome == NULL || base == NULL
        ? NULL
        : IOSUsePlayCompositeWindowCaptures(
            captures,
            2,
            deviceFrame,
            9001,
            &evidence,
            &failure
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
    BOOL outputGeometryReady =
        composite != NULL &&
        CGImageGetWidth(composite) ==
            IOSUsePlayDeviceNativeWidth &&
        CGImageGetHeight(composite) ==
            IOSUsePlayDeviceNativeHeight &&
        CGImageGetWidth(composite) /
            IOSUsePlayDeviceLogicalWidth == 3 &&
        CGImageGetHeight(composite) /
            IOSUsePlayDeviceLogicalHeight == 3;
    BOOL evidenceReady =
        evidence.count == 2 &&
        IOSUseFixtureEvidenceMatches(
            evidence[0],
            9002,
            backingScale,
            expectedSourceWidth,
            expectedSourceHeight
        ) &&
        IOSUseFixtureEvidenceMatches(
            evidence[1],
            9001,
            backingScale,
            expectedSourceWidth,
            expectedSourceHeight
        );

    uint8_t backgroundPixel[4] = {0};
    uint8_t timePixel[4] = {0};
    uint8_t glyphPixel[4] = {0};
    uint8_t islandPixel[4] = {0};
    uint8_t homePixel[4] = {0};
    BOOL backgroundReady =
        IOSUseFixtureSampleTopLeftPixel(
            composite,
            CGPointMake(10, 200),
            backgroundPixel
        ) &&
        IOSUseFixtureColorMatches(
            backgroundPixel,
            IOSUseFixtureBaseColor
        );
    BOOL timeReady =
        IOSUseFixtureSampleTopLeftPixel(
            composite,
            CGPointMake(40, 24),
            timePixel
        ) &&
        IOSUseFixtureColorMatches(
            timePixel,
            IOSUseFixtureTimeColor
        );
    BOOL glyphsReady =
        IOSUseFixtureSampleTopLeftPixel(
            composite,
            CGPointMake(350, 24),
            glyphPixel
        ) &&
        IOSUseFixtureColorMatches(
            glyphPixel,
            IOSUseFixtureGlyphColor
        );
    BOOL islandReady =
        IOSUseFixtureSampleTopLeftPixel(
            composite,
            CGPointMake(
                IOSUsePlayDeviceLogicalWidth / 2.0,
                IOSUsePlayDeviceDynamicIslandTop +
                    IOSUsePlayDeviceDynamicIslandHeight / 2.0
            ),
            islandPixel
        ) &&
        IOSUseFixtureColorMatches(
            islandPixel,
            IOSUseFixtureIslandColor
        );
    BOOL homeReady =
        IOSUseFixtureSampleTopLeftPixel(
            composite,
            CGPointMake(
                IOSUsePlayDeviceLogicalWidth / 2.0,
                IOSUsePlayDeviceLogicalHeight -
                    IOSUsePlayDeviceHomeIndicatorBottom -
                    IOSUsePlayDeviceHomeIndicatorHeight / 2.0
            ),
            homePixel
        ) &&
        IOSUseFixtureColorMatches(
            homePixel,
            IOSUseFixtureHomeColor
        );
    CGFloat clickError = INFINITY;
    CGPoint click = CGPointMake(NAN, NAN);
    BOOL clickReady = IOSUseFixtureResolveClick(
        backingScale,
        &click,
        &clickError
    );
    if (logicalClick != NULL) {
        *logicalClick = click;
    }
    BOOL passed = fixedDeviceReady &&
        outputGeometryReady &&
        evidenceReady &&
        backgroundReady &&
        timeReady &&
        glyphsReady &&
        islandReady &&
        homeReady &&
        clickReady &&
        failure == nil;
    fprintf(
        stderr,
        "[window-compositor-backing-scale] host=%.0fx "
        "logical=%ldx%ld source=%zux%zu native=%zux%zu output=3x "
        "chrome={time:%d glyphs:%d island:%d home:%d} "
        "click=(%.3f,%.3f) error=%.3f pass=%d%s%s\n",
        backingScale,
        (long)IOSUsePlayDeviceLogicalWidth,
        (long)IOSUsePlayDeviceLogicalHeight,
        expectedSourceWidth,
        expectedSourceHeight,
        composite == NULL ? 0 : CGImageGetWidth(composite),
        composite == NULL ? 0 : CGImageGetHeight(composite),
        timeReady,
        glyphsReady,
        islandReady,
        homeReady,
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
    if (chrome != NULL) {
        CGImageRelease(chrome);
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
        BOOL passed =
            scale1Ready &&
            scale2Ready &&
            clickDrift <= 0.5;
        fprintf(
            stderr,
            "[window-compositor-backing-scale] "
            "host-scale click-drift=%.3f logical-point pass=%d\n",
            clickDrift,
            passed
        );
        return passed ? 0 : 1;
    }
}
