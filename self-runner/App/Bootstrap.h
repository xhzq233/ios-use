#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
BOOL SRLoadXCTest(NSError **error);
BOOL SRInitializeXCTest(NSError **error);
BOOL SRLoadRuntime(NSError **error);
NSDictionary * _Nullable SRExecute(NSString *command, NSDictionary *arguments, NSError **error);
void SRStopAutomation(void);
NS_ASSUME_NONNULL_END
