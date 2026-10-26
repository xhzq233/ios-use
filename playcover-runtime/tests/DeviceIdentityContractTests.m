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
        // Folding changes display geometry while retaining the same hardware.
        setenv("IOS_USE_MAC_DEVICE", "iphone-duo", 1);
        setenv("IOS_USE_MAC_ORIENTATION", "portrait", 1);
        setenv("IOS_USE_MAC_EXPANDED", "0", 1);
        IOSUsePlayDeviceInsets folded = IOSUsePlayDeviceSafeInsets();
        passed &= IOSUsePlayDeviceIdentityRequire(
            strcmp(IOSUsePlayDeviceProductType(), "iPhone19,4") == 0 &&
            strcmp(IOSUsePlayDeviceHardwareTarget(), "A3447") == 0 &&
            IOSUsePlayDeviceNativeWidth == 1398 && IOSUsePlayDeviceNativeHeight == 2034 &&
            folded.right == 84 && folded.bottom == 34,
            @"Duo folded identity, framebuffer or safe area differs from iOS 27.1");
        setenv("IOS_USE_MAC_EXPANDED", "1", 1);
        IOSUsePlayDeviceInsets opened = IOSUsePlayDeviceSafeInsets();
        passed &= IOSUsePlayDeviceIdentityRequire(
            strcmp(IOSUsePlayDeviceProductType(), "iPhone19,4") == 0 &&
            IOSUsePlayDeviceNativeWidth == 2007 && IOSUsePlayDeviceNativeHeight == 2853 &&
            opened.top == 82 && opened.bottom == 34,
            @"Duo inner portrait framebuffer or safe area differs from iOS 27.1");
        const char *landscapes[] = {"landscape-right", "landscape-left"};
        for (int i = 0; i < 2; i++) {
            setenv("IOS_USE_MAC_ORIENTATION", landscapes[i], 1);
            setenv("IOS_USE_MAC_EXPANDED", "1", 1);
            IOSUsePlayDeviceInsets inner = IOSUsePlayDeviceSafeInsets();
            passed &= IOSUsePlayDeviceIdentityRequire(inner.right == 84 && inner.left == 0 && inner.bottom == 34,
                @"inner side band must remain right in both landscape orientations");
            setenv("IOS_USE_MAC_EXPANDED", "0", 1);
            IOSUsePlayDeviceInsets outer = IOSUsePlayDeviceSafeInsets();
            passed &= IOSUsePlayDeviceIdentityRequire(
                (i == 0 ? outer.left == 84 && outer.right == 0 : outer.right == 84 && outer.left == 0) && outer.bottom == 34,
                @"outer side band must follow the Simulator interface orientation");
        }
        unsetenv("IOS_USE_MAC_DEVICE");
        unsetenv("IOS_USE_MAC_ORIENTATION");
        unsetenv("IOS_USE_MAC_EXPANDED");
        if (!passed) {
            return 1;
        }
        puts("[device-identity-contract] PASS");
        return 0;
    }
}
