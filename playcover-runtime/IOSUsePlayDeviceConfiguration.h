#import <Foundation/Foundation.h>
@class UIWindow;

// The socket and native toolbar share this main-queue entry point.
NSDictionary *IOSUsePlayDeviceState(void);
void IOSUsePlayConfigureDevice(NSDictionary *changes, void (^completion)(NSDictionary *state, NSError *error));
BOOL IOSUsePlayDeviceConfigurationInProgress(void);
void IOSUsePlayRefreshDeviceTraits(UIWindow *window);

// Called by the existing safe-area provider during native geometry/layout.
void IOSUsePlayDeviceGeometryWillLayout(UIWindow *window);
