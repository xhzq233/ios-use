#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// AppKit is reached dynamically because this code is built as one Catalyst
/// framework rather than PlayTools' separate macOS AKInterface bundle.
@interface IOSUsePlayAppKitBridge : NSObject

+ (void)captureSceneBackingLaunchEnvironment;
+ (void)scheduleFixedWindowConfiguration;
+ (BOOL)configureFixedWindow:(NSError * _Nullable * _Nullable)error;
+ (NSInteger)screenCount;
+ (CGPoint)mousePoint;
+ (CGRect)windowFrame;
+ (CGRect)mainScreenFrame;
+ (BOOL)isMainScreenEqualToFirst;
+ (BOOL)isFullscreen;
+ (void)setMenuBarVisible:(BOOL)visible;
+ (BOOL)hasVisibleNativeAlertCandidate;
+ (BOOL)hasVisibleNativeAlert;
+ (NSDictionary<NSString *, id> *)nativeAlertSnapshot;
+ (CGRect)nativeAlertFrame;
+ (NSString *)nativeAlertText;
+ (NSArray<NSDictionary<NSString *, id> *> *)nativeAlertActions;
+ (NSDictionary<NSString *, id> * _Nullable)
    performNativeAlertActionWithLabel:(NSString *)label
                                error:
        (NSError * _Nullable * _Nullable)error;
+ (NSDictionary<NSString *, id> * _Nullable)
    canvasCaptureGeometryWithError:
        (NSError * _Nullable * _Nullable)error;
+ (NSDictionary<NSString *, id> * _Nullable)
    dismissTransientTextInputWindows:
        (NSError * _Nullable * _Nullable)error;
+ (NSDictionary<NSString *, id> *)readinessDiagnostics;
+ (NSDictionary<NSString *, id> *)uiAutomationAvailability;
+ (NSDictionary<NSString *, id> *)diagnostics;
+ (NSDictionary<NSString *, id> *)diagnosticsWithNativeAlertSnapshot:
    (NSDictionary<NSString *, id> *)nativeAlertSnapshot;

@end

NS_ASSUME_NONNULL_END
