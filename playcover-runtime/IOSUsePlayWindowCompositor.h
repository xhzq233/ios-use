#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    CGImageRef image;
    CGRect appKitFrame;
    CGRect deviceLogicalRect;
    CGFloat backingScale;
    uint32_t windowNumber;
} IOSUsePlayWindowCapture;

typedef struct {
    uint32_t windowNumber;
    CGRect appKitFrame;
    CGRect cgWindowBounds;
    CGFloat backingScale;
} IOSUsePlayWindowPlanEntry;

/// Normalizes an observed point/rectangle in Catalyst's native AppKit content
/// coordinates into the fixed iPhone logical model. These helpers do not
/// participate in display layout; they exist only for native input and
/// evidence geometry.
FOUNDATION_EXPORT BOOL IOSUsePlayMapHostContentPointToDevice(
    CGRect hostContentBounds,
    CGPoint hostContentPoint,
    CGPoint * _Nullable deviceLogicalPoint,
    NSString * _Nullable * _Nullable failure
);

FOUNDATION_EXPORT BOOL IOSUsePlayMapHostContentRectToDevice(
    CGRect hostContentBounds,
    CGRect hostContentRect,
    CGRect * _Nullable deviceLogicalRect,
    NSString * _Nullable * _Nullable failure
);

/// Converts AppKit's global bottom-left screen rectangle into CGWindow's
/// global top-left coordinates using the main-display coordinate extent. The
/// caller supplies that extent so this can be tested for vertically arranged
/// and differently sized displays without AppKit state.
FOUNDATION_EXPORT BOOL IOSUsePlayResolveAppKitScreenRectInCGWindowCoordinates(
    CGRect appKitScreenRect,
    CGRect mainDisplayBounds,
    CGRect * _Nullable cgWindowRect,
    NSString * _Nullable * _Nullable failure
);

/// Returns the visible intersection of a native CGWindow with the canvas in
/// fixed top-left logical device coordinates. Native windows outside the
/// canvas are host decoration/transient UI and are not target evidence.
FOUNDATION_EXPORT BOOL IOSUsePlayResolveCGWindowRectInCanvas(
    CGRect sourceCGWindowBounds,
    CGRect canvasCGWindowRect,
    CGFloat backingScaleFactor,
    CGRect * _Nullable deviceLogicalRect,
    NSString * _Nullable * _Nullable failure
);

/// Crops an own-process native window to its intersection with the render
/// canvas and normalizes that crop to the fixed @3x device coordinate space.
/// This is intentionally the only route from a host CGSHW image to a target
/// compositor source, so title bars, traffic lights, content-area rounding
/// margins, desktop pixels, and host shadows cannot enter screenshots or
/// captures.
FOUNDATION_EXPORT CGImageRef _Nullable
IOSUsePlayCropAndNormalizeCanvasCapture(
    CGImageRef source,
    CGRect sourceCGWindowBounds,
    CGRect canvasCGWindowRect,
    CGFloat backingScaleFactor,
    CGRect * _Nullable deviceLogicalRect,
    NSDictionary<NSString *, id> * _Nullable * _Nullable evidence,
    NSString * _Nullable * _Nullable failure
) CF_RETURNS_RETAINED;

/// Produces a total foreground scene order: active first, inactive second,
/// then stable identifier. The caller supplies platform-specific accessors so
/// the same policy can be fixture-tested without UIKit.
FOUNDATION_EXPORT NSArray * _Nullable IOSUsePlayOrderForegroundScenes(
    NSArray *scenes,
    NSInteger (^activationRank)(id scene),
    NSString * _Nullable (^stableIdentifier)(id scene),
    NSString * _Nullable * _Nullable failure
);

FOUNDATION_EXPORT id _Nullable IOSUsePlaySelectPrimaryWindow(
    NSArray *orderedScenes,
    NSArray * _Nullable (^windowsInScene)(id scene),
    BOOL (^isKeyWindow)(id window)
);

/// Matches PlayTools' UIWindow-to-NSWindow policy without importing AppKit:
/// the NSApplication.windows[i].uiWindows association is authoritative, while
/// the private -[UIWindow nsWindow] bridge and NSApplication.keyWindow are
/// ordered fallbacks.
FOUNDATION_EXPORT id _Nullable IOSUsePlayResolveMappedWindow(
    id _Nullable uiWindow,
    NSArray *applicationWindows,
    id _Nullable keyWindowFallback,
    NSString * _Nullable * _Nullable mappingSource
);

/// Unions all required mapped UIKit hosts with every visible numbered native
/// NSApplication window. Duplicate numbers must identify the same object.
FOUNDATION_EXPORT NSArray * _Nullable IOSUsePlayUnionCaptureWindows(
    NSArray *mappedWindows,
    NSArray *applicationWindows,
    BOOL (^isVisible)(id window),
    NSInteger (^windowNumber)(id window),
    NSString * _Nullable * _Nullable failure
);

/// CGSHW must return exactly one image for each requested native window.
FOUNDATION_EXPORT BOOL IOSUsePlayValidateCapturedWindowCount(
    NSUInteger requestedCount,
    CFArrayRef _Nullable capturedImages,
    NSString * _Nullable * _Nullable failure
);

/// Composites captures supplied in native front-to-back order. Every source
/// uses its CG-derived deviceLogicalRect and must be fully inside deviceFrame;
/// the function never clips an off-device source into an apparently complete
/// result. The base window must cover the complete logical device frame.
FOUNDATION_EXPORT CGImageRef _Nullable
IOSUsePlayCompositeWindowCaptures(
    const IOSUsePlayWindowCapture *captures,
    NSUInteger captureCount,
    CGRect deviceFrame,
    uint32_t baseWindowNumber,
    NSArray<NSDictionary<NSString *, id> *> * _Nullable
        * _Nullable sourceEvidence,
    NSString * _Nullable * _Nullable failure
) CF_RETURNS_RETAINED;

/// AppKit and CGWindow use different global origins but must report the same
/// logical size for one native window.
FOUNDATION_EXPORT BOOL IOSUsePlayAppKitCGWindowSizesMatch(
    CGRect appKitFrame,
    CGRect cgWindowBounds
);

FOUNDATION_EXPORT BOOL IOSUsePlayAppKitCGWindowSizesMatchAtBackingScale(
    CGRect appKitFrame,
    CGRect cgWindowBounds,
    CGFloat backingScaleFactor
);

/// Validates that AppKit and CGWindow describe the same-sized base and target
/// windows. Placement is authoritative from the exact own-process CGWindow
/// bounds relative to the exact base CGWindow bounds; raw NSWindow origins are
/// deliberately not used because Catalyst may report a divergent coordinate
/// space for native panels.
FOUNDATION_EXPORT BOOL IOSUsePlayValidateRelativeWindowGeometry(
    CGRect baseAppKitFrame,
    CGRect baseCGWindowBounds,
    CGRect appKitFrame,
    CGRect cgWindowBounds,
    CGRect * _Nullable deviceLogicalRect,
    NSString * _Nullable * _Nullable failure
);

/// Converts an AppKit bottom-left local rect inside a native window into the
/// fixed device's top-left logical coordinate space. The native window's
/// deviceLogicalRect must already have been resolved from exact CGWindow
/// metadata.
FOUNDATION_EXPORT BOOL IOSUsePlayResolveLocalAppKitRect(
    CGRect windowDeviceLogicalRect,
    CGRect localAppKitRect,
    CGRect * _Nullable deviceLogicalRect,
    NSString * _Nullable * _Nullable failure
);

/// Capture plan arrays are already in front-to-back order. Equality includes
/// exact window identity, AppKit and CGWindow geometry, and backing scale.
FOUNDATION_EXPORT BOOL IOSUsePlayWindowCapturePlansEqual(
    const IOSUsePlayWindowPlanEntry *before,
    NSUInteger beforeCount,
    uint32_t beforeBaseWindowNumber,
    const IOSUsePlayWindowPlanEntry *after,
    NSUInteger afterCount,
    uint32_t afterBaseWindowNumber,
    NSString * _Nullable * _Nullable failure
);

NS_ASSUME_NONNULL_END
