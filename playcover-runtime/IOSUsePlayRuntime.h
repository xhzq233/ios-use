#import <Foundation/Foundation.h>
#import "IOSUsePlayAppKitBridge.h"
#import "IOSUsePlayDevice.h"
#import "PTFakeMetaTouch.h"

FOUNDATION_EXPORT double IOSUsePlayRuntimeVersionNumber;
FOUNDATION_EXPORT const unsigned char IOSUsePlayRuntimeVersionString[];

FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nonnull
IOSUsePlayRuntimePhotosAuthorizationDiagnostics(void);

FOUNDATION_EXPORT BOOL
IOSUsePlayRuntimeTryLinearizePhotosMutation(
    uint64_t expectedStateVersion,
    NSDictionary<NSString *, id> * _Nullable * _Nullable
        blockingDiagnostics
);
