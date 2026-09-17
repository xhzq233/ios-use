#import <Foundation/Foundation.h>

// The socket and native toolbar share this main-queue entry point.
NSDictionary *IOSUsePlayDeviceState(void);
NSDictionary *IOSUsePlayConfigureDevice(NSDictionary *changes, NSError **error);
