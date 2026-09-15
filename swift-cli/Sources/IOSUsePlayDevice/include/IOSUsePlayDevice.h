/* Shared Mac device presets, selected for each cold App launch. */
#ifndef IOS_USE_PLAY_DEVICE_H
#define IOS_USE_PLAY_DEVICE_H
#include <stdlib.h>
#include <string.h>
typedef struct {
    const char *name;
    const char *productType;
    const char *hardwareTarget;
    int idiom;
    int logicalWidth, logicalHeight, scale;
    int safeAreaTop, safeAreaBottom;
} IOSUsePlayDevicePreset;
static inline const IOSUsePlayDevicePreset *IOSUsePlayDevicePresetAt(int index) {
    static const IOSUsePlayDevicePreset presets[] = {
        {"iphone-15-pro-max", "iPhone16,2", "A2849", 0, 430, 932, 3, 59, 34},
        {"iphone-se", "iPhone14,6", "A2595", 0, 375, 667, 2, 20, 0},
        {"iphone-13", "iPhone14,5", "A2482", 0, 390, 844, 3, 47, 34},
        {"iphone-15-pro", "iPhone16,1", "A2848", 0, 393, 852, 3, 59, 34},
        {"ipad-pro-11", "iPad14,3", "A2759", 1, 834, 1194, 2, 24, 20},
    };
    return index >= 0 && index < (int)(sizeof(presets) / sizeof(presets[0]))
        ? &presets[index] : NULL;
}
static inline const IOSUsePlayDevicePreset *IOSUsePlayDevicePresetNamed(const char *name) {
    if (!name || !name[0]) return IOSUsePlayDevicePresetAt(0);
    for (int i = 0; IOSUsePlayDevicePresetAt(i); i++) {
        const IOSUsePlayDevicePreset *preset = IOSUsePlayDevicePresetAt(i);
        if (strcmp(name, preset->name) == 0) return preset;
    }
    return NULL;
}
static inline const IOSUsePlayDevicePreset *IOSUsePlayDeviceCurrent(void) {
    const IOSUsePlayDevicePreset *preset = IOSUsePlayDevicePresetNamed(getenv("IOS_USE_MAC_DEVICE"));
    return preset ? preset : IOSUsePlayDevicePresetAt(0);
}
static inline const char *IOSUsePlayDeviceProductType(void) { return IOSUsePlayDeviceCurrent()->productType; }
static inline const char *IOSUsePlayDeviceHardwareTarget(void) { return IOSUsePlayDeviceCurrent()->hardwareTarget; }
static inline const char *IOSUsePlayDeviceModel(void) { return IOSUsePlayDeviceCurrent()->idiom == 1 ? "iPad" : "iPhone"; }
static inline const char *IOSUsePlayDeviceLocalizedModel(void) { return IOSUsePlayDeviceModel(); }
#define IOS_USE_PLAY_DEVICE_PRODUCT_TYPE IOSUsePlayDeviceProductType()
#define IOS_USE_PLAY_DEVICE_HARDWARE_TARGET IOSUsePlayDeviceHardwareTarget()
#define IOSUsePlayDeviceUserInterfaceIdiom (IOSUsePlayDeviceCurrent()->idiom)
#define IOSUsePlayDeviceOrientation 1
#define IOSUsePlayDeviceLogicalWidth (IOSUsePlayDeviceCurrent()->logicalWidth)
#define IOSUsePlayDeviceLogicalHeight (IOSUsePlayDeviceCurrent()->logicalHeight)
#define IOSUsePlayDeviceScale (IOSUsePlayDeviceCurrent()->scale)
#define IOSUsePlayDeviceNativeWidth (IOSUsePlayDeviceLogicalWidth * IOSUsePlayDeviceScale)
#define IOSUsePlayDeviceNativeHeight (IOSUsePlayDeviceLogicalHeight * IOSUsePlayDeviceScale)
#define IOSUsePlayDeviceSafeAreaTop (IOSUsePlayDeviceCurrent()->safeAreaTop)
#define IOSUsePlayDeviceSafeAreaLeft 0
#define IOSUsePlayDeviceSafeAreaBottom (IOSUsePlayDeviceCurrent()->safeAreaBottom)
#define IOSUsePlayDeviceSafeAreaRight 0
#endif
