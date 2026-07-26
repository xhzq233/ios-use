#import <Foundation/Foundation.h>

static NSString *FunctionBody(
    NSString *source,
    NSString *functionName
) {
    NSString *needle = [functionName stringByAppendingString:@"("];
    NSRange declaration = [source rangeOfString:needle];
    if (declaration.location == NSNotFound) {
        return nil;
    }
    NSRange opening = [source
        rangeOfString:@"{"
              options:0
                range:NSMakeRange(
                    NSMaxRange(declaration),
                    source.length - NSMaxRange(declaration)
                )];
    if (opening.location == NSNotFound) {
        return nil;
    }
    NSUInteger depth = 0;
    for (NSUInteger index = opening.location;
         index < source.length;
         index += 1) {
        unichar character = [source characterAtIndex:index];
        if (character == '{') {
            depth += 1;
        } else if (character == '}') {
            depth -= 1;
            if (depth == 0) {
                return [source substringWithRange:NSMakeRange(
                    opening.location,
                    index - opening.location + 1
                )];
            }
        }
    }
    return nil;
}

static NSUInteger OccurrenceCount(
    NSString *source,
    NSString *needle
) {
    NSUInteger count = 0;
    NSRange search = NSMakeRange(0, source.length);
    while (search.length > 0) {
        NSRange occurrence = [source
            rangeOfString:needle
                  options:0
                    range:search];
        if (occurrence.location == NSNotFound) {
            break;
        }
        count += 1;
        NSUInteger next = NSMaxRange(occurrence);
        search = NSMakeRange(next, source.length - next);
    }
    return count;
}

static BOOL Require(
    BOOL condition,
    NSString *message
) {
    if (!condition) {
        fprintf(
            stderr,
            "[runtime-screenshot-contract] %s\n",
            message.UTF8String
        );
    }
    return condition;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 4) {
            fprintf(
                stderr,
                "usage: RuntimeScreenshotSourceContract "
                "<RuntimeScreenshot.m> <WindowCompositor.m> "
                "<AppKitBridge.m>\n"
            );
            return 2;
        }
        NSError *error = nil;
        NSString *runtimePath = [NSString
            stringWithUTF8String:argv[1]];
        NSString *compositorPath = [NSString
            stringWithUTF8String:argv[2]];
        NSString *runtime = [NSString
            stringWithContentsOfFile:runtimePath
                            encoding:NSUTF8StringEncoding
                               error:&error];
        if (runtime == nil) {
            fprintf(
                stderr,
                "[runtime-screenshot-contract] read failed: %s\n",
                error.localizedDescription.UTF8String
            );
            return 2;
        }
        NSString *compositor = [NSString
            stringWithContentsOfFile:compositorPath
                            encoding:NSUTF8StringEncoding
                               error:&error];
        if (compositor == nil) {
            fprintf(
                stderr,
                "[runtime-screenshot-contract] read failed: %s\n",
                error.localizedDescription.UTF8String
            );
            return 2;
        }
        NSString *bridgePath = [NSString
            stringWithUTF8String:argv[3]];
        NSString *bridge = [NSString
            stringWithContentsOfFile:bridgePath
                            encoding:NSUTF8StringEncoding
                               error:&error];
        if (bridge == nil) {
            fprintf(
                stderr,
                "[runtime-screenshot-contract] read failed: %s\n",
                error.localizedDescription.UTF8String
            );
            return 2;
        }

        NSString *collector = FunctionBody(
            runtime,
            @"IOSUseScreenshotCollectNativeWindows"
        );
        NSString *capture = FunctionBody(
            runtime,
            @"IOSUseScreenshotCaptureFrameOnMain"
        );
        NSString *payload = FunctionBody(
            runtime,
            @"IOSUseScreenshotPayloadOnMain"
        );
        NSString *fingerprint = FunctionBody(
            runtime,
            @"IOSUseScreenshotFingerprintOnMain"
        );
        NSString *payloadSettling = FunctionBody(
            runtime,
            @"IOSUseScreenshotPayloadWithSettlingOnMain"
        );
        NSString *fingerprintSettling = FunctionBody(
            runtime,
            @"IOSUseScreenshotFingerprintWithSettlingOnMain"
        );
        NSString *screenshotCommand = FunctionBody(
            runtime,
            @"IOSUsePlayRuntimeScreenshotCommand"
        );
        NSString *fingerprintCommand = FunctionBody(
            runtime,
            @"IOSUsePlayRuntimeScreenshotFingerprint"
        );
        NSString *fullFrame = FunctionBody(
            runtime,
            @"IOSUseScreenshotFullFrameEvidence"
        );
        NSString *composite = FunctionBody(
            compositor,
            @"IOSUsePlayCompositeWindowCaptures"
        );
        NSString *bridgeWindowGeometry = FunctionBody(
            bridge,
            @"IOSUseBridgeWindowLogicalFrame"
        );
        NSString *bridgeAlertControlGeometry = FunctionBody(
            bridge,
            @"IOSUseBridgeAlertButtonLogicalFrame"
        );
        NSString *bridgeAlertSelection = FunctionBody(
            bridge,
            @"IOSUseBridgeVisibleNativeAlertSelection"
        );
        NSString *bridgeFocusableWindow = FunctionBody(
            bridge,
            @"IOSUseBridgeMakeBorderlessWindowFocusable"
        );
        NSString *bridgeWindowPolicy = FunctionBody(
            bridge,
            @"IOSUseBridgeApplyWindowPolicy"
        );
        NSString *bridgeMouseMonitor = FunctionBody(
            bridge,
            @"IOSUseBridgeInstallMouseLocalMonitor"
        );
        NSString *bridgeConfiguration = FunctionBody(
            bridge,
            @"+ (BOOL)configureFixedWindow:"
        );
        BOOL passed = YES;
        passed &= Require(
            collector != nil &&
                [collector containsString:
                    @"IOSUsePlayUnionCaptureWindows"] &&
                [collector containsString:
                    @"canvasCaptureGeometryWithError"] &&
                [collector containsString:
                    @"IOSUsePlayResolveCGWindowRectInCanvas"] &&
                [collector containsString:
                    @"compositor_window_outside_canvas"] &&
                capture != nil &&
                [capture containsString:
                    @"IOSUsePlayCropAndNormalizeCanvasCapture"],
            @"collector must union native windows, derive exact fixed canvas "
            @"geometry, and crop every native source to that canvas"
        );
        passed &= Require(
            capture != nil &&
                [capture containsString:
                    @".deviceLogicalRect ="] &&
                composite != nil &&
                [composite containsString:
                    @"capture.deviceLogicalRect"] &&
                ![composite containsString:
                    @"capture.appKitFrame.origin"],
            @"capture evidence and drawing must use CG-derived "
            @"deviceLogicalRect instead of raw AppKit origins"
        );
        passed &= Require(
            capture != nil &&
                OccurrenceCount(
                    capture,
                    @"IOSUseScreenshotCollectNativeWindows"
                ) == 2 &&
                [capture containsString:
                    @"IOSUsePlayWindowCapturePlansEqual"],
            @"capture must collect and compare exact pre/post window plans"
        );
        passed &= Require(
            payload != nil &&
                [payload containsString:
                    @"IOSUseScreenshotCaptureFrameOnMain"] &&
                fingerprint != nil &&
                [fingerprint containsString:
                    @"IOSUseScreenshotCaptureFrameOnMain"],
            @"screenshot and fingerprint must share the complete-frame "
            @"capture path"
        );
        passed &= Require(
            payloadSettling != nil &&
                fingerprintSettling != nil &&
                [runtime containsString:
                    @"IOSUseScreenshotSettlingAttemptLimit = 8"] &&
                OccurrenceCount(
                    payloadSettling,
                    @"attempt < IOSUseScreenshotSettlingAttemptLimit"
                ) == 1 &&
                OccurrenceCount(
                    fingerprintSettling,
                    @"attempt < IOSUseScreenshotSettlingAttemptLimit"
                ) == 1 &&
                [payloadSettling containsString:
                    @"IOSUseScreenshotTransientCaptureFailure"] &&
                [fingerprintSettling containsString:
                    @"IOSUseScreenshotTransientCaptureFailure"] &&
                screenshotCommand != nil &&
                [screenshotCommand containsString:
                    @"IOSUseScreenshotPayloadWithSettlingOnMain"] &&
                fingerprintCommand != nil &&
                [fingerprintCommand containsString:
                    @"IOSUseScreenshotFingerprintWithSettlingOnMain"],
            @"screenshot and action fingerprints must share bounded strict "
            @"settling for transient compositor geometry frames"
        );
        passed &= Require(
            fullFrame != nil &&
                [fullFrame containsString:@"@\"uncropped\": @YES"] &&
                [fullFrame containsString:
                    @"@\"safeAreaCropped\": @NO"] &&
                [fullFrame containsString:
                    @"@\"identityMapping\":"] &&
                payload != nil &&
                [payload containsString:@"@\"syntheticChrome\": @NO"] &&
                [runtime containsString:@"@\"canvasOnly\": @YES"] &&
                [runtime containsString:
                    @"@\"hostDecorationsExcluded\": @YES"] &&
                [payload containsString:@"@\"fullFrame\":"] &&
                composite != nil &&
                [composite containsString:
                    @"primary native window does not uniquely cover"] &&
                ![runtime containsString:@"IOSUsePlaySystemChrome"] &&
                ![runtime containsString:@"systemChromeEvidence"] &&
                ![runtime containsString:@"containsSystemChrome"] &&
                ![runtime containsString:@"systemChromeMapped"],
            @"screenshot must prove a full fixed-canvas identity-mapped "
            @"frame without Runtime-owned chrome or host decoration pixels"
        );
        passed &= Require(
            [bridge containsString:
                @"IOSUseBridgeOwnOnscreenCGWindowMetadata"] &&
                [bridge containsString:@"kCGWindowOwnerPID"] &&
                [bridge containsString:@"kCGWindowNumber"] &&
                [bridge containsString:@"kCGWindowIsOnscreen"] &&
                bridgeWindowGeometry != nil &&
                OccurrenceCount(
                    bridgeWindowGeometry,
                    @"IOSUseBridgeExactOnscreenCGWindowMetadata"
                ) >= 1 &&
                [bridgeWindowGeometry containsString:
                    @"IOSUseBridgeHostCanvasCaptureGeometry"] &&
                [bridgeWindowGeometry containsString:
                    @"IOSUsePlayResolveCGWindowRectInCanvas"],
            @"native alert placement must resolve exact same-PID onscreen "
            @"CGWindow identities through the fixed host canvas"
        );
        passed &= Require(
            bridgeAlertSelection != nil &&
                [bridgeAlertSelection containsString:
                    @"IOSUseBridgeOwnOnscreenCGWindowMetadata"] &&
                [bridgeAlertSelection containsString:
                    @"IOSUseBridgeExactOnscreenCGWindowMetadata"] &&
                [bridgeAlertSelection containsString:
                    @"frontToBackIndex"] &&
                [bridgeAlertSelection containsString:
                    @"sortUsingComparator"] &&
                ![bridgeAlertSelection containsString:
                    @"reverseObjectEnumerator"] &&
                OccurrenceCount(
                    bridge,
                    @"IOSUseBridgeVisibleNativeAlertSelection()"
                ) >= 5,
            @"native alert APIs must reject phantom AppKit panels and share "
            @"the exact frontmost CGWindow-backed selection policy"
        );
        passed &= Require(
            bridgeAlertControlGeometry != nil &&
                [bridgeAlertControlGeometry containsString:
                    @"convertRect:toView:"] &&
                [bridgeAlertControlGeometry containsString:
                    @"convertRectToScreen:"] &&
                [bridgeAlertControlGeometry containsString:
                    @"IOSUseBridgeAppKitScreenRectToCanvasLogicalRect"] &&
                ![bridgeAlertControlGeometry containsString:
                    @"alertFrame.origin"],
            @"native alert controls must route button-local geometry through "
            @"the alert window's AppKit screen rect and shared canvas inverse transform"
        );
        passed &= Require(
            bridgeFocusableWindow == nil &&
                bridgeWindowPolicy != nil &&
                [bridgeWindowPolicy containsString:
                    @"publicHostStyleMask"] &&
                [bridgeWindowPolicy containsString:
                    @"@\"setStyleMask:\""] &&
                [bridgeWindowPolicy containsString:
                    @"@\"setOpaque:\", NO"] &&
                [bridgeWindowPolicy containsString:
                    @"@\"setTitlebarAppearsTransparent:\", YES"] &&
                [bridgeWindowPolicy containsString:
                    @"IOSUseBridgeHostTitle()"] &&
                [bridgeWindowPolicy containsString:
                    @"@\"setContentMinSize:\""] &&
                [bridgeWindowPolicy containsString:
                    @"@\"setIgnoresMouseEvents:\", NO"] &&
                [bridgeWindowPolicy containsString:
                    @"@\"setAcceptsMouseMovedEvents:\", YES"],
            @"the visible Catalyst window must remain a public, transparent, "
            @"mouse-interactive Simulator-style host rather than a private "
            @"borderless device window"
        );
        passed &= Require(
            bridgeMouseMonitor != nil &&
                [bridgeMouseMonitor containsString:
                    @"kCGEventSourceUserData"] &&
                [bridgeMouseMonitor containsString:
                    @"kCGEventSourceUnixProcessID"] &&
                [bridgeMouseMonitor containsString:
                    @"IOSUsePlayMapHostContentPointToCanvas"] &&
                [bridgeMouseMonitor containsString:
                    @"IOSUseBridgeUpdateHostCanvasLayout"] &&
                [bridgeMouseMonitor containsString:
                    @"targetHitTest"] &&
                [bridgeMouseMonitor containsString:
                    @"IOSUsePlayLastMouseDownDelivery"] &&
                [bridgeMouseMonitor containsString:
                    @"IOSUsePlayLastMouseUpDelivery"] &&
                [bridgeMouseMonitor containsString:
                    @"IOSUsePlayMouseDeliveryCount"] &&
                bridgeConfiguration != nil &&
                [bridgeConfiguration containsString:
                    @"IOSUseBridgeInstallMouseLocalMonitor"],
            @"AppKit mouse evidence must retain tagged down/up identity, "
            @"inverse-map host content through the fixed canvas, and reject "
            @"title-bar/gap/outside points as non-target hit tests"
        );
        passed &= Require(
            ![runtime containsString:@"CGRequestScreenCaptureAccess"] &&
                ![runtime containsString:@"ScreenCaptureKit"] &&
                ![runtime containsString:@"CGDisplayCreateImage"] &&
                ![compositor containsString:
                    @"CGRequestScreenCaptureAccess"] &&
                ![compositor containsString:@"ScreenCaptureKit"] &&
                ![compositor containsString:@"CGDisplayCreateImage"] &&
                ![bridge containsString:
                    @"CGRequestScreenCaptureAccess"] &&
                ![bridge containsString:@"ScreenCaptureKit"] &&
                ![bridge containsString:@"CGDisplayCreateImage"],
            @"runtime compositor must remain an in-process own-window path"
        );
        passed &= Require(
            ![runtime containsString:@"430x932"] &&
                ![compositor containsString:@"430x932"] &&
                ![bridge containsString:@"430x932"],
            @"production failures must derive geometry from device constants"
        );
        fprintf(
            stderr,
            "[runtime-screenshot-contract] pass=%d\n",
            passed
        );
        return passed ? 0 : 1;
    }
}
