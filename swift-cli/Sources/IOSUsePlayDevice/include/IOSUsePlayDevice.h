/*
 * IOSUsePlayDevice.h
 *
 * The single compile-time device contract shared by the PlayCover Runtime and
 * the Swift host.  Do not mirror these values in plist/bootstrap/session data.
 *
 * This header fixes only the target App's logical/native render surface.
 * Runtime-reported safe-area values are platform diagnostics: they are not a
 * host-prescribed inset or a synthetic system-chrome contract.
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
