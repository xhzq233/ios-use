#import "IOSUsePlayRuntimeSocket.h"
#import "IOSUsePlayRuntime.h"
#import "IOSUsePlayRuntimeAutomation.h"
#import "IOSUsePlayRuntimeDOM.h"
#import "IOSUsePlayRuntimeViewTree.h"
#import "IOSUsePlayAppKitBridge.h"
#import "IOSUsePlayHookRegistry.h"
#import "IOSUsePlayRuntimeScreenshot.h"
#import "IOSUsePlayRuntimeStdio.h"
#import "IOSUsePlayRuntimeFrida.h"
#import "IOSUsePlayDevice.h"
#import "IOSUsePlaySwiftBridge.h"

#import <UIKit/UIKit.h>
#import <arpa/inet.h>
#import <crt_externs.h>
#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <objc/message.h>
#import <os/lock.h>
#import <signal.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <poll.h>
#import <stdlib.h>
#import <sys/un.h>
#import <unistd.h>

static const NSUInteger IOSUseMaximumRequestFrameSize = 64 * 1024;
static const NSUInteger IOSUseMaximumResponseFrameSize = 16 * 1024 * 1024;
static const NSTimeInterval IOSUseSocketIOTimeoutSeconds = 15;
static const CGFloat IOSUseRuntimeDeviceLogicalWidth =
    (CGFloat)IOSUsePlayDeviceLogicalWidth;
static const CGFloat IOSUseRuntimeDeviceLogicalHeight =
    (CGFloat)IOSUsePlayDeviceLogicalHeight;
static const CGFloat IOSUseRuntimeDeviceNativeWidth =
    (CGFloat)IOSUsePlayDeviceNativeWidth;
static const CGFloat IOSUseRuntimeDeviceNativeHeight =
    (CGFloat)IOSUsePlayDeviceNativeHeight;
static const CGFloat IOSUseRuntimeDeviceScale =
    (CGFloat)IOSUsePlayDeviceScale;
static const CGFloat IOSUseRuntimeDeviceSafeAreaTop =
    (CGFloat)IOSUsePlayDeviceSafeAreaTop;

static NSString *IOSUseRuntimeSessionID;
static NSString *IOSUseRuntimeSocketPath;
static NSString *IOSUseRuntimeInstallRevision;
static NSString *IOSUseRuntimePlayChainRoot;
static NSString *IOSUseRuntimeSocketStatus = @"not-started";
static NSString *IOSUseRuntimeSocketFailureStage;
static NSNumber *IOSUseRuntimeSocketFailureErrno;
static char IOSUseRuntimeSocketSignalPath[
    sizeof(((struct sockaddr_un *)0)->sun_path)
];
static volatile sig_atomic_t IOSUseRuntimeSocketOwned;
static int IOSUseRuntimeSocketListener = -1;
static volatile sig_atomic_t IOSUseRuntimeSocketCommandLoopStarted;
static os_unfair_lock IOSUseRuntimeSocketStateLock =
    OS_UNFAIR_LOCK_INIT;
static os_unfair_lock IOSUseRuntimeUIStateLock =
    OS_UNFAIR_LOCK_INIT;
static NSDictionary<NSString *, id> *IOSUseRuntimeUIState;
static NSDictionary<NSString *, id> *IOSUseRuntimeUISnapshot;
static dispatch_queue_t IOSUseRuntimeCommandQueue;
static dispatch_queue_t IOSUseRuntimeDebugQueue;
static dispatch_queue_t IOSUseRuntimeConnectionQueue;

@interface IOSUseFridaSocketEventContext : NSObject
@property(nonatomic, assign) int connection;
@property(nonatomic, copy) NSString *requestID;
@property(nonatomic, copy) NSString *sessionID;
@property(nonatomic, strong) NSLock *writeLock;
@end

@implementation IOSUseFridaSocketEventContext
@end

static BOOL IOSUseWriteExactly(
    int descriptor,
    const void *buffer,
    size_t length
);

static BOOL IOSUseIsNonemptyString(id value) {
    return [value isKindOfClass:NSString.class] &&
        [(NSString *)value length] > 0;
}

static BOOL IOSUseIsLowercaseSHA256(NSString *value) {
    if (value.length != 64) {
        return NO;
    }
    NSCharacterSet *allowed = [NSCharacterSet
        characterSetWithCharactersInString:@"0123456789abcdef"];
    return [value rangeOfCharacterFromSet:allowed.invertedSet]
        .location == NSNotFound;
}

static NSDictionary<NSString *, id> *IOSUseErrorObject(
    NSString *code,
    NSString *message,
    NSString *category,
    NSString *phase,
    BOOL retryable
) {
    return @{
        @"code": code,
        @"message": message,
        @"details": @{
            @"category": category,
            @"phase": phase,
            @"retryable": @(retryable),
            @"fatal": @NO,
            @"candidateCount": @0,
            @"candidates": @[],
            @"suggestions": @[],
        },
    };
}

static NSDictionary<NSString *, id> *IOSUseRuntimeStdioEvidence(void) {
    IOSUsePlayRuntimeStdioState state = {0};
    IOSUsePlayRuntimeCopyStdioState(&state);
    NSString *status = @"failed";
    switch (state.status) {
        case IOSUsePlayRuntimeStdioDisabled:
            status = @"disabled";
            break;
        case IOSUsePlayRuntimeStdioRedirected:
            status = @"redirected";
            break;
        case IOSUsePlayRuntimeStdioFailed:
            status = @"failed";
            break;
    }
    NSString *path = state.path[0] == '\0'
        ? nil
        : [NSString stringWithUTF8String:state.path];
    NSString *failureStage =
        state.failureStage[0] == '\0'
            ? nil
            : [NSString
                stringWithUTF8String:state.failureStage];
    return @{
        @"status": status,
        @"path": path ?: NSNull.null,
        @"device":
            state.status == IOSUsePlayRuntimeStdioDisabled
                ? (id)NSNull.null
                : @(state.device),
        @"inode":
            state.status == IOSUsePlayRuntimeStdioDisabled
                ? (id)NSNull.null
                : @(state.inode),
        @"failureStage": failureStage ?: NSNull.null,
        @"errorNumber":
            state.status == IOSUsePlayRuntimeStdioFailed
                ? @(state.errorNumber)
                : (id)NSNull.null,
    };
}

void IOSUsePlayRuntimeSetUIReadiness(
    NSString *state,
    NSString *stage,
    NSString *failure
) {
    if (![@[@"initializing", @"ready", @"backgrounded", @"failed"]
            containsObject:state] ||
        stage.length == 0) {
        return;
    }
    NSDictionary<NSString *, id> *snapshot = @{
        @"state": state,
        @"stage": stage,
        @"failure": failure ?: NSNull.null,
    };
    os_unfair_lock_lock(&IOSUseRuntimeUIStateLock);
    IOSUseRuntimeUIState = snapshot;
    os_unfair_lock_unlock(&IOSUseRuntimeUIStateLock);
}

static NSDictionary<NSString *, id> *IOSUseCurrentUIReadiness(void) {
    os_unfair_lock_lock(&IOSUseRuntimeUIStateLock);
    NSDictionary<NSString *, id> *state =
        [IOSUseRuntimeUIState copy];
    os_unfair_lock_unlock(&IOSUseRuntimeUIStateLock);
    return state ?: @{
        @"state": @"initializing",
        @"stage": @"runtime-constructor",
        @"failure": NSNull.null,
    };
}

static NSDictionary<NSString *, id> *IOSUseErrorEnvelope(
    NSString *requestID,
    NSDictionary<NSString *, id> *error
) {
    return @{
        @"requestId": requestID ?: @"",
        @"sessionID": IOSUseRuntimeSessionID ?: @"",
        @"ok": @NO,
        @"error": error,
    };
}

static NSDictionary<NSString *, id> *IOSUseBasicErrorEnvelope(
    NSString *requestID,
    NSString *code,
    NSString *message,
    NSString *category,
    NSString *phase,
    BOOL retryable
) {
    return IOSUseErrorEnvelope(
        requestID,
        IOSUseErrorObject(
            code,
            message,
            category,
            phase,
            retryable
        )
    );
}

static void IOSUseRecordSocketState(
    NSString *status,
    NSString *failureStage,
    NSInteger errorCode
) {
    os_unfair_lock_lock(&IOSUseRuntimeSocketStateLock);
    IOSUseRuntimeSocketStatus = [status copy];
    IOSUseRuntimeSocketFailureStage = [failureStage copy];
    IOSUseRuntimeSocketFailureErrno =
        failureStage == nil ? nil : @(errorCode);
    os_unfair_lock_unlock(&IOSUseRuntimeSocketStateLock);
}

static void IOSUseRecordSocketFailure(
    NSString *stage,
    NSInteger errorCode
) {
    IOSUseRecordSocketState(@"failed", stage, errorCode);
    NSLog(
        @"[ios-use-play] Runtime socket failed stage=%@ errno=%ld",
        stage,
        (long)errorCode
    );
}

static BOOL IOSUseConfigureSocket(int descriptor, BOOL connection) {
    int descriptorFlags = fcntl(descriptor, F_GETFD);
    if (descriptorFlags < 0 ||
        fcntl(
            descriptor,
            F_SETFD,
            descriptorFlags | FD_CLOEXEC
        ) != 0) {
        return NO;
    }
    int enabled = 1;
    if (setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            sizeof(enabled)
        ) != 0) {
        return NO;
    }
    if (!connection) {
        return YES;
    }
    struct timeval timeout = {
        .tv_sec = (time_t)IOSUseSocketIOTimeoutSeconds,
        .tv_usec = 0,
    };
    return setsockopt(
               descriptor,
               SOL_SOCKET,
               SO_RCVTIMEO,
               &timeout,
               sizeof(timeout)
           ) == 0 &&
        setsockopt(
               descriptor,
               SOL_SOCKET,
               SO_SNDTIMEO,
               &timeout,
               sizeof(timeout)
           ) == 0;
}

static BOOL IOSUseReadExactly(
    int descriptor,
    void *buffer,
    size_t length
) {
    uint8_t *cursor = buffer;
    size_t remaining = length;
    while (remaining > 0) {
        ssize_t count = read(descriptor, cursor, remaining);
        if (count > 0) {
            cursor += count;
            remaining -= (size_t)count;
            continue;
        }
        if (count < 0 && errno == EINTR) {
            continue;
        }
        return NO;
    }
    return YES;
}

static BOOL IOSUseWriteExactly(
    int descriptor,
    const void *buffer,
    size_t length
) {
    const uint8_t *cursor = buffer;
    size_t remaining = length;
    while (remaining > 0) {
        ssize_t count = write(descriptor, cursor, remaining);
        if (count > 0) {
            cursor += count;
            remaining -= (size_t)count;
            continue;
        }
        if (count < 0 && errno == EINTR) {
            continue;
        }
        return NO;
    }
    return YES;
}

static void IOSUseClearReadTimeout(int descriptor) {
    struct timeval timeout = {.tv_sec = 0, .tv_usec = 0};
    (void)setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_RCVTIMEO,
        &timeout,
        sizeof(timeout)
    );
}

static BOOL IOSUseSocketPeerDisconnected(int descriptor) {
    uint8_t byte = 0;
    ssize_t count = recv(
        descriptor,
        &byte,
        sizeof(byte),
        MSG_PEEK | MSG_DONTWAIT
    );
    if (count == 0) {
        return YES;
    }
    return count < 0 &&
        errno != EAGAIN &&
        errno != EWOULDBLOCK &&
        errno != EINTR;
}

static NSArray<NSString *> *IOSUseCapabilities(BOOL requiredHooksReady) {
    if (!requiredHooksReady) {
        return @[];
    }
    return @[
        @"hello",
        @"ping",
        @"diagnostics",
        @"screenshot",
        @"dom",
        @"uiTree",
        @"waitFor",
        @"tap",
        @"longPress",
        @"swipe",
        @"input",
        @"dismissAlert",
        @"dismissAlertByLabel",
        @"debug",
    ];
}

/// The public `geometry.window` remains the immutable UIKit target canvas.
/// Keep the independently resizable AppKit host in a separate diagnostic
/// object so clients never mistake title-bar or host dimensions for iPhone
/// coordinates.
static NSDictionary<NSString *, NSNumber *> *IOSUseSocketZeroRect(void) {
    return @{
        @"x": @0,
        @"y": @0,
        @"width": @0,
        @"height": @0,
    };
}

static BOOL IOSUseSocketHasFiniteRectFields(id value) {
    if (![value isKindOfClass:NSDictionary.class]) {
        return NO;
    }
    NSDictionary *dictionary = value;
    for (NSString *key in @[@"x", @"y", @"width", @"height"]) {
        id rawNumber = dictionary[key];
        if (![rawNumber isKindOfClass:NSNumber.class] ||
            !isfinite([(NSNumber *)rawNumber doubleValue])) {
            return NO;
        }
    }
    return YES;
}

static BOOL IOSUseSocketHasPositiveRectFields(id value) {
    if (!IOSUseSocketHasFiniteRectFields(value)) {
        return NO;
    }
    NSDictionary *dictionary = value;
    return [dictionary[@"width"] doubleValue] > 0 &&
        [dictionary[@"height"] doubleValue] > 0;
}

static NSDictionary<NSString *, NSNumber *> *IOSUseSocketStableRect(
    id value
) {
    if (!IOSUseSocketHasFiniteRectFields(value)) {
        return IOSUseSocketZeroRect();
    }
    NSDictionary *dictionary = value;
    return @{
        @"x": @([dictionary[@"x"] doubleValue]),
        @"y": @([dictionary[@"y"] doubleValue]),
        @"width": @([dictionary[@"width"] doubleValue]),
        @"height": @([dictionary[@"height"] doubleValue]),
    };
}

static NSDictionary<NSString *, NSNumber *> *IOSUseSocketPreferredRect(
    id preferred,
    id fallback
) {
    return IOSUseSocketStableRect(
        IOSUseSocketHasPositiveRectFields(preferred) ? preferred : fallback
    );
}

static NSNumber *IOSUseSocketStableFiniteNumber(id value) {
    if (![value isKindOfClass:NSNumber.class] ||
        !isfinite([(NSNumber *)value doubleValue])) {
        return @0;
    }
    return @([(NSNumber *)value doubleValue]);
}

static NSNumber *IOSUseSocketStableBool(id value) {
    // `&&` promotes the expression to C `int`; boxing that directly produces
    // JSON `0`/`1`, which Swift's `Bool` decoder correctly rejects.  Return a
    // canonical CFBoolean so every typed Runtime host field remains a JSON
    // boolean even on its unavailable/error path.
    BOOL boolValue = [value isKindOfClass:NSNumber.class] &&
        [(NSNumber *)value boolValue];
    return boolValue ? @YES : @NO;
}

static NSString *IOSUseSocketStableString(id value) {
    return [value isKindOfClass:NSString.class] ? value : @"";
}

static id IOSUseSocketStableOptionalInteger(id value) {
    if (![value isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
        return NSNull.null;
    }
    double number = [(NSNumber *)value doubleValue];
    if (!isfinite(number) || trunc(number) != number ||
        number < (double)LLONG_MIN || number > (double)LLONG_MAX) {
        return NSNull.null;
    }
    return @([(NSNumber *)value longLongValue]);
}

static id IOSUseSocketStableCaptureError(
    id value,
    BOOL captureDiagnosticsAreComplete
) {
    if ([value isKindOfClass:NSString.class]) {
        return value;
    }
    if (value != nil && value != NSNull.null) {
        NSString *description = [value description];
        if (description.length > 0) {
            return description;
        }
    }
    return captureDiagnosticsAreComplete
        ? (id)NSNull.null
        : @"canvas capture diagnostics are unavailable";
}

static NSDictionary<NSString *, id> *IOSUseHostGeometry(
    NSDictionary<NSString *, id> *hooks
) {
    id rawWindow = hooks[@"window"];
    NSDictionary<NSString *, id> *window =
        [rawWindow isKindOfClass:NSDictionary.class]
            ? rawWindow
            : @{};
    id rawCapture = window[@"canvasCapture"];
    NSDictionary<NSString *, id> *capture =
        [rawCapture isKindOfClass:NSDictionary.class]
            ? rawCapture
            : @{};
    id rawSceneScale = window[@"sceneScale"];
    NSDictionary<NSString *, id> *sceneScale =
        [rawSceneScale isKindOfClass:NSDictionary.class]
            ? rawSceneScale
            : @{};
    BOOL captureDiagnosticsAreComplete =
        IOSUseSocketHasPositiveRectFields(
            capture[@"hostContentCGWindowRect"]
        ) &&
        IOSUseSocketHasPositiveRectFields(
            capture[@"hostCGWindowBounds"]
        ) &&
        IOSUseSocketHasPositiveRectFields(
            capture[@"canvasCGWindowRect"]
        );
    id captureError = IOSUseSocketStableCaptureError(
        capture[@"error"],
        captureDiagnosticsAreComplete
    );
    BOOL captureReady = capture[@"error"] == nil &&
        captureDiagnosticsAreComplete;
    return @{
        @"frame": IOSUseSocketPreferredRect(
            window[@"hostFrame"],
            window[@"frame"]
        ),
        @"status": [window[@"status"] isKindOfClass:NSString.class]
            ? window[@"status"]
            : @"not-configured",
        @"hostPolicy": IOSUseSocketStableBool(window[@"hostPolicy"]),
        @"contentBounds": IOSUseSocketStableRect(
            window[@"hostContentBounds"]
        ),
        @"canvasRect": IOSUseSocketStableRect(window[@"canvasRect"]),
        @"backingPixelCanvasRect": IOSUseSocketStableRect(
            window[@"backingPixelCanvasRect"]
        ),
        @"canvasBounds": IOSUseSocketStableRect(window[@"canvasBounds"]),
        @"renderViewBounds": IOSUseSocketStableRect(
            window[@"renderViewBounds"]
        ),
        @"sceneRenderViewFrame": IOSUseSocketStableRect(
            window[@"sceneRenderViewFrame"]
        ),
        @"sceneRenderViewBounds": IOSUseSocketStableRect(
            window[@"sceneRenderViewBounds"]
        ),
        @"inputRenderViewFrame": IOSUseSocketStableRect(
            window[@"inputRenderViewFrame"]
        ),
        @"inputRenderViewBounds": IOSUseSocketStableRect(
            window[@"inputRenderViewBounds"]
        ),
        @"displayScale": IOSUseSocketStableFiniteNumber(
            window[@"displayScale"]
        ),
        @"inverseDisplayScale": IOSUseSocketStableFiniteNumber(
            window[@"inverseDisplayScale"]
        ),
        @"backingScaleFactor": IOSUseSocketStableFiniteNumber(
            window[@"backingScaleFactor"]
        ),
        @"halfPixelTolerance": IOSUseSocketStableFiniteNumber(
            window[@"halfPixelTolerance"]
        ),
        @"idiomScale": IOSUseSocketStableFiniteNumber(
            sceneScale[@"idiom"]
        ),
        @"windowScale": IOSUseSocketStableFiniteNumber(
            sceneScale[@"windows"]
        ),
        @"downscaleWindowIfNecessary": IOSUseSocketStableBool(
            sceneScale[@"downscaleWindowIfNecessary"]
        ),
        @"opaque": IOSUseSocketStableBool(window[@"opaque"]),
        @"publicTitleBar": IOSUseSocketStableBool(
            window[@"publicTitleBar"]
        ),
        @"titleVisible": IOSUseSocketStableBool(window[@"titleVisible"]),
        @"resizable": IOSUseSocketStableBool(window[@"resizable"]),
        @"title": IOSUseSocketStableString(window[@"title"]),
        @"titleExpected": IOSUseSocketStableString(
            window[@"titleExpected"]
        ),
        @"capture": @{
            @"ready": @(captureReady),
            @"error": captureError,
            @"hostContentCGWindowRect": IOSUseSocketStableRect(
                capture[@"hostContentCGWindowRect"]
            ),
            @"hostCGWindowBounds": IOSUseSocketStableRect(
                capture[@"hostCGWindowBounds"]
            ),
            @"canvasCGWindowRect": IOSUseSocketStableRect(
                capture[@"canvasCGWindowRect"]
            ),
            @"hostWindowNumber": IOSUseSocketStableOptionalInteger(
                capture[@"hostWindowNumber"]
            ),
        },
    };
}

static BOOL IOSUseSocketRectFromJSON(id value, CGRect *rect) {
    if (![value isKindOfClass:NSDictionary.class]) {
        return NO;
    }
    NSDictionary *dictionary = value;
    for (NSString *key in @[@"x", @"y", @"width", @"height"]) {
        if (![dictionary[key] isKindOfClass:NSNumber.class]) {
            return NO;
        }
    }
    CGRect result = CGRectMake(
        [dictionary[@"x"] doubleValue],
        [dictionary[@"y"] doubleValue],
        [dictionary[@"width"] doubleValue],
        [dictionary[@"height"] doubleValue]
    );
    if (!isfinite(result.origin.x) || !isfinite(result.origin.y) ||
        !isfinite(result.size.width) || !isfinite(result.size.height) ||
        result.size.width <= 0 || result.size.height <= 0) {
        return NO;
    }
    if (rect != NULL) {
        *rect = result;
    }
    return YES;
}

static BOOL IOSUseSocketContainsRect(
    CGRect outer,
    CGRect inner,
    CGFloat tolerance
) {
    return CGRectGetMinX(inner) >= CGRectGetMinX(outer) - tolerance &&
        CGRectGetMinY(inner) >= CGRectGetMinY(outer) - tolerance &&
        CGRectGetMaxX(inner) <= CGRectGetMaxX(outer) + tolerance &&
        CGRectGetMaxY(inner) <= CGRectGetMaxY(outer) + tolerance;
}

static BOOL IOSUseSocketMatchesFixedLogicalCanvas(
    CGRect rect,
    CGFloat originTolerance,
    CGFloat sizeTolerance
) {
    return fabs(rect.origin.x) <= originTolerance &&
        fabs(rect.origin.y) <= originTolerance &&
        fabs(rect.size.width - IOSUseRuntimeDeviceLogicalWidth) <=
            sizeTolerance &&
        fabs(rect.size.height - IOSUseRuntimeDeviceLogicalHeight) <=
            sizeTolerance;
}

static BOOL IOSUseSocketMatchesPixelQuantizedPrivateCanvas(
    CGRect rect,
    CGFloat originTolerance,
    CGFloat positiveWidthTolerance,
    CGFloat positiveHeightTolerance
) {
    // UIKitMacHelper's private frame accessors can quantize one axis to five
    // fractional digits while the host-canvas layout retains the full double.
    // Keep this far below one backing pixel, but do not reject a valid resized
    // host over a few millionths of one logical point.
    const CGFloat quantizationEpsilon = 0.00001;
    CGFloat widthDelta =
        rect.size.width - IOSUseRuntimeDeviceLogicalWidth;
    CGFloat heightDelta =
        rect.size.height - IOSUseRuntimeDeviceLogicalHeight;
    CGFloat maximumXDelta =
        CGRectGetMaxX(rect) - IOSUseRuntimeDeviceLogicalWidth;
    CGFloat maximumYDelta =
        CGRectGetMaxY(rect) - IOSUseRuntimeDeviceLogicalHeight;
    return fabs(rect.origin.x) <= originTolerance &&
        fabs(rect.origin.y) <= originTolerance &&
        widthDelta >= -originTolerance &&
        widthDelta <= positiveWidthTolerance + quantizationEpsilon &&
        heightDelta >= -originTolerance &&
        heightDelta <= positiveHeightTolerance + quantizationEpsilon &&
        maximumXDelta >= -originTolerance &&
        maximumXDelta <= positiveWidthTolerance + quantizationEpsilon &&
        maximumYDelta >= -originTolerance &&
        maximumYDelta <= positiveHeightTolerance + quantizationEpsilon;
}

static BOOL IOSUseSocketRectsApproximatelyEqual(
    CGRect lhs,
    CGRect rhs
) {
    return fabs(lhs.origin.x - rhs.origin.x) <= 0.01 &&
        fabs(lhs.origin.y - rhs.origin.y) <= 0.01 &&
        fabs(lhs.size.width - rhs.size.width) <= 0.01 &&
        fabs(lhs.size.height - rhs.size.height) <= 0.01;
}

static BOOL IOSUseSocketBackingAligned(
    CGFloat value,
    CGFloat backingScaleFactor
) {
    CGFloat pixels = value * backingScaleFactor;
    return isfinite(pixels) && fabs(pixels - round(pixels)) <= 0.000001;
}

static BOOL IOSUseHostGeometryReady(NSDictionary<NSString *, id> *host) {
    NSDictionary<NSString *, id> *capture =
        [host[@"capture"] isKindOfClass:NSDictionary.class]
            ? host[@"capture"]
            : @{};
    CGRect frame = CGRectZero;
    CGRect contentBounds = CGRectZero;
    CGRect canvasBounds = CGRectZero;
    CGRect renderViewBounds = CGRectZero;
    CGRect sceneRenderViewFrame = CGRectZero;
    CGRect sceneRenderViewBounds = CGRectZero;
    CGRect inputRenderViewFrame = CGRectZero;
    CGRect inputRenderViewBounds = CGRectZero;
    CGRect canvasRect = CGRectZero;
    CGRect backingPixelCanvasRect = CGRectZero;
    CGRect hostContentCGWindowRect = CGRectZero;
    CGRect hostCGWindowBounds = CGRectZero;
    CGRect canvasCGWindowRect = CGRectZero;
    CGFloat displayScale = [host[@"displayScale"] doubleValue];
    CGFloat inverseDisplayScale =
        [host[@"inverseDisplayScale"] doubleValue];
    CGFloat backingScaleFactor =
        [host[@"backingScaleFactor"] doubleValue];
    CGFloat halfPixelTolerance =
        [host[@"halfPixelTolerance"] doubleValue];
    CGFloat idiomScale = [host[@"idiomScale"] doubleValue];
    CGFloat windowScale = [host[@"windowScale"] doubleValue];
    NSString *title = [host[@"title"] isKindOfClass:NSString.class]
        ? host[@"title"]
        : @"";
    NSString *expectedTitle =
        [host[@"titleExpected"] isKindOfClass:NSString.class]
            ? host[@"titleExpected"]
            : @"";
    NSNumber *hostWindowNumber =
        [capture[@"hostWindowNumber"] isKindOfClass:NSNumber.class]
            ? capture[@"hostWindowNumber"]
            : nil;
    BOOL captureErrorIsNull = capture[@"error"] == NSNull.null;
    BOOL commonReady =
        [host[@"status"] isEqualToString:@"configured"] &&
        [host[@"hostPolicy"] boolValue] &&
        [host[@"publicTitleBar"] boolValue] &&
        [host[@"titleVisible"] boolValue] &&
        [host[@"resizable"] boolValue] &&
        title.length > 0 && [title isEqualToString:expectedTitle] &&
        IOSUseSocketRectFromJSON(host[@"frame"], &frame) &&
        IOSUseSocketRectFromJSON(
            host[@"contentBounds"],
            &contentBounds
        ) &&
        IOSUseSocketRectFromJSON(host[@"canvasBounds"], &canvasBounds) &&
        IOSUseSocketRectFromJSON(
            host[@"renderViewBounds"],
            &renderViewBounds
        ) &&
        IOSUseSocketRectFromJSON(
            host[@"sceneRenderViewFrame"],
            &sceneRenderViewFrame
        ) &&
        IOSUseSocketRectFromJSON(
            host[@"sceneRenderViewBounds"],
            &sceneRenderViewBounds
        ) &&
        IOSUseSocketRectFromJSON(
            host[@"inputRenderViewFrame"],
            &inputRenderViewFrame
        ) &&
        IOSUseSocketRectFromJSON(
            host[@"inputRenderViewBounds"],
            &inputRenderViewBounds
        ) &&
        IOSUseSocketRectFromJSON(host[@"canvasRect"], &canvasRect) &&
        IOSUseSocketRectFromJSON(
            host[@"backingPixelCanvasRect"],
            &backingPixelCanvasRect
        );
    if (!commonReady) {
        return NO;
    }
    CGFloat leftMargin =
        CGRectGetMinX(canvasRect) - CGRectGetMinX(contentBounds);
    CGFloat rightMargin =
        CGRectGetMaxX(contentBounds) - CGRectGetMaxX(canvasRect);
    CGFloat bottomMargin =
        CGRectGetMinY(canvasRect) - CGRectGetMinY(contentBounds);
    CGFloat topMargin =
        CGRectGetMaxY(contentBounds) - CGRectGetMaxY(canvasRect);
    CGFloat logicalTolerance =
        isfinite(displayScale) && displayScale > 0
            ? halfPixelTolerance / displayScale
            : 0;
    CGFloat logicalEdgeTolerance = logicalTolerance;
    CGFloat horizontalSurplus =
        MAX(0, leftMargin + rightMargin);
    CGFloat verticalSurplus =
        MAX(0, bottomMargin + topMargin);
    // UIKitMacHelper may project both centered subpixel edge margins into one
    // positive private render-view extent. Derive each axis from the actual
    // host surplus, bound it by the same two half-pixel edges, and keep
    // origins/undersize at the single-edge tolerance. Input still consumes
    // the ideal canvas transform rather than this raster extent.
    CGFloat privateWidthTolerance = MAX(
        logicalEdgeTolerance,
        MIN(
            horizontalSurplus / displayScale,
            logicalEdgeTolerance * 2
        )
    );
    CGFloat privateHeightTolerance = MAX(
        logicalEdgeTolerance,
        MIN(
            verticalSurplus / displayScale,
            logicalEdgeTolerance * 2
        )
    );
    return [host[@"opaque"] boolValue] &&
        isfinite(displayScale) && displayScale > 0 &&
        isfinite(backingScaleFactor) &&
        backingScaleFactor > 0 && backingScaleFactor <= 4 &&
        isfinite(halfPixelTolerance) &&
        fabs(halfPixelTolerance -
            0.5 / backingScaleFactor) <= 0.000001 &&
        isfinite(logicalTolerance) && logicalTolerance > 0 &&
        IOSUseSocketBackingAligned(
            CGRectGetMinX(backingPixelCanvasRect),
            backingScaleFactor
        ) &&
        IOSUseSocketBackingAligned(
            CGRectGetMinY(backingPixelCanvasRect),
            backingScaleFactor
        ) &&
        IOSUseSocketBackingAligned(
            CGRectGetMaxX(backingPixelCanvasRect),
            backingScaleFactor
        ) &&
        IOSUseSocketBackingAligned(
            CGRectGetMaxY(backingPixelCanvasRect),
            backingScaleFactor
        ) &&
        isfinite(inverseDisplayScale) &&
        fabs(displayScale * inverseDisplayScale - 1.0) <= 0.01 &&
        fabs(canvasBounds.origin.x) <= logicalEdgeTolerance &&
        fabs(canvasBounds.origin.y) <= logicalEdgeTolerance &&
        fabs(canvasBounds.size.width - IOSUseRuntimeDeviceLogicalWidth) <=
            logicalEdgeTolerance &&
        fabs(canvasBounds.size.height - IOSUseRuntimeDeviceLogicalHeight) <=
            logicalEdgeTolerance &&
        IOSUseSocketMatchesFixedLogicalCanvas(
            renderViewBounds,
            logicalEdgeTolerance,
            logicalEdgeTolerance
        ) &&
        IOSUseSocketMatchesPixelQuantizedPrivateCanvas(
            sceneRenderViewFrame,
            logicalEdgeTolerance,
            privateWidthTolerance,
            privateHeightTolerance
        ) &&
        IOSUseSocketMatchesPixelQuantizedPrivateCanvas(
            sceneRenderViewBounds,
            logicalEdgeTolerance,
            privateWidthTolerance,
            privateHeightTolerance
        ) &&
        IOSUseSocketMatchesPixelQuantizedPrivateCanvas(
            inputRenderViewFrame,
            logicalEdgeTolerance,
            privateWidthTolerance,
            privateHeightTolerance
        ) &&
        IOSUseSocketMatchesPixelQuantizedPrivateCanvas(
            inputRenderViewBounds,
            logicalEdgeTolerance,
            privateWidthTolerance,
            privateHeightTolerance
        ) &&
        IOSUseSocketRectsApproximatelyEqual(
            sceneRenderViewFrame,
            sceneRenderViewBounds
        ) &&
        IOSUseSocketRectsApproximatelyEqual(
            sceneRenderViewFrame,
            inputRenderViewFrame
        ) &&
        IOSUseSocketRectsApproximatelyEqual(
            sceneRenderViewFrame,
            inputRenderViewBounds
        ) &&
        isfinite(idiomScale) &&
        fabs(idiomScale - 1.0) <= 0.01 &&
        isfinite(windowScale) &&
        fabs(windowScale - 1.0) <= 0.01 &&
        ![host[@"downscaleWindowIfNecessary"] boolValue] &&
        IOSUseSocketContainsRect(
            contentBounds,
            canvasRect,
            halfPixelTolerance
        ) &&
        leftMargin >= -halfPixelTolerance &&
        rightMargin >= -halfPixelTolerance &&
        bottomMargin >= -halfPixelTolerance &&
        topMargin >= -halfPixelTolerance &&
        leftMargin + rightMargin <= halfPixelTolerance * 2 &&
        bottomMargin + topMargin <= halfPixelTolerance * 2 &&
        fabs(leftMargin - rightMargin) <= halfPixelTolerance &&
        fabs(bottomMargin - topMargin) <= halfPixelTolerance &&
        fabs(canvasRect.size.width / displayScale -
            IOSUseRuntimeDeviceLogicalWidth) <= logicalTolerance &&
        fabs(canvasRect.size.height / displayScale -
            IOSUseRuntimeDeviceLogicalHeight) <= logicalTolerance &&
        IOSUseSocketRectFromJSON(
            capture[@"hostContentCGWindowRect"],
            &hostContentCGWindowRect
        ) &&
        IOSUseSocketRectFromJSON(
            capture[@"hostCGWindowBounds"],
            &hostCGWindowBounds
        ) &&
        IOSUseSocketRectFromJSON(
            capture[@"canvasCGWindowRect"],
            &canvasCGWindowRect
        ) &&
        [capture[@"ready"] boolValue] &&
        captureErrorIsNull && hostWindowNumber != nil &&
        hostWindowNumber.unsignedLongLongValue > 0 &&
        fabs(hostCGWindowBounds.size.width - frame.size.width) <=
            halfPixelTolerance &&
        fabs(hostCGWindowBounds.size.height - frame.size.height) <=
            halfPixelTolerance &&
        IOSUseSocketContainsRect(
            hostCGWindowBounds,
            hostContentCGWindowRect,
            halfPixelTolerance
        ) &&
        IOSUseSocketContainsRect(
            hostCGWindowBounds,
            canvasCGWindowRect,
            halfPixelTolerance
        ) &&
        fabs(hostContentCGWindowRect.size.width -
            contentBounds.size.width) <= halfPixelTolerance &&
        fabs(hostContentCGWindowRect.size.height -
            contentBounds.size.height) <= halfPixelTolerance &&
        fabs(
            canvasCGWindowRect.origin.x -
                (hostContentCGWindowRect.origin.x +
                    backingPixelCanvasRect.origin.x -
                    contentBounds.origin.x)
        ) <= halfPixelTolerance &&
        fabs(
            canvasCGWindowRect.origin.y -
                (hostContentCGWindowRect.origin.y +
                    CGRectGetMaxY(contentBounds) -
                    CGRectGetMaxY(backingPixelCanvasRect))
        ) <= halfPixelTolerance &&
        fabs(canvasCGWindowRect.size.width -
            backingPixelCanvasRect.size.width) <=
                halfPixelTolerance &&
        fabs(canvasCGWindowRect.size.height -
            backingPixelCanvasRect.size.height) <=
                halfPixelTolerance &&
        fabs(CGRectGetMinX(backingPixelCanvasRect) -
            CGRectGetMinX(canvasRect)) <= halfPixelTolerance &&
        fabs(CGRectGetMinY(backingPixelCanvasRect) -
            CGRectGetMinY(canvasRect)) <= halfPixelTolerance &&
        fabs(CGRectGetMaxX(backingPixelCanvasRect) -
            CGRectGetMaxX(canvasRect)) <= halfPixelTolerance &&
        fabs(CGRectGetMaxY(backingPixelCanvasRect) -
            CGRectGetMaxY(canvasRect)) <= halfPixelTolerance;
}

/// Capture one scope's UIKit/AppKit fields for one response in one main-thread
/// turn. Readiness keeps the exact geometry predicate inputs without paying
/// for status-only inventories; full diagnostics retains the public payload.
static NSDictionary<NSString *, id> *IOSUseRuntimeSnapshot(
    IOSUsePlayRuntimeDiagnosticsScope scope,
    NSDictionary<NSString *, id> *nativeAlertSnapshot,
    NSDictionary<NSString *, id> *photosAuthorizationDiagnostics
) {
    __block NSDictionary<NSString *, id> *geometry;
    __block NSDictionary<NSString *, id> *hooks;
    __block NSDictionary<NSString *, id> *observed;
    __block NSString *stage;
    __block BOOL requiredHooksReady = NO;
    __block BOOL requiredHooksFailed = NO;
    void (^capture)(void) = ^{
        UIScreen *screen = UIScreen.mainScreen;
        UIWindow *keyWindow = nil;
        for (UIScene *scene in
             UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) {
                continue;
            }
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window.isKeyWindow) {
                    keyWindow = window;
                    break;
                }
            }
        }
        CGRect logical = screen.bounds;
        CGRect native = screen.nativeBounds;
        CGFloat screenScale = screen.scale;
        CGFloat nativeScale = screen.nativeScale;
        CGRect windowBounds = keyWindow.bounds;
        UIView *rootView = keyWindow.rootViewController.view;
        UIEdgeInsets safeArea =
            rootView == nil ? UIEdgeInsetsZero : rootView.safeAreaInsets;
        UIDevice *device = UIDevice.currentDevice;
        UIUserInterfaceIdiom deviceIdiom = device.userInterfaceIdiom;
        UIUserInterfaceIdiom traitIdiom =
            keyWindow == nil
                ? UIUserInterfaceIdiomUnspecified
                : keyWindow.traitCollection.userInterfaceIdiom;
        UIDeviceOrientation deviceOrientation = device.orientation;
        UIInterfaceOrientation sceneOrientation =
            keyWindow.windowScene == nil
                ? UIInterfaceOrientationUnknown
                : keyWindow.windowScene.interfaceOrientation;
        UIStatusBarManager *statusBarManager =
            keyWindow.windowScene.statusBarManager;
        CGRect statusBarFrame = statusBarManager == nil
            ? CGRectZero
            : statusBarManager.statusBarFrame;
        SEL applicationStatusBarFrameSelector =
            NSSelectorFromString(@"statusBarFrame");
        CGRect applicationStatusBarFrame =
            [UIApplication.sharedApplication
                respondsToSelector:applicationStatusBarFrameSelector]
                ? ((CGRect (*)(id, SEL))objc_msgSend)(
                    UIApplication.sharedApplication,
                    applicationStatusBarFrameSelector
                )
                : CGRectZero;
        BOOL statusBarReady =
            statusBarManager != nil &&
            isfinite(statusBarFrame.size.height) &&
            statusBarFrame.size.height ==
                IOSUseRuntimeDeviceSafeAreaTop &&
            isfinite(applicationStatusBarFrame.size.height) &&
            applicationStatusBarFrame.size.height ==
                IOSUseRuntimeDeviceSafeAreaTop;
        NSString *deviceModel = device.model ?: @"";
        NSString *localizedDeviceModel = device.localizedModel ?: @"";
        BOOL deviceIdentityReady =
            [deviceModel isEqualToString:
                [NSString stringWithUTF8String:
                    IOSUsePlayDeviceModel()]] &&
            [localizedDeviceModel isEqualToString:
                [NSString stringWithUTF8String:
                    IOSUsePlayDeviceLocalizedModel()]] &&
            deviceIdiom ==
                (UIUserInterfaceIdiom)
                    IOSUsePlayDeviceUserInterfaceIdiom &&
            traitIdiom ==
                (UIUserInterfaceIdiom)
                    IOSUsePlayDeviceUserInterfaceIdiom &&
            deviceOrientation ==
                (UIDeviceOrientation)IOSUsePlayDeviceOrientation &&
            sceneOrientation == UIInterfaceOrientationPortrait &&
            nativeScale == IOSUseRuntimeDeviceScale &&
            statusBarReady;
        hooks = IOSUsePlayRuntimeHookDiagnostics(
            scope,
            nativeAlertSnapshot,
            photosAuthorizationDiagnostics
        );
        NSDictionary<NSString *, id> *hookRegistry =
            hooks[@"hookRegistry"];
        NSString *configurationStage =
            [hooks[@"configurationStage"] isKindOfClass:NSString.class]
                ? hooks[@"configurationStage"]
                : @"runtime-constructor";
        BOOL configurationFailed =
            [configurationStage hasSuffix:@"-failed"];
        requiredHooksReady = [hookRegistry[@"requiredReady"] boolValue];
        requiredHooksFailed =
            IOSUsePlayHookRegistryHasRequiredFailure(
                hookRegistry,
                configurationFailed
            );
        NSDictionary<NSString *, id> *hostGeometry =
            IOSUseHostGeometry(hooks);
        geometry = @{
            @"logical": @{
                @"width": @(logical.size.width),
                @"height": @(logical.size.height),
            },
            @"native": @{
                @"width": @(native.size.width),
                @"height": @(native.size.height),
            },
            @"scale": @(screenScale),
            @"nativeScale": @(nativeScale),
            // This is intentionally UIKit's fixed logical canvas, not the
            // independently resizable simulator-scale AppKit host.
            @"window": @{
                @"width": @(windowBounds.size.width),
                @"height": @(windowBounds.size.height),
            },
            @"host": hostGeometry,
            @"safeArea": @{
                @"top": @(safeArea.top),
                @"left": @(safeArea.left),
                @"bottom": @(safeArea.bottom),
                @"right": @(safeArea.right),
            },
        };
        observed = @{
            @"screenBounds": @{
                @"x": @(logical.origin.x),
                @"y": @(logical.origin.y),
                @"width": @(logical.size.width),
                @"height": @(logical.size.height),
            },
            @"nativeBounds": @{
                @"x": @(native.origin.x),
                @"y": @(native.origin.y),
                @"width": @(native.size.width),
                @"height": @(native.size.height),
            },
            @"screenScale": @(screenScale),
            @"nativeScale": @(nativeScale),
            @"statusBarFrame":
                statusBarManager == nil
                    ? (id)NSNull.null
                    : @{
                        @"x": @(statusBarFrame.origin.x),
                        @"y": @(statusBarFrame.origin.y),
                        @"width": @(statusBarFrame.size.width),
                        @"height": @(statusBarFrame.size.height),
                    },
            @"applicationStatusBarFrame": @{
                @"x": @(applicationStatusBarFrame.origin.x),
                @"y": @(applicationStatusBarFrame.origin.y),
                @"width": @(applicationStatusBarFrame.size.width),
                @"height": @(applicationStatusBarFrame.size.height),
            },
            @"windowBounds":
                keyWindow == nil
                    ? (id)NSNull.null
                    : @{
                        @"x": @(windowBounds.origin.x),
                        @"y": @(windowBounds.origin.y),
                        @"width": @(windowBounds.size.width),
                        @"height": @(windowBounds.size.height),
                    },
            @"safeArea":
                keyWindow == nil
                    ? (id)NSNull.null
                    : @{
                        @"top": @(safeArea.top),
                        @"left": @(safeArea.left),
                        @"bottom": @(safeArea.bottom),
                        @"right": @(safeArea.right),
                    },
            @"deviceIdentity": @{
                @"model": deviceModel,
                @"localizedModel": localizedDeviceModel,
                @"deviceUserInterfaceIdiom": @(deviceIdiom),
                @"traitUserInterfaceIdiom": @(traitIdiom),
                @"deviceOrientation": @(deviceOrientation),
                @"sceneInterfaceOrientation": @(sceneOrientation),
                @"ready": @(deviceIdentityReady),
            },
            @"appKit": hooks[@"window"] ?: @{},
        };
        BOOL exact =
            fabs(logical.size.width -
                IOSUseRuntimeDeviceLogicalWidth) <= 0.01 &&
            fabs(logical.size.height -
                IOSUseRuntimeDeviceLogicalHeight) <= 0.01 &&
            fabs(native.size.width -
                IOSUseRuntimeDeviceNativeWidth) <= 0.01 &&
            fabs(native.size.height -
                IOSUseRuntimeDeviceNativeHeight) <= 0.01 &&
            fabs(screenScale - IOSUseRuntimeDeviceScale) <= 0.01 &&
            fabs(nativeScale - IOSUseRuntimeDeviceScale) <= 0.01 &&
            fabs(windowBounds.size.width -
                IOSUseRuntimeDeviceLogicalWidth) <= 0.01 &&
            fabs(windowBounds.size.height -
                IOSUseRuntimeDeviceLogicalHeight) <= 0.01 &&
            deviceIdentityReady &&
            requiredHooksReady &&
            [hooks[@"configurationStage"]
                isEqualToString:@"window-configured"] &&
            IOSUseHostGeometryReady(hostGeometry);
        stage = exact
            ? @"ready"
            : requiredHooksFailed
                ? @"required-hook-failed"
            : !requiredHooksReady
                ? @"waiting-for-required-hook-observation"
            : !deviceIdentityReady
                ? @"device-identity-mismatch"
            : [configurationStage isEqualToString:@"window-configured"]
                ? @"host-geometry-mismatch"
                : configurationStage ?: @"geometry-mismatch";
    };
    if (NSThread.isMainThread) {
        capture();
    } else {
        dispatch_sync(dispatch_get_main_queue(), capture);
    }
    NSDictionary<NSString *, id> *playChain =
        [PlayKeychain storageIdentity];
    if (requiredHooksReady &&
        ![playChain[@"status"] isEqualToString:@"ready"]) {
        stage = @"playchain-location-invalid";
    }
    NSDictionary<NSString *, id> *stdio =
        IOSUseRuntimeStdioEvidence();
    if (requiredHooksReady &&
        [stdio[@"status"] isEqualToString:@"failed"]) {
        stage = @"stdio-redirection-failed";
    }
    NSDictionary<NSString *, id> *identity = @{
        @"pid": @(getpid()),
        @"bundleIdentifier":
            NSBundle.mainBundle.bundleIdentifier ?: @"",
        @"executablePath":
            NSBundle.mainBundle.executablePath ?: @"",
        @"capabilities": IOSUseCapabilities(requiredHooksReady),
        @"geometry": geometry ?: @{},
        @"stage": stage ?: @"geometry-mismatch",
        @"stdio": stdio,
    };
    return @{
        @"identity": identity,
        @"observed": observed ?: @{},
        @"runtime": hooks ?: @{},
        @"playChain": playChain ?: @{},
    };
}

static NSDictionary<NSString *, id> *IOSUseInitialUISnapshot(void) {
    NSDictionary<NSString *, id> *uiState =
        IOSUseCurrentUIReadiness();
    BOOL requiredHooksReady =
        IOSUsePlayRuntimeRequiredHooksReady();
    NSDictionary<NSString *, id> *geometry = @{
        @"logical": @{
            @"width": @(IOSUsePlayDeviceLogicalWidth),
            @"height": @(IOSUsePlayDeviceLogicalHeight),
        },
        @"native": @{
            @"width": @(IOSUsePlayDeviceNativeWidth),
            @"height": @(IOSUsePlayDeviceNativeHeight),
        },
        @"scale": @(IOSUsePlayDeviceScale),
        @"nativeScale": @(IOSUsePlayDeviceScale),
        @"window": @{
            @"width": @0,
            @"height": @0,
        },
        @"host": NSNull.null,
        @"safeArea": @{
            @"top": @0,
            @"left": @0,
            @"bottom": @0,
            @"right": @0,
        },
    };
    return @{
        @"identity": @{
            @"pid": @(getpid()),
            @"bundleIdentifier":
                NSBundle.mainBundle.bundleIdentifier ?: @"",
            @"executablePath":
                NSBundle.mainBundle.executablePath ?: @"",
            @"capabilities":
                IOSUseCapabilities(requiredHooksReady),
            @"geometry": geometry,
            @"stage": uiState[@"stage"] ?: @"runtime-constructor",
            @"stdio": IOSUseRuntimeStdioEvidence(),
            @"uiState": uiState,
        },
        @"observed": @{},
        @"runtime": @{
            @"configurationStage":
                uiState[@"stage"] ?: @"runtime-constructor",
            @"configurationFailure":
                uiState[@"failure"] ?: NSNull.null,
        },
        @"playChain": @{},
    };
}

void IOSUsePlayRuntimePublishUIReadiness(void) {
    NSCAssert(
        NSThread.isMainThread,
        @"UI readiness publication is main-only"
    );
    NSDictionary<NSString *, id> *snapshot =
        IOSUseRuntimeSnapshot(
            IOSUsePlayRuntimeDiagnosticsScopeReadiness,
            nil,
            nil
        );
    NSDictionary<NSString *, id> *identity = snapshot[@"identity"];
    NSString *stage = [identity[@"stage"] isKindOfClass:NSString.class]
        ? identity[@"stage"]
        : @"geometry-mismatch";
    NSString *state = @"initializing";
    if ([stage isEqualToString:@"ready"]) {
        state = @"ready";
    } else if ([stage hasSuffix:@"-failed"] ||
               [stage isEqualToString:@"device-identity-mismatch"] ||
               [stage isEqualToString:@"playchain-location-invalid"]) {
        state = @"failed";
    }
    NSDictionary<NSString *, id> *availability =
        [IOSUsePlayAppKitBridge uiAutomationAvailability];
    NSString *availabilityReason =
        [availability[@"reason"] isKindOfClass:NSString.class]
            ? availability[@"reason"]
            : @"window-unavailable";
    if (![state isEqualToString:@"failed"] &&
        ![availability[@"available"] boolValue] &&
        ![availabilityReason isEqualToString:@"window-unavailable"]) {
        state = @"backgrounded";
        stage = availabilityReason;
    }
    NSDictionary<NSString *, id> *runtime = snapshot[@"runtime"];
    id rawFailure = runtime[@"configurationFailure"];
    NSString *failure = [rawFailure isKindOfClass:NSString.class]
        ? rawFailure
        : nil;
    IOSUsePlayRuntimeSetUIReadiness(state, stage, failure);
    NSDictionary<NSString *, id> *uiState =
        IOSUseCurrentUIReadiness();
    NSMutableDictionary<NSString *, id> *publishedIdentity =
        [identity mutableCopy];
    publishedIdentity[@"uiState"] = uiState;
    NSMutableDictionary<NSString *, id> *published =
        [snapshot mutableCopy];
    published[@"identity"] = publishedIdentity;
    os_unfair_lock_lock(&IOSUseRuntimeUIStateLock);
    IOSUseRuntimeUISnapshot = [published copy];
    os_unfair_lock_unlock(&IOSUseRuntimeUIStateLock);
}

static NSDictionary<NSString *, id> *IOSUseCachedUISnapshot(void) {
    os_unfair_lock_lock(&IOSUseRuntimeUIStateLock);
    NSDictionary<NSString *, id> *snapshot =
        [IOSUseRuntimeUISnapshot copy];
    os_unfair_lock_unlock(&IOSUseRuntimeUIStateLock);
    return snapshot ?: IOSUseInitialUISnapshot();
}

static NSDictionary<NSString *, id> *IOSUseControlHelloPayload(void) {
    BOOL requiredHooksReady =
        IOSUsePlayRuntimeRequiredHooksReady();
    NSDictionary<NSString *, id> *stdio =
        IOSUseRuntimeStdioEvidence();
    NSDictionary<NSString *, id> *playChain =
        [PlayKeychain storageIdentity];
    NSString *controlStage = @"ready";
    if (!requiredHooksReady) {
        controlStage = @"required-hook-failed";
    } else if (![playChain[@"status"] isEqualToString:@"ready"]) {
        controlStage = @"playchain-location-invalid";
    } else if ([stdio[@"status"] isEqualToString:@"failed"]) {
        controlStage = @"stdio-redirection-failed";
    }
    return @{
        @"pid": @(getpid()),
        @"bundleIdentifier":
            NSBundle.mainBundle.bundleIdentifier ?: @"",
        @"executablePath":
            NSBundle.mainBundle.executablePath ?: @"",
        @"installRevision": IOSUseRuntimeInstallRevision ?: @"",
        @"capabilities": IOSUseCapabilities(requiredHooksReady),
        @"controlStage": controlStage,
        @"controlFailure":
            IOSUsePlayRuntimeRequiredHooksFailure() ?: NSNull.null,
        @"uiState": IOSUseCurrentUIReadiness(),
        @"stdio": stdio,
    };
}

static BOOL IOSUseRuntimeJSONBoolean(id value) {
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) ==
            CFBooleanGetTypeID();
}

static void IOSUseRuntimeAppendPhotosInteraction(
    NSMutableArray<NSDictionary<NSString *, id> *> *interactions,
    NSDictionary<NSString *, id> *photos
) {
    NSUInteger outstandingCount =
        [photos[@"outstandingCount"] unsignedIntegerValue];
    if (outstandingCount == 0) {
        return;
    }
    NSDictionary<NSString *, id> *oldestRequest =
        [photos[@"pendingRequests"] isKindOfClass:NSArray.class]
            ? [photos[@"pendingRequests"] firstObject]
            : nil;
    [interactions addObject:@{
        @"type": @"pendingExternalInteraction",
        @"kind": @"photosAuthorization",
        @"pending": @YES,
        @"visibility": @"unknown",
        @"actionableByIOSUse": @NO,
        @"outstandingCount": @(outstandingCount),
        @"sequence":
            oldestRequest[@"sequence"] ?: NSNull.null,
        @"api": oldestRequest[@"api"] ?: NSNull.null,
        @"accessLevel":
            oldestRequest[@"accessLevel"] ?: NSNull.null,
        @"authorizationStatus":
            photos[@"authorizationStatus"] ?: NSNull.null,
        @"ageMicroseconds":
            oldestRequest[@"ageMicroseconds"] ?: NSNull.null,
        @"resolution": @"manual_or_computer_use",
    }];
}

static NSDictionary<NSString *, id> *
IOSUseRuntimeInteractionStateByReplacingPhotos(
    NSDictionary<NSString *, id> *state,
    NSDictionary<NSString *, id> *photos
) {
    NSMutableArray<NSDictionary<NSString *, id> *> *interactions =
        [NSMutableArray array];
    for (NSDictionary<NSString *, id> *interaction
         in state[@"interactions"]) {
        BOOL photosInteraction =
            [interaction[@"type"]
                isEqualToString:@"pendingExternalInteraction"] &&
            [interaction[@"kind"]
                isEqualToString:@"photosAuthorization"];
        if (!photosInteraction) {
            [interactions addObject:interaction];
        }
    }
    IOSUseRuntimeAppendPhotosInteraction(interactions, photos);
    return @{
        @"refreshComplete": @YES,
        @"refreshError": NSNull.null,
        @"blocking":
            interactions.count > 0 ? @YES : @NO,
        @"interactions": interactions,
    };
}

static NSDictionary<NSString *, id> *
IOSUseRuntimeInteractionSnapshotOnMainThread(
    uint64_t *photosStateVersion,
    NSDictionary<NSString *, id> **capturedNativeAlert,
    NSDictionary<NSString *, id> **capturedPhotosAuthorization
) {
    NSCParameterAssert(NSThread.isMainThread);
    NSDictionary<NSString *, id> *nativeAlert =
        [IOSUsePlayAppKitBridge nativeAlertSnapshot];
    NSDictionary<NSString *, id> *uikitAlert =
        IOSUsePlayRuntimeUIKitAlertSnapshot();

    NSMutableArray<NSDictionary<NSString *, id> *> *interactions =
        [NSMutableArray array];
    if ([nativeAlert[@"candidateVisible"] boolValue]) {
        [interactions addObject:@{
            @"type": @"inProcessAlert",
            @"owner": @"targetApp",
            @"visible": @YES,
            @"actionableByIOSUse":
                [nativeAlert[@"actionableByIOSUse"] boolValue]
                    ? @YES
                    : @NO,
            @"source":
                nativeAlert[@"source"] ?: @"appkitNativeUnresolved",
            @"text": nativeAlert[@"text"] ?: @"",
            @"actions": nativeAlert[@"actions"] ?: @[],
            @"windowClass":
                nativeAlert[@"windowClass"] ?: NSNull.null,
            @"windowNumber":
                nativeAlert[@"windowNumber"] ?: NSNull.null,
            @"frame": nativeAlert[@"frame"] ?: NSNull.null,
            @"suggestedCommand":
                @"ios-use dismissAlert --label <exact-label>",
        }];
    } else if ([uikitAlert[@"visible"] boolValue]) {
        [interactions addObject:@{
            @"type": @"inProcessAlert",
            @"owner": @"targetApp",
            @"visible": @YES,
            @"actionableByIOSUse":
                [uikitAlert[@"actionableByIOSUse"] boolValue]
                    ? @YES
                    : @NO,
            @"source": uikitAlert[@"source"] ?: @"uikit",
            @"text": uikitAlert[@"text"] ?: @"",
            @"actions": uikitAlert[@"actions"] ?: @[],
            @"controllerClass":
                uikitAlert[@"controllerClass"] ?: NSNull.null,
            @"suggestedCommand":
                @"ios-use dismissAlert --label <exact-label>",
        }];
    }

    NSDictionary<NSString *, id> *photos =
        IOSUsePlayRuntimePhotosAuthorizationDiagnostics();
    if (capturedNativeAlert != NULL) {
        *capturedNativeAlert = nativeAlert;
    }
    if (capturedPhotosAuthorization != NULL) {
        *capturedPhotosAuthorization = photos;
    }
    if (photosStateVersion != NULL) {
        *photosStateVersion =
            [photos[@"stateVersion"] unsignedLongLongValue];
    }
    IOSUseRuntimeAppendPhotosInteraction(interactions, photos);

    return @{
        @"refreshComplete": @YES,
        @"refreshError": NSNull.null,
        @"blocking":
            interactions.count > 0 ? @YES : @NO,
        @"interactions": interactions,
    };
}

static NSDictionary<NSString *, id> *
IOSUseRuntimeInteractionGateError(
    NSString *code,
    NSString *message,
    NSArray<NSString *> *suggestions,
    NSDictionary<NSString *, id> *interactionState
) {
    NSMutableDictionary<NSString *, id> *details =
        [IOSUseErrorObject(
            code,
            message,
            @"interaction",
            @"precondition",
            NO
        )[@"details"] mutableCopy];
    details[@"suggestions"] = suggestions ?: @[];
    NSArray<NSDictionary<NSString *, id> *> *interactions =
        interactionState[@"interactions"];
    NSDictionary<NSString *, id> *alert = nil;
    for (NSDictionary<NSString *, id> *interaction in interactions) {
        if ([interaction[@"type"]
                isEqualToString:@"inProcessAlert"]) {
            alert = interaction;
            break;
        }
    }
    if (alert != nil) {
        details[@"alert"] = alert;
    }
    return @{
        @"code": code,
        @"message": message,
        @"details": details,
    };
}

static BOOL IOSUseRuntimeIsAtomicMutationCommand(
    NSString *command
) {
    return [command isEqualToString:@"tap"] ||
        [command isEqualToString:@"longPress"] ||
        [command isEqualToString:@"swipe"] ||
        [command isEqualToString:@"input"];
}

static NSDictionary<NSString *, id> * _Nullable
IOSUseRuntimeGateCommand(
    NSString *command,
    NSDictionary<NSString *, id> *interactionState
) {
    if (![interactionState[@"blocking"] boolValue]) {
        return nil;
    }
    BOOL hasInProcessAlert = NO;
    BOOL hasPendingExternalInteraction = NO;
    for (NSDictionary<NSString *, id> *interaction
         in interactionState[@"interactions"]) {
        hasInProcessAlert |= [interaction[@"type"]
            isEqualToString:@"inProcessAlert"];
        hasPendingExternalInteraction |= [interaction[@"type"]
            isEqualToString:@"pendingExternalInteraction"];
    }
    BOOL dismissCommand =
        [command isEqualToString:@"dismissAlert"] ||
        [command isEqualToString:@"dismissAlertByLabel"];
    if (dismissCommand) {
        if (hasInProcessAlert) {
            return nil;
        }
        if (hasPendingExternalInteraction) {
            return IOSUseRuntimeInteractionGateError(
                @"photos_permission_interaction_required",
                @"a PhotoKit authorization request is outstanding and may require external macOS interaction; ios-use does not inspect or click process-external windows",
                @[
                    @"Approve or deny the macOS prompt manually or with Computer Use, then retry the command.",
                ],
                interactionState
            );
        }
    }

    if (!IOSUseRuntimeIsAtomicMutationCommand(command)) {
        return nil;
    }
    if (hasInProcessAlert) {
        return IOSUseRuntimeInteractionGateError(
            @"preexisting_alert",
            @"a visible App-owned alert blocks this mutation; use dismissAlert with an explicit selection",
            @[
                @"Run ios-use dismissAlert with --label, --index, --only-button, or --primary.",
            ],
            interactionState
        );
    }
    return IOSUseRuntimeInteractionGateError(
        @"photos_permission_interaction_required",
        @"a PhotoKit authorization request is outstanding and may require external macOS interaction; the mutation was not dispatched",
        @[
            @"Approve or deny the macOS prompt manually or with Computer Use, then retry the command.",
        ],
        interactionState
    );
}

static NSDictionary<NSString *, id> *
IOSUseRuntimeResponseWithMetadata(
    NSDictionary<NSString *, id> *response,
    NSDictionary<NSString *, id> * _Nullable interactionState,
    NSNumber * _Nullable alertRefreshElapsedMs
) {
    NSMutableDictionary<NSString *, id> *result =
        [response mutableCopy];
    result[@"interactionState"] =
        interactionState ?: NSNull.null;
    result[@"performance"] = @{
        @"alertRefreshElapsedMs":
            alertRefreshElapsedMs ?: NSNull.null,
    };
    return result;
}

static NSDictionary<NSString *, id> *IOSUseSuccessEnvelope(
    NSString *requestID,
    NSDictionary<NSString *, id> *payload
) {
    return @{
        @"requestId": requestID,
        @"sessionID": IOSUseRuntimeSessionID,
        @"ok": @YES,
        @"payload": payload,
    };
}

static NSDictionary<NSString *, id> *IOSUseHandleScreenshot(
    NSString *requestID
) {
    __block NSDictionary<NSString *, id> *screenshot;
    __block NSDictionary<NSString *, id> *dom;
    __block NSDictionary<NSString *, id> *domError;
    __block NSDictionary<NSString *, id> *readinessError;
    __block NSString *failureCode;
    __block NSString *failureMessage;
    void (^capture)(void) = ^{
        readinessError = IOSUsePlayRuntimeUICommandError();
        if (readinessError != nil) {
            return;
        }
        // One main-queue turn is deliberate: no run-loop event can occur
        // between compositor capture and its matching fresh DOM snapshot.
        screenshot = IOSUsePlayRuntimeScreenshotCommand(
            &failureCode,
            &failureMessage
        );
        if (screenshot != nil) {
            dom = IOSUsePlayRuntimeDOMCommand(
                @{
                    @"raw": @NO,
                    @"fresh": @YES,
                    @"waitQuiescence": @NO,
                },
                &domError
            );
        }
    };
    if (NSThread.isMainThread) {
        capture();
    } else {
        dispatch_sync(dispatch_get_main_queue(), capture);
    }
    if (readinessError != nil) {
        return IOSUseErrorEnvelope(requestID, readinessError);
    }
    if (screenshot == nil) {
        return IOSUseBasicErrorEnvelope(
            requestID,
            failureCode ?: @"screenshot_unavailable",
            failureMessage ?: @"own-window compositor capture failed",
            @"capture",
            @"compositor",
            YES
        );
    }
    if (dom == nil ||
        ![dom[@"snapshotGeneration"] isKindOfClass:NSNumber.class]) {
        return IOSUseErrorEnvelope(
            requestID,
            domError ?: IOSUseErrorObject(
                @"snapshot_failed",
                @"fresh DOM failed in the compositor capture turn",
                @"lookup",
                @"snapshot",
                YES
            )
        );
    }
    NSMutableDictionary<NSString *, id> *typed =
        [screenshot mutableCopy];
    typed[@"snapshotGeneration"] = dom[@"snapshotGeneration"];
    return IOSUseSuccessEnvelope(
        requestID,
        @{
            @"screenshot": typed,
            @"dom": dom,
        }
    );
}

static BOOL IOSUseWriteFridaEventFrame(
    int connection,
    NSString *requestID,
    NSString *sessionID,
    NSString *kind,
    NSString *display
) {
    NSDictionary<NSString *, id> *frame = @{
        @"requestId": requestID ?: @"",
        @"sessionID": sessionID ?: @"",
        @"event": @"debug",
        @"kind": kind ?: @"event",
        @"display": display ?: @"",
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:frame
                                                     options:0
                                                       error:NULL];
    if (data == nil || data.length == 0 ||
        data.length > IOSUseMaximumResponseFrameSize) {
        return NO;
    }
    uint32_t length = htonl((uint32_t)data.length);
    return IOSUseWriteExactly(connection, &length, sizeof(length)) &&
        IOSUseWriteExactly(connection, data.bytes, data.length);
}

static void IOSUseFridaSocketEventCallback(
    const char *kind,
    const char *display,
    void *context
) {
    IOSUseFridaSocketEventContext *eventContext =
        (__bridge IOSUseFridaSocketEventContext *)context;
    if (eventContext == nil) {
        return;
    }
    @autoreleasepool {
        NSString *eventKind = kind == NULL
            ? @"event"
            : [NSString stringWithUTF8String:kind] ?: @"event";
        NSString *eventDisplay = display == NULL
            ? @""
            : [NSString stringWithUTF8String:display] ?: @"";
        [eventContext.writeLock lock];
        (void)IOSUseWriteFridaEventFrame(
                eventContext.connection,
                eventContext.requestID,
                eventContext.sessionID,
                eventKind,
                eventDisplay
            );
        [eventContext.writeLock unlock];
    }
}

static BOOL IOSUseRuntimeIsUICommand(NSString *command) {
    static NSSet<NSString *> *commands;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        commands = [NSSet setWithArray:@[
            @"screenshot",
            @"dom",
            @"uiTree",
            @"waitFor",
            @"tap",
            @"longPress",
            @"swipe",
            @"input",
            @"dismissAlert",
            @"dismissAlertByLabel",
        ]];
    });
    return [commands containsObject:command];
}

static NSDictionary<NSString *, id> *
IOSUseRuntimeUIReadinessErrorObject(
    NSDictionary<NSString *, id> *uiState
) {
    NSString *state = [uiState[@"state"] isKindOfClass:NSString.class]
        ? uiState[@"state"]
        : @"initializing";
    NSString *stage = [uiState[@"stage"] isKindOfClass:NSString.class]
        ? uiState[@"stage"]
        : @"runtime-constructor";
    BOOL failed = [state isEqualToString:@"failed"];
    BOOL backgrounded = [state isEqualToString:@"backgrounded"];
    id rawFailure = uiState[@"failure"];
    NSString *failure = [rawFailure isKindOfClass:NSString.class]
        ? rawFailure
        : nil;
    return @{
        @"code": failed
            ? @"runtime_ui_failed"
            : backgrounded
                ? @"runtime_ui_backgrounded"
                : @"runtime_ui_not_ready",
        @"message": failed
            ? failure ?: @"Runtime UI initialization failed"
            : backgrounded
                ? [NSString stringWithFormat:
                    @"Runtime UI is not available: %@",
                    stage]
                : @"Runtime UI is still initializing; retry this command",
        @"details": @{
            @"category": @"precondition",
            @"phase": stage,
            @"reason": backgrounded ? stage : (id)NSNull.null,
            @"retryable": @((BOOL)!failed),
            @"fatal": @(failed),
            @"candidateCount": @0,
            @"candidates": @[],
            @"suggestions": failed
                ? @[]
                : backgrounded
                    ? @[@"make the App window visible on the active Space, then retry"]
                    : @[@"retry the same UI command"],
        },
    };
}

NSDictionary<NSString *, id> *IOSUsePlayRuntimeUICommandError(void) {
    NSCAssert(
        NSThread.isMainThread,
        @"UI command readiness validation is main-only"
    );
    NSDictionary<NSString *, id> *uiState = IOSUseCurrentUIReadiness();
    if ([uiState[@"state"] isEqualToString:@"failed"]) {
        return IOSUseRuntimeUIReadinessErrorObject(uiState);
    }
    NSDictionary<NSString *, id> *availability =
        [IOSUsePlayAppKitBridge uiAutomationAvailability];
    if (![availability[@"available"] boolValue]) {
        NSString *reason =
            [availability[@"reason"] isKindOfClass:NSString.class]
                ? availability[@"reason"]
                : @"window-unavailable";
        if ([reason isEqualToString:@"window-unavailable"] &&
            [uiState[@"state"] isEqualToString:@"initializing"]) {
            return IOSUseRuntimeUIReadinessErrorObject(uiState);
        }
        IOSUsePlayRuntimeSetUIReadiness(
            @"backgrounded",
            reason,
            nil
        );
        return IOSUseRuntimeUIReadinessErrorObject(
            IOSUseCurrentUIReadiness()
        );
    }
    if (![uiState[@"state"] isEqualToString:@"ready"]) {
        IOSUsePlayRuntimePublishUIReadiness();
        uiState = IOSUseCurrentUIReadiness();
    }
    if ([uiState[@"state"] isEqualToString:@"ready"]) {
        return nil;
    }
    return IOSUseRuntimeUIReadinessErrorObject(uiState);
}

static NSDictionary<NSString *, id> *IOSUseHandleRequestBody(
    id object,
    int connection,
    NSDictionary<NSString *, id> * _Nullable *interactionState,
    NSNumber * _Nullable *alertRefreshElapsedMs,
    void * _Nullable fridaEventContext,
    BOOL * _Nullable fridaEventSubscription
) {
    if (interactionState != NULL) {
        *interactionState = nil;
    }
    if (alertRefreshElapsedMs != NULL) {
        *alertRefreshElapsedMs = nil;
    }
    if (fridaEventSubscription != NULL) {
        *fridaEventSubscription = NO;
    }
    if (![object isKindOfClass:NSDictionary.class]) {
        return IOSUseBasicErrorEnvelope(
            @"",
            @"invalid_request",
            @"request must be a JSON object",
            @"protocol",
            @"validation",
            NO
        );
    }
    NSDictionary<NSString *, id> *request = object;
    NSString *requestID = IOSUseIsNonemptyString(request[@"requestId"])
        ? request[@"requestId"]
        : @"";
    NSSet<NSString *> *requiredKeys = [NSSet setWithArray:@[
        @"requestId",
        @"sessionID",
        @"command",
        @"arguments",
    ]];
    NSMutableSet<NSString *> *actualKeys =
        [NSMutableSet setWithArray:request.allKeys];
    [actualKeys removeObject:@"refreshAlertStatus"];
    id refreshAlertStatus = request[@"refreshAlertStatus"];
    if (![actualKeys isEqualToSet:requiredKeys] ||
        (request.count != requiredKeys.count &&
         request.count != requiredKeys.count + 1) ||
        (refreshAlertStatus != nil &&
         !IOSUseRuntimeJSONBoolean(refreshAlertStatus)) ||
        requestID.length == 0 ||
        requestID.length > 256 ||
        !IOSUseIsNonemptyString(request[@"sessionID"]) ||
        !IOSUseIsNonemptyString(request[@"command"]) ||
        ![request[@"arguments"] isKindOfClass:NSDictionary.class]) {
        return IOSUseBasicErrorEnvelope(
            requestID,
            @"invalid_request",
            @"request does not match the Runtime command contract",
            @"protocol",
            @"validation",
            NO
        );
    }
    if (![request[@"sessionID"]
            isEqualToString:IOSUseRuntimeSessionID]) {
        return IOSUseBasicErrorEnvelope(
            requestID,
            @"unauthorized_session",
            @"sessionID does not match the active Runtime",
            @"protocol",
            @"authentication",
            NO
        );
    }
    NSString *command = request[@"command"];
    NSDictionary<NSString *, id> *arguments = request[@"arguments"];
    __block NSDictionary<NSString *, id>
        *preexecutedAutomationResult = nil;
    __block NSDictionary<NSString *, id>
        *preexecutedAutomationError = nil;
    __block uint64_t freshPhotosStateVersion = 0;
    __block BOOL photosMutationLinearized = NO;
    __block NSDictionary<NSString *, id>
        *freshNativeAlertSnapshot = nil;
    __block NSDictionary<NSString *, id>
        *freshPhotosAuthorizationDiagnostics = nil;
    BOOL preexecuteAutomation =
        [refreshAlertStatus boolValue] &&
        IOSUseRuntimeIsAtomicMutationCommand(command);
    BOOL shouldRefreshAlertStatus =
        [refreshAlertStatus boolValue] &&
        ![@[@"hello", @"ping", @"diagnostics"]
            containsObject:command] &&
        ![command isEqualToString:@"waitFor"];
    if (shouldRefreshAlertStatus) {
        NSTimeInterval refreshStarted =
            NSProcessInfo.processInfo.systemUptime;
        __block NSDictionary<NSString *, id>
            *freshInteractionState = nil;
        __block NSDictionary<NSString *, id> *gateError = nil;
        __block NSNumber *measuredRefreshElapsedMs = nil;
        NSLock *executionLock = [NSLock new];
        __block BOOL executionCancelled = NO;
        __block BOOL automationStarted = NO;
        void (^refreshAndMaybeExecute)(void) = ^{
            [executionLock lock];
            BOOL shouldRefresh = !executionCancelled;
            [executionLock unlock];
            if (!shouldRefresh) {
                return;
            }
            uint64_t capturedPhotosStateVersion = 0;
            NSDictionary<NSString *, id> *capturedNativeAlert = nil;
            NSDictionary<NSString *, id>
                *capturedPhotosAuthorization = nil;
            NSDictionary<NSString *, id> *capturedState = nil;
            NSDictionary<NSString *, id> *capturedGateError =
                IOSUseRuntimeIsUICommand(command)
                    ? IOSUsePlayRuntimeUICommandError()
                    : nil;
            if (capturedGateError != nil) {
                NSString *refreshError =
                    [capturedGateError[@"code"]
                        isKindOfClass:NSString.class]
                        ? capturedGateError[@"code"]
                        : @"runtime_ui_not_ready";
                capturedState = @{
                    @"refreshComplete": @NO,
                    @"refreshError": refreshError,
                    @"blocking": @NO,
                    @"interactions": @[],
                };
            } else {
                capturedState =
                    IOSUseRuntimeInteractionSnapshotOnMainThread(
                        &capturedPhotosStateVersion,
                        &capturedNativeAlert,
                        &capturedPhotosAuthorization
                    );
                capturedGateError = IOSUseRuntimeGateCommand(
                    command,
                    capturedState
                );
            }
            BOOL capturedPhotosMutationLinearized = NO;
            if (capturedGateError == nil &&
                preexecuteAutomation) {
                NSDictionary<NSString *, id> *blockingPhotos = nil;
                capturedPhotosMutationLinearized =
                    IOSUsePlayRuntimeTryLinearizePhotosMutation(
                        capturedPhotosStateVersion,
                        &blockingPhotos
                    );
                if (!capturedPhotosMutationLinearized) {
                    capturedState =
                        IOSUseRuntimeInteractionStateByReplacingPhotos(
                            capturedState,
                            blockingPhotos ?: @{}
                        );
                    capturedGateError =
                        IOSUseRuntimeGateCommand(
                            command,
                            capturedState
                        );
                }
            }
            NSNumber *capturedElapsedMs = @(
                (NSProcessInfo.processInfo.systemUptime -
                    refreshStarted) * 1000.0
            );
            [executionLock lock];
            freshInteractionState = capturedState;
            measuredRefreshElapsedMs = capturedElapsedMs;
            gateError = capturedGateError;
            freshPhotosStateVersion =
                capturedPhotosStateVersion;
            freshNativeAlertSnapshot =
                capturedNativeAlert;
            freshPhotosAuthorizationDiagnostics =
                capturedPhotosAuthorization;
            photosMutationLinearized =
                capturedPhotosMutationLinearized;
            BOOL shouldExecute =
                !executionCancelled &&
                capturedGateError == nil &&
                preexecuteAutomation &&
                capturedPhotosMutationLinearized;
            if (shouldExecute) {
                automationStarted = YES;
            }
            [executionLock unlock];
            if (shouldExecute) {
                NSDictionary<NSString *, id> *localError = nil;
                NSDictionary<NSString *, id> *localResult =
                    IOSUsePlayRuntimeAutomationCommand(
                        command,
                        arguments,
                        &localError
                    );
                [executionLock lock];
                preexecutedAutomationResult = localResult;
                preexecutedAutomationError = localError;
                [executionLock unlock];
            }
        };
        BOOL mainThreadTimedOut = NO;
        if (NSThread.isMainThread) {
            refreshAndMaybeExecute();
        } else {
            dispatch_semaphore_t completion =
                dispatch_semaphore_create(0);
            dispatch_async(dispatch_get_main_queue(), ^{
                refreshAndMaybeExecute();
                dispatch_semaphore_signal(completion);
            });
            dispatch_time_t deadline = dispatch_time(
                DISPATCH_TIME_NOW,
                (int64_t)(
                    IOSUsePlayRuntimeAutomationMainThreadTimeout()
                    * NSEC_PER_SEC
                )
            );
            mainThreadTimedOut =
                dispatch_semaphore_wait(completion, deadline) != 0;
        }
        if (mainThreadTimedOut) {
            [executionLock lock];
            executionCancelled = YES;
            BOOL mutationMayHaveApplied = automationStarted;
            NSDictionary<NSString *, id> *capturedState =
                freshInteractionState;
            NSNumber *capturedElapsedMs =
                measuredRefreshElapsedMs;
            [executionLock unlock];
            if (capturedState == nil) {
                capturedState = @{
                    @"refreshComplete": @NO,
                    @"refreshError": @"main_thread_timeout",
                    @"blocking": @NO,
                    @"interactions": @[],
                };
            }
            if (capturedElapsedMs == nil) {
                capturedElapsedMs = @(
                    (NSProcessInfo.processInfo.systemUptime -
                        refreshStarted) * 1000.0
                );
            }
            if (interactionState != NULL) {
                *interactionState = capturedState;
            }
            if (alertRefreshElapsedMs != NULL) {
                *alertRefreshElapsedMs = capturedElapsedMs;
            }
            return IOSUseErrorEnvelope(
                requestID,
                IOSUseErrorObject(
                    @"main_thread_timeout",
                    mutationMayHaveApplied
                        ? @"Runtime main-thread automation exceeded its deadline after dispatch began"
                        : @"Runtime main thread did not complete the alert refresh before its deadline",
                    mutationMayHaveApplied
                        ? @"action"
                        : @"timeout",
                    mutationMayHaveApplied
                        ? @"dispatch"
                        : @"alert_refresh",
                    YES
                )
            );
        }
        if (interactionState != NULL) {
            *interactionState = freshInteractionState;
        }
        if (alertRefreshElapsedMs != NULL) {
            *alertRefreshElapsedMs =
                measuredRefreshElapsedMs;
        }
        if (gateError != nil) {
            return IOSUseErrorEnvelope(requestID, gateError);
        }
        if (IOSUseRuntimeIsAtomicMutationCommand(command) &&
            !photosMutationLinearized) {
            NSDictionary<NSString *, id> *blockingPhotos = nil;
            photosMutationLinearized =
                IOSUsePlayRuntimeTryLinearizePhotosMutation(
                    freshPhotosStateVersion,
                    &blockingPhotos
                );
            if (!photosMutationLinearized) {
                freshInteractionState =
                    IOSUseRuntimeInteractionStateByReplacingPhotos(
                        freshInteractionState,
                        blockingPhotos ?: @{}
                    );
                measuredRefreshElapsedMs = @(
                    (NSProcessInfo.processInfo.systemUptime -
                        refreshStarted) * 1000.0
                );
                if (interactionState != NULL) {
                    *interactionState =
                        freshInteractionState;
                }
                if (alertRefreshElapsedMs != NULL) {
                    *alertRefreshElapsedMs =
                        measuredRefreshElapsedMs;
                }
                return IOSUseErrorEnvelope(
                    requestID,
                    IOSUseRuntimeGateCommand(
                        command,
                        freshInteractionState
                    ) ?: IOSUseErrorObject(
                        @"photos_permission_interaction_required",
                        @"a PhotoKit authorization request became outstanding before mutation dispatch",
                        @"interaction",
                        @"precondition",
                        NO
                    )
                );
            }
        }
        if (preexecuteAutomation &&
            preexecutedAutomationResult == nil) {
            return IOSUseErrorEnvelope(
                requestID,
                preexecutedAutomationError ?:
                    IOSUseErrorObject(
                        @"automation_failed",
                        @"Runtime automation failed",
                        @"interaction",
                        @"dispatch",
                        YES
                    )
            );
        }
    }
    NSMutableDictionary<NSString *, id> *payload =
        [NSMutableDictionary dictionary];
    if ([command isEqualToString:@"hello"]) {
        if (arguments.count != 0) {
            return IOSUseBasicErrorEnvelope(
                requestID,
                @"invalid_arguments",
                @"hello requires an empty arguments object",
                @"validation",
                @"validation",
                NO
            );
        }
        payload = [IOSUseControlHelloPayload() mutableCopy];
    } else if ([command isEqualToString:@"ping"]) {
        if (arguments.count != 0) {
            return IOSUseBasicErrorEnvelope(
                requestID,
                @"invalid_arguments",
                @"ping requires an empty arguments object",
                @"validation",
                @"validation",
                NO
            );
        }
        payload[@"pid"] = @(getpid());
        payload[@"bundleIdentifier"] =
            NSBundle.mainBundle.bundleIdentifier ?: @"";
        payload[@"executablePath"] =
            NSBundle.mainBundle.executablePath ?: @"";
        payload[@"pong"] = @YES;
    } else if ([command isEqualToString:@"diagnostics"]) {
        if (arguments.count != 0) {
            return IOSUseBasicErrorEnvelope(
                requestID,
                @"invalid_arguments",
                @"diagnostics requires an empty arguments object",
                @"validation",
                @"validation",
                NO
            );
        }
        NSDictionary<NSString *, id> *snapshot =
            IOSUseCachedUISnapshot();
        payload = [snapshot[@"identity"] mutableCopy];
        payload[@"uiState"] = IOSUseCurrentUIReadiness();
        payload[@"stdio"] = IOSUseRuntimeStdioEvidence();
        payload[@"diagnostics"] = @{
            @"runtime": snapshot[@"runtime"],
            @"socket": IOSUsePlayRuntimeSocketIdentity(),
            @"observed": snapshot[@"observed"],
            @"playChain": snapshot[@"playChain"],
        };
    } else if ([command isEqualToString:@"debug"]) {
        NSDictionary<NSString *, id> *commandError = nil;
        NSDictionary<NSString *, id> *debug =
            IOSUsePlayRuntimeFridaDebugCommand(
                arguments,
                IOSUseFridaSocketEventCallback,
                fridaEventContext,
                [arguments[@"stream"] boolValue],
                &commandError
            );
        if (debug == nil) {
            return IOSUseErrorEnvelope(
                requestID,
                commandError ?: IOSUseErrorObject(
                    @"frida_eval_failed",
                    @"Frida Engine debug evaluation failed",
                    @"capability",
                    @"debug",
                    YES
                )
            );
        }
        if (fridaEventSubscription != NULL &&
            [arguments[@"stream"] boolValue]) {
            *fridaEventSubscription = YES;
        }
        payload[@"debug"] = debug;
    } else if ([command isEqualToString:@"screenshot"]) {
        if (arguments.count != 0) {
            return IOSUseBasicErrorEnvelope(
                requestID,
                @"invalid_arguments",
                @"screenshot requires an empty arguments object",
                @"validation",
                @"validation",
                NO
            );
        }
        return IOSUseHandleScreenshot(requestID);
    } else if ([command isEqualToString:@"dom"]) {
        NSDictionary<NSString *, id> *commandError = nil;
        NSDictionary<NSString *, id> *dom =
            IOSUsePlayRuntimeDOMCommand(arguments, &commandError);
        if (dom == nil) {
            return IOSUseErrorEnvelope(
                requestID,
                commandError ?: IOSUseErrorObject(
                    @"snapshot_failed",
                    @"Runtime DOM snapshot failed",
                    @"lookup",
                    @"snapshot",
                    YES
                )
            );
        }
        payload[@"dom"] = dom;
    } else if ([command isEqualToString:@"uiTree"]) {
        NSDictionary<NSString *, id> *commandError = nil;
        NSDictionary<NSString *, id> *uiTree =
            IOSUsePlayRuntimeViewTreeCommand(arguments, &commandError);
        if (uiTree == nil) {
            return IOSUseErrorEnvelope(
                requestID,
                commandError ?: IOSUseErrorObject(
                    @"ui_tree_snapshot_failed",
                    @"Runtime UIKit view hierarchy snapshot failed",
                    @"lookup",
                    @"snapshot",
                    YES
                )
            );
        }
        payload[@"uiTree"] = uiTree;
    } else if ([command isEqualToString:@"waitFor"]) {
        NSDictionary<NSString *, id> *commandError = nil;
        NSDictionary<NSString *, id> *waitFor =
            IOSUsePlayRuntimeWaitForCommand(
                arguments,
                ^BOOL{
                    return IOSUseSocketPeerDisconnected(connection);
                },
                &commandError
            );
        if (waitFor == nil) {
            return IOSUseErrorEnvelope(
                requestID,
                commandError ?: IOSUseErrorObject(
                    @"wait_failed",
                    @"Runtime waitFor failed",
                    @"lookup",
                    @"wait",
                    YES
                )
            );
        }
        payload[@"waitFor"] = waitFor;
    } else if (
        [@[
            @"tap",
            @"longPress",
            @"swipe",
            @"input",
            @"dismissAlert",
            @"dismissAlertByLabel",
        ] containsObject:command]
    ) {
        NSDictionary<NSString *, id> *commandError =
            preexecutedAutomationError;
        NSDictionary<NSString *, id> *result =
            preexecuteAutomation
                ? preexecutedAutomationResult
                : IOSUsePlayRuntimeAutomationCommand(
                    command,
                    arguments,
                    &commandError
                );
        if (result == nil) {
            return IOSUseErrorEnvelope(
                requestID,
                commandError ?: IOSUseErrorObject(
                    @"automation_failed",
                    @"Runtime automation failed",
                    @"interaction",
                    @"dispatch",
                    YES
                )
            );
        }
        payload[command] = result;
    } else {
        return IOSUseBasicErrorEnvelope(
            requestID,
            @"unsupported_command",
            @"Runtime supports hello, ping, diagnostics, screenshot, dom, waitFor, tap, longPress, swipe, input, dismissAlert, dismissAlertByLabel, and debug",
            @"protocol",
            @"dispatch",
            NO
        );
    }
    return IOSUseSuccessEnvelope(requestID, payload);
}

static NSDictionary<NSString *, id> *IOSUseHandleRequest(
    id object,
    int connection,
    void * _Nullable fridaEventContext,
    BOOL * _Nullable fridaEventSubscription
) {
    NSDictionary<NSString *, id> *interactionState = nil;
    NSNumber *alertRefreshElapsedMs = nil;
    NSDictionary<NSString *, id> *response =
        IOSUseHandleRequestBody(
            object,
            connection,
            &interactionState,
            &alertRefreshElapsedMs,
            fridaEventContext,
            fridaEventSubscription
        );
    return IOSUseRuntimeResponseWithMetadata(
        response,
        interactionState,
        alertRefreshElapsedMs
    );
}

static void IOSUseWriteResponse(
    int connection,
    NSDictionary<NSString *, id> *response
) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization
        dataWithJSONObject:response
                   options:0
                     error:&error];
    if (data == nil || data.length > IOSUseMaximumResponseFrameSize) {
        NSString *requestID = IOSUseIsNonemptyString(
            response[@"requestId"]
        ) ? response[@"requestId"] : @"";
        NSMutableDictionary<NSString *, id> *fallback =
            [IOSUseBasicErrorEnvelope(
            requestID,
            data == nil ? @"internal_failure" : @"response_too_large",
            data == nil
                ? @"Runtime response could not be encoded"
                : @"Runtime response exceeded 16 MiB",
            @"internal",
            @"encoding",
            NO
        ) mutableCopy];
        fallback[@"interactionState"] =
            response[@"interactionState"] ?: NSNull.null;
        fallback[@"performance"] =
            response[@"performance"] ?: NSNull.null;
        response = fallback;
        data = [NSJSONSerialization
            dataWithJSONObject:response
                       options:0
                         error:NULL];
    }
    if (data == nil || data.length > IOSUseMaximumResponseFrameSize) {
        return;
    }
    uint32_t length = htonl((uint32_t)data.length);
    if (!IOSUseWriteExactly(connection, &length, sizeof(length))) {
        return;
    }
    (void)IOSUseWriteExactly(connection, data.bytes, data.length);
}

static void IOSUseServeConnection(int connection) {
    if (!IOSUseConfigureSocket(connection, YES)) {
        return;
    }
    uid_t peerUser = (uid_t)-1;
    gid_t peerGroup = (gid_t)-1;
    if (getpeereid(connection, &peerUser, &peerGroup) != 0 ||
        peerUser != geteuid()) {
        NSLog(@"[ios-use-play] rejected Runtime socket peer");
        return;
    }
    uint32_t networkLength = 0;
    if (!IOSUseReadExactly(
            connection,
            &networkLength,
            sizeof(networkLength)
        )) {
        return;
    }
    uint32_t frameLength = ntohl(networkLength);
    if (frameLength == 0 ||
        frameLength > IOSUseMaximumRequestFrameSize) {
        IOSUseWriteResponse(
            connection,
            IOSUseBasicErrorEnvelope(
                @"",
                @"invalid_frame",
                @"request frame must be between 1 and 65536 bytes",
                @"protocol",
                @"framing",
                NO
            )
        );
        return;
    }
    NSMutableData *frame =
        [NSMutableData dataWithLength:frameLength];
    if (!IOSUseReadExactly(
            connection,
            frame.mutableBytes,
            frameLength
        )) {
        return;
    }
    IOSUseClearReadTimeout(connection);
    NSString *utf8 = [[NSString alloc]
        initWithData:frame
             encoding:NSUTF8StringEncoding];
    NSError *error = nil;
    id object = utf8 == nil
        ? nil
        : [NSJSONSerialization JSONObjectWithData:frame
                                          options:0
                                            error:&error];
    IOSUseFridaSocketEventContext *fridaEventContext = [IOSUseFridaSocketEventContext new];
    fridaEventContext.connection = connection;
    fridaEventContext.writeLock = [NSLock new];
    fridaEventContext.requestID = [object isKindOfClass:NSDictionary.class]
        ? (IOSUseIsNonemptyString(object[@"requestId"]) ? object[@"requestId"] : @"")
        : @"";
    fridaEventContext.sessionID = IOSUseRuntimeSessionID ?: @"";
    __block BOOL fridaEventSubscription = NO;
    __block NSDictionary<NSString *, id> *response = nil;
    if (object == nil) {
        response = IOSUseBasicErrorEnvelope(
            @"",
            @"invalid_json",
            utf8 == nil
                ? @"request frame is not valid UTF-8"
                : @"request frame is not valid JSON",
            @"protocol",
            @"decoding",
            NO
        );
    } else {
        dispatch_queue_t commandQueue = IOSUseRuntimeCommandQueue;
        NSString *command = [object isKindOfClass:NSDictionary.class] &&
                [object[@"command"] isKindOfClass:NSString.class]
            ? object[@"command"]
            : nil;
        BOOL isControlRequest = [
            @[@"hello", @"ping", @"diagnostics"]
            containsObject:command ?: @""
        ];
        BOOL isDebugRequest = [command isEqualToString:@"debug"];
        void (^handleRequest)(void) = ^{
            response = IOSUseHandleRequest(
                object,
                connection,
                (__bridge void *)fridaEventContext,
                &fridaEventSubscription
            );
        };
        if (isDebugRequest && IOSUseRuntimeDebugQueue != nil) {
            dispatch_sync(IOSUseRuntimeDebugQueue, handleRequest);
        } else if (commandQueue != nil && !isControlRequest) {
            dispatch_sync(commandQueue, handleRequest);
        } else {
            handleRequest();
        }
    }
    [fridaEventContext.writeLock lock];
    @try {
        IOSUseWriteResponse(connection, response);
    } @finally {
        [fridaEventContext.writeLock unlock];
    }
    @try {
        if (fridaEventSubscription && [response[@"ok"] boolValue]) {
            for (;;) {
                if (IOSUseSocketPeerDisconnected(connection)) {
                    break;
                }
                struct pollfd state = {
                    .fd = connection,
                    .events = POLLIN | POLLHUP | POLLERR,
                    .revents = 0,
                };
                int result;
                do {
                    result = poll(&state, 1, 250);
                } while (result < 0 && errno == EINTR);
                if (result < 0 ||
                    (state.revents & (POLLHUP | POLLERR | POLLNVAL)) != 0 ||
                    IOSUseSocketPeerDisconnected(connection)) {
                    break;
                }
            }
        }
    } @finally {
        if (fridaEventSubscription) {
            // Clear even when response encoding or the peer poll raises an
            // Objective-C exception; the Engine stores this context as a raw
            // pointer and must not outlive the connection's autorelease pool.
            IOSUsePlayRuntimeFridaClearEventSubscription();
        }
    }
}

static BOOL IOSUseSecureSocketDirectory(NSString *socketPath) {
    NSString *directory =
        [socketPath stringByDeletingLastPathComponent];
    if (directory.length == 0 ||
        [directory isEqualToString:@"/"]) {
        IOSUseRecordSocketFailure(@"socket-directory", EPERM);
        return NO;
    }
    int descriptor = open(
        directory.fileSystemRepresentation,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    );
    if (descriptor < 0) {
        IOSUseRecordSocketFailure(@"socket-directory-open", errno);
        return NO;
    }
    struct stat status;
    BOOL secure =
        fstat(descriptor, &status) == 0 &&
        S_ISDIR(status.st_mode) &&
        status.st_uid == geteuid() &&
        (status.st_mode & 0077) == 0;
    int savedErrno = secure ? 0 : EPERM;
    close(descriptor);
    if (!secure) {
        IOSUseRecordSocketFailure(
            @"socket-directory-permissions",
            savedErrno
        );
    }
    return secure;
}

static void IOSUseRemoveOwnedSocket(void) {
    if (IOSUseRuntimeSocketOwned == 0) {
        return;
    }
    // Consume deletion ownership before unlink. If SIGTERM interrupts
    // another cleanup between these operations, preserving a residue is
    // safer than allowing a later callback to delete a replacement path.
    IOSUseRuntimeSocketOwned = 0;
    (void)unlink(IOSUseRuntimeSocketSignalPath);
}

static void IOSUseHandleTerminationSignal(int signalNumber) {
    IOSUseRemoveOwnedSocket();
    _exit(128 + signalNumber);
}

static int IOSUseCreateListener(NSString *socketPath) {
    if (![socketPath isAbsolutePath] ||
        !IOSUseSecureSocketDirectory(socketPath)) {
        return -1;
    }
    NSData *pathData =
        [socketPath dataUsingEncoding:NSUTF8StringEncoding];
    if (pathData.length == 0 ||
        pathData.length >=
            sizeof(((struct sockaddr_un *)0)->sun_path)) {
        IOSUseRecordSocketFailure(
            @"socket-path-length",
            ENAMETOOLONG
        );
        return -1;
    }
    struct stat existing;
    if (lstat(socketPath.fileSystemRepresentation, &existing) == 0) {
        IOSUseRecordSocketFailure(@"socket-path-exists", EEXIST);
        return -1;
    }
    if (errno != ENOENT) {
        IOSUseRecordSocketFailure(@"socket-path-lstat", errno);
        return -1;
    }
    int listener = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listener < 0) {
        IOSUseRecordSocketFailure(@"socket-create", errno);
        return -1;
    }
    if (!IOSUseConfigureSocket(listener, NO)) {
        IOSUseRecordSocketFailure(@"socket-configure", errno);
        close(listener);
        return -1;
    }
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    address.sun_len = (uint8_t)sizeof(address);
    memcpy(address.sun_path, pathData.bytes, pathData.length);
    address.sun_path[pathData.length] = '\0';
    if (bind(
            listener,
            (const struct sockaddr *)&address,
            sizeof(address)
        ) != 0) {
        IOSUseRecordSocketFailure(@"socket-bind", errno);
        close(listener);
        return -1;
    }
    const char *filePath = socketPath.fileSystemRepresentation;
    struct stat status;
    if (chmod(filePath, 0600) != 0 ||
        lstat(filePath, &status) != 0 ||
        !S_ISSOCK(status.st_mode) ||
        status.st_uid != geteuid() ||
        (status.st_mode & 0777) != 0600) {
        IOSUseRecordSocketFailure(@"socket-secure", errno ?: EPERM);
        close(listener);
        unlink(filePath);
        return -1;
    }
    size_t signalPathLength = strlen(filePath);
    if (signalPathLength + 1 >
        sizeof(IOSUseRuntimeSocketSignalPath)) {
        IOSUseRecordSocketFailure(
            @"socket-signal-path-length",
            ENAMETOOLONG
        );
        close(listener);
        IOSUseRemoveOwnedSocket();
        return -1;
    }
    memcpy(
        IOSUseRuntimeSocketSignalPath,
        filePath,
        signalPathLength + 1
    );
    IOSUseRuntimeSocketOwned = 1;
    if (listen(listener, 16) != 0) {
        IOSUseRecordSocketFailure(@"socket-listen", errno);
        close(listener);
        IOSUseRemoveOwnedSocket();
        return -1;
    }
    struct sigaction terminationAction = {0};
    terminationAction.sa_handler =
        IOSUseHandleTerminationSignal;
    terminationAction.sa_flags = SA_RESETHAND;
    sigemptyset(&terminationAction.sa_mask);
    if (sigaction(SIGTERM, &terminationAction, NULL) != 0) {
        IOSUseRecordSocketFailure(
            @"socket-termination-handler",
            errno
        );
        close(listener);
        IOSUseRemoveOwnedSocket();
        return -1;
    }
    return listener;
}

void IOSUsePlayRuntimeStartSocket(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char *sessionValue = getenv("IOS_USE_PLAY_SESSION_ID");
        const char *socketValue = getenv("IOS_USE_PLAY_RUNTIME_SOCKET");
        const char *installRevisionValue =
            getenv("IOS_USE_PLAY_INSTALL_REVISION");
        const char *playChainRootValue =
            getenv("IOS_USE_PLAYCHAIN_ROOT");
        NSString *sessionID = sessionValue == NULL
            ? nil
            : [NSString stringWithUTF8String:sessionValue];
        NSString *socketPath = socketValue == NULL
            ? nil
            : [NSString stringWithUTF8String:socketValue];
        NSString *installRevision = installRevisionValue == NULL
            ? nil
            : [NSString stringWithUTF8String:installRevisionValue];
        NSString *playChainRoot = playChainRootValue == NULL
            ? nil
            : [NSString stringWithUTF8String:playChainRootValue];
        if (sessionID.length == 0 ||
            [sessionID lengthOfBytesUsingEncoding:NSUTF8StringEncoding] >
                128) {
            IOSUseRecordSocketFailure(@"session-env", EINVAL);
            return;
        }
        if (socketPath.length == 0) {
            IOSUseRecordSocketFailure(@"socket-env", EINVAL);
            return;
        }
        if (!IOSUseIsLowercaseSHA256(installRevision)) {
            IOSUseRecordSocketFailure(@"install-revision-env", EINVAL);
            return;
        }
        IOSUseRuntimeSessionID = [sessionID copy];
        IOSUseRuntimeSocketPath = [socketPath copy];
        IOSUseRuntimeInstallRevision = [installRevision copy];
        IOSUseRuntimePlayChainRoot = [playChainRoot copy];
        IOSUseRecordSocketState(@"starting", nil, 0);
        int listener = IOSUseCreateListener(socketPath);
        if (listener < 0) {
            return;
        }
        IOSUseRuntimeSocketListener = listener;
        atexit(IOSUseRemoveOwnedSocket);
        IOSUseRecordSocketState(@"listening", nil, 0);
    });
}

const char *IOSUsePlayRuntimeCapturedInstallRevision(void) {
    return IOSUseRuntimeInstallRevision.UTF8String;
}

const char *IOSUsePlayRuntimeCapturedPlayChainRoot(void) {
    return IOSUseRuntimePlayChainRoot.UTF8String;
}

void IOSUsePlayRuntimeHideLaunchEnvironment(void) {
    NSMutableOrderedSet<NSString *> *names =
        [NSMutableOrderedSet orderedSetWithArray:@[
            @"IOS_USE_PLAY_SESSION_ID",
            @"IOS_USE_PLAY_RUNTIME_SOCKET",
            @"IOS_USE_PLAY_INSTALL_REVISION",
            @"IOS_USE_PLAYCHAIN_ROOT",
            @"IOS_USE_PLAY_STDIO_LOG",
        ]];
    char ***environmentPointer = _NSGetEnviron();
    if (environmentPointer != NULL && *environmentPointer != NULL) {
        for (char **entry = *environmentPointer;
             *entry != NULL;
             entry += 1) {
            char *separator = strchr(*entry, '=');
            if (separator == NULL || separator[1] != '\0') {
                continue;
            }
            size_t length = (size_t)(separator - *entry);
            if (length == 0) {
                continue;
            }
            NSString *name = [[NSString alloc]
                initWithBytes:*entry
                length:length
                encoding:NSUTF8StringEncoding];
            if (name.length > 0) {
                [names addObject:name];
            }
        }
    }
    for (NSString *name in names) {
        (void)unsetenv(name.UTF8String);
    }
}

int IOSUsePlayRuntimeBootstrapStdio(void) {
    const char *enabled = getenv("IOS_USE_PLAY_STDIO_LOG");
    if (enabled == NULL || enabled[0] == '\0') {
        return 0;
    }
    if (strcmp(enabled, "1") != 0) {
        return EINVAL;
    }
    int listener = IOSUseRuntimeSocketListener;
    if (listener < 0) {
        return ENOTCONN;
    }
    struct pollfd pollDescriptor = {
        .fd = listener,
        .events = POLLIN,
    };
    int pollResult;
    do {
        pollResult = poll(&pollDescriptor, 1, 15000);
    } while (pollResult < 0 && errno == EINTR);
    if (pollResult <= 0) {
        IOSUseRecordSocketFailure(
            @"stdio-bootstrap-timeout",
            pollResult == 0 ? ETIMEDOUT : errno
        );
        return pollResult == 0 ? ETIMEDOUT : errno;
    }
    int connection = accept(listener, NULL, NULL);
    if (connection < 0) {
        IOSUseRecordSocketFailure(@"stdio-bootstrap-accept", errno);
        return errno;
    }
    int result = 0;
    @try {
        if (!IOSUseConfigureSocket(connection, YES)) {
            result = errno ?: EIO;
        } else {
            uid_t peerUser = (uid_t)-1;
            gid_t peerGroup = (gid_t)-1;
            if (getpeereid(connection, &peerUser, &peerGroup) != 0 ||
                peerUser != geteuid()) {
                result = EPERM;
            } else {
                uint8_t bytes[4096] = {0};
                uint8_t control[CMSG_SPACE(sizeof(int))] = {0};
                struct iovec vector = {
                    .iov_base = bytes,
                    .iov_len = sizeof(bytes),
                };
                struct msghdr message = {0};
                message.msg_iov = &vector;
                message.msg_iovlen = 1;
                message.msg_control = control;
                message.msg_controllen = sizeof(control);
                ssize_t count = recvmsg(connection, &message, 0);
                if (count <= 0 || (message.msg_flags & MSG_CTRUNC) != 0) {
                    result = count < 0 ? errno : EPROTO;
                } else {
                    int receivedDescriptor = -1;
                    for (
                        struct cmsghdr *header = CMSG_FIRSTHDR(&message);
                        header != NULL;
                        header = CMSG_NXTHDR(&message, header)
                    ) {
                        if (header->cmsg_level == SOL_SOCKET &&
                            header->cmsg_type == SCM_RIGHTS &&
                            header->cmsg_len >= CMSG_LEN(sizeof(int))) {
                            memcpy(
                                &receivedDescriptor,
                                CMSG_DATA(header),
                                sizeof(receivedDescriptor)
                            );
                            break;
                        }
                    }
                    NSError *jsonError = nil;
                    NSData *payload = [NSData
                        dataWithBytes:bytes
                               length:(NSUInteger)count];
                    id object = [NSJSONSerialization
                        JSONObjectWithData:payload
                                   options:0
                                     error:&jsonError];
                    NSDictionary *metadata =
                        [object isKindOfClass:NSDictionary.class]
                            ? object
                            : nil;
                    NSString *sessionID = metadata[@"sessionID"];
                    NSString *path = metadata[@"path"];
                    NSNumber *device = metadata[@"device"];
                    NSNumber *inode = metadata[@"inode"];
                    if (receivedDescriptor < 0 ||
                        ![sessionID isEqualToString:IOSUseRuntimeSessionID] ||
                        ![path isKindOfClass:NSString.class] ||
                        ![device isKindOfClass:NSNumber.class] ||
                        ![inode isKindOfClass:NSNumber.class]) {
                        if (receivedDescriptor >= 0) {
                            close(receivedDescriptor);
                        }
                        result = EPROTO;
                    } else {
                        result =
                            IOSUsePlayRuntimeConfigureStdioFromDescriptor(
                                receivedDescriptor,
                                path.fileSystemRepresentation,
                                device.unsignedLongLongValue,
                                inode.unsignedLongLongValue
                            );
                    }
                }
            }
        }
    } @catch (NSException *exception) {
        result = EPROTO;
    } @finally {
        close(connection);
    }
    if (result != 0) {
        IOSUseRecordSocketFailure(@"stdio-bootstrap", result);
    }
    return result;
}

void IOSUsePlayRuntimeStartCommandLoop(void) {
    if (IOSUseRuntimeSocketCommandLoopStarted != 0) {
        return;
    }
    IOSUseRuntimeSocketCommandLoopStarted = 1;
    int listener = IOSUseRuntimeSocketListener;
    if (listener < 0) {
        return;
    }
    IOSUseRuntimeCommandQueue = dispatch_queue_create(
        "io.ios-use.play-runtime.command",
        DISPATCH_QUEUE_SERIAL
    );
    IOSUseRuntimeDebugQueue = dispatch_queue_create(
        "io.ios-use.play-runtime.debug",
        DISPATCH_QUEUE_SERIAL
    );
    IOSUseRuntimeConnectionQueue = dispatch_queue_create(
        "io.ios-use.play-runtime.connection",
        DISPATCH_QUEUE_CONCURRENT
    );
    dispatch_queue_t acceptQueue = dispatch_queue_create(
        "io.ios-use.play-runtime.accept",
        DISPATCH_QUEUE_SERIAL
    );
    dispatch_async(acceptQueue, ^{
            NSLog(
                @"[ios-use-play] Runtime socket listening"
            );
            for (;;) {
                @autoreleasepool {
                    int connection = accept(listener, NULL, NULL);
                    if (connection < 0) {
                        if (errno == EINTR) {
                            continue;
                        }
                        IOSUseRecordSocketFailure(
                            @"socket-accept",
                            errno
                        );
                        close(listener);
                        IOSUseRemoveOwnedSocket();
                        return;
                    }
                    dispatch_async(IOSUseRuntimeConnectionQueue, ^{
                        @autoreleasepool {
                            @try {
                                IOSUseServeConnection(connection);
                            } @catch (NSException *exception) {
                                NSLog(
                                    @"[ios-use-play] Runtime command exception %@",
                                    exception.name
                                );
                            } @finally {
                                close(connection);
                            }
                        }
                    });
                }
            }
        });
}

NSDictionary<NSString *, id> *IOSUsePlayRuntimeSocketIdentity(void) {
    os_unfair_lock_lock(&IOSUseRuntimeSocketStateLock);
    NSString *status = [IOSUseRuntimeSocketStatus copy];
    NSString *failureStage =
        [IOSUseRuntimeSocketFailureStage copy];
    NSNumber *failureErrno = IOSUseRuntimeSocketFailureErrno;
    os_unfair_lock_unlock(&IOSUseRuntimeSocketStateLock);
    NSMutableDictionary<NSString *, id> *identity = [@{
        @"status": status ?: @"unknown",
        @"transport": @"unix-domain-socket",
    } mutableCopy];
    if (failureStage.length > 0) {
        identity[@"failureStage"] = failureStage;
        identity[@"failureErrno"] = failureErrno ?: @0;
    }
    return identity;
}
