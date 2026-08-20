#import "IOSUsePlayWindowCompositor.h"
#import "IOSUsePlayDevice.h"

#import <objc/message.h>

#import <math.h>

typedef id (*IOSUseCompositorSendID)(id, SEL);

static const CGFloat IOSUseCompositorGeometryTolerance = 0.01;
static const CGFloat IOSUseCompositorDeviceLogicalWidth =
    (CGFloat)IOSUsePlayDeviceLogicalWidth;
static const CGFloat IOSUseCompositorDeviceLogicalHeight =
    (CGFloat)IOSUsePlayDeviceLogicalHeight;
static const CGFloat IOSUseCompositorDeviceScale =
    (CGFloat)IOSUsePlayDeviceScale;
static const CGBitmapInfo IOSUseCompositorBitmapInfo = (CGBitmapInfo)(
    (uint32_t)kCGBitmapByteOrder32Little |
    (uint32_t)kCGImageAlphaPremultipliedFirst
);

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

static BOOL IOSUseCompositorValidBackingScale(CGFloat backingScaleFactor) {
    return isfinite(backingScaleFactor) &&
        backingScaleFactor > 0 &&
        backingScaleFactor <= 4;
}

static CGFloat IOSUseCompositorHalfPixelTolerance(
    CGFloat backingScaleFactor
) {
    return 0.5 / backingScaleFactor;
}

static BOOL IOSUseCompositorApproximatelyEqualWithTolerance(
    CGFloat lhs,
    CGFloat rhs,
    CGFloat tolerance
) {
    return isfinite(lhs) && isfinite(rhs) && isfinite(tolerance) &&
        tolerance >= 0 && fabs(lhs - rhs) <= tolerance;
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

static BOOL IOSUseCompositorContainsRectWithTolerance(
    CGRect container,
    CGRect candidate,
    CGFloat tolerance
) {
    return IOSUseCompositorFiniteRect(container) &&
        IOSUseCompositorFiniteRect(candidate) &&
        isfinite(tolerance) && tolerance >= 0 &&
        CGRectGetMinX(candidate) >= CGRectGetMinX(container) - tolerance &&
        CGRectGetMinY(candidate) >= CGRectGetMinY(container) - tolerance &&
        CGRectGetMaxX(candidate) <= CGRectGetMaxX(container) + tolerance &&
        CGRectGetMaxY(candidate) <= CGRectGetMaxY(container) + tolerance;
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

static BOOL IOSUseCompositorExactPixelCoordinate(
    CGFloat points,
    CGFloat backingScaleFactor,
    NSInteger *pixels
) {
    CGFloat rawPixels = points * backingScaleFactor;
    if (!isfinite(rawPixels)) {
        return NO;
    }
    CGFloat roundedPixels = round(rawPixels);
    if (fabs(rawPixels - roundedPixels) > 0.000001 ||
        roundedPixels < (CGFloat)NSIntegerMin ||
        roundedPixels > (CGFloat)NSIntegerMax) {
        return NO;
    }
    if (pixels != NULL) {
        *pixels = (NSInteger)roundedPixels;
    }
    return YES;
}

BOOL IOSUsePlayMapHostContentPointToDevice(
    CGRect hostContentBounds,
    CGPoint hostContentPoint,
    CGPoint *deviceLogicalPoint,
    NSString **failure
) {
    if (deviceLogicalPoint != NULL) {
        *deviceLogicalPoint = CGPointMake(NAN, NAN);
    }
    if (failure != NULL) {
        *failure = nil;
    }
    CGFloat tolerance = IOSUseCompositorGeometryTolerance;
    if (!IOSUseCompositorFiniteRect(hostContentBounds) ||
        !isfinite(hostContentPoint.x) ||
        !isfinite(hostContentPoint.y) ||
        !IOSUseCompositorContainsPoint(
            CGRectInset(hostContentBounds, -tolerance, -tolerance),
            hostContentPoint,
            YES
        )) {
        if (failure != NULL) {
            *failure = @"host point is outside native Catalyst content";
        }
        return NO;
    }
    CGFloat minimumX = CGRectGetMinX(hostContentBounds);
    CGFloat maximumY = CGRectGetMaxY(hostContentBounds);
    CGPoint clamped = CGPointMake(
        MIN(
            MAX(hostContentPoint.x, minimumX),
            CGRectGetMaxX(hostContentBounds)
        ),
        MIN(
            MAX(hostContentPoint.y, CGRectGetMinY(hostContentBounds)),
            maximumY
        )
    );
    CGPoint logical = CGPointMake(
        (clamped.x - minimumX) /
            hostContentBounds.size.width *
            IOSUseCompositorDeviceLogicalWidth,
        (maximumY - clamped.y) /
            hostContentBounds.size.height *
            IOSUseCompositorDeviceLogicalHeight
    );
    if (!IOSUseCompositorContainsPoint(
            CGRectMake(
                0,
                0,
                IOSUseCompositorDeviceLogicalWidth,
                IOSUseCompositorDeviceLogicalHeight
            ),
            logical,
            YES
        )) {
        if (failure != NULL) {
            *failure = @"native content point did not map into the device";
        }
        return NO;
    }
    if (deviceLogicalPoint != NULL) {
        *deviceLogicalPoint = logical;
    }
    return YES;
}

BOOL IOSUsePlayMapHostContentRectToDevice(
    CGRect hostContentBounds,
    CGRect hostContentRect,
    CGRect *deviceLogicalRect,
    NSString **failure
) {
    if (deviceLogicalRect != NULL) {
        *deviceLogicalRect = CGRectNull;
    }
    if (failure != NULL) {
        *failure = nil;
    }
    CGFloat tolerance = IOSUseCompositorGeometryTolerance;
    if (!IOSUseCompositorFiniteRect(hostContentBounds) ||
        !IOSUseCompositorFiniteRect(hostContentRect) ||
        !IOSUseCompositorContainsRectWithTolerance(
            hostContentBounds,
            hostContentRect,
            tolerance
        )) {
        if (failure != NULL) {
            *failure =
                @"host rectangle is outside native Catalyst content";
        }
        return NO;
    }
    CGRect clamped = CGRectIntersection(
        hostContentBounds,
        hostContentRect
    );
    if (!IOSUseCompositorFiniteRect(clamped)) {
        if (failure != NULL) {
            *failure =
                @"host rectangle has no native Catalyst content area";
        }
        return NO;
    }
    CGRect logical = CGRectMake(
        (CGRectGetMinX(clamped) -
            CGRectGetMinX(hostContentBounds)) /
            hostContentBounds.size.width *
            IOSUseCompositorDeviceLogicalWidth,
        (CGRectGetMaxY(hostContentBounds) -
            CGRectGetMaxY(clamped)) /
            hostContentBounds.size.height *
            IOSUseCompositorDeviceLogicalHeight,
        clamped.size.width / hostContentBounds.size.width *
            IOSUseCompositorDeviceLogicalWidth,
        clamped.size.height / hostContentBounds.size.height *
            IOSUseCompositorDeviceLogicalHeight
    );
    if (!IOSUseCompositorFiniteRect(logical) ||
        !IOSUseCompositorContainsRectWithTolerance(
            CGRectMake(
                0,
                0,
                IOSUseCompositorDeviceLogicalWidth,
                IOSUseCompositorDeviceLogicalHeight
            ),
            logical,
            tolerance
        )) {
        if (failure != NULL) {
            *failure =
                @"native content rectangle did not map into the device";
        }
        return NO;
    }
    if (deviceLogicalRect != NULL) {
        *deviceLogicalRect = logical;
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
    CGFloat backingScaleFactor,
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
        !IOSUseCompositorValidBackingScale(backingScaleFactor)) {
        if (failure != NULL) {
            *failure =
                @"source or native canvas CGWindow geometry is invalid";
        }
        return NO;
    }
    CGFloat scaleX =
        canvasCGWindowRect.size.width /
        IOSUseCompositorDeviceLogicalWidth;
    CGFloat scaleY =
        canvasCGWindowRect.size.height /
        IOSUseCompositorDeviceLogicalHeight;
    if (!isfinite(scaleX) || scaleX <= 0 ||
        !isfinite(scaleY) || scaleY <= 0) {
        if (failure != NULL) {
            *failure =
                @"native canvas cannot map to the fixed device model";
        }
        return NO;
    }
    CGRect intersection = CGRectIntersection(
        sourceCGWindowBounds,
        canvasCGWindowRect
    );
    CGFloat hostTolerance =
        IOSUseCompositorHalfPixelTolerance(backingScaleFactor);
    if (CGRectIsNull(intersection) ||
        CGRectIsEmpty(intersection) ||
        !IOSUseCompositorContainsRectWithTolerance(
            canvasCGWindowRect,
            intersection,
            hostTolerance
        )) {
        if (failure != NULL) {
            *failure =
                @"source native window does not intersect the target canvas";
        }
        return NO;
    }
    CGRect logical = CGRectMake(
        (intersection.origin.x - canvasCGWindowRect.origin.x) /
            scaleX,
        (intersection.origin.y - canvasCGWindowRect.origin.y) /
            scaleY,
        intersection.size.width / scaleX,
        intersection.size.height / scaleY
    );
    if (fabs(
            CGRectGetMinX(intersection) -
                CGRectGetMinX(canvasCGWindowRect)
        ) <= 0.000001) {
        logical.origin.x = 0;
    }
    if (fabs(
            CGRectGetMinY(intersection) -
                CGRectGetMinY(canvasCGWindowRect)
        ) <= 0.000001) {
        logical.origin.y = 0;
    }
    CGFloat logicalMaximumX = CGRectGetMaxX(logical);
    CGFloat logicalMaximumY = CGRectGetMaxY(logical);
    if (fabs(
            CGRectGetMaxX(intersection) -
                CGRectGetMaxX(canvasCGWindowRect)
        ) <= 0.000001) {
        logicalMaximumX = IOSUseCompositorDeviceLogicalWidth;
    }
    if (fabs(
            CGRectGetMaxY(intersection) -
                CGRectGetMaxY(canvasCGWindowRect)
        ) <= 0.000001) {
        logicalMaximumY = IOSUseCompositorDeviceLogicalHeight;
    }
    logical.size.width = logicalMaximumX - logical.origin.x;
    logical.size.height = logicalMaximumY - logical.origin.y;
    CGFloat logicalTolerance = MAX(
        hostTolerance / scaleX,
        hostTolerance / scaleY
    );
    if (!IOSUseCompositorFiniteRect(logical) ||
        !IOSUseCompositorContainsRectWithTolerance(
            CGRectMake(
                0,
                0,
                IOSUseCompositorDeviceLogicalWidth,
                IOSUseCompositorDeviceLogicalHeight
            ),
            logical,
            logicalTolerance
        )) {
        if (failure != NULL) {
            *failure =
                @"source intersection resolves outside the fixed device";
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
    CGFloat backingScaleFactor,
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
            backingScaleFactor,
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
    if (fabs(
            (CGFloat)sourceWidth -
                sourceCGWindowBounds.size.width * backingScaleFactor
        ) > 0.500001 ||
        fabs(
            (CGFloat)sourceHeight -
                sourceCGWindowBounds.size.height * backingScaleFactor
        ) > 0.500001) {
        if (failure != NULL) {
            *failure =
                @"native source pixels disagree with the backing scale";
        }
        return NULL;
    }
    CGFloat sourcePixelsPerPointX =
        (CGFloat)sourceWidth / sourceCGWindowBounds.size.width;
    CGFloat sourcePixelsPerPointY =
        (CGFloat)sourceHeight / sourceCGWindowBounds.size.height;
    NSInteger minimumX = 0;
    NSInteger minimumY = 0;
    NSInteger maximumX = 0;
    NSInteger maximumY = 0;
    BOOL cropIsPixelAligned =
        IOSUseCompositorExactPixelCoordinate(
            intersection.origin.x - sourceCGWindowBounds.origin.x,
            sourcePixelsPerPointX,
            &minimumX
        ) &&
        IOSUseCompositorExactPixelCoordinate(
            intersection.origin.y - sourceCGWindowBounds.origin.y,
            sourcePixelsPerPointY,
            &minimumY
        ) &&
        IOSUseCompositorExactPixelCoordinate(
            CGRectGetMaxX(intersection) -
                sourceCGWindowBounds.origin.x,
            sourcePixelsPerPointX,
            &maximumX
        ) &&
        IOSUseCompositorExactPixelCoordinate(
            CGRectGetMaxY(intersection) -
                sourceCGWindowBounds.origin.y,
            sourcePixelsPerPointY,
            &maximumY
        );
    if (!cropIsPixelAligned) {
        if (failure != NULL) {
            *failure =
                @"canvas crop boundaries are not backing-pixel aligned";
        }
        return NULL;
    }
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
        logical.size.width * IOSUseCompositorDeviceScale
    );
    size_t normalizedHeight = (size_t)llround(
        logical.size.height * IOSUseCompositorDeviceScale
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
        IOSUseCompositorBitmapInfo
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
            @"backingScaleFactor": @(backingScaleFactor),
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

BOOL IOSUsePlayAppKitCGWindowSizesMatch(
    CGRect appKitFrame,
    CGRect cgWindowBounds
) {
    return IOSUseCompositorFiniteRect(appKitFrame) &&
        IOSUseCompositorFiniteRect(cgWindowBounds) &&
        IOSUseCompositorApproximatelyEqual(
            appKitFrame.size.width,
            cgWindowBounds.size.width
        ) &&
        IOSUseCompositorApproximatelyEqual(
            appKitFrame.size.height,
            cgWindowBounds.size.height
        );
}

BOOL IOSUsePlayAppKitCGWindowSizesMatchAtBackingScale(
    CGRect appKitFrame,
    CGRect cgWindowBounds,
    CGFloat backingScaleFactor
) {
    if (!IOSUseCompositorValidBackingScale(backingScaleFactor)) {
        return NO;
    }
    CGFloat tolerance =
        IOSUseCompositorHalfPixelTolerance(backingScaleFactor);
    return IOSUseCompositorFiniteRect(appKitFrame) &&
        IOSUseCompositorFiniteRect(cgWindowBounds) &&
        IOSUseCompositorApproximatelyEqualWithTolerance(
            appKitFrame.size.width,
            cgWindowBounds.size.width,
            tolerance
        ) &&
        IOSUseCompositorApproximatelyEqualWithTolerance(
            appKitFrame.size.height,
            cgWindowBounds.size.height,
            tolerance
        );
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
    if (!IOSUsePlayAppKitCGWindowSizesMatch(
            baseAppKitFrame,
            baseCGWindowBounds
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
    if (!IOSUsePlayAppKitCGWindowSizesMatch(
            appKitFrame,
            cgWindowBounds
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
        IOSUseCompositorDeviceLogicalWidth,
        IOSUseCompositorDeviceLogicalHeight
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
            IOSUseCompositorDeviceLogicalWidth
        ) ||
        !IOSUseCompositorApproximatelyEqual(
            deviceFrame.size.height,
            IOSUseCompositorDeviceLogicalHeight
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
                IOSUseCompositorDeviceScale,
            capture.deviceLogicalRect.origin.y *
                IOSUseCompositorDeviceScale,
            capture.deviceLogicalRect.size.width *
                IOSUseCompositorDeviceScale,
            capture.deviceLogicalRect.size.height *
                IOSUseCompositorDeviceScale
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
        IOSUseCompositorBitmapInfo
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
            IOSUseCompositorDeviceLogicalHeight -
            CGRectGetMaxY(capture.deviceLogicalRect);
        CGRect destination = CGRectMake(
            capture.deviceLogicalRect.origin.x *
                IOSUseCompositorDeviceScale,
            relativeBottom * IOSUseCompositorDeviceScale,
            capture.deviceLogicalRect.size.width *
                IOSUseCompositorDeviceScale,
            capture.deviceLogicalRect.size.height *
                IOSUseCompositorDeviceScale
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
