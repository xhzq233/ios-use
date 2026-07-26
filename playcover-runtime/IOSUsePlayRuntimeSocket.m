#import "IOSUsePlayRuntimeSocket.h"
#import "IOSUsePlayRuntimeAutomation.h"
#import "IOSUsePlayRuntimeDOM.h"
#import "IOSUsePlayRuntimeScreenshot.h"
#import "IOSUsePlayDevice.h"
#import "IOSUsePlaySwiftBridge.h"

#import <UIKit/UIKit.h>
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <os/lock.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <sys/un.h>
#import <unistd.h>

static const NSUInteger IOSUseMaximumRequestFrameSize = 64 * 1024;
static const NSUInteger IOSUseMaximumResponseFrameSize = 16 * 1024 * 1024;
static const NSTimeInterval IOSUseSocketIOTimeoutSeconds = 15;

static NSString *IOSUseRuntimeSessionID;
static NSString *IOSUseRuntimeSocketPath;
static NSString *IOSUseRuntimeSocketStatus = @"not-started";
static NSString *IOSUseRuntimeSocketFailureStage;
static NSNumber *IOSUseRuntimeSocketFailureErrno;
static ino_t IOSUseRuntimeSocketInode;
static dev_t IOSUseRuntimeSocketDevice;
static os_unfair_lock IOSUseRuntimeSocketStateLock =
    OS_UNFAIR_LOCK_INIT;

static BOOL IOSUseIsNonemptyString(id value) {
    return [value isKindOfClass:NSString.class] &&
        [(NSString *)value length] > 0;
}

static BOOL IOSUseIsSchemaVersionTwo(id value) {
    if (![value isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value) ==
            CFBooleanGetTypeID()) {
        return NO;
    }
    NSNumber *number = value;
    return number.longLongValue == 2 &&
        number.doubleValue == 2.0;
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

static NSDictionary<NSString *, id> *IOSUseErrorEnvelope(
    NSString *requestID,
    NSDictionary<NSString *, id> *error
) {
    return @{
        @"schemaVersion": @2,
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

static NSArray<NSString *> *IOSUseCapabilities(void) {
    return @[
        @"hello",
        @"ping",
        @"diagnostics",
        @"screenshot",
        @"dom",
        @"waitFor",
        @"tap",
        @"longPress",
        @"swipe",
        @"input",
        @"dismissAlert",
        @"open",
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
    return @([value isKindOfClass:NSNumber.class] &&
        [(NSNumber *)value boolValue]);
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
        @"canvasBounds": IOSUseSocketStableRect(window[@"canvasBounds"]),
        @"displayScale": IOSUseSocketStableFiniteNumber(
            window[@"displayScale"]
        ),
        @"inverseDisplayScale": IOSUseSocketStableFiniteNumber(
            window[@"inverseDisplayScale"]
        ),
        @"transparentSpacer": IOSUseSocketStableFiniteNumber(
            window[@"transparentSpacer"]
        ),
        @"transparent": IOSUseSocketStableBool(
            window[@"transparentHost"]
        ),
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

static BOOL IOSUseSocketContainsRect(CGRect outer, CGRect inner) {
    return CGRectGetMinX(inner) >= CGRectGetMinX(outer) - 0.01 &&
        CGRectGetMinY(inner) >= CGRectGetMinY(outer) - 0.01 &&
        CGRectGetMaxX(inner) <= CGRectGetMaxX(outer) + 0.01 &&
        CGRectGetMaxY(inner) <= CGRectGetMaxY(outer) + 0.01;
}

static BOOL IOSUseHostGeometryReady(NSDictionary<NSString *, id> *host) {
    NSDictionary<NSString *, id> *capture =
        [host[@"capture"] isKindOfClass:NSDictionary.class]
            ? host[@"capture"]
            : @{};
    CGRect frame = CGRectZero;
    CGRect contentBounds = CGRectZero;
    CGRect canvasBounds = CGRectZero;
    CGRect canvasRect = CGRectZero;
    CGRect hostContentCGWindowRect = CGRectZero;
    CGRect hostCGWindowBounds = CGRectZero;
    CGRect canvasCGWindowRect = CGRectZero;
    CGFloat displayScale = [host[@"displayScale"] doubleValue];
    CGFloat inverseDisplayScale =
        [host[@"inverseDisplayScale"] doubleValue];
    CGFloat spacer = [host[@"transparentSpacer"] doubleValue];
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
    return [host[@"status"] isEqualToString:@"configured"] &&
        [host[@"hostPolicy"] boolValue] &&
        [host[@"transparent"] boolValue] &&
        [host[@"publicTitleBar"] boolValue] &&
        [host[@"titleVisible"] boolValue] &&
        [host[@"resizable"] boolValue] &&
        title.length > 0 && [title isEqualToString:expectedTitle] &&
        isfinite(displayScale) && displayScale > 0 &&
        isfinite(inverseDisplayScale) &&
        fabs(displayScale * inverseDisplayScale - 1.0) <= 0.01 &&
        fabs(spacer - 8.0) <= 0.01 &&
        IOSUseSocketRectFromJSON(host[@"frame"], &frame) &&
        IOSUseSocketRectFromJSON(
            host[@"contentBounds"],
            &contentBounds
        ) &&
        IOSUseSocketRectFromJSON(host[@"canvasBounds"], &canvasBounds) &&
        fabs(canvasBounds.origin.x) <= 0.01 &&
        fabs(canvasBounds.origin.y) <= 0.01 &&
        fabs(canvasBounds.size.width - IOSUsePlayDeviceLogicalWidth) <= 0.01 &&
        fabs(canvasBounds.size.height - IOSUsePlayDeviceLogicalHeight) <= 0.01 &&
        IOSUseSocketRectFromJSON(host[@"canvasRect"], &canvasRect) &&
        IOSUseSocketContainsRect(contentBounds, canvasRect) &&
        fabs(CGRectGetMaxY(canvasRect) + spacer -
            CGRectGetMaxY(contentBounds)) <= 0.01 &&
        fabs(canvasRect.size.width / displayScale -
            IOSUsePlayDeviceLogicalWidth) <= 0.01 &&
        fabs(canvasRect.size.height / displayScale -
            IOSUsePlayDeviceLogicalHeight) <= 0.01 &&
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
        IOSUseSocketContainsRect(
            hostCGWindowBounds,
            hostContentCGWindowRect
        ) &&
        IOSUseSocketContainsRect(hostCGWindowBounds, canvasCGWindowRect) &&
        fabs(
            canvasCGWindowRect.origin.x -
                (hostContentCGWindowRect.origin.x +
                    canvasRect.origin.x - contentBounds.origin.x)
        ) <= 0.01 &&
        fabs(
            canvasCGWindowRect.origin.y -
                (hostContentCGWindowRect.origin.y +
                    CGRectGetMaxY(contentBounds) -
                    CGRectGetMaxY(canvasRect))
        ) <= 0.01 &&
        fabs(canvasCGWindowRect.size.width / displayScale -
            IOSUsePlayDeviceLogicalWidth) <= 0.01 &&
        fabs(canvasCGWindowRect.size.height / displayScale -
            IOSUsePlayDeviceLogicalHeight) <= 0.01;
}

static NSMutableDictionary<NSString *, id> *IOSUseBasePayload(void) {
    __block NSDictionary<NSString *, id> *geometry;
    __block NSString *stage;
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
        CGRect windowBounds = keyWindow.bounds;
        UIView *rootView = keyWindow.rootViewController.view;
        UIEdgeInsets safeArea =
            rootView == nil ? UIEdgeInsetsZero : rootView.safeAreaInsets;
        NSDictionary<NSString *, id> *hooks =
            IOSUsePlayRuntimeHookDiagnostics();
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
            @"scale": @(screen.scale),
            // This is intentionally UIKit's fixed logical canvas, not the
            // independently resizable transparent AppKit host.
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
        BOOL exact =
            fabs(logical.size.width -
                IOSUsePlayDeviceLogicalWidth) <= 0.01 &&
            fabs(logical.size.height -
                IOSUsePlayDeviceLogicalHeight) <= 0.01 &&
            fabs(native.size.width -
                IOSUsePlayDeviceNativeWidth) <= 0.01 &&
            fabs(native.size.height -
                IOSUsePlayDeviceNativeHeight) <= 0.01 &&
            fabs(screen.scale - IOSUsePlayDeviceScale) <= 0.01 &&
            fabs(windowBounds.size.width -
                IOSUsePlayDeviceLogicalWidth) <= 0.01 &&
            fabs(windowBounds.size.height -
                IOSUsePlayDeviceLogicalHeight) <= 0.01 &&
            [hooks[@"configurationStage"]
                isEqualToString:@"window-configured"] &&
            IOSUseHostGeometryReady(hostGeometry);
        NSString *configurationStage = hooks[@"configurationStage"];
        stage = exact
            ? @"ready"
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
    if (![playChain[@"status"] isEqualToString:@"ready"]) {
        stage = @"playchain-location-invalid";
    }
    return [@{
        @"pid": @(getpid()),
        @"bundleIdentifier":
            NSBundle.mainBundle.bundleIdentifier ?: @"",
        @"executablePath":
            NSBundle.mainBundle.executablePath ?: @"",
        @"capabilities": IOSUseCapabilities(),
        @"geometry": geometry ?: @{},
        @"playChain": playChain ?: @{},
        @"stage": stage ?: @"geometry-mismatch",
    } mutableCopy];
}

static NSDictionary<NSString *, id> *IOSUseObserved(void) {
    __block NSDictionary<NSString *, id> *observed;
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
        observed = @{
            @"screenBounds": @{
                @"x": @(screen.bounds.origin.x),
                @"y": @(screen.bounds.origin.y),
                @"width": @(screen.bounds.size.width),
                @"height": @(screen.bounds.size.height),
            },
            @"nativeBounds": @{
                @"x": @(screen.nativeBounds.origin.x),
                @"y": @(screen.nativeBounds.origin.y),
                @"width": @(screen.nativeBounds.size.width),
                @"height": @(screen.nativeBounds.size.height),
            },
            @"screenScale": @(screen.scale),
            @"windowBounds":
                keyWindow == nil
                    ? (id)NSNull.null
                    : @{
                        @"x": @(keyWindow.bounds.origin.x),
                        @"y": @(keyWindow.bounds.origin.y),
                        @"width": @(keyWindow.bounds.size.width),
                        @"height": @(keyWindow.bounds.size.height),
                    },
            @"safeArea":
                keyWindow == nil
                    ? (id)NSNull.null
                    : @{
                        @"top": @(keyWindow.rootViewController.view
                            .safeAreaInsets.top),
                        @"left": @(keyWindow.rootViewController.view
                            .safeAreaInsets.left),
                        @"bottom": @(keyWindow.rootViewController.view
                            .safeAreaInsets.bottom),
                        @"right": @(keyWindow.rootViewController.view
                            .safeAreaInsets.right),
                    },
            @"appKit": [IOSUsePlayRuntimeHookDiagnostics()
                objectForKey:@"window"] ?: @{},
        };
    };
    if (NSThread.isMainThread) {
        capture();
    } else {
        dispatch_sync(dispatch_get_main_queue(), capture);
    }
    return observed ?: @{};
}

static NSDictionary<NSString *, id> *IOSUseSuccessEnvelope(
    NSString *requestID,
    NSDictionary<NSString *, id> *payload
) {
    return @{
        @"schemaVersion": @2,
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
    __block NSString *failureCode;
    __block NSString *failureMessage;
    void (^capture)(void) = ^{
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
    typed[@"dom"] = dom;
    NSMutableDictionary<NSString *, id> *payload =
        IOSUseBasePayload();
    payload[@"screenshot"] = typed;
    payload[@"dom"] = dom;
    return IOSUseSuccessEnvelope(requestID, payload);
}

static NSDictionary<NSString *, id> *IOSUseHandleRequest(
    id object,
    int connection
) {
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
    NSSet<NSString *> *expectedKeys = [NSSet setWithArray:@[
        @"schemaVersion",
        @"requestId",
        @"sessionID",
        @"command",
        @"arguments",
    ]];
    if (request.count != expectedKeys.count ||
        ![[NSSet setWithArray:request.allKeys]
            isEqualToSet:expectedKeys] ||
        !IOSUseIsSchemaVersionTwo(request[@"schemaVersion"]) ||
        requestID.length == 0 ||
        requestID.length > 256 ||
        !IOSUseIsNonemptyString(request[@"sessionID"]) ||
        !IOSUseIsNonemptyString(request[@"command"]) ||
        ![request[@"arguments"] isKindOfClass:NSDictionary.class]) {
        return IOSUseBasicErrorEnvelope(
            requestID,
            @"invalid_request",
            @"request does not match Runtime schema version 2",
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
    NSMutableDictionary<NSString *, id> *payload =
        IOSUseBasePayload();
    if ([command isEqualToString:@"hello"] ||
        [command isEqualToString:@"ping"]) {
        if (arguments.count != 0) {
            return IOSUseBasicErrorEnvelope(
                requestID,
                @"invalid_arguments",
                @"hello and ping require an empty arguments object",
                @"validation",
                @"validation",
                NO
            );
        }
        payload[@"observed"] = IOSUseObserved();
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
        payload[@"diagnostics"] = @{
            @"runtime": IOSUsePlayRuntimeHookDiagnostics(),
            @"socket": IOSUsePlayRuntimeSocketIdentity(),
            @"observed": IOSUseObserved(),
            @"playChain": [PlayKeychain storageIdentity],
        };
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
            @"open",
        ] containsObject:command]
    ) {
        NSDictionary<NSString *, id> *commandError = nil;
        NSDictionary<NSString *, id> *result =
            IOSUsePlayRuntimeAutomationCommand(
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
            @"Runtime supports hello, ping, diagnostics, screenshot, dom, waitFor, tap, longPress, swipe, input, dismissAlert, and open",
            @"protocol",
            @"dispatch",
            NO
        );
    }
    return IOSUseSuccessEnvelope(requestID, payload);
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
        response = IOSUseBasicErrorEnvelope(
            requestID,
            data == nil ? @"internal_failure" : @"response_too_large",
            data == nil
                ? @"Runtime response could not be encoded"
                : @"Runtime response exceeded 16 MiB",
            @"internal",
            @"encoding",
            NO
        );
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
    NSDictionary<NSString *, id> *response = object == nil
        ? IOSUseBasicErrorEnvelope(
            @"",
            @"invalid_json",
            utf8 == nil
                ? @"request frame is not valid UTF-8"
                : @"request frame is not valid JSON",
            @"protocol",
            @"decoding",
            NO
        )
        : IOSUseHandleRequest(object, connection);
    IOSUseWriteResponse(connection, response);
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
    NSString *path = IOSUseRuntimeSocketPath;
    if (path.length == 0 ||
        IOSUseRuntimeSocketInode == 0) {
        return;
    }
    struct stat status;
    if (lstat(path.fileSystemRepresentation, &status) == 0 &&
        S_ISSOCK(status.st_mode) &&
        status.st_uid == geteuid() &&
        status.st_ino == IOSUseRuntimeSocketInode &&
        status.st_dev == IOSUseRuntimeSocketDevice) {
        (void)unlink(path.fileSystemRepresentation);
    }
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
    IOSUseRuntimeSocketInode = status.st_ino;
    IOSUseRuntimeSocketDevice = status.st_dev;
    if (listen(listener, 16) != 0) {
        IOSUseRecordSocketFailure(@"socket-listen", errno);
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
        NSString *sessionID = sessionValue == NULL
            ? nil
            : [NSString stringWithUTF8String:sessionValue];
        NSString *socketPath = socketValue == NULL
            ? nil
            : [NSString stringWithUTF8String:socketValue];
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
        IOSUseRuntimeSessionID = [sessionID copy];
        IOSUseRuntimeSocketPath = [socketPath copy];
        IOSUseRecordSocketState(@"starting", nil, 0);
        int listener = IOSUseCreateListener(socketPath);
        if (listener < 0) {
            return;
        }
        atexit(IOSUseRemoveOwnedSocket);
        IOSUseRecordSocketState(@"listening", nil, 0);
        dispatch_queue_t acceptQueue = dispatch_queue_create(
            "io.ios-use.play-runtime.socket.fifo",
            DISPATCH_QUEUE_SERIAL
        );
        dispatch_async(acceptQueue, ^{
            NSLog(
                @"[ios-use-play] Runtime v2 socket listening"
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
                    @try {
                        // Serving inline is the Runtime's per-session FIFO.
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
            }
        });
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
        @"protocolSchemaVersion": @2,
        @"fifo": @YES,
    } mutableCopy];
    if (failureStage.length > 0) {
        identity[@"failureStage"] = failureStage;
        identity[@"failureErrno"] = failureErrno ?: @0;
    }
    return identity;
}
