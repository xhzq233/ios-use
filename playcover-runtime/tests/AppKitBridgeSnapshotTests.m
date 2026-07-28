#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "IOSUsePlayAppKitBridge.h"

#import <stdint.h>
#import <unistd.h>

typedef CFArrayRef _Nullable
    (*IOSUseBridgeTestCopyWindowInfo)(
        CGWindowListOption,
        CGWindowID
    );
typedef NSArray * _Nullable
    (*IOSUseBridgeTestNativeAlertWindowsProvider)(void);

extern void
IOSUsePlayAppKitBridgeSetCGWindowListCopyWindowInfoForTesting(
    IOSUseBridgeTestCopyWindowInfo copyWindowInfo
);
extern void
IOSUsePlayAppKitBridgeSetNativeAlertWindowsProviderForTesting(
    IOSUseBridgeTestNativeAlertWindowsProvider windowsProvider
);
extern NSDictionary<
    NSNumber *,
    NSDictionary<NSString *, id> *
> * _Nullable
IOSUsePlayAppKitBridgeCopyOwnOnscreenCGWindowMetadataForTesting(void);
extern NSDictionary<NSString *, id> * _Nullable
IOSUsePlayAppKitBridgeSelectVisibleNativeAlertForTesting(
    NSArray * _Nullable windows,
    NSDictionary<
        NSNumber *,
        NSDictionary<NSString *, id> *
    > * _Nullable cgMetadata
);
extern BOOL
IOSUsePlayAppKitBridgeHasVisibleNativeAlertCandidateForTesting(
    NSArray * _Nullable windows
);

typedef NS_ENUM(NSUInteger, IOSUseBridgeSnapshotFixtureMode) {
    IOSUseBridgeSnapshotFixtureModeEmpty,
    IOSUseBridgeSnapshotFixtureModeValid,
    IOSUseBridgeSnapshotFixtureModeNil,
    IOSUseBridgeSnapshotFixtureModeDuplicate,
    IOSUseBridgeSnapshotFixtureModeInvalidBounds,
};

static IOSUseBridgeSnapshotFixtureMode
    IOSUseBridgeSnapshotCurrentFixtureMode;
static NSUInteger IOSUseBridgeSnapshotEnumerationCount;
static BOOL IOSUseBridgeSnapshotUnexpectedEnumerationArguments;

@interface IOSUseBridgeSnapshotAlertContentFixture : NSObject
@end

@implementation IOSUseBridgeSnapshotAlertContentFixture
@end

@interface IOSUseBridgeSnapshotAlertPanelFixture : NSObject

- (instancetype)initWithWindowNumber:(NSInteger)windowNumber;
- (BOOL)isVisible;
- (NSInteger)windowNumber;
- (id)contentView;

@end

@implementation IOSUseBridgeSnapshotAlertPanelFixture {
    NSInteger _windowNumber;
    IOSUseBridgeSnapshotAlertContentFixture *_contentView;
}

- (instancetype)initWithWindowNumber:(NSInteger)windowNumber {
    self = [super init];
    if (self != nil) {
        _windowNumber = windowNumber;
        _contentView =
            [[IOSUseBridgeSnapshotAlertContentFixture alloc] init];
    }
    return self;
}

- (BOOL)isVisible {
    return YES;
}

- (NSInteger)windowNumber {
    return _windowNumber;
}

- (id)contentView {
    return _contentView;
}

@end

static BOOL IOSUseBridgeSnapshotRequire(
    BOOL condition,
    NSString *message
) {
    if (!condition) {
        fprintf(
            stderr,
            "[appkit-bridge-snapshot] %s\n",
            message.UTF8String
        );
    }
    return condition;
}

static NSDictionary *IOSUseBridgeSnapshotRawWindowEntry(
    uint32_t windowNumber,
    CGRect bounds
) {
    CFDictionaryRef rawBounds =
        CGRectCreateDictionaryRepresentation(bounds);
    NSDictionary *entry = @{
        (__bridge NSString *)kCGWindowOwnerPID: @(getpid()),
        (__bridge NSString *)kCGWindowNumber: @(windowNumber),
        (__bridge NSString *)kCGWindowIsOnscreen: @YES,
        (__bridge NSString *)kCGWindowBounds:
            (__bridge NSDictionary *)rawBounds,
    };
    CFRelease(rawBounds);
    return entry;
}

static CFArrayRef _Nullable IOSUseBridgeSnapshotCopyWindowInfo(
    CGWindowListOption option,
    CGWindowID relativeToWindow
) {
    IOSUseBridgeSnapshotEnumerationCount += 1;
    if (option != kCGWindowListOptionOnScreenOnly ||
        relativeToWindow != kCGNullWindowID) {
        IOSUseBridgeSnapshotUnexpectedEnumerationArguments = YES;
    }
    switch (IOSUseBridgeSnapshotCurrentFixtureMode) {
        case IOSUseBridgeSnapshotFixtureModeEmpty:
            return CFBridgingRetain(@[]);
        case IOSUseBridgeSnapshotFixtureModeValid:
            return CFBridgingRetain(@[
                IOSUseBridgeSnapshotRawWindowEntry(
                    41,
                    CGRectMake(10, 20, 300, 600)
                ),
            ]);
        case IOSUseBridgeSnapshotFixtureModeNil:
            return NULL;
        case IOSUseBridgeSnapshotFixtureModeDuplicate: {
            NSDictionary *entry =
                IOSUseBridgeSnapshotRawWindowEntry(
                    41,
                    CGRectMake(10, 20, 300, 600)
                );
            return CFBridgingRetain(@[entry, entry]);
        }
        case IOSUseBridgeSnapshotFixtureModeInvalidBounds:
            return CFBridgingRetain(@[
                IOSUseBridgeSnapshotRawWindowEntry(
                    41,
                    CGRectMake(10, 20, 0, 600)
                ),
            ]);
    }
}

static NSArray *IOSUseBridgeSnapshotEmptyNativeAlertWindows(void) {
    return @[];
}

static void IOSUseBridgeSnapshotResetEnumeration(
    IOSUseBridgeSnapshotFixtureMode mode
) {
    IOSUseBridgeSnapshotCurrentFixtureMode = mode;
    IOSUseBridgeSnapshotEnumerationCount = 0;
    IOSUseBridgeSnapshotUnexpectedEnumerationArguments = NO;
}

static BOOL IOSUseBridgeSnapshotTestMetadataValidation(void) {
    BOOL passed = YES;

    IOSUseBridgeSnapshotResetEnumeration(
        IOSUseBridgeSnapshotFixtureModeValid
    );
    NSDictionary *valid =
        IOSUsePlayAppKitBridgeCopyOwnOnscreenCGWindowMetadataForTesting();
    NSDictionary *entry = valid[@41];
    passed &= IOSUseBridgeSnapshotRequire(
        IOSUseBridgeSnapshotEnumerationCount == 1 &&
            !IOSUseBridgeSnapshotUnexpectedEnumerationArguments &&
            valid.count == 1 &&
            [entry[@"frontToBackIndex"] unsignedIntegerValue] == 0 &&
            CGRectEqualToRect(
                [entry[@"boundsValue"] CGRectValue],
                CGRectMake(10, 20, 300, 600)
            ),
        @"valid metadata did not preserve exact bounds and z-order"
    );

    IOSUseBridgeSnapshotResetEnumeration(
        IOSUseBridgeSnapshotFixtureModeNil
    );
    passed &= IOSUseBridgeSnapshotRequire(
        IOSUsePlayAppKitBridgeCopyOwnOnscreenCGWindowMetadataForTesting() ==
                nil &&
            IOSUseBridgeSnapshotEnumerationCount == 1,
        @"a nil CGWindow snapshot did not fail closed"
    );

    IOSUseBridgeSnapshotResetEnumeration(
        IOSUseBridgeSnapshotFixtureModeDuplicate
    );
    passed &= IOSUseBridgeSnapshotRequire(
        IOSUsePlayAppKitBridgeCopyOwnOnscreenCGWindowMetadataForTesting() ==
                nil &&
            IOSUseBridgeSnapshotEnumerationCount == 1,
        @"duplicate own-process window numbers did not fail closed"
    );

    IOSUseBridgeSnapshotResetEnumeration(
        IOSUseBridgeSnapshotFixtureModeInvalidBounds
    );
    passed &= IOSUseBridgeSnapshotRequire(
        IOSUsePlayAppKitBridgeCopyOwnOnscreenCGWindowMetadataForTesting() ==
                nil &&
            IOSUseBridgeSnapshotEnumerationCount == 1,
        @"invalid own-process window bounds did not fail closed"
    );

    return passed;
}

static BOOL IOSUseBridgeSnapshotTestCallerMetadataSelection(void) {
    IOSUseBridgeSnapshotAlertPanelFixture *back =
        [[IOSUseBridgeSnapshotAlertPanelFixture alloc]
            initWithWindowNumber:51];
    IOSUseBridgeSnapshotAlertPanelFixture *front =
        [[IOSUseBridgeSnapshotAlertPanelFixture alloc]
            initWithWindowNumber:52];
    NSDictionary *metadata = @{
        @51: @{
            @"boundsValue":
                [NSValue valueWithCGRect:
                    CGRectMake(20, 30, 200, 400)],
            @"frontToBackIndex": @1,
        },
        @52: @{
            @"boundsValue":
                [NSValue valueWithCGRect:
                    CGRectMake(25, 35, 180, 360)],
            @"frontToBackIndex": @0,
        },
    };
    NSDictionary *selection =
        IOSUsePlayAppKitBridgeSelectVisibleNativeAlertForTesting(
            @[back, front],
            metadata
        );
    BOOL passed = IOSUseBridgeSnapshotRequire(
        IOSUsePlayAppKitBridgeHasVisibleNativeAlertCandidateForTesting(
            @[back, front]
        ),
        @"visible native alert candidates were not detected before exact CGWindow selection"
    );
    passed &= IOSUseBridgeSnapshotRequire(
        !IOSUsePlayAppKitBridgeHasVisibleNativeAlertCandidateForTesting(
            @[]
        ),
        @"an empty AppKit window inventory reported an alert candidate"
    );
    passed &= IOSUseBridgeSnapshotRequire(
        selection[@"window"] == front &&
            selection[@"cgMetadata"] == metadata &&
            [selection[@"windowNumber"] unsignedIntegerValue] == 52,
        @"caller-provided metadata did not select the frontmost exact alert"
    );
    passed &= IOSUseBridgeSnapshotRequire(
        IOSUsePlayAppKitBridgeSelectVisibleNativeAlertForTesting(
            @[front],
            nil
        ) == nil,
        @"a nil caller-provided metadata snapshot did not fail closed"
    );
    IOSUseBridgeSnapshotAlertPanelFixture *duplicate =
        [[IOSUseBridgeSnapshotAlertPanelFixture alloc]
            initWithWindowNumber:52];
    passed &= IOSUseBridgeSnapshotRequire(
        IOSUsePlayAppKitBridgeSelectVisibleNativeAlertForTesting(
            @[front, duplicate],
            metadata
        ) == nil,
        @"duplicate AppKit objects for one CGWindow identity did not fail closed"
    );
    return passed;
}

static BOOL IOSUseBridgeSnapshotTestRequestEnumerationCounts(void) {
    IOSUseBridgeSnapshotResetEnumeration(
        IOSUseBridgeSnapshotFixtureModeEmpty
    );
    NSDictionary *first = [IOSUsePlayAppKitBridge diagnostics];
    BOOL passed = IOSUseBridgeSnapshotRequire(
        [first isKindOfClass:NSDictionary.class] &&
            IOSUseBridgeSnapshotEnumerationCount == 1 &&
            !IOSUseBridgeSnapshotUnexpectedEnumerationArguments,
        @"one full diagnostics request did not enumerate CGWindow metadata exactly once"
    );

    NSDictionary *second = [IOSUsePlayAppKitBridge diagnostics];
    passed &= IOSUseBridgeSnapshotRequire(
        [second isKindOfClass:NSDictionary.class] &&
            IOSUseBridgeSnapshotEnumerationCount == 2,
        @"consecutive full diagnostics requests did not take one fresh snapshot each"
    );

    NSUInteger count = IOSUseBridgeSnapshotEnumerationCount;
    (void)[IOSUsePlayAppKitBridge hasVisibleNativeAlert];
    passed &= IOSUseBridgeSnapshotRequire(
        IOSUseBridgeSnapshotEnumerationCount == count + 1,
        @"hasVisibleNativeAlert did not take a fresh snapshot"
    );
    count = IOSUseBridgeSnapshotEnumerationCount;
    (void)[IOSUsePlayAppKitBridge nativeAlertFrame];
    passed &= IOSUseBridgeSnapshotRequire(
        IOSUseBridgeSnapshotEnumerationCount == count + 1,
        @"nativeAlertFrame did not take a fresh snapshot"
    );
    count = IOSUseBridgeSnapshotEnumerationCount;
    (void)[IOSUsePlayAppKitBridge nativeAlertText];
    passed &= IOSUseBridgeSnapshotRequire(
        IOSUseBridgeSnapshotEnumerationCount == count + 1,
        @"nativeAlertText did not take a fresh snapshot"
    );
    count = IOSUseBridgeSnapshotEnumerationCount;
    (void)[IOSUsePlayAppKitBridge nativeAlertActions];
    passed &= IOSUseBridgeSnapshotRequire(
        IOSUseBridgeSnapshotEnumerationCount == count + 1,
        @"nativeAlertActions did not take a fresh snapshot"
    );

    count = IOSUseBridgeSnapshotEnumerationCount;
    NSError *firstActionError = nil;
    NSDictionary *firstAction =
        [IOSUsePlayAppKitBridge
            performNativeAlertActionWithLabel:@"OK"
                                        error:&firstActionError];
    passed &= IOSUseBridgeSnapshotRequire(
        firstAction == nil &&
            firstActionError != nil &&
            IOSUseBridgeSnapshotEnumerationCount == count + 1,
        @"native alert action reused diagnostics metadata"
    );
    count = IOSUseBridgeSnapshotEnumerationCount;
    NSError *secondActionError = nil;
    NSDictionary *secondAction =
        [IOSUsePlayAppKitBridge
            performNativeAlertActionWithLabel:@"OK"
                                        error:&secondActionError];
    passed &= IOSUseBridgeSnapshotRequire(
        secondAction == nil &&
            secondActionError != nil &&
            IOSUseBridgeSnapshotEnumerationCount == count + 1,
        @"consecutive native alert actions did not each select freshly"
    );
    return passed;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        (void)argv;
        if (argc != 1) {
            fprintf(
                stderr,
                "usage: AppKitBridgeSnapshotTests\n"
            );
            return 2;
        }
        IOSUsePlayAppKitBridgeSetCGWindowListCopyWindowInfoForTesting(
            IOSUseBridgeSnapshotCopyWindowInfo
        );
        IOSUsePlayAppKitBridgeSetNativeAlertWindowsProviderForTesting(
            IOSUseBridgeSnapshotEmptyNativeAlertWindows
        );

        BOOL passed =
            IOSUseBridgeSnapshotTestMetadataValidation();
        passed &=
            IOSUseBridgeSnapshotTestCallerMetadataSelection();
        passed &=
            IOSUseBridgeSnapshotTestRequestEnumerationCounts();

        IOSUsePlayAppKitBridgeSetNativeAlertWindowsProviderForTesting(
            NULL
        );
        IOSUsePlayAppKitBridgeSetCGWindowListCopyWindowInfoForTesting(
            NULL
        );
        if (!passed) {
            return 1;
        }
        printf(
            "[appkit-bridge-snapshot] PASS fresh request snapshots\n"
        );
        return 0;
    }
}
