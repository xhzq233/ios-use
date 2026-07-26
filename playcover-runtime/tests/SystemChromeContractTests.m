#import "IOSUsePlayDevice.h"
#import "IOSUsePlaySystemChrome.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <string.h>

static void IOSUseTestFail(NSString *message) {
    fprintf(stderr, "SystemChromeContractTests: %s\n", message.UTF8String);
    exit(1);
}

static void IOSUseTestAssert(BOOL condition, NSString *message) {
    if (!condition) {
        IOSUseTestFail(message);
    }
}

static BOOL IOSUseTestMethodHasABI(
    Method method,
    const char *returnType,
    const char *argumentType,
    unsigned int argumentCount
) {
    if (method == NULL ||
        method_getNumberOfArguments(method) != argumentCount) {
        return NO;
    }
    char *actualReturn = method_copyReturnType(method);
    char *actualArgument = argumentCount > 2
        ? method_copyArgumentType(method, argumentCount - 1)
        : NULL;
    BOOL matches =
        actualReturn != NULL &&
        strcmp(actualReturn, returnType) == 0 &&
        ((argumentType == NULL && actualArgument == NULL) ||
         (argumentType != NULL &&
          actualArgument != NULL &&
          strcmp(actualArgument, argumentType) == 0));
    free(actualReturn);
    free(actualArgument);
    return matches;
}

static void IOSUseTestFillSevenSegmentDigit(
    CGContextRef context,
    CGFloat x,
    CGFloat y
) {
    CGRect segments[] = {
        CGRectMake(x + 2, y, 7, 1.5),
        CGRectMake(x + 1, y + 2, 1.5, 6),
        CGRectMake(x + 9, y + 2, 1.5, 6),
        CGRectMake(x + 2, y + 8, 7, 1.5),
        CGRectMake(x + 1, y + 10, 1.5, 6),
        CGRectMake(x + 9, y + 10, 1.5, 6),
        CGRectMake(x + 2, y + 16, 7, 1.5),
    };
    for (NSUInteger index = 0;
         index < sizeof(segments) / sizeof(segments[0]);
         index += 1) {
        CGContextFillRect(context, segments[index]);
    }
}

static CGImageRef IOSUseTestCreateImage(
    BOOL whiteBackground,
    BOOL includeChrome,
    BOOL dimmed
) CF_RETURNS_RETAINED {
    size_t width = IOSUsePlayDeviceNativeWidth;
    size_t height = IOSUsePlayDeviceNativeHeight;
    size_t rowBytes = width * 4;
    void *pixels = calloc(height, rowBytes);
    IOSUseTestAssert(pixels != NULL, @"could not allocate test pixels");
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(
        pixels,
        width,
        height,
        8,
        rowBytes,
        colorSpace,
        (CGBitmapInfo)kCGImageAlphaPremultipliedLast
    );
    CGColorSpaceRelease(colorSpace);
    IOSUseTestAssert(context != NULL, @"could not create test context");
    CGContextTranslateCTM(context, 0, height);
    CGContextScaleCTM(
        context,
        IOSUsePlayDeviceScale,
        -IOSUsePlayDeviceScale
    );
    CGFloat background = whiteBackground ? 1 : 0;
    CGContextSetRGBFillColor(
        context,
        background,
        background,
        background,
        1
    );
    CGContextFillRect(
        context,
        CGRectMake(
            0,
            0,
            IOSUsePlayDeviceLogicalWidth,
            IOSUsePlayDeviceLogicalHeight
        )
    );
    if (includeChrome) {
        CGRect island = CGRectMake(
            (IOSUsePlayDeviceLogicalWidth -
                IOSUsePlayDeviceDynamicIslandWidth) / 2.0,
            IOSUsePlayDeviceDynamicIslandTop,
            IOSUsePlayDeviceDynamicIslandWidth,
            IOSUsePlayDeviceDynamicIslandHeight
        );
        CGPathRef islandPath = CGPathCreateWithRoundedRect(
            island,
            island.size.height / 2.0,
            island.size.height / 2.0,
            NULL
        );
        CGContextSetRGBFillColor(context, 0, 0, 0, 1);
        CGContextAddPath(context, islandPath);
        CGContextFillPath(context);
        CGPathRelease(islandPath);

        CGFloat foreground = whiteBackground ? 0 : 1;
        CGContextSetRGBFillColor(
            context,
            foreground,
            foreground,
            foreground,
            1
        );
        for (NSUInteger index = 0; index < 5; index += 1) {
            IOSUseTestFillSevenSegmentDigit(
                context,
                27 + index * 14,
                18
            );
        }
        for (NSUInteger index = 0; index < 4; index += 1) {
            CGContextFillRect(
                context,
                CGRectMake(
                    326 + index * 4,
                    29 - index * 2,
                    2.5,
                    3 + index * 2
                )
            );
        }
        CGContextSetRGBStrokeColor(
            context,
            foreground,
            foreground,
            foreground,
            1
        );
        CGContextSetLineWidth(context, 1.5);
        CGContextStrokeRect(
            context,
            CGRectMake(349, 20, 17, 12)
        );
        CGContextStrokeRect(
            context,
            CGRectMake(378, 20, 25, 12)
        );
        CGContextFillRect(
            context,
            CGRectMake(381, 23, 17, 6)
        );
        CGContextFillRect(
            context,
            CGRectMake(404, 24, 2, 4)
        );

        CGRect home = CGRectMake(
            (IOSUsePlayDeviceLogicalWidth -
                IOSUsePlayDeviceHomeIndicatorWidth) / 2.0,
            IOSUsePlayDeviceLogicalHeight -
                IOSUsePlayDeviceHomeIndicatorBottom -
                IOSUsePlayDeviceHomeIndicatorHeight,
            IOSUsePlayDeviceHomeIndicatorWidth,
            IOSUsePlayDeviceHomeIndicatorHeight
        );
        CGPathRef homePath = CGPathCreateWithRoundedRect(
            home,
            home.size.height / 2.0,
            home.size.height / 2.0,
            NULL
        );
        CGContextAddPath(context, homePath);
        CGContextFillPath(context);
        CGPathRelease(homePath);
    }
    if (dimmed) {
        // Catalyst's native alert panel causes WindowServer to dim the
        // complete UIKit host window, including Runtime-owned chrome.
        CGContextSetRGBFillColor(context, 0, 0, 0, 0.80);
        CGContextFillRect(
            context,
            CGRectMake(
                0,
                0,
                IOSUsePlayDeviceLogicalWidth,
                IOSUsePlayDeviceLogicalHeight
            )
        );
    }
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    free(pixels);
    return image;
}

static NSDictionary<NSString *, id> *IOSUseTestEvidence(
    BOOL whiteBackground,
    BOOL includeChrome,
    BOOL dimmed
) {
    CGImageRef image = IOSUseTestCreateImage(
        whiteBackground,
        includeChrome,
        dimmed
    );
    NSDictionary<NSString *, id> *evidence =
        IOSUsePlaySystemChromeImageEvidence(image);
    CGImageRelease(image);
    return evidence;
}

static BOOL IOSUseTestSignature(
    NSDictionary<NSString *, id> *evidence,
    NSString *surface
) {
    return [evidence[surface][@"pixelSignature"] boolValue];
}

static BOOL IOSUseTestDimmedSignature(
    NSDictionary<NSString *, id> *evidence,
    NSString *surface
) {
    return [evidence[surface][@"dimmedPixelSignature"] boolValue];
}

static void IOSUseTestPixelDifferential(void) {
    NSDictionary *whiteBlank = IOSUseTestEvidence(YES, NO, NO);
    IOSUseTestAssert(
        [whiteBlank[@"dynamicIsland"][@"pixelObservable"] boolValue],
        @"white background should make Island pixels observable"
    );
    IOSUseTestAssert(
        !IOSUseTestSignature(whiteBlank, @"dynamicIsland") &&
        !IOSUseTestSignature(whiteBlank, @"statusTime") &&
        !IOSUseTestSignature(whiteBlank, @"statusGlyphs") &&
        !IOSUseTestSignature(whiteBlank, @"homeIndicator"),
        @"plain white image must not pass any chrome signature"
    );

    NSDictionary *blackBlank = IOSUseTestEvidence(NO, NO, NO);
    IOSUseTestAssert(
        ![blackBlank[@"dynamicIsland"][@"pixelObservable"] boolValue],
        @"black background should report Island pixels unobservable"
    );
    IOSUseTestAssert(
        !IOSUseTestSignature(blackBlank, @"dynamicIsland") &&
        !IOSUseTestSignature(blackBlank, @"statusTime") &&
        !IOSUseTestSignature(blackBlank, @"statusGlyphs") &&
        !IOSUseTestSignature(blackBlank, @"homeIndicator"),
        @"plain black image must not pass any chrome signature"
    );

    NSDictionary *whiteChrome = IOSUseTestEvidence(YES, YES, NO);
    IOSUseTestAssert(
        IOSUseTestSignature(whiteChrome, @"dynamicIsland") &&
        IOSUseTestSignature(whiteChrome, @"statusTime") &&
        IOSUseTestSignature(whiteChrome, @"statusGlyphs") &&
        IOSUseTestSignature(whiteChrome, @"homeIndicator"),
        [NSString stringWithFormat:
            @"chrome must have four independent signatures on white: %@",
            whiteChrome]
    );

    NSDictionary *blackChrome = IOSUseTestEvidence(NO, YES, NO);
    IOSUseTestAssert(
        ![blackChrome[@"dynamicIsland"][@"pixelObservable"] boolValue] &&
        !IOSUseTestSignature(blackChrome, @"dynamicIsland") &&
        IOSUseTestSignature(blackChrome, @"statusTime") &&
        IOSUseTestSignature(blackChrome, @"statusGlyphs") &&
        IOSUseTestSignature(blackChrome, @"homeIndicator"),
        [NSString stringWithFormat:
            @"black differential must expose only the documented "
             "Island fallback: %@",
            blackChrome]
    );

    NSDictionary *dimmedWhiteBlank =
        IOSUseTestEvidence(YES, NO, YES);
    IOSUseTestAssert(
        !IOSUseTestDimmedSignature(
            dimmedWhiteBlank,
            @"dynamicIsland"
        ) &&
        !IOSUseTestDimmedSignature(
            dimmedWhiteBlank,
            @"statusTime"
        ) &&
        !IOSUseTestDimmedSignature(
            dimmedWhiteBlank,
            @"statusGlyphs"
        ) &&
        !IOSUseTestDimmedSignature(
            dimmedWhiteBlank,
            @"homeIndicator"
        ),
        @"a uniformly dimmed blank image must not mimic modal chrome"
    );

    NSDictionary *dimmedWhiteChrome =
        IOSUseTestEvidence(YES, YES, YES);
    IOSUseTestAssert(
        IOSUseTestDimmedSignature(
            dimmedWhiteChrome,
            @"dynamicIsland"
        ) &&
        IOSUseTestDimmedSignature(
            dimmedWhiteChrome,
            @"statusTime"
        ) &&
        IOSUseTestDimmedSignature(
            dimmedWhiteChrome,
            @"statusGlyphs"
        ) &&
        IOSUseTestDimmedSignature(
            dimmedWhiteChrome,
            @"homeIndicator"
        ),
        [NSString stringWithFormat:
            @"native-modal dimming must preserve four bounded chrome "
             "signatures: %@",
            dimmedWhiteChrome]
    );
}

static void IOSUseTestSourceContract(NSString *sourcePath) {
    NSError *error = nil;
    NSString *source = [NSString
        stringWithContentsOfFile:sourcePath
                       encoding:NSUTF8StringEncoding
                          error:&error];
    IOSUseTestAssert(
        source != nil,
        [NSString stringWithFormat:
            @"could not read source contract: %@",
            error.localizedDescription]
    );
    NSRegularExpression *assignment = [
        NSRegularExpression
        regularExpressionWithPattern:
            @"additionalSafeAreaInsets\\s*="
                         options:0
                           error:&error
    ];
    IOSUseTestAssert(
        assignment != nil && error == nil,
        @"could not compile root-mutation audit"
    );
    IOSUseTestAssert(
        [assignment numberOfMatchesInString:source
                                    options:0
                                      range:NSMakeRange(
                                          0,
                                          source.length
                                      )] == 0 &&
        [source rangeOfString:@"setAdditionalSafeAreaInsets:"].location ==
            NSNotFound,
        @"Runtime must never write App additionalSafeAreaInsets"
    );
    for (NSString *required in @[
        @"_sceneSafeAreaInsetsIncludingStatusBar:",
        @"_sceneSettingsSafeAreaInsetsDidChange",
        @"method_getImplementation",
        @"dispatch_once",
        @"IOSUseSystemChromeMinuteTimerInstallCount",
        @"IOSUsePlayChromeSurfaceView",
        @"IOSUseChromeStatusBarController",
        @"childViewControllerForStatusBarStyle",
        @"IOSUseSystemChromeNativeAlertVisible",
        @"modalDimmedSignatures",
        @"runtimeAdditionalSafeAreaWriteCount",
    ]) {
        IOSUseTestAssert(
            [source rangeOfString:required].location != NSNotFound,
            [NSString stringWithFormat:
                @"missing system-chrome contract marker %@",
                required]
        );
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        IOSUseTestAssert(
            argc == 2,
            @"usage: SystemChromeContractTests <SystemChrome.m>"
        );
        SEL providerSelector = NSSelectorFromString(
            @"_sceneSafeAreaInsetsIncludingStatusBar:"
        );
        Method provider = class_getInstanceMethod(
            UIWindow.class,
            providerSelector
        );
        IOSUseTestAssert(
            IOSUseTestMethodHasABI(
                provider,
                @encode(UIEdgeInsets),
                @encode(BOOL),
                3
            ),
            @"safe-area provider selector/ABI mismatch"
        );
        Method invalidation = class_getInstanceMethod(
            UIWindow.class,
            NSSelectorFromString(
                @"_sceneSettingsSafeAreaInsetsDidChange"
            )
        );
        IOSUseTestAssert(
            IOSUseTestMethodHasABI(
                invalidation,
                @encode(void),
                NULL,
                2
            ),
            @"safe-area invalidation selector/ABI mismatch"
        );
        IOSUseTestSourceContract(
            [NSString stringWithUTF8String:argv[1]]
        );
        IOSUseTestPixelDifferential();
        printf("SystemChromeContractTests: passed\n");
    }
    return 0;
}
