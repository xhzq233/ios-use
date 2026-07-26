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
            @"configureFixedWindow:"
        );
        BOOL passed = YES;
        passed &= Require(
            collector != nil &&
                [collector containsString:
                    @"IOSUsePlayUnionCaptureWindows"] &&
                [collector containsString:
                    @"IOSUsePlayValidateRelativeWindowGeometry"],
            @"collector must union native alerts and validate exact "
            @"AppKit/CG window geometry"
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
                [payload containsString:@"@\"fullFrame\":"] &&
                composite != nil &&
                [composite containsString:
                    @"primary native window does not uniquely cover"] &&
                ![runtime containsString:@"IOSUsePlaySystemChrome"] &&
                ![runtime containsString:@"systemChromeEvidence"] &&
                ![runtime containsString:@"containsSystemChrome"] &&
                ![runtime containsString:@"systemChromeMapped"],
            @"screenshot must prove a full uncropped identity-mapped frame "
            @"without a Runtime-owned system-chrome overlay"
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
                ) == 2 &&
                [bridgeWindowGeometry containsString:
                    @"IOSUsePlayValidateRelativeWindowGeometry"],
            @"native alert placement must resolve exact same-PID onscreen "
            @"CGWindow identities for the base and alert"
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
                    @"IOSUsePlayResolveLocalAppKitRect"] &&
                ![bridgeAlertControlGeometry containsString:
                    @"alertFrame.origin"],
            @"native alert controls must translate local bottom-left "
            @"coordinates through the CG-derived alert rect"
        );
        passed &= Require(
            bridgeFocusableWindow != nil &&
                [bridgeFocusableWindow containsString:
                    @"object_getClass(window)"] &&
                [bridgeFocusableWindow containsString:
                    @"class_getInstanceMethod"] &&
                [bridgeFocusableWindow containsString:
                    @"method_getTypeEncoding"] &&
                [bridgeFocusableWindow containsString:
                    @"class_addMethod"] &&
                [bridgeFocusableWindow containsString:
                    @"method_setImplementation"] &&
                [bridgeFocusableWindow containsString:
                    @"canBecomeKeyWindow"] &&
                [bridgeFocusableWindow containsString:
                    @"canBecomeMainWindow"] &&
                bridgeWindowPolicy != nil &&
                [bridgeWindowPolicy containsString:
                    @"IOSUseBridgeMakeBorderlessWindowFocusable(window)"] &&
                [bridgeWindowPolicy containsString:
                    @"@\"setStyleMask:\", 0"] &&
                [bridgeWindowPolicy containsString:
                    @"@\"setIgnoresMouseEvents:\", NO"] &&
                [bridgeWindowPolicy containsString:
                    @"@\"setAcceptsMouseMovedEvents:\", YES"],
            @"the exact Catalyst app-window class must keep an ABI-matched "
             @"key/main focus policy when the fixed window becomes truly "
             @"borderless and mouse-interactive"
        );
        passed &= Require(
            bridgeMouseMonitor != nil &&
                [bridgeMouseMonitor containsString:
                    @"kCGEventSourceUserData"] &&
                [bridgeMouseMonitor containsString:
                    @"kCGEventSourceUnixProcessID"] &&
                [bridgeMouseMonitor containsString:
                    @"IOSUseBridgeWindowLogicalFrame"] &&
                [bridgeMouseMonitor containsString:
                    @"IOSUsePlayLastMouseDownDelivery"] &&
                [bridgeMouseMonitor containsString:
                    @"IOSUsePlayLastMouseUpDelivery"] &&
                [bridgeMouseMonitor containsString:
                    @"IOSUsePlayMouseDeliveryCount"] &&
                bridgeConfiguration != nil &&
                [bridgeConfiguration containsString:
                    @"IOSUseBridgeInstallMouseLocalMonitor"] &&
                [bridgeConfiguration containsString:
                    @"IOSUseBridgeCGWindowIsInsideVisibleFrame"],
            @"AppKit mouse evidence must retain tagged down/up identity, "
             @"translate through exact CG window geometry, and only report "
             @"ready when the physical window is on the visible display"
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
