#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, IOSUsePlaySnapshotStopReason) {
    IOSUsePlaySnapshotStopNone,
    IOSUsePlaySnapshotStopDeadline,
    IOSUsePlaySnapshotStopCancelled,
};

/// Shared by the waiting command and its main-thread traversal. Cancellation
/// is cooperative: an accessibility getter already executing cannot be stopped.
@interface IOSUsePlaySnapshotBudget : NSObject
- (instancetype)initWithTimeout:(NSTimeInterval)timeout;
@property(nonatomic, readonly) NSTimeInterval remainingSeconds;
@property(nonatomic, readonly) IOSUsePlaySnapshotStopReason stopReason;
- (BOOL)shouldContinue;
- (void)cancel;
@end

/// Serializes captures and discards results produced after their deadline.
/// The capture block must check its budget between synchronous getter calls.
id _Nullable IOSUsePlayRunSnapshot(
    NSTimeInterval timeout,
    BOOL (^ _Nullable cancellationCheck)(void),
    id _Nullable (^capture)(IOSUsePlaySnapshotBudget *budget),
    IOSUsePlaySnapshotStopReason *stopReason
);

NSArray * _Nullable IOSUsePlaySnapshotContainerElements(
    id object,
    NSUInteger maximumChildren,
    IOSUsePlaySnapshotBudget * _Nullable budget,
    NSString * _Nullable * _Nullable failureMessage
);

NS_ASSUME_NONNULL_END
