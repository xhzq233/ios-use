#import "IOSUsePlayInteractionView.h"

BOOL IOSUsePlayInteractionOwnersConflict(UIView *target, UIView *other) {
    if (target.window == nil || target.window != other.window) return NO;
    if (target != other && [target isDescendantOfView:other] &&
        ([other isKindOfClass:UITableViewCell.class] ||
         [other isKindOfClass:UICollectionViewCell.class])) return NO;
    return target == other || [target isDescendantOfView:other] ||
        [other isDescendantOfView:target];
}

UIView * _Nullable IOSUsePlayNormalizedInteractionView(
    UIView * _Nullable view
) {
    // Labels can live below noninteractive decoration inside a UIControl
    // (e.g. Catalyst's UITabBarButton > UIVisualEffectView > content > label).
    // The control owns delivery; its decoration does not disable the control.
    // Validate visibility while finding it, then validate its entire ancestry.
    for (UIView *candidate = view;
         candidate != nil && ![candidate isKindOfClass:UIWindow.class];
         candidate = candidate.superview) {
        if (candidate.hidden || candidate.alpha <= 0.01 ||
            candidate.accessibilityElementsHidden) return nil;
        if ([candidate isKindOfClass:UIControl.class]) {
            view = candidate;
            break;
        }
    }
    UIView *nearestOwner = nil;
    for (UIView *candidate = view;
         candidate != nil;
         candidate = candidate.superview) {
        if (candidate.hidden ||
            candidate.alpha <= 0.01 ||
            candidate.accessibilityElementsHidden) {
            return nil;
        }
        if ([candidate isKindOfClass:UIControl.class] &&
            ![(UIControl *)candidate isEnabled]) {
            return nil;
        }
        if (!candidate.userInteractionEnabled) {
            if (candidate == view &&
                ![candidate isKindOfClass:UIControl.class]) {
                continue;
            }
            return nil;
        }
        if (nearestOwner == nil &&
            ![candidate isKindOfClass:UIWindow.class]) {
            nearestOwner = candidate;
        }
        if ([candidate isKindOfClass:UIWindow.class]) {
            break;
        }
    }
    return nearestOwner;
}
