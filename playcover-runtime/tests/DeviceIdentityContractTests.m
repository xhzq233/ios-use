#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "IOSUsePlayDevice.h"

static BOOL IOSUsePlayDeviceIdentityRequire(
    BOOL condition,
    NSString *message
) {
    if (!condition) {
        fprintf(
            stderr,
            "[device-identity-contract] %s\n",
            message.UTF8String
        );
    }
    return condition;
}

int main(void) {
    @autoreleasepool {
        BOOL passed = YES;
        passed &= IOSUsePlayDeviceIdentityRequire(
            strcmp(IOSUsePlayDeviceProductType(), "iPhone16,2") == 0,
            @"product type is not the fixed iPhone16,2 contract"
        );
        passed &= IOSUsePlayDeviceIdentityRequire(
            strcmp(IOSUsePlayDeviceHardwareTarget(), "A2849") == 0,
            @"hardware target is not the fixed iPhone16,2 contract"
        );
        passed &= IOSUsePlayDeviceIdentityRequire(
            strcmp(IOSUsePlayDeviceModel(), "iPhone") == 0 &&
                strcmp(
                    IOSUsePlayDeviceLocalizedModel(),
                    "iPhone"
                ) == 0,
            @"UIDevice model strings are not fixed to iPhone"
        );
        passed &= IOSUsePlayDeviceIdentityRequire(
            IOSUsePlayDeviceUserInterfaceIdiom ==
                UIUserInterfaceIdiomPhone,
            @"user-interface idiom is not phone"
        );
        passed &= IOSUsePlayDeviceIdentityRequire(
            IOSUsePlayDeviceOrientation ==
                UIDeviceOrientationPortrait,
            @"device orientation is not portrait"
        );
        if (!passed) {
            return 1;
        }
        puts("[device-identity-contract] PASS");
        return 0;
    }
}
