#import <Foundation/Foundation.h>
#import "IOSUsePlayAppKitBridge.h"
#import "IOSUsePlayDevice.h"
#import "PTFakeMetaTouch.h"

FOUNDATION_EXPORT double IOSUsePlayRuntimeVersionNumber;
FOUNDATION_EXPORT const unsigned char IOSUsePlayRuntimeVersionString[];

/// Launch-only values retained after ios-use removes its private bootstrap
/// variables from the App-visible process environment.
FOUNDATION_EXPORT const char * _Nullable
IOSUsePlayRuntimeCapturedInstallRevision(void);

FOUNDATION_EXPORT const char * _Nullable
IOSUsePlayRuntimeCapturedPlayChainRoot(void);

FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nonnull
IOSUsePlayRuntimePhotosAuthorizationDiagnostics(void);

FOUNDATION_EXPORT BOOL
IOSUsePlayRuntimeTryLinearizePhotosMutation(
    uint64_t expectedStateVersion,
    NSDictionary<NSString *, id> * _Nullable * _Nullable
        blockingDiagnostics
);
