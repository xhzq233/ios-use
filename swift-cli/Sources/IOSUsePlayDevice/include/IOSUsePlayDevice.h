/*
 * IOSUsePlayDevice.h
 *
 * The single compile-time device contract shared by the PlayCover Runtime and
 * the Swift host.  Do not mirror these values in plist/bootstrap/session data.
 *
 * The safe-area and system-chrome geometry below matches the current
 * iPhone16,2 portrait contract.  It is intentionally centralized here, but
 * still requires the plan's live iPhone/vPhone oracle gate before release.
 */

#ifndef IOS_USE_PLAY_DEVICE_H
#define IOS_USE_PLAY_DEVICE_H

#include <stdint.h>

#define IOS_USE_PLAY_DEVICE_PRODUCT_TYPE "iPhone16,2"
#define IOS_USE_PLAY_DEVICE_HARDWARE_TARGET "A2849"

enum {
    IOSUsePlayDeviceLogicalWidth = 430,
    IOSUsePlayDeviceLogicalHeight = 932,
    IOSUsePlayDeviceScale = 3,
    IOSUsePlayDeviceNativeWidth =
        IOSUsePlayDeviceLogicalWidth * IOSUsePlayDeviceScale,
    IOSUsePlayDeviceNativeHeight =
        IOSUsePlayDeviceLogicalHeight * IOSUsePlayDeviceScale,

    IOSUsePlayDeviceSafeAreaTop = 59,
    IOSUsePlayDeviceSafeAreaLeft = 0,
    IOSUsePlayDeviceSafeAreaBottom = 34,
    IOSUsePlayDeviceSafeAreaRight = 0,

    IOSUsePlayDeviceStatusBarHeight = 59,
    IOSUsePlayDeviceDynamicIslandWidth = 126,
    IOSUsePlayDeviceDynamicIslandHeight = 37,
    IOSUsePlayDeviceDynamicIslandTop = 11,
    IOSUsePlayDeviceHomeIndicatorWidth = 148,
    IOSUsePlayDeviceHomeIndicatorHeight = 5,
    IOSUsePlayDeviceHomeIndicatorBottom = 8,
};

static inline const char *IOSUsePlayDeviceProductType(void) {
    return IOS_USE_PLAY_DEVICE_PRODUCT_TYPE;
}

static inline const char *IOSUsePlayDeviceHardwareTarget(void) {
    return IOS_USE_PLAY_DEVICE_HARDWARE_TARGET;
}

#if defined(__cplusplus)
static_assert(
    IOSUsePlayDeviceNativeWidth ==
        IOSUsePlayDeviceLogicalWidth * IOSUsePlayDeviceScale,
    "PlayCover native width must be derived from logical width and scale"
);
static_assert(
    IOSUsePlayDeviceNativeHeight ==
        IOSUsePlayDeviceLogicalHeight * IOSUsePlayDeviceScale,
    "PlayCover native height must be derived from logical height and scale"
);
#else
_Static_assert(
    IOSUsePlayDeviceNativeWidth ==
        IOSUsePlayDeviceLogicalWidth * IOSUsePlayDeviceScale,
    "PlayCover native width must be derived from logical width and scale"
);
_Static_assert(
    IOSUsePlayDeviceNativeHeight ==
        IOSUsePlayDeviceLogicalHeight * IOSUsePlayDeviceScale,
    "PlayCover native height must be derived from logical height and scale"
);
#endif

#endif /* IOS_USE_PLAY_DEVICE_H */
