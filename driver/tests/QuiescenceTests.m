#import <XCTest/XCTest.h>
#import <dlfcn.h>
#import "XCTestPrivate.h"

@interface QuiescenceTests : XCTestCase
@end

@implementation QuiescenceTests
- (void)testNativeApplicationStateTimeoutIsScopedAndRestoredOnException {
    double (*getTimeout)(void) = dlsym(RTLD_DEFAULT, "_XCTApplicationStateTimeout");
    XCTAssertTrue(getTimeout != NULL);
    if (!getTimeout) return;
    double previous = getTimeout();
    __block double during = 0;
    NSError *error = nil;
    XCTAssertTrue(XCWithApplicationStateTimeout(0.25, ^{ during = getTimeout(); }, &error));
    XCTAssertNil(error);
    XCTAssertEqualWithAccuracy(during, 0.25, 0.001);
    XCTAssertEqualWithAccuracy(getTimeout(), previous, 0.001);
    XCTAssertFalse(XCWithApplicationStateTimeout(0.5, ^{
        @throw [NSException exceptionWithName:@"TestNativeWait" reason:nil userInfo:nil];
    }, &error));
    XCTAssertNotNil(error);
    XCTAssertEqualWithAccuracy(getTimeout(), previous, 0.001);
}
@end
