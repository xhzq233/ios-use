#import <Foundation/Foundation.h>

static void IOSUseTestFail(NSString *message) {
    fprintf(stderr, "SyntheticChromeRemovalContract: %s\n", message.UTF8String);
    exit(1);
}

static void IOSUseTestAssert(BOOL condition, NSString *message) {
    if (!condition) {
        IOSUseTestFail(message);
    }
}

static NSString *IOSUseTestReadSource(const char *path) {
    NSError *error = nil;
    NSString *source = [NSString
        stringWithContentsOfFile:[NSString stringWithUTF8String:path]
                       encoding:NSUTF8StringEncoding
                          error:&error];
    IOSUseTestAssert(
        source != nil,
        [NSString stringWithFormat:@"could not read source: %@", error]
    );
    return source;
}

static NSString *IOSUseTestFunctionBody(
    NSString *source,
    NSString *name
) {
    NSRange declaration = [source rangeOfString:[name stringByAppendingString:@"("]];
    if (declaration.location == NSNotFound) {
        return nil;
    }
    NSRange opening = [source rangeOfString:@"{"
                                     options:0
                                       range:NSMakeRange(
                                           NSMaxRange(declaration),
                                           source.length - NSMaxRange(declaration)
                                       )];
    if (opening.location == NSNotFound) {
        return nil;
    }
    NSUInteger depth = 0;
    for (NSUInteger index = opening.location; index < source.length; index += 1) {
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

static void IOSUseTestNoLegacyChrome(
    NSString *source,
    NSString *sourceName
) {
    for (NSString *forbidden in @[
        @"IOSUsePlaySystemChrome",
        @"IOSUsePlayPassthroughWindow",
        @"systemChromeEvidence",
        @"containsSystemChrome",
        @"systemChromeMapped",
        @"system-chrome",
        @"_sceneSafeAreaInsetsIncludingStatusBar:",
        @"_sceneSettingsSafeAreaInsetsDidChange",
    ]) {
        IOSUseTestAssert(
            [source rangeOfString:forbidden].location == NSNotFound,
            [NSString stringWithFormat:
                @"%@ still contains removed synthetic-chrome marker %@",
                sourceName,
                forbidden]
        );
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        IOSUseTestAssert(
            argc == 5,
            @"usage: SystemChromeContractTests <RuntimeScreenshot.m> <Runtime.m> <RuntimeSocket.m> <RuntimeAutomation.m>"
        );
        NSString *screenshot = IOSUseTestReadSource(argv[1]);
        NSString *runtime = IOSUseTestReadSource(argv[2]);
        NSString *socket = IOSUseTestReadSource(argv[3]);
        NSString *automation = IOSUseTestReadSource(argv[4]);
        IOSUseTestNoLegacyChrome(screenshot, @"RuntimeScreenshot");
        IOSUseTestNoLegacyChrome(runtime, @"Runtime");
        IOSUseTestNoLegacyChrome(socket, @"RuntimeSocket");
        IOSUseTestNoLegacyChrome(automation, @"RuntimeAutomation");

        NSString *fullFrame = IOSUseTestFunctionBody(
            screenshot,
            @"IOSUseScreenshotFullFrameEvidence"
        );
        IOSUseTestAssert(
            fullFrame != nil &&
                [fullFrame containsString:@"@\"logicalRect\""] &&
                [fullFrame containsString:@"IOSUsePlayDeviceLogicalWidth"] &&
                [fullFrame containsString:@"IOSUsePlayDeviceLogicalHeight"] &&
                [fullFrame containsString:@"IOSUsePlayDeviceNativeWidth"] &&
                [fullFrame containsString:@"IOSUsePlayDeviceNativeHeight"] &&
                [fullFrame containsString:@"@\"uncropped\": @YES"] &&
                [fullFrame containsString:@"@\"safeAreaCropped\": @NO"] &&
                [fullFrame containsString:@"@\"identityMapping\""] &&
                [screenshot containsString:
                    @"IOSUsePlayCompositeWindowCaptures"] &&
                [screenshot containsString:
                    @"@\"syntheticChrome\": @NO"] &&
                [screenshot containsString:
                    @"@\"fullFrame\": fullFrameEvidence ?: @{}"],
            @"screenshot must emit the exact uncropped 430x932/1290x2796 full-frame proof"
        );

        NSString *runtimeFullFrame = IOSUseTestFunctionBody(
            runtime,
            @"IOSUseRuntimeFullFrameEvidence"
        );
        IOSUseTestAssert(
            runtimeFullFrame != nil &&
                [runtimeFullFrame containsString:@"@\"uncropped\": @YES"] &&
                [runtimeFullFrame containsString:@"@\"safeAreaCropped\": @NO"] &&
                [runtime containsString:@"@\"rendering\""] &&
                [runtime containsString:@"@\"syntheticChrome\": @NO"] &&
                [runtime containsString:@"@\"safeAreaOverride\": @NO"],
            @"runtime diagnostics must declare raw App rendering without a safe-area override"
        );

        IOSUseTestAssert(
            [socket containsString:@"@\"safeArea\":"] &&
                ![socket containsString:@"IOSUsePlayDeviceSafeArea"] &&
                ![socket containsString:@"safeArea.top -"],
            @"Runtime socket may observe safe area but must not use a fixed safe area as readiness"
        );

        NSString *bottomInteraction = IOSUseTestFunctionBody(
            automation,
            @"IOSUseAutomationIsBottomInteraction"
        );
        IOSUseTestAssert(
            bottomInteraction != nil &&
                [bottomInteraction containsString:@"UITabBar.class"] &&
                ![bottomInteraction containsString:@"point.y"] &&
                ![automation containsString:@"IOSUsePlayDeviceSafeArea"] &&
                [automation containsString:@"@\"tab-bar-interaction\""],
            @"focus release must be based only on a real UITabBar ancestor"
        );
        printf("SyntheticChromeRemovalContract: passed\n");
    }
    return 0;
}
