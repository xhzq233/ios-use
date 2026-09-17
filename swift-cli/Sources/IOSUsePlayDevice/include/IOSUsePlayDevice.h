/* Shared Mac device geometry. Runtime changes are applied on the main queue. */
#ifndef IOS_USE_PLAY_DEVICE_H
#define IOS_USE_PLAY_DEVICE_H
#include <stdlib.h>
#include <stddef.h>
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
        // Duo layout previews: App Store screenshot canvases at 3x.
        // Keep the supported iPhone runtime identity; these do not emulate iOS 27.
        {"iphone-duo-inner", "iPhone16,2", "A2849", 0, 669, 951, 3, 0, 0},
        {"iphone-duo-outer", "iPhone16,2", "A2849", 0, 466, 678, 3, 0, 0},
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
    const char *name = getenv("IOS_USE_MAC_DEVICE");
    if (name && strcmp(name, "iphone-duo") == 0) {
        const char *expanded = getenv("IOS_USE_MAC_EXPANDED");
        name = expanded && strcmp(expanded, "0") == 0 ? "iphone-duo-outer" : "iphone-duo-inner";
    }
    const IOSUsePlayDevicePreset *preset = IOSUsePlayDevicePresetNamed(name);
    return preset ? preset : IOSUsePlayDevicePresetAt(0);
}
static inline int IOSUsePlayDeviceIsLandscape(void) {
    const char *value = getenv("IOS_USE_MAC_ORIENTATION");
    return value && strcmp(value, "landscape-right") == 0;
}
static inline int IOSUsePlayDeviceWidth(void) {
    return IOSUsePlayDeviceIsLandscape() ? IOSUsePlayDeviceCurrent()->logicalHeight : IOSUsePlayDeviceCurrent()->logicalWidth;
}
static inline int IOSUsePlayDeviceHeight(void) {
    return IOSUsePlayDeviceIsLandscape() ? IOSUsePlayDeviceCurrent()->logicalWidth : IOSUsePlayDeviceCurrent()->logicalHeight;
}
static inline const char *IOSUsePlayDeviceProductType(void) { return IOSUsePlayDeviceCurrent()->productType; }
static inline const char *IOSUsePlayDeviceHardwareTarget(void) { return IOSUsePlayDeviceCurrent()->hardwareTarget; }
static inline const char *IOSUsePlayDeviceModel(void) { return IOSUsePlayDeviceCurrent()->idiom == 1 ? "iPad" : "iPhone"; }
static inline const char *IOSUsePlayDeviceLocalizedModel(void) { return IOSUsePlayDeviceModel(); }
#define IOS_USE_PLAY_DEVICE_PRODUCT_TYPE IOSUsePlayDeviceProductType()
#define IOS_USE_PLAY_DEVICE_HARDWARE_TARGET IOSUsePlayDeviceHardwareTarget()
#define IOSUsePlayDeviceUserInterfaceIdiom (IOSUsePlayDeviceCurrent()->idiom)
#define IOSUsePlayDeviceOrientation (IOSUsePlayDeviceIsLandscape() ? 3 : 1)
#define IOSUsePlayDeviceLogicalWidth IOSUsePlayDeviceWidth()
#define IOSUsePlayDeviceLogicalHeight IOSUsePlayDeviceHeight()
#define IOSUsePlayDeviceScale (IOSUsePlayDeviceCurrent()->scale)
#define IOSUsePlayDeviceNativeWidth ((size_t)(IOSUsePlayDeviceLogicalWidth * IOSUsePlayDeviceScale))
#define IOSUsePlayDeviceNativeHeight ((size_t)(IOSUsePlayDeviceLogicalHeight * IOSUsePlayDeviceScale))
#define IOSUsePlayDeviceSafeAreaTop (IOSUsePlayDeviceIsLandscape() ? 0 : IOSUsePlayDeviceCurrent()->safeAreaTop)
#define IOSUsePlayDeviceSafeAreaLeft (IOSUsePlayDeviceIsLandscape() ? IOSUsePlayDeviceCurrent()->safeAreaTop : 0)
#define IOSUsePlayDeviceSafeAreaBottom (IOSUsePlayDeviceIsLandscape() ? (IOSUsePlayDeviceCurrent()->safeAreaBottom ? 21 : 0) : IOSUsePlayDeviceCurrent()->safeAreaBottom)
#define IOSUsePlayDeviceSafeAreaRight IOSUsePlayDeviceSafeAreaLeft
#endif
