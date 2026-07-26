#import "IOSUsePlayWindowCompositor.h"
#import "IOSUsePlayDevice.h"

#import <CommonCrypto/CommonDigest.h>
#import <objc/message.h>

#import <math.h>

typedef id (*IOSUseCompositorSendID)(id, SEL);

static const CGFloat IOSUseCompositorGeometryTolerance = 0.01;

CGFloat const IOSUsePlayHostCanvasSpacerPoints = 8.0;
CGFloat const IOSUsePlayHostCanvasMinimumDisplayScale = 0.5;

static NSDictionary<NSString *, NSNumber *> *IOSUseCompositorRectJSON(
    CGRect rect
) {
    return @{
        @"x": @(rect.origin.x),
        @"y": @(rect.origin.y),
        @"width": @(rect.size.width),
        @"height": @(rect.size.height),
    };
}

static BOOL IOSUseCompositorFiniteRect(CGRect rect) {
    return isfinite(rect.origin.x) &&
        isfinite(rect.origin.y) &&
        isfinite(rect.size.width) &&
        isfinite(rect.size.height) &&
        rect.size.width > 0 &&
        rect.size.height > 0;
}

static BOOL IOSUseCompositorApproximatelyEqual(
    CGFloat lhs,
    CGFloat rhs
) {
    return fabs(lhs - rhs) <= IOSUseCompositorGeometryTolerance;
}

static BOOL IOSUseCompositorRectEquals(CGRect lhs, CGRect rhs) {
    return IOSUseCompositorApproximatelyEqual(
            lhs.origin.x,
            rhs.origin.x
        ) &&
        IOSUseCompositorApproximatelyEqual(
            lhs.origin.y,
            rhs.origin.y
        ) &&
        IOSUseCompositorApproximatelyEqual(
            lhs.size.width,
            rhs.size.width
        ) &&
        IOSUseCompositorApproximatelyEqual(
            lhs.size.height,
            rhs.size.height
        );
}

static BOOL IOSUseCompositorContainsRect(
    CGRect container,
    CGRect candidate
) {
    return CGRectGetMinX(candidate) >=
            CGRectGetMinX(container) -
                IOSUseCompositorGeometryTolerance &&
        CGRectGetMinY(candidate) >=
            CGRectGetMinY(container) -
                IOSUseCompositorGeometryTolerance &&
        CGRectGetMaxX(candidate) <=
        CGRectGetMaxX(container) +
                IOSUseCompositorGeometryTolerance &&
        CGRectGetMaxY(candidate) <=
            CGRectGetMaxY(container) +
                IOSUseCompositorGeometryTolerance;
}

static BOOL IOSUseCompositorContainsPoint(
    CGRect rect,
    CGPoint point,
    BOOL includeMaximumEdge
) {
    if (!IOSUseCompositorFiniteRect(rect) ||
        !isfinite(point.x) ||
        !isfinite(point.y)) {
        return NO;
    }
    BOOL xInside = point.x >= CGRectGetMinX(rect) &&
        (includeMaximumEdge
            ? point.x <= CGRectGetMaxX(rect)
            : point.x < CGRectGetMaxX(rect));
    BOOL yInside = point.y >= CGRectGetMinY(rect) &&
        (includeMaximumEdge
            ? point.y <= CGRectGetMaxY(rect)
            : point.y < CGRectGetMaxY(rect));
    return xInside && yInside;
}

static CGFloat IOSUseCompositorClampNear(
    CGFloat value,
    CGFloat lower,
    CGFloat upper
) {
    if (fabs(value - lower) <= IOSUseCompositorGeometryTolerance) {
        return lower;
    }
    if (fabs(value - upper) <= IOSUseCompositorGeometryTolerance) {
        return upper;
    }
    return value;
}

BOOL IOSUsePlayResolveHostInitialContentSize(
    CGSize visibleFrameSize,
    CGSize frameDecorationSize,
    CGSize *contentSize,
    NSString **failure
) {
    if (contentSize != NULL) {
        *contentSize = CGSizeZero;
    }
    if (failure != NULL) {
        *failure = nil;
    }
    if (!isfinite(visibleFrameSize.width) ||
        !isfinite(visibleFrameSize.height) ||
        !isfinite(frameDecorationSize.width) ||
        !isfinite(frameDecorationSize.height) ||
        visibleFrameSize.width <= 0 || visibleFrameSize.height <= 0 ||
        frameDecorationSize.width < 0 || frameDecorationSize.height < 0) {
        if (failure != NULL) {
            *failure = @"visible host frame or frame decoration is invalid";
        }
        return NO;
    }
    CGSize minimumContent = CGSizeMake(
        IOSUsePlayDeviceLogicalWidth *
            IOSUsePlayHostCanvasMinimumDisplayScale,
        IOSUsePlayHostCanvasSpacerPoints +
            IOSUsePlayDeviceLogicalHeight *
                IOSUsePlayHostCanvasMinimumDisplayScale
    );
    CGSize minimumFrame = CGSizeMake(
        minimumContent.width + frameDecorationSize.width,
        minimumContent.height + frameDecorationSize.height
    );
    if (visibleFrameSize.width + IOSUseCompositorGeometryTolerance <
            minimumFrame.width ||
        visibleFrameSize.height + IOSUseCompositorGeometryTolerance <
            minimumFrame.height) {
        if (failure != NULL) {
            *failure = [NSString stringWithFormat:
                @"visible host frame %.3fx%.3f cannot contain minimum "
                 "titled host frame %.3fx%.3f",
                visibleFrameSize.width,
                visibleFrameSize.height,
                minimumFrame.width,
                minimumFrame.height
            ];
        }
        return NO;
    }
    CGSize largestContent = CGSizeMake(
        visibleFrameSize.width - frameDecorationSize.width,
        visibleFrameSize.height - frameDecorationSize.height
    );
    CGSize preferredContent = CGSizeMake(
        IOSUsePlayDeviceLogicalWidth,
        IOSUsePlayDeviceLogicalHeight + IOSUsePlayHostCanvasSpacerPoints
    );
    CGSize resolved = CGSizeMake(
        MIN(preferredContent.width, largestContent.width),
        MIN(preferredContent.height, largestContent.height)
    );
    if (resolved.width + IOSUseCompositorGeometryTolerance <
            minimumContent.width ||
        resolved.height + IOSUseCompositorGeometryTolerance <
            minimumContent.height) {
        if (failure != NULL) {
            *failure = @"resolved host content would clip the fixed canvas";
        }
        return NO;
    }
    if (contentSize != NULL) {
        *contentSize = resolved;
    }
    return YES;
}

BOOL IOSUsePlayResolveHostCanvasLayout(
    CGRect hostContentBounds,
    IOSUsePlayHostCanvasLayout *layout,
    NSString **failure
) {
    if (failure != NULL) {
        *failure = nil;
    }
    if (!IOSUseCompositorFiniteRect(hostContentBounds)) {
        if (failure != NULL) {
            *failure = @"host content bounds are not finite and non-empty";
        }
        return NO;
    }
    CGFloat minimumWidth =
        IOSUsePlayDeviceLogicalWidth *
        IOSUsePlayHostCanvasMinimumDisplayScale;
    CGFloat minimumHeight = IOSUsePlayHostCanvasSpacerPoints +
        IOSUsePlayDeviceLogicalHeight *
            IOSUsePlayHostCanvasMinimumDisplayScale;
    if (hostContentBounds.size.width +
            IOSUseCompositorGeometryTolerance < minimumWidth ||
        hostContentBounds.size.height +
            IOSUseCompositorGeometryTolerance < minimumHeight) {
        if (failure != NULL) {
            *failure = [NSString stringWithFormat:
                @"host content %.3fx%.3f is smaller than the explicit "
                 "minimum %.3fx%.3f for the complete canvas",
                hostContentBounds.size.width,
                hostContentBounds.size.height,
                minimumWidth,
                minimumHeight
            ];
        }
        return NO;
    }
    CGFloat drawableHeight = hostContentBounds.size.height -
        IOSUsePlayHostCanvasSpacerPoints;
    if (drawableHeight <= 0) {
        if (failure != NULL) {
            *failure = @"host content has no area below the transparent spacer";
        }
        return NO;
    }
    CGFloat displayScale = MIN(
        hostContentBounds.size.width / IOSUsePlayDeviceLogicalWidth,
        drawableHeight / IOSUsePlayDeviceLogicalHeight
    );
    if (!isfinite(displayScale) ||
        displayScale < IOSUsePlayHostCanvasMinimumDisplayScale -
            IOSUseCompositorGeometryTolerance) {
        if (failure != NULL) {
            *failure = @"host canvas display scale is invalid";
        }
        return NO;
    }
    CGSize canvasSize = CGSizeMake(
        IOSUsePlayDeviceLogicalWidth * displayScale,
        IOSUsePlayDeviceLogicalHeight * displayScale
    );
    CGRect canvasRect = CGRectMake(
        hostContentBounds.origin.x +
            (hostContentBounds.size.width - canvasSize.width) / 2.0,
        CGRectGetMaxY(hostContentBounds) -
            IOSUsePlayHostCanvasSpacerPoints - canvasSize.height,
        canvasSize.width,
        canvasSize.height
    );
    if (!IOSUseCompositorContainsRect(hostContentBounds, canvasRect) ||
        !IOSUseCompositorApproximatelyEqual(
            CGRectGetMaxY(canvasRect) +
                IOSUsePlayHostCanvasSpacerPoints,
            CGRectGetMaxY(hostContentBounds)
        )) {
        if (failure != NULL) {
            *failure = @"resolved canvas is not fully below the transparent spacer";
        }
        return NO;
    }
    if (layout != NULL) {
        *layout = (IOSUsePlayHostCanvasLayout){
            .hostContentBounds = hostContentBounds,
            .canvasRect = canvasRect,
            .displayScale = displayScale,
            .inverseDisplayScale = 1.0 / displayScale,
            .transparentSpacer = IOSUsePlayHostCanvasSpacerPoints,
        };
    }
    return YES;
}

BOOL IOSUsePlayMapHostContentPointToCanvas(
    IOSUsePlayHostCanvasLayout layout,
    CGPoint hostContentPoint,
    CGPoint *canvasLogicalPoint,
    NSString **failure
) {
    if (failure != NULL) {
        *failure = nil;
    }
    if (!IOSUseCompositorFiniteRect(layout.hostContentBounds) ||
        !IOSUseCompositorFiniteRect(layout.canvasRect) ||
        !isfinite(layout.displayScale) ||
        layout.displayScale <= 0 ||
        !IOSUseCompositorContainsPoint(
            layout.hostContentBounds,
            hostContentPoint,
            NO
        )) {
        if (failure != NULL) {
            *failure = @"host point or host-canvas layout is invalid";
        }
        return NO;
    }
    if (!IOSUseCompositorContainsPoint(
            layout.canvasRect,
            hostContentPoint,
            NO
        )) {
        if (failure != NULL) {
            *failure = @"host point is outside the target canvas";
        }
        return NO;
    }
    CGPoint logical = CGPointMake(
        (hostContentPoint.x - CGRectGetMinX(layout.canvasRect)) /
            layout.displayScale,
        (CGRectGetMaxY(layout.canvasRect) - hostContentPoint.y) /
            layout.displayScale
    );
    logical.x = IOSUseCompositorClampNear(
        logical.x,
        0,
        IOSUsePlayDeviceLogicalWidth
    );
    logical.y = IOSUseCompositorClampNear(
        logical.y,
        0,
        IOSUsePlayDeviceLogicalHeight
    );
    if (!IOSUseCompositorContainsPoint(
            CGRectMake(
                0,
                0,
                IOSUsePlayDeviceLogicalWidth,
                IOSUsePlayDeviceLogicalHeight
            ),
            logical,
            NO
        )) {
        if (failure != NULL) {
            *failure = @"inverse host transform is outside the fixed canvas";
        }
        return NO;
    }
    if (canvasLogicalPoint != NULL) {
        *canvasLogicalPoint = logical;
    }
    return YES;
}

BOOL IOSUsePlayMapCanvasPointToHostContent(
    IOSUsePlayHostCanvasLayout layout,
    CGPoint canvasLogicalPoint,
    CGPoint *hostContentPoint,
    NSString **failure
) {
    if (failure != NULL) {
        *failure = nil;
    }
    CGRect device = CGRectMake(
        0,
        0,
        IOSUsePlayDeviceLogicalWidth,
        IOSUsePlayDeviceLogicalHeight
    );
    if (!IOSUseCompositorFiniteRect(layout.hostContentBounds) ||
        !IOSUseCompositorFiniteRect(layout.canvasRect) ||
        !isfinite(layout.displayScale) ||
        layout.displayScale <= 0 ||
        !IOSUseCompositorContainsPoint(
            device,
            canvasLogicalPoint,
            YES
        )) {
        if (failure != NULL) {
            *failure = @"canvas point or host-canvas layout is invalid";
        }
        return NO;
    }
    CGPoint point = CGPointMake(
        CGRectGetMinX(layout.canvasRect) +
            canvasLogicalPoint.x * layout.displayScale,
        CGRectGetMaxY(layout.canvasRect) -
            canvasLogicalPoint.y * layout.displayScale
    );
    if (!IOSUseCompositorContainsPoint(
            layout.canvasRect,
            point,
            YES
        )) {
        if (failure != NULL) {
            *failure = @"forward host transform is outside the canvas";
        }
        return NO;
    }
    if (hostContentPoint != NULL) {
        *hostContentPoint = point;
    }
    return YES;
}

BOOL IOSUsePlayMapHostContentRectToCanvas(
    IOSUsePlayHostCanvasLayout layout,
    CGRect hostContentRect,
    CGRect *canvasLogicalRect,
    NSString **failure
) {
    if (canvasLogicalRect != NULL) {
        *canvasLogicalRect = CGRectNull;
    }
    if (failure != NULL) {
        *failure = nil;
    }
    if (!IOSUseCompositorFiniteRect(layout.hostContentBounds) ||
        !IOSUseCompositorFiniteRect(layout.canvasRect) ||
        !IOSUseCompositorFiniteRect(hostContentRect) ||
        !isfinite(layout.displayScale) || layout.displayScale <= 0 ||
        !IOSUseCompositorContainsRect(
            layout.canvasRect,
            hostContentRect
        )) {
        if (failure != NULL) {
            *failure = @"host rectangle is outside the target canvas";
        }
        return NO;
    }
    CGRect logical = CGRectMake(
        (CGRectGetMinX(hostContentRect) -
            CGRectGetMinX(layout.canvasRect)) /
            layout.displayScale,
        (CGRectGetMaxY(layout.canvasRect) -
            CGRectGetMaxY(hostContentRect)) /
            layout.displayScale,
        hostContentRect.size.width / layout.displayScale,
        hostContentRect.size.height / layout.displayScale
    );
    logical.origin.x = IOSUseCompositorClampNear(
        logical.origin.x,
        0,
        IOSUsePlayDeviceLogicalWidth
    );
    logical.origin.y = IOSUseCompositorClampNear(
        logical.origin.y,
        0,
        IOSUsePlayDeviceLogicalHeight
    );
    if (!IOSUseCompositorFiniteRect(logical) ||
        !IOSUseCompositorContainsRect(
            CGRectMake(
                0,
                0,
                IOSUsePlayDeviceLogicalWidth,
                IOSUsePlayDeviceLogicalHeight
            ),
            logical
        )) {
        if (failure != NULL) {
            *failure = @"host rectangle inverse transform is outside the fixed canvas";
        }
        return NO;
    }
    if (canvasLogicalRect != NULL) {
        *canvasLogicalRect = logical;
    }
    return YES;
}

BOOL IOSUsePlayResolveCanvasCGWindowRect(
    CGRect hostContentCGWindowRect,
    IOSUsePlayHostCanvasLayout layout,
    CGRect *canvasCGWindowRect,
    NSString **failure
) {
    if (failure != NULL) {
        *failure = nil;
    }
    if (!IOSUseCompositorFiniteRect(hostContentCGWindowRect) ||
        !IOSUseCompositorFiniteRect(layout.hostContentBounds) ||
        !IOSUseCompositorFiniteRect(layout.canvasRect) ||
        !IOSUseCompositorApproximatelyEqual(
            hostContentCGWindowRect.size.width,
            layout.hostContentBounds.size.width
        ) ||
        !IOSUseCompositorApproximatelyEqual(
            hostContentCGWindowRect.size.height,
            layout.hostContentBounds.size.height
        )) {
        if (failure != NULL) {
            *failure = @"host content CGWindow geometry disagrees with the canvas layout";
        }
        return NO;
    }
    CGRect canvas = CGRectMake(
        hostContentCGWindowRect.origin.x +
            (layout.canvasRect.origin.x -
                layout.hostContentBounds.origin.x),
        hostContentCGWindowRect.origin.y +
            (CGRectGetMaxY(layout.hostContentBounds) -
                CGRectGetMaxY(layout.canvasRect)),
        layout.canvasRect.size.width,
        layout.canvasRect.size.height
    );
    if (!IOSUseCompositorContainsRect(hostContentCGWindowRect, canvas)) {
        if (failure != NULL) {
            *failure = @"resolved canvas CGWindow rect is outside host content";
        }
        return NO;
    }
    if (canvasCGWindowRect != NULL) {
        *canvasCGWindowRect = canvas;
    }
    return YES;
}

BOOL IOSUsePlayResolveAppKitScreenRectInCGWindowCoordinates(
    CGRect appKitScreenRect,
    CGRect mainDisplayBounds,
    CGRect *cgWindowRect,
    NSString **failure
) {
    if (cgWindowRect != NULL) {
        *cgWindowRect = CGRectNull;
    }
    if (failure != NULL) {
        *failure = nil;
    }
    if (!IOSUseCompositorFiniteRect(appKitScreenRect) ||
        !IOSUseCompositorFiniteRect(mainDisplayBounds)) {
        if (failure != NULL) {
            *failure = @"AppKit screen rect or main display bounds are invalid";
        }
        return NO;
    }
    CGRect resolved = CGRectMake(
        appKitScreenRect.origin.x,
        CGRectGetMaxY(mainDisplayBounds) -
            CGRectGetMaxY(appKitScreenRect),
        appKitScreenRect.size.width,
        appKitScreenRect.size.height
    );
    if (!IOSUseCompositorFiniteRect(resolved)) {
        if (failure != NULL) {
            *failure = @"resolved CGWindow rect is invalid";
        }
        return NO;
    }
    if (cgWindowRect != NULL) {
        *cgWindowRect = resolved;
    }
    return YES;
}

BOOL IOSUsePlayResolveCGWindowRectInCanvas(
    CGRect sourceCGWindowBounds,
    CGRect canvasCGWindowRect,
    CGFloat displayScale,
    CGRect *deviceLogicalRect,
    NSString **failure
) {
    if (deviceLogicalRect != NULL) {
        *deviceLogicalRect = CGRectNull;
    }
    if (failure != NULL) {
        *failure = nil;
    }
    if (!IOSUseCompositorFiniteRect(sourceCGWindowBounds) ||
        !IOSUseCompositorFiniteRect(canvasCGWindowRect) ||
        !isfinite(displayScale) ||
        displayScale <= 0 ||
        !IOSUseCompositorApproximatelyEqual(
            canvasCGWindowRect.size.width / displayScale,
            IOSUsePlayDeviceLogicalWidth
        ) ||
        !IOSUseCompositorApproximatelyEqual(
            canvasCGWindowRect.size.height / displayScale,
            IOSUsePlayDeviceLogicalHeight
        )) {
        if (failure != NULL) {
            *failure = @"source or fixed canvas CGWindow geometry is invalid";
        }
        return NO;
    }
    CGRect intersection = CGRectIntersection(
        sourceCGWindowBounds,
        canvasCGWindowRect
    );
    if (CGRectIsNull(intersection) ||
        CGRectIsEmpty(intersection) ||
        !IOSUseCompositorContainsRect(
            canvasCGWindowRect,
            intersection
        )) {
        if (failure != NULL) {
            *failure = @"source native window does not intersect the target canvas";
        }
        return NO;
    }
    CGRect logical = CGRectMake(
        (intersection.origin.x - canvasCGWindowRect.origin.x) /
            displayScale,
        (intersection.origin.y - canvasCGWindowRect.origin.y) /
            displayScale,
        intersection.size.width / displayScale,
        intersection.size.height / displayScale
    );
    logical.origin.x = IOSUseCompositorClampNear(
        logical.origin.x,
        0,
        IOSUsePlayDeviceLogicalWidth
    );
    logical.origin.y = IOSUseCompositorClampNear(
        logical.origin.y,
        0,
        IOSUsePlayDeviceLogicalHeight
    );
    logical.size.width = IOSUseCompositorClampNear(
        logical.size.width,
        0,
        IOSUsePlayDeviceLogicalWidth
    );
    logical.size.height = IOSUseCompositorClampNear(
        logical.size.height,
        0,
        IOSUsePlayDeviceLogicalHeight
    );
    if (!IOSUseCompositorFiniteRect(logical) ||
        !IOSUseCompositorContainsRect(
            CGRectMake(
                0,
                0,
                IOSUsePlayDeviceLogicalWidth,
                IOSUsePlayDeviceLogicalHeight
            ),
            logical
        )) {
        if (failure != NULL) {
            *failure = @"source intersection resolves outside the fixed canvas";
        }
        return NO;
    }
    if (deviceLogicalRect != NULL) {
        *deviceLogicalRect = logical;
    }
    return YES;
}

CGImageRef IOSUsePlayCropAndNormalizeCanvasCapture(
    CGImageRef source,
    CGRect sourceCGWindowBounds,
    CGRect canvasCGWindowRect,
    CGFloat displayScale,
    CGRect *deviceLogicalRect,
    NSDictionary<NSString *, id> **evidence,
    NSString **failure
) {
    if (deviceLogicalRect != NULL) {
        *deviceLogicalRect = CGRectNull;
    }
    if (evidence != NULL) {
        *evidence = nil;
    }
    if (failure != NULL) {
        *failure = nil;
    }
    if (source == NULL ||
        CFGetTypeID(source) != CGImageGetTypeID()) {
        if (failure != NULL) {
            *failure = @"native source is not a CGImage";
        }
        return NULL;
    }
    CGRect logical = CGRectNull;
    NSString *logicalFailure = nil;
    if (!IOSUsePlayResolveCGWindowRectInCanvas(
            sourceCGWindowBounds,
            canvasCGWindowRect,
            displayScale,
            &logical,
            &logicalFailure
        )) {
        if (failure != NULL) {
            *failure = logicalFailure;
        }
        return NULL;
    }
    CGRect intersection = CGRectIntersection(
        sourceCGWindowBounds,
        canvasCGWindowRect
    );
    size_t sourceWidth = CGImageGetWidth(source);
    size_t sourceHeight = CGImageGetHeight(source);
    if (sourceWidth == 0 || sourceHeight == 0) {
        if (failure != NULL) {
            *failure = @"source native window image is empty";
        }
        return NULL;
    }
    CGFloat sourcePixelsPerPointX =
        (CGFloat)sourceWidth / sourceCGWindowBounds.size.width;
    CGFloat sourcePixelsPerPointY =
        (CGFloat)sourceHeight / sourceCGWindowBounds.size.height;
    // Crop inward at fractional source-pixel boundaries. Flooring/ceiling
    // outward would admit a one-pixel strip of title bar, transparent gap,
    // desktop, or host decoration while claiming canvas-only evidence.
    NSInteger minimumX = (NSInteger)ceil(
        (intersection.origin.x - sourceCGWindowBounds.origin.x) *
            sourcePixelsPerPointX
    );
    NSInteger minimumY = (NSInteger)ceil(
        (intersection.origin.y - sourceCGWindowBounds.origin.y) *
            sourcePixelsPerPointY
    );
    NSInteger maximumX = (NSInteger)floor(
        (CGRectGetMaxX(intersection) - sourceCGWindowBounds.origin.x) *
            sourcePixelsPerPointX
    );
    NSInteger maximumY = (NSInteger)floor(
        (CGRectGetMaxY(intersection) - sourceCGWindowBounds.origin.y) *
            sourcePixelsPerPointY
    );
    if (minimumX < 0 || minimumY < 0 ||
        maximumX > (NSInteger)sourceWidth ||
        maximumY > (NSInteger)sourceHeight ||
        maximumX <= minimumX || maximumY <= minimumY) {
        if (failure != NULL) {
            *failure = @"canvas crop resolves outside native source pixels";
        }
        return NULL;
    }
    CGRect sourcePixelCrop = CGRectMake(
        minimumX,
        minimumY,
        maximumX - minimumX,
        maximumY - minimumY
    );
    CGImageRef cropped = CGImageCreateWithImageInRect(
        source,
        sourcePixelCrop
    );
    if (cropped == NULL) {
        if (failure != NULL) {
            *failure = @"could not crop native source to the target canvas";
        }
        return NULL;
    }
    size_t normalizedWidth = (size_t)llround(
        logical.size.width * IOSUsePlayDeviceScale
    );
    size_t normalizedHeight = (size_t)llround(
        logical.size.height * IOSUsePlayDeviceScale
    );
    size_t rowBytes = normalizedWidth * 4;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = colorSpace == NULL ? NULL : CGBitmapContextCreate(
        NULL,
        normalizedWidth,
        normalizedHeight,
        8,
        rowBytes,
        colorSpace,
        kCGBitmapByteOrder32Little |
            kCGImageAlphaPremultipliedFirst
    );
    if (colorSpace != NULL) {
        CGColorSpaceRelease(colorSpace);
    }
    if (context == NULL) {
        CGImageRelease(cropped);
        if (failure != NULL) {
            *failure = @"could not allocate normalized fixed-canvas pixels";
        }
        return NULL;
    }
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextDrawImage(
        context,
        CGRectMake(0, 0, normalizedWidth, normalizedHeight),
        cropped
    );
    CGImageRelease(cropped);
    CGImageRef normalized = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    if (normalized == NULL) {
        if (failure != NULL) {
            *failure = @"could not materialize normalized fixed-canvas pixels";
        }
        return NULL;
    }
    if (deviceLogicalRect != NULL) {
        *deviceLogicalRect = logical;
    }
    if (evidence != NULL) {
        *evidence = @{
            @"canvasOnly": @YES,
            @"hostDecorationsExcluded": @YES,
            @"sourceCGWindowBounds":
                IOSUseCompositorRectJSON(sourceCGWindowBounds),
            @"canvasCGWindowRect":
                IOSUseCompositorRectJSON(canvasCGWindowRect),
            @"intersectionCGWindowRect":
                IOSUseCompositorRectJSON(intersection),
            @"sourcePixelCropRect":
                IOSUseCompositorRectJSON(sourcePixelCrop),
            @"deviceLogicalRect": IOSUseCompositorRectJSON(logical),
            @"normalizedPixelWidth": @(normalizedWidth),
            @"normalizedPixelHeight": @(normalizedHeight),
            @"displayScale": @(displayScale),
        };
    }
    return normalized;
}

NSArray *IOSUsePlayOrderForegroundScenes(
    NSArray *scenes,
    NSInteger (^activationRank)(id scene),
    NSString * _Nullable (^stableIdentifier)(id scene),
    NSString **failure
) {
    if (failure != NULL) {
        *failure = nil;
    }
    if (activationRank == nil || stableIdentifier == nil) {
        if (failure != NULL) {
            *failure = @"foreground scene policy accessors are unavailable";
        }
        return nil;
    }
    NSMutableArray<NSDictionary<NSString *, id> *> *descriptors =
        [NSMutableArray array];
    NSMutableSet<NSString *> *identifiers = [NSMutableSet set];
    for (id scene in scenes) {
        NSInteger rank = activationRank(scene);
        if (rank < 0) {
            continue;
        }
        NSString *identifier = stableIdentifier(scene);
        if (![identifier isKindOfClass:NSString.class] ||
            identifier.length == 0 ||
            [identifiers containsObject:identifier]) {
            if (failure != NULL) {
                *failure =
                    @"foreground scenes do not have unique stable "
                    @"identifiers";
            }
            return nil;
        }
        [identifiers addObject:identifier];
        [descriptors addObject:@{
            @"scene": scene,
            @"rank": @(rank),
            @"identifier": identifier,
        }];
    }
    [descriptors sortUsingComparator:^NSComparisonResult(
        NSDictionary<NSString *, id> *left,
        NSDictionary<NSString *, id> *right
    ) {
        NSInteger leftRank = [left[@"rank"] integerValue];
        NSInteger rightRank = [right[@"rank"] integerValue];
        if (leftRank < rightRank) {
            return NSOrderedAscending;
        }
        if (leftRank > rightRank) {
            return NSOrderedDescending;
        }
        return [left[@"identifier"] compare:right[@"identifier"]];
    }];
    NSMutableArray *result =
        [NSMutableArray arrayWithCapacity:descriptors.count];
    for (NSDictionary<NSString *, id> *descriptor in descriptors) {
        [result addObject:descriptor[@"scene"]];
    }
    return result;
}

id IOSUsePlaySelectPrimaryWindow(
    NSArray *orderedScenes,
    NSArray * _Nullable (^windowsInScene)(id scene),
    BOOL (^isKeyWindow)(id window)
) {
    if (windowsInScene == nil || isKeyWindow == nil) {
        return nil;
    }
    for (id scene in orderedScenes) {
        NSArray *windows = windowsInScene(scene);
        for (id window in
             [windows isKindOfClass:NSArray.class] ? windows : @[]) {
            if (isKeyWindow(window)) {
                return window;
            }
        }
    }
    return nil;
}

id IOSUsePlayResolveMappedWindow(
    id uiWindow,
    NSArray *applicationWindows,
    id keyWindowFallback,
    NSString **mappingSource
) {
    if (mappingSource != NULL) {
        *mappingSource = nil;
    }
    if (uiWindow != nil) {
        SEL uiWindowsSelector = NSSelectorFromString(@"uiWindows");
        for (id candidate in applicationWindows) {
            if (![candidate respondsToSelector:uiWindowsSelector]) {
                continue;
            }
            id uiWindows = ((IOSUseCompositorSendID)objc_msgSend)(
                candidate,
                uiWindowsSelector
            );
            if ([uiWindows isKindOfClass:NSArray.class] &&
                [(NSArray *)uiWindows containsObject:uiWindow]) {
                if (mappingSource != NULL) {
                    *mappingSource = @"application.uiWindows";
                }
                return candidate;
            }
        }
        SEL nsWindowSelector = NSSelectorFromString(@"nsWindow");
        if ([uiWindow respondsToSelector:nsWindowSelector]) {
            id direct = ((IOSUseCompositorSendID)objc_msgSend)(
                uiWindow,
                nsWindowSelector
            );
            if (direct != nil) {
                if (mappingSource != NULL) {
                    *mappingSource = @"uiWindow.nsWindow";
                }
                return direct;
            }
        }
    }
    if (keyWindowFallback != nil && mappingSource != NULL) {
        *mappingSource = @"application.keyWindow";
    }
    return keyWindowFallback;
}

NSArray *IOSUsePlayUnionCaptureWindows(
    NSArray *mappedWindows,
    NSArray *applicationWindows,
    BOOL (^isVisible)(id window),
    NSInteger (^windowNumber)(id window),
    NSString **failure
) {
    if (failure != NULL) {
        *failure = nil;
    }
    if (isVisible == nil || windowNumber == nil) {
        if (failure != NULL) {
            *failure = @"native window inventory accessors are unavailable";
        }
        return nil;
    }
    NSMutableArray *result = [NSMutableArray array];
    NSMutableDictionary<NSNumber *, id> *byNumber =
        [NSMutableDictionary dictionary];
    __block NSString *appendFailure = nil;
    BOOL (^append)(id, BOOL) = ^BOOL(id window, BOOL required) {
        NSInteger rawWindowNumber =
            window == nil ? 0 : windowNumber(window);
        if (window == nil ||
            !isVisible(window) ||
            rawWindowNumber <= 0 ||
            (uint64_t)rawWindowNumber > UINT32_MAX) {
            if (required) {
                appendFailure =
                    @"mapped UIKit host is not a visible numbered "
                    @"native window";
            }
            return !required;
        }
        NSNumber *key = @((uint32_t)rawWindowNumber);
        id existing = byNumber[key];
        if (existing != nil && existing != window) {
            appendFailure =
                @"one native window number identifies multiple "
                @"window objects";
            return NO;
        }
        if (existing == nil) {
            byNumber[key] = window;
            [result addObject:window];
        }
        return YES;
    };
    for (id window in mappedWindows) {
        if (!append(window, YES)) {
            if (failure != NULL) {
                *failure = appendFailure;
            }
            return nil;
        }
    }
    for (id window in applicationWindows) {
        if (!append(window, NO)) {
            if (failure != NULL) {
                *failure = appendFailure;
            }
            return nil;
        }
    }
    return result;
}

BOOL IOSUsePlayValidateRelativeWindowGeometry(
    CGRect baseAppKitFrame,
    CGRect baseCGWindowBounds,
    CGRect appKitFrame,
    CGRect cgWindowBounds,
    CGRect *deviceLogicalRect,
    NSString **failure
) {
    if (failure != NULL) {
        *failure = nil;
    }
    if (!IOSUseCompositorFiniteRect(baseAppKitFrame) ||
        !IOSUseCompositorFiniteRect(baseCGWindowBounds) ||
        !IOSUseCompositorFiniteRect(appKitFrame) ||
        !IOSUseCompositorFiniteRect(cgWindowBounds)) {
        if (failure != NULL) {
            *failure = @"AppKit or CGWindow geometry is invalid";
        }
        return NO;
    }
    if (!IOSUseCompositorApproximatelyEqual(
            baseAppKitFrame.size.width,
            baseCGWindowBounds.size.width
        ) ||
        !IOSUseCompositorApproximatelyEqual(
            baseAppKitFrame.size.height,
            baseCGWindowBounds.size.height
        )) {
        if (failure != NULL) {
            *failure = [NSString stringWithFormat:
                @"base AppKit size %.3fx%.3f disagrees with CGWindow "
                @"size %.3fx%.3f",
                baseAppKitFrame.size.width,
                baseAppKitFrame.size.height,
                baseCGWindowBounds.size.width,
                baseCGWindowBounds.size.height
            ];
        }
        return NO;
    }
    if (!IOSUseCompositorApproximatelyEqual(
            appKitFrame.size.width,
            cgWindowBounds.size.width
        ) ||
        !IOSUseCompositorApproximatelyEqual(
            appKitFrame.size.height,
            cgWindowBounds.size.height
        )) {
        if (failure != NULL) {
            *failure = [NSString stringWithFormat:
                @"AppKit size %.3fx%.3f disagrees with CGWindow size "
                @"%.3fx%.3f",
                appKitFrame.size.width,
                appKitFrame.size.height,
                cgWindowBounds.size.width,
                cgWindowBounds.size.height
            ];
        }
        return NO;
    }
    CGRect cgRelative = CGRectMake(
        cgWindowBounds.origin.x - baseCGWindowBounds.origin.x,
        cgWindowBounds.origin.y - baseCGWindowBounds.origin.y,
        cgWindowBounds.size.width,
        cgWindowBounds.size.height
    );
    CGRect baseLogicalRect = CGRectMake(
        0,
        0,
        baseCGWindowBounds.size.width,
        baseCGWindowBounds.size.height
    );
    if (!IOSUseCompositorContainsRect(
            baseLogicalRect,
            cgRelative
        )) {
        if (failure != NULL) {
            *failure = [NSString stringWithFormat:
                @"CGWindow relative rect %.3f,%.3f %.3fx%.3f is outside "
                @"base %.3fx%.3f",
                cgRelative.origin.x,
                cgRelative.origin.y,
                cgRelative.size.width,
                cgRelative.size.height,
                baseLogicalRect.size.width,
                baseLogicalRect.size.height
            ];
        }
        return NO;
    }
    if (deviceLogicalRect != NULL) {
        *deviceLogicalRect = cgRelative;
    }
    return YES;
}

BOOL IOSUsePlayResolveLocalAppKitRect(
    CGRect windowDeviceLogicalRect,
    CGRect localAppKitRect,
    CGRect *deviceLogicalRect,
    NSString **failure
) {
    if (failure != NULL) {
        *failure = nil;
    }
    CGRect logicalDevice = CGRectMake(
        0,
        0,
        IOSUsePlayDeviceLogicalWidth,
        IOSUsePlayDeviceLogicalHeight
    );
    CGRect localWindow = CGRectMake(
        0,
        0,
        windowDeviceLogicalRect.size.width,
        windowDeviceLogicalRect.size.height
    );
    if (!IOSUseCompositorFiniteRect(windowDeviceLogicalRect) ||
        !IOSUseCompositorFiniteRect(localAppKitRect) ||
        !IOSUseCompositorContainsRect(
            logicalDevice,
            windowDeviceLogicalRect
        ) ||
        !IOSUseCompositorContainsRect(
            localWindow,
            localAppKitRect
        )) {
        if (failure != NULL) {
            *failure =
                @"native window or local AppKit rect is outside the "
                @"fixed logical device";
        }
        return NO;
    }
    CGRect resolved = CGRectMake(
        windowDeviceLogicalRect.origin.x +
            localAppKitRect.origin.x,
        windowDeviceLogicalRect.origin.y +
            windowDeviceLogicalRect.size.height -
            CGRectGetMaxY(localAppKitRect),
        localAppKitRect.size.width,
        localAppKitRect.size.height
    );
    if (!IOSUseCompositorContainsRect(logicalDevice, resolved)) {
        if (failure != NULL) {
            *failure =
                @"resolved AppKit local rect is outside the fixed "
                @"logical device";
        }
        return NO;
    }
    if (deviceLogicalRect != NULL) {
        *deviceLogicalRect = resolved;
    }
    return YES;
}

BOOL IOSUsePlayWindowCapturePlansEqual(
    const IOSUsePlayWindowPlanEntry *before,
    NSUInteger beforeCount,
    uint32_t beforeBaseWindowNumber,
    const IOSUsePlayWindowPlanEntry *after,
    NSUInteger afterCount,
    uint32_t afterBaseWindowNumber,
    NSString **failure
) {
    if (failure != NULL) {
        *failure = nil;
    }
    if (before == NULL ||
        after == NULL ||
        beforeCount == 0 ||
        beforeCount != afterCount ||
        beforeBaseWindowNumber != afterBaseWindowNumber) {
        if (failure != NULL) {
            *failure =
                @"window count or primary identity changed during capture";
        }
        return NO;
    }
    for (NSUInteger index = 0; index < beforeCount; index += 1) {
        IOSUsePlayWindowPlanEntry lhs = before[index];
        IOSUsePlayWindowPlanEntry rhs = after[index];
        if (lhs.windowNumber != rhs.windowNumber ||
            !IOSUseCompositorRectEquals(
                lhs.appKitFrame,
                rhs.appKitFrame
            ) ||
            !IOSUseCompositorRectEquals(
                lhs.cgWindowBounds,
                rhs.cgWindowBounds
            ) ||
            !IOSUseCompositorApproximatelyEqual(
                lhs.backingScale,
                rhs.backingScale
            )) {
            if (failure != NULL) {
                *failure = [NSString stringWithFormat:
                    @"window plan entry %lu changed during capture",
                    (unsigned long)index
                ];
            }
            return NO;
        }
    }
    return YES;
}

BOOL IOSUsePlayValidateCapturedWindowCount(
    NSUInteger requestedCount,
    CFArrayRef capturedImages,
    NSString **failure
) {
    if (capturedImages != NULL &&
        CFGetTypeID(capturedImages) != CFArrayGetTypeID()) {
        if (failure != NULL) {
            *failure = @"CGSHW returned a non-array capture response";
        }
        return NO;
    }
    CFIndex capturedCount =
        capturedImages == NULL ? 0 : CFArrayGetCount(capturedImages);
    if (capturedCount < 0 ||
        (NSUInteger)capturedCount != requestedCount) {
        if (failure != NULL) {
            *failure = [NSString stringWithFormat:
                @"CGSHW requested %lu windows but returned %ld images",
                (unsigned long)requestedCount,
                (long)capturedCount
            ];
        }
        return NO;
    }
    return YES;
}

CGImageRef IOSUsePlayCompositeWindowCaptures(
    const IOSUsePlayWindowCapture *captures,
    NSUInteger captureCount,
    CGRect deviceFrame,
    uint32_t baseWindowNumber,
    NSArray<NSDictionary<NSString *, id> *> **sourceEvidence,
    NSString **failure
) {
    if (sourceEvidence != NULL) {
        *sourceEvidence = nil;
    }
    if (captureCount == 0 || captures == NULL) {
        if (failure != NULL) {
            *failure = @"window compositor received no captures";
        }
        return NULL;
    }
    if (!IOSUseCompositorFiniteRect(deviceFrame) ||
        !IOSUseCompositorApproximatelyEqual(
            deviceFrame.origin.x,
            0
        ) ||
        !IOSUseCompositorApproximatelyEqual(
            deviceFrame.origin.y,
            0
        ) ||
        !IOSUseCompositorApproximatelyEqual(
            deviceFrame.size.width,
            IOSUsePlayDeviceLogicalWidth
        ) ||
        !IOSUseCompositorApproximatelyEqual(
            deviceFrame.size.height,
            IOSUsePlayDeviceLogicalHeight
        )) {
        if (failure != NULL) {
            *failure = [NSString stringWithFormat:
                @"logical device frame is not origin-zero %ldx%ld",
                (long)IOSUsePlayDeviceLogicalWidth,
                (long)IOSUsePlayDeviceLogicalHeight
            ];
        }
        return NULL;
    }

    BOOL baseCaptureFound = NO;
    NSMutableSet<NSNumber *> *windowNumbers =
        [NSMutableSet setWithCapacity:captureCount];
    NSMutableArray<NSDictionary<NSString *, id> *> *evidence =
        [NSMutableArray arrayWithCapacity:captureCount];
    for (NSUInteger index = 0; index < captureCount; index += 1) {
        IOSUsePlayWindowCapture capture = captures[index];
        NSNumber *number = @(capture.windowNumber);
        if (capture.windowNumber == 0 ||
            [windowNumbers containsObject:number]) {
            if (failure != NULL) {
                *failure = [NSString stringWithFormat:
                    @"window compositor source %lu has an invalid or "
                    @"duplicate window number",
                    (unsigned long)index
                ];
            }
            return NULL;
        }
        [windowNumbers addObject:number];
        if (capture.image == NULL ||
            CFGetTypeID(capture.image) != CGImageGetTypeID()) {
            if (failure != NULL) {
                *failure = [NSString stringWithFormat:
                    @"CGSHW source %lu is not a CGImage",
                    (unsigned long)index
                ];
            }
            return NULL;
        }
        if (!IOSUseCompositorFiniteRect(capture.appKitFrame) ||
            !IOSUseCompositorFiniteRect(
                capture.deviceLogicalRect
            ) ||
            !isfinite(capture.backingScale) ||
            capture.backingScale <= 0 ||
            capture.backingScale > 4) {
            if (failure != NULL) {
                *failure = [NSString stringWithFormat:
                    @"CGSHW source %lu has invalid AppKit geometry",
                    (unsigned long)index
                ];
            }
            return NULL;
        }
        if (!IOSUseCompositorApproximatelyEqual(
                capture.appKitFrame.size.width,
                capture.deviceLogicalRect.size.width
            ) ||
            !IOSUseCompositorApproximatelyEqual(
                capture.appKitFrame.size.height,
                capture.deviceLogicalRect.size.height
            )) {
            if (failure != NULL) {
                *failure = [NSString stringWithFormat:
                    @"CGSHW source %lu window %u AppKit and device "
                    @"logical sizes disagree",
                    (unsigned long)index,
                    capture.windowNumber
                ];
            }
            return NULL;
        }
        if (!IOSUseCompositorContainsRect(
                deviceFrame,
                capture.deviceLogicalRect
            )) {
            if (failure != NULL) {
                *failure = [NSString stringWithFormat:
                    @"CGSHW source %lu window %u is outside the fixed "
                    @"device frame",
                    (unsigned long)index,
                    capture.windowNumber
                ];
            }
            return NULL;
        }
        size_t sourceWidth = CGImageGetWidth(capture.image);
        size_t sourceHeight = CGImageGetHeight(capture.image);
        size_t expectedWidth = (size_t)llround(
            capture.deviceLogicalRect.size.width *
                capture.backingScale
        );
        size_t expectedHeight = (size_t)llround(
            capture.deviceLogicalRect.size.height *
                capture.backingScale
        );
        if (sourceWidth == 0 ||
            sourceHeight == 0 ||
            sourceWidth != expectedWidth ||
            sourceHeight != expectedHeight) {
            if (failure != NULL) {
                *failure = [NSString stringWithFormat:
                    @"CGSHW source %lu window %u has invalid %zux%zu "
                    @"backing geometry; expected %zux%zu for %.3fx",
                    (unsigned long)index,
                    capture.windowNumber,
                    sourceWidth,
                    sourceHeight,
                    expectedWidth,
                    expectedHeight,
                    capture.backingScale
                ];
            }
            return NULL;
        }
        CGRect destinationNativeRect = CGRectMake(
            capture.deviceLogicalRect.origin.x *
                IOSUsePlayDeviceScale,
            capture.deviceLogicalRect.origin.y *
                IOSUsePlayDeviceScale,
            capture.deviceLogicalRect.size.width *
                IOSUsePlayDeviceScale,
            capture.deviceLogicalRect.size.height *
                IOSUsePlayDeviceScale
        );
        [evidence addObject:@{
            @"windowNumber": number,
            @"frontToBackIndex": @(index),
            @"appKitFrame":
                IOSUseCompositorRectJSON(capture.appKitFrame),
            @"deviceLogicalRect":
                IOSUseCompositorRectJSON(
                    capture.deviceLogicalRect
                ),
            @"destinationNativeRect":
                IOSUseCompositorRectJSON(destinationNativeRect),
            @"backingScaleFactor": @(capture.backingScale),
            @"sourcePixelWidth": @(sourceWidth),
            @"sourcePixelHeight": @(sourceHeight),
            @"coversDevice": @(
                IOSUseCompositorRectEquals(
                    capture.deviceLogicalRect,
                    deviceFrame
                )
            ),
        }];
        if (capture.windowNumber == baseWindowNumber) {
            if (baseCaptureFound ||
                !IOSUseCompositorRectEquals(
                    capture.deviceLogicalRect,
                    deviceFrame
                )) {
                if (failure != NULL) {
                    *failure =
                        @"primary native window does not uniquely cover "
                        @"the complete device frame";
                }
                return NULL;
            }
            baseCaptureFound = YES;
        }
    }
    if (!baseCaptureFound) {
        if (failure != NULL) {
            *failure =
                @"primary AppKit window is absent from compositor sources";
        }
        return NULL;
    }

    size_t width = IOSUsePlayDeviceNativeWidth;
    size_t height = IOSUsePlayDeviceNativeHeight;
    size_t rowBytes = width * 4;
    void *pixels = calloc(height, rowBytes);
    if (pixels == NULL) {
        if (failure != NULL) {
            *failure = @"window compositor allocation failed";
        }
        return NULL;
    }
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (colorSpace == NULL) {
        free(pixels);
        if (failure != NULL) {
            *failure =
                @"window compositor color-space creation failed";
        }
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
        if (failure != NULL) {
            *failure = @"window compositor context creation failed";
        }
        return NULL;
    }
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    // Inputs are front-to-back. Quartz uses an AppKit-style bottom-left
    // coordinate system, so draw from the native back to the native front.
    for (NSUInteger remaining = captureCount;
         remaining > 0;
         remaining -= 1) {
        IOSUsePlayWindowCapture capture = captures[remaining - 1];
        CGFloat relativeBottom =
            IOSUsePlayDeviceLogicalHeight -
            CGRectGetMaxY(capture.deviceLogicalRect);
        CGRect destination = CGRectMake(
            capture.deviceLogicalRect.origin.x *
                IOSUsePlayDeviceScale,
            relativeBottom * IOSUsePlayDeviceScale,
            capture.deviceLogicalRect.size.width *
                IOSUsePlayDeviceScale,
            capture.deviceLogicalRect.size.height *
                IOSUsePlayDeviceScale
        );
        CGContextDrawImage(context, destination, capture.image);
    }
    CGImageRef result = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    free(pixels);
    if (result == NULL) {
        if (failure != NULL) {
            *failure = @"window compositor did not produce an image";
        }
        return NULL;
    }
    if (sourceEvidence != NULL) {
        *sourceEvidence = evidence;
    }
    return result;
}

NSDictionary<NSString *, id> *IOSUsePlayFingerprintCompositorImage(
    CGImageRef image,
    CGRect logicalRect,
    NSString **failure
) {
    CGRect logicalDevice = CGRectMake(
        0,
        0,
        IOSUsePlayDeviceLogicalWidth,
        IOSUsePlayDeviceLogicalHeight
    );
    if (image == NULL ||
        CGImageGetWidth(image) != IOSUsePlayDeviceNativeWidth ||
        CGImageGetHeight(image) != IOSUsePlayDeviceNativeHeight) {
        if (failure != NULL) {
            *failure =
                @"fingerprint image is not the complete native device";
        }
        return nil;
    }
    if (!IOSUseCompositorFiniteRect(logicalRect) ||
        !IOSUseCompositorContainsRect(logicalDevice, logicalRect)) {
        if (failure != NULL) {
            *failure =
                @"fingerprint rect must be finite, non-empty, and "
                @"completely inside the logical device";
        }
        return nil;
    }
    CGFloat scale = IOSUsePlayDeviceScale;
    NSInteger minimumX = (NSInteger)floor(
        CGRectGetMinX(logicalRect) * scale
    );
    NSInteger minimumY = (NSInteger)floor(
        CGRectGetMinY(logicalRect) * scale
    );
    NSInteger maximumX = (NSInteger)ceil(
        CGRectGetMaxX(logicalRect) * scale
    );
    NSInteger maximumY = (NSInteger)ceil(
        CGRectGetMaxY(logicalRect) * scale
    );
    CGRect pixelRect = CGRectMake(
        minimumX,
        minimumY,
        maximumX - minimumX,
        maximumY - minimumY
    );
    if (minimumX < 0 ||
        minimumY < 0 ||
        maximumX > (NSInteger)IOSUsePlayDeviceNativeWidth ||
        maximumY > (NSInteger)IOSUsePlayDeviceNativeHeight ||
        pixelRect.size.width <= 0 ||
        pixelRect.size.height <= 0) {
        if (failure != NULL) {
            *failure =
                @"fingerprint rect does not resolve to valid native pixels";
        }
        return nil;
    }
    CGImageRef cropped = CGImageCreateWithImageInRect(
        image,
        pixelRect
    );
    if (cropped == NULL) {
        if (failure != NULL) {
            *failure =
                @"could not crop compositor pixels for fingerprinting";
        }
        return nil;
    }
    size_t pixelWidth = CGImageGetWidth(cropped);
    size_t pixelHeight = CGImageGetHeight(cropped);
    size_t rowBytes = pixelWidth * 4;
    NSMutableData *pixels = [NSMutableData
        dataWithLength:rowBytes * pixelHeight];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (colorSpace == NULL) {
        CGImageRelease(cropped);
        if (failure != NULL) {
            *failure =
                @"could not create canonical fingerprint color space";
        }
        return nil;
    }
    CGContextRef context = CGBitmapContextCreate(
        pixels.mutableBytes,
        pixelWidth,
        pixelHeight,
        8,
        rowBytes,
        colorSpace,
        kCGBitmapByteOrder32Little |
            kCGImageAlphaPremultipliedFirst
    );
    CGColorSpaceRelease(colorSpace);
    if (context == NULL) {
        CGImageRelease(cropped);
        if (failure != NULL) {
            *failure =
                @"could not create canonical fingerprint pixel storage";
        }
        return nil;
    }
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextDrawImage(
        context,
        CGRectMake(0, 0, pixelWidth, pixelHeight),
        cropped
    );
    CGContextRelease(context);
    CGImageRelease(cropped);
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(
        pixels.bytes,
        (CC_LONG)pixels.length,
        digest
    );
    NSMutableString *hex = [NSMutableString
        stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0;
         index < CC_SHA256_DIGEST_LENGTH;
         index += 1) {
        [hex appendFormat:@"%02x", digest[index]];
    }
    return @{
        @"algorithm": @"sha256-bgra8-premultiplied",
        @"hash": hex,
        @"logicalRect": IOSUseCompositorRectJSON(logicalRect),
        @"nativePixelRect": IOSUseCompositorRectJSON(pixelRect),
        @"pixelWidth": @(pixelWidth),
        @"pixelHeight": @(pixelHeight),
    };
}
