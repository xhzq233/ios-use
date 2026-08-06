#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns a bounded, read-only snapshot of the active UIKit UIView hierarchy.
/// UIKit work is marshalled to the main queue. On failure, `commandError`
/// contains the complete Runtime JSON error object.
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable
IOSUsePlayRuntimeViewTreeCommand(
    NSDictionary<NSString *, id> *arguments,
    NSDictionary<NSString *, id> * _Nullable * _Nullable commandError
);

#if defined(IOS_USE_PLAY_RUNTIME_VIEW_TREE_TESTING)
FOUNDATION_EXPORT NSDictionary<NSString *, id> *
IOSUsePlayRuntimeViewTreeSnapshotForTesting(
    NSArray<UIView *> *roots,
    NSInteger maximumDepth
);
#endif

NS_ASSUME_NONNULL_END
