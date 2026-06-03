#import <Foundation/Foundation.h>
#import "IOSUseDriver-Swift.h"

__attribute__((constructor))
static void IOSUseDriverAutostart(void) {
    NSLog(@"%@", @"[debug][xctest-autostart] IOSUseDriver bundle loaded");
    [DriverServer startSharedIfNeeded];
}
