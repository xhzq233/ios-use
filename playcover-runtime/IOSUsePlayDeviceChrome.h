#import <Foundation/Foundation.h>

// Main queue only. Decoration never reparents the UIKit host or handles input.
void IOSUsePlayDeviceChromeUpdate(id hostWindow);
void IOSUsePlayDeviceChromeReset(void);
void IOSUsePlayDeviceChromeRefreshAppearance(void);

void IOSUsePlayDeviceChromeSetConfigurationPending(BOOL pending);
