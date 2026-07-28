#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "IOSUsePlayDevice.h"

extern UIEdgeInsets IOSUsePlaySafeAreaMaximumInsetsForTesting(
    UIEdgeInsets left,
    UIEdgeInsets right
);
extern BOOL IOSUsePlaySafeAreaMethodHasABIForTesting(
    Method method,
    const char *returnType,
    const char *lastArgumentType,
    unsigned int argumentCount
);
@interface IOSUsePlaySafeAreaABIFixture : NSObject
- (UIEdgeInsets)provider:(BOOL)includeStatusBar;
- (void)invalidate;
- (CGRect)wrongProvider:(BOOL)includeStatusBar;
- (void)wrongInvalidation:(BOOL)value;
@end

@implementation IOSUsePlaySafeAreaABIFixture
- (UIEdgeInsets)provider:(BOOL)includeStatusBar {
    (void)includeStatusBar;
    return UIEdgeInsetsZero;
}
- (void)invalidate {}
- (CGRect)wrongProvider:(BOOL)includeStatusBar {
    (void)includeStatusBar;
    return CGRectZero;
}
- (void)wrongInvalidation:(BOOL)value {
    (void)value;
}
@end

static BOOL IOSUsePlaySafeAreaRequire(
    BOOL condition,
    NSString *message
) {
    if (!condition) {
        fprintf(
            stderr,
            "[safe-area-contract] %s\n",
            message.UTF8String
        );
    }
    return condition;
}

static BOOL IOSUsePlaySafeAreaInsetsEqual(
    UIEdgeInsets left,
    UIEdgeInsets right
) {
    return UIEdgeInsetsEqualToEdgeInsets(left, right);
}

int main(void) {
    @autoreleasepool {
        BOOL passed = YES;
        UIEdgeInsets device = UIEdgeInsetsMake(
            IOSUsePlayDeviceSafeAreaTop,
            IOSUsePlayDeviceSafeAreaLeft,
            IOSUsePlayDeviceSafeAreaBottom,
            IOSUsePlayDeviceSafeAreaRight
        );
        passed &= IOSUsePlaySafeAreaRequire(
            IOSUsePlaySafeAreaInsetsEqual(
                device,
                UIEdgeInsetsMake(59, 0, 34, 0)
            ),
            @"iPhone16,2 base safe-area constants changed"
        );
        passed &= IOSUsePlaySafeAreaRequire(
            IOSUsePlaySafeAreaInsetsEqual(
                IOSUsePlaySafeAreaMaximumInsetsForTesting(
                    UIEdgeInsetsZero,
                    device
                ),
                device
            ),
            @"zero provider did not resolve to the device contract"
        );
        UIEdgeInsets larger = UIEdgeInsetsMake(61, 4, 40, 5);
        passed &= IOSUsePlaySafeAreaRequire(
            IOSUsePlaySafeAreaInsetsEqual(
                IOSUsePlaySafeAreaMaximumInsetsForTesting(
                    larger,
                    device
                ),
                larger
            ),
            @"compatibility helper shrank a larger provider inset"
        );
        Method provider = class_getInstanceMethod(
            IOSUsePlaySafeAreaABIFixture.class,
            @selector(provider:)
        );
        Method invalidation = class_getInstanceMethod(
            IOSUsePlaySafeAreaABIFixture.class,
            @selector(invalidate)
        );
        Method wrongProvider = class_getInstanceMethod(
            IOSUsePlaySafeAreaABIFixture.class,
            @selector(wrongProvider:)
        );
        Method wrongInvalidation = class_getInstanceMethod(
            IOSUsePlaySafeAreaABIFixture.class,
            @selector(wrongInvalidation:)
        );
        passed &= IOSUsePlaySafeAreaRequire(
            IOSUsePlaySafeAreaMethodHasABIForTesting(
                provider,
                @encode(UIEdgeInsets),
                @encode(BOOL),
                3
            ),
            @"UIEdgeInsets(id,SEL,BOOL) provider ABI was rejected"
        );
        passed &= IOSUsePlaySafeAreaRequire(
            IOSUsePlaySafeAreaMethodHasABIForTesting(
                invalidation,
                @encode(void),
                NULL,
                2
            ),
            @"void(id,SEL) invalidation ABI was rejected"
        );
        passed &= IOSUsePlaySafeAreaRequire(
            !IOSUsePlaySafeAreaMethodHasABIForTesting(
                wrongProvider,
                @encode(UIEdgeInsets),
                @encode(BOOL),
                3
            ),
            @"wrong provider return ABI was accepted"
        );
        passed &= IOSUsePlaySafeAreaRequire(
            !IOSUsePlaySafeAreaMethodHasABIForTesting(
                wrongInvalidation,
                @encode(void),
                NULL,
                2
            ),
            @"wrong invalidation argument ABI was accepted"
        );
        if (!passed) {
            return 1;
        }
        puts("[safe-area-contract] PASS");
        return 0;
    }
}
