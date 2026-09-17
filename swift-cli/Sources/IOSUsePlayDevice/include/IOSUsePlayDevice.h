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
        // Full-screen UIKit window, iPadOS 26 Simulator (both orientations).
        {"ipad-pro-11", "iPad14,3", "A2759", 1, 834, 1194, 2, 32, 25},
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
// Clockwise turns of the device artwork from its portrait source.
static inline int IOSUsePlayDeviceQuarterTurns(void) {
    const char *value = getenv("IOS_USE_MAC_ORIENTATION");
    if (!value) return 0;
    if (strcmp(value, "landscape-right") == 0) return 1;
    if (strcmp(value, "portrait-upside-down") == 0) return 2;
    if (strcmp(value, "landscape-left") == 0) return 3;
    return 0;
}
static inline const char *IOSUsePlayDeviceInterfaceName(int turns) {
    static const char *names[] = {"portrait", "landscape-right", "portrait-upside-down", "landscape-left"};
    return names[turns % 4];
}
static inline const char *IOSUsePlayDevicePhysicalName(int turns) {
    static const char *names[] = {"portrait", "landscape-left", "portrait-upside-down", "landscape-right"};
    return names[turns % 4];
}
static inline int IOSUsePlayDeviceIsLandscape(void) {
    return IOSUsePlayDeviceQuarterTurns() % 2;
}
static inline int IOSUsePlayDeviceInterfaceOrientation(void) {
    static const int orientations[] = {1, 3, 2, 4};
    return orientations[IOSUsePlayDeviceQuarterTurns()];
}
static inline int IOSUsePlayDeviceIsDuoInner(void) {
    return strcmp(IOSUsePlayDeviceCurrent()->name, "iphone-duo-inner") == 0;
}
static inline int IOSUsePlayDeviceIsDuo(void) {
    return strncmp(IOSUsePlayDeviceCurrent()->name, "iphone-duo-", 11) == 0;
}
static inline int IOSUsePlayDevicePhysicalQuarterTurns(void) {
    // The open screen's long axis is perpendicular to the outer screen's.
    // Opening the hinge changes interface aspect, not how the device is held.
    return (IOSUsePlayDeviceQuarterTurns() + (IOSUsePlayDeviceIsDuoInner() ? 3 : 0)) % 4;
}
static inline int IOSUsePlayDevicePhysicalOrientation(void) {
    static const int orientations[] = {1, 3, 2, 4};
    return orientations[IOSUsePlayDevicePhysicalQuarterTurns()];
}
typedef struct { int top, left, bottom, right; } IOSUsePlayDeviceInsets;
static inline int IOSUsePlayDeviceHasSideStatusBar(void) {
    return IOSUsePlayDeviceIsDuo() && (!IOSUsePlayDeviceIsDuoInner() || IOSUsePlayDeviceIsLandscape());
}
static inline int IOSUsePlayDeviceStatusBarOnLeft(void) {
    return IOSUsePlayDeviceQuarterTurns() >= 2;
}
static inline IOSUsePlayDeviceInsets IOSUsePlayDeviceSafeInsets(void) {
    const IOSUsePlayDevicePreset *p = IOSUsePlayDeviceCurrent();
    if (IOSUsePlayDeviceIsDuo()) {
        // Layout preview measured against Apple's Tech Talk 111466, 7:00.
        // The side band is ~18% of the 466pt outer canvas (84pt). These
        // estimates require calibration against the future Duo Simulator.
        if (IOSUsePlayDeviceHasSideStatusBar())
            return IOSUsePlayDeviceStatusBarOnLeft()
                ? (IOSUsePlayDeviceInsets){0, 84, 0, 0}
                : (IOSUsePlayDeviceInsets){0, 0, 0, 84};
        return (IOSUsePlayDeviceInsets){32, 0, 25, 0};
    }
    if (p->idiom == 0 && IOSUsePlayDeviceQuarterTurns() == 2)
        return (IOSUsePlayDeviceInsets){p->safeAreaBottom, 0, p->safeAreaTop, 0};
    if (p->idiom == 1 || !IOSUsePlayDeviceIsLandscape())
        return (IOSUsePlayDeviceInsets){p->safeAreaTop, 0, p->safeAreaBottom, 0};
    // Home-button iPhones have no landscape status bar or sensor housing.
    if (!p->safeAreaBottom) return (IOSUsePlayDeviceInsets){0, 0, 0, 0};
    return (IOSUsePlayDeviceInsets){0, p->safeAreaTop, 21, p->safeAreaTop};
}
static inline int IOSUsePlayDeviceWidth(void) {
    return IOSUsePlayDeviceIsLandscape() ? IOSUsePlayDeviceCurrent()->logicalHeight : IOSUsePlayDeviceCurrent()->logicalWidth;
}
static inline int IOSUsePlayDeviceHeight(void) {
    return IOSUsePlayDeviceIsLandscape() ? IOSUsePlayDeviceCurrent()->logicalWidth : IOSUsePlayDeviceCurrent()->logicalHeight;
}
typedef struct { int x, y, width, height; } IOSUsePlayDeviceRect;
static inline IOSUsePlayDeviceRect IOSUsePlayDeviceStatusBarRect(void) {
    int w = IOSUsePlayDeviceWidth(), h = IOSUsePlayDeviceHeight();
    if (IOSUsePlayDeviceHasSideStatusBar())
        return (IOSUsePlayDeviceRect){IOSUsePlayDeviceStatusBarOnLeft() ? 0 : w-84, 0, 84, h};
    return (IOSUsePlayDeviceRect){0, 0, w, IOSUsePlayDeviceSafeInsets().top};
}
static inline const char *IOSUsePlayDeviceProductType(void) { return IOSUsePlayDeviceCurrent()->productType; }
static inline const char *IOSUsePlayDeviceHardwareTarget(void) { return IOSUsePlayDeviceCurrent()->hardwareTarget; }
static inline const char *IOSUsePlayDeviceModel(void) { return IOSUsePlayDeviceCurrent()->idiom == 1 ? "iPad" : "iPhone"; }
static inline const char *IOSUsePlayDeviceLocalizedModel(void) { return IOSUsePlayDeviceModel(); }
#define IOS_USE_PLAY_DEVICE_PRODUCT_TYPE IOSUsePlayDeviceProductType()
#define IOS_USE_PLAY_DEVICE_HARDWARE_TARGET IOSUsePlayDeviceHardwareTarget()
#define IOSUsePlayDeviceUserInterfaceIdiom (IOSUsePlayDeviceCurrent()->idiom)
#define IOSUsePlayDeviceOrientation IOSUsePlayDevicePhysicalOrientation()
#define IOSUsePlayDeviceLogicalWidth IOSUsePlayDeviceWidth()
#define IOSUsePlayDeviceLogicalHeight IOSUsePlayDeviceHeight()
#define IOSUsePlayDeviceScale (IOSUsePlayDeviceCurrent()->scale)
#define IOSUsePlayDeviceNativeWidth ((size_t)(IOSUsePlayDeviceLogicalWidth * IOSUsePlayDeviceScale))
#define IOSUsePlayDeviceNativeHeight ((size_t)(IOSUsePlayDeviceLogicalHeight * IOSUsePlayDeviceScale))
#define IOSUsePlayDeviceSafeAreaTop (IOSUsePlayDeviceSafeInsets().top)
#define IOSUsePlayDeviceSafeAreaLeft (IOSUsePlayDeviceSafeInsets().left)
#define IOSUsePlayDeviceSafeAreaBottom (IOSUsePlayDeviceSafeInsets().bottom)
#define IOSUsePlayDeviceSafeAreaRight (IOSUsePlayDeviceSafeInsets().right)
#endif
