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

/// The AppKit host is deliberately not the device.  It owns a public title
/// bar and a transparent 8pt strip; only this fixed logical canvas belongs to
/// UIKit, automation coordinates, and screenshots.  `canvasRect` uses the
/// host content view's bottom-left coordinate system, while logical points
/// use the device's usual top-left coordinate system.
typedef struct {
    CGRect hostContentBounds;
    CGRect canvasRect;
    CGFloat displayScale;
    CGFloat inverseDisplayScale;
    CGFloat transparentSpacer;
} IOSUsePlayHostCanvasLayout;

FOUNDATION_EXPORT CGFloat const IOSUsePlayHostCanvasSpacerPoints;
FOUNDATION_EXPORT CGFloat const IOSUsePlayHostCanvasMinimumDisplayScale;

/// Chooses the first public-host content size that fits a visible AppKit
/// frame after title-bar/other frame decoration is accounted for. The canvas
/// remains fixed internally; this only establishes the outer host's initial
/// display scale. A visible frame smaller than the explicit half-scale host
/// minimum is rejected rather than clipped.
FOUNDATION_EXPORT BOOL IOSUsePlayResolveHostInitialContentSize(
    CGSize visibleFrameSize,
    CGSize frameDecorationSize,
    CGSize * _Nullable contentSize,
    NSString * _Nullable * _Nullable failure
);

/// Calculates the one display-only transform for a resizable AppKit host.
/// The canvas is top-anchored directly below the transparent spacer; host
/// resize never changes its 430x932 local logical bounds.
FOUNDATION_EXPORT BOOL IOSUsePlayResolveHostCanvasLayout(
    CGRect hostContentBounds,
    IOSUsePlayHostCanvasLayout * _Nullable layout,
    NSString * _Nullable * _Nullable failure
);

/// Converts between AppKit host-content coordinates (bottom-left) and the
/// fixed target logical coordinates (top-left). Points outside the canvas,
/// including the title-bar-adjacent spacer, are not target hit tests.
FOUNDATION_EXPORT BOOL IOSUsePlayMapHostContentPointToCanvas(
    IOSUsePlayHostCanvasLayout layout,
    CGPoint hostContentPoint,
    CGPoint * _Nullable canvasLogicalPoint,
    NSString * _Nullable * _Nullable failure
);

FOUNDATION_EXPORT BOOL IOSUsePlayMapCanvasPointToHostContent(
    IOSUsePlayHostCanvasLayout layout,
    CGPoint canvasLogicalPoint,
    CGPoint * _Nullable hostContentPoint,
    NSString * _Nullable * _Nullable failure
);

/// Maps a fully visible AppKit host-content rectangle to top-left fixed
/// canvas coordinates. Callers that accept a partially visible AX/native
/// control must intersect with `layout.canvasRect` before using this helper.
FOUNDATION_EXPORT BOOL IOSUsePlayMapHostContentRectToCanvas(
    IOSUsePlayHostCanvasLayout layout,
    CGRect hostContentRect,
    CGRect * _Nullable canvasLogicalRect,
    NSString * _Nullable * _Nullable failure
);

/// Resolves the fixed canvas in global CoreGraphics top-left coordinates from
/// the host content rect. This keeps title bar and transparent spacer outside
/// every capture crop even when AppKit and CGWindow origins differ.
FOUNDATION_EXPORT BOOL IOSUsePlayResolveCanvasCGWindowRect(
    CGRect hostContentCGWindowRect,
    IOSUsePlayHostCanvasLayout layout,
    CGRect * _Nullable canvasCGWindowRect,
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
    CGFloat displayScale,
    CGRect * _Nullable deviceLogicalRect,
    NSString * _Nullable * _Nullable failure
);

/// Crops an own-process native window to its intersection with the render
/// canvas and normalizes that crop to the fixed @3x device coordinate space.
/// This is intentionally the only route from a host CGSHW image to a target
/// compositor source, so title bars, traffic lights, transparent gaps,
/// desktop pixels, and host shadows cannot enter screenshots or captures.
FOUNDATION_EXPORT CGImageRef _Nullable
IOSUsePlayCropAndNormalizeCanvasCapture(
    CGImageRef source,
    CGRect sourceCGWindowBounds,
    CGRect canvasCGWindowRect,
    CGFloat displayScale,
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

/// Hashes a top-left logical subrect of an already complete native compositor
/// image. The canonical digest input is premultiplied BGRA8, not JPEG bytes.
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable
IOSUsePlayFingerprintCompositorImage(
    CGImageRef image,
    CGRect logicalRect,
    NSString * _Nullable * _Nullable failure
);

NS_ASSUME_NONNULL_END
