#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Resolves a semantic view to its control or nearest interactive ancestor.
/// The caller must still validate current geometry, occlusion and hit testing.
UIView * _Nullable IOSUsePlayNormalizedInteractionView(UIView * _Nullable view);

/// A containing list cell does not compete with its own descendant control.
/// Equal owners and nested actionable descendants remain ambiguous.
BOOL IOSUsePlayInteractionOwnersConflict(UIView *target, UIView *other);

NS_ASSUME_NONNULL_END
