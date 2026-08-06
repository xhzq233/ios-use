#import "IOSUsePlayRuntimeViewTree.h"

#import "IOSUsePlayRuntimeDOM.h"

#import <CoreFoundation/CoreFoundation.h>
#import <math.h>

static const NSInteger IOSUseViewTreeMaximumDepth = 20;
static const NSUInteger IOSUseViewTreeMaximumNodes = 1000;
static const NSUInteger IOSUseViewTreeMaximumStringLength = 512;

@interface IOSUseViewTreeContext : NSObject
@property(nonatomic) NSInteger maximumDepth;
@property(nonatomic) NSUInteger nodeCount;
@property(nonatomic) BOOL truncated;
@property(nonatomic, copy, nullable) NSString *failureMessage;
@end

@implementation IOSUseViewTreeContext
@end

static NSDictionary<NSString *, id> *IOSUseViewTreeError(
    NSString *code,
    NSString *message,
    NSString *category,
    NSString *phase,
    BOOL retryable
) {
    return @{
        @"code": code,
        @"message": message,
        @"details": @{
            @"category": category,
            @"phase": phase,
            @"retryable": @(retryable),
            @"fatal": @NO,
            @"candidateCount": @0,
            @"candidates": @[],
            @"suggestions": @[],
        },
    };
}

static BOOL IOSUseViewTreeIsInteger(id value) {
    if (![value isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value) ==
            CFBooleanGetTypeID()) {
        return NO;
    }
    double number = [value doubleValue];
    return isfinite(number) && floor(number) == number;
}

static NSString * _Nullable IOSUseViewTreeString(
    id _Nullable value
) {
    if (![value isKindOfClass:NSString.class]) {
        return nil;
    }
    NSString *string = value;
    if (string.length <= IOSUseViewTreeMaximumStringLength) {
        return string;
    }
    NSRange range = [string rangeOfComposedCharacterSequencesForRange:
        NSMakeRange(0, IOSUseViewTreeMaximumStringLength)];
    return [[string substringWithRange:range]
        stringByAppendingString:@"…"];
}

static NSDictionary<NSString *, NSNumber *> *IOSUseViewTreeRect(
    CGRect rect
) {
    return @{
        @"x": @(rect.origin.x),
        @"y": @(rect.origin.y),
        @"width": @(rect.size.width),
        @"height": @(rect.size.height),
    };
}

static NSDictionary<NSString *, NSNumber *> *IOSUseViewTreeSize(
    CGSize size
) {
    return @{
        @"width": @(size.width),
        @"height": @(size.height),
    };
}

static NSDictionary<NSString *, NSNumber *> *IOSUseViewTreePoint(
    CGPoint point
) {
    return @{
        @"x": @(point.x),
        @"y": @(point.y),
    };
}

static NSDictionary<NSString *, NSNumber *> *IOSUseViewTreeInsets(
    UIEdgeInsets insets
) {
    return @{
        @"top": @(insets.top),
        @"left": @(insets.left),
        @"bottom": @(insets.bottom),
        @"right": @(insets.right),
    };
}

static NSString *IOSUseViewTreeContentMode(
    UIViewContentMode mode
) {
    switch (mode) {
        case UIViewContentModeScaleToFill: return @"scaleToFill";
        case UIViewContentModeScaleAspectFit: return @"scaleAspectFit";
        case UIViewContentModeScaleAspectFill: return @"scaleAspectFill";
        case UIViewContentModeRedraw: return @"redraw";
        case UIViewContentModeCenter: return @"center";
        case UIViewContentModeTop: return @"top";
        case UIViewContentModeBottom: return @"bottom";
        case UIViewContentModeLeft: return @"left";
        case UIViewContentModeRight: return @"right";
        case UIViewContentModeTopLeft: return @"topLeft";
        case UIViewContentModeTopRight: return @"topRight";
        case UIViewContentModeBottomLeft: return @"bottomLeft";
        case UIViewContentModeBottomRight: return @"bottomRight";
    }
    return [NSString stringWithFormat:@"unknown(%ld)", (long)mode];
}

static NSString *IOSUseViewTreeTextAlignment(
    NSTextAlignment alignment
) {
    switch (alignment) {
        case NSTextAlignmentLeft: return @"left";
        case NSTextAlignmentCenter: return @"center";
        case NSTextAlignmentRight: return @"right";
        case NSTextAlignmentJustified: return @"justified";
        case NSTextAlignmentNatural: return @"natural";
    }
    return [NSString stringWithFormat:
        @"unknown(%ld)",
        (long)alignment];
}

static NSString *IOSUseViewTreeImageRenderingMode(
    UIImageRenderingMode mode
) {
    switch (mode) {
        case UIImageRenderingModeAutomatic: return @"automatic";
        case UIImageRenderingModeAlwaysOriginal: return @"alwaysOriginal";
        case UIImageRenderingModeAlwaysTemplate: return @"alwaysTemplate";
    }
    return [NSString stringWithFormat:@"unknown(%ld)", (long)mode];
}

static NSString *IOSUseViewTreeStackAxis(
    UILayoutConstraintAxis axis
) {
    switch (axis) {
        case UILayoutConstraintAxisHorizontal: return @"horizontal";
        case UILayoutConstraintAxisVertical: return @"vertical";
    }
    return [NSString stringWithFormat:@"unknown(%ld)", (long)axis];
}

static NSString *IOSUseViewTreeStackAlignment(
    UIStackViewAlignment alignment,
    UILayoutConstraintAxis axis
) {
    switch ((NSInteger)alignment) {
        case 0: return @"fill";
        case 1:
            return axis == UILayoutConstraintAxisHorizontal
                ? @"top"
                : @"leading";
        case 2: return @"firstBaseline";
        case 3: return @"center";
        case 4:
            return axis == UILayoutConstraintAxisHorizontal
                ? @"bottom"
                : @"trailing";
        case 5: return @"lastBaseline";
        default:
            return [NSString stringWithFormat:
                @"unknown(%ld)",
                (long)alignment];
    }
}

static NSString *IOSUseViewTreeStackDistribution(
    UIStackViewDistribution distribution
) {
    switch (distribution) {
        case UIStackViewDistributionFill: return @"fill";
        case UIStackViewDistributionFillEqually: return @"fillEqually";
        case UIStackViewDistributionFillProportionally:
            return @"fillProportionally";
        case UIStackViewDistributionEqualSpacing: return @"equalSpacing";
        case UIStackViewDistributionEqualCentering: return @"equalCentering";
    }
    return [NSString stringWithFormat:
        @"unknown(%ld)",
        (long)distribution];
}

static NSString *IOSUseViewTreeControllerClass(UIView *view) {
    UIResponder *responder = view.nextResponder;
    NSUInteger traversed = 0;
    while (responder != nil && traversed < 64) {
        if ([responder isKindOfClass:UIViewController.class]) {
            return NSStringFromClass(responder.class);
        }
        responder = responder.nextResponder;
        traversed += 1;
    }
    return nil;
}

static NSDictionary<NSString *, id> *IOSUseViewTreeProperties(
    UIView *view
) {
    NSMutableDictionary<NSString *, id> *properties =
        [NSMutableDictionary dictionary];
    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        properties[@"text"] =
            IOSUseViewTreeString(label.text) ?: NSNull.null;
        properties[@"fontName"] =
            IOSUseViewTreeString(label.font.fontName) ?: NSNull.null;
        properties[@"fontSize"] = @(label.font.pointSize);
        properties[@"numberOfLines"] = @(label.numberOfLines);
        properties[@"textAlignment"] =
            IOSUseViewTreeTextAlignment(label.textAlignment);
    }
    if ([view isKindOfClass:UIImageView.class]) {
        UIImageView *imageView = (UIImageView *)view;
        UIImage *image = imageView.image;
        properties[@"image"] = image == nil
            ? (id)NSNull.null
            : @{
                @"size": IOSUseViewTreeSize(image.size),
                @"scale": @(image.scale),
                @"renderingMode":
                    IOSUseViewTreeImageRenderingMode(image.renderingMode),
            };
        properties[@"highlighted"] = @(imageView.highlighted);
    }
    if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)view;
        properties[@"title"] =
            IOSUseViewTreeString(button.currentTitle) ?: NSNull.null;
        properties[@"enabled"] = @(button.enabled);
        properties[@"selected"] = @(button.selected);
        if (button.titleLabel.font != nil) {
            properties[@"titleFontName"] =
                IOSUseViewTreeString(button.titleLabel.font.fontName)
                ?: NSNull.null;
            properties[@"titleFontSize"] =
                @(button.titleLabel.font.pointSize);
        }
    }
    if ([view isKindOfClass:UIScrollView.class]) {
        UIScrollView *scrollView = (UIScrollView *)view;
        properties[@"contentSize"] =
            IOSUseViewTreeSize(scrollView.contentSize);
        properties[@"contentOffset"] =
            IOSUseViewTreePoint(scrollView.contentOffset);
        properties[@"contentInset"] =
            IOSUseViewTreeInsets(scrollView.contentInset);
        properties[@"adjustedContentInset"] =
            IOSUseViewTreeInsets(scrollView.adjustedContentInset);
        properties[@"scrollEnabled"] = @(scrollView.scrollEnabled);
        properties[@"bounces"] = @(scrollView.bounces);
        properties[@"pagingEnabled"] = @(scrollView.pagingEnabled);
    }
    if ([view isKindOfClass:UIStackView.class]) {
        UIStackView *stackView = (UIStackView *)view;
        properties[@"axis"] = IOSUseViewTreeStackAxis(stackView.axis);
        properties[@"spacing"] = @(stackView.spacing);
        properties[@"alignment"] = IOSUseViewTreeStackAlignment(
            stackView.alignment,
            stackView.axis
        );
        properties[@"distribution"] = IOSUseViewTreeStackDistribution(
            stackView.distribution
        );
        properties[@"arrangedSubviewCount"] =
            @(stackView.arrangedSubviews.count);
    }
    return properties;
}

static NSString *IOSUseViewTreeNodeID(NSArray<NSNumber *> *path) {
    NSMutableArray<NSString *> *parts =
        [NSMutableArray arrayWithCapacity:path.count];
    for (NSNumber *component in path) {
        [parts addObject:component.stringValue];
    }
    return [@"v" stringByAppendingString:
        [parts componentsJoinedByString:@"."]];
}

static NSDictionary<NSString *, id> * _Nullable
IOSUseViewTreeSerializeView(
    UIView *view,
    NSArray<NSNumber *> *path,
    NSInteger depth,
    NSInteger index,
    IOSUseViewTreeContext *context
) {
    if (context.nodeCount >= IOSUseViewTreeMaximumNodes) {
        context.truncated = YES;
        return nil;
    }
    @try {
        context.nodeCount += 1;
        NSArray<UIView *> *subviews = [view.subviews copy] ?: @[];
        NSMutableArray<NSDictionary<NSString *, id> *> *children =
            [NSMutableArray array];
        if (depth < context.maximumDepth) {
            for (NSUInteger childIndex = 0;
                 childIndex < subviews.count;
                 childIndex += 1) {
                NSMutableArray<NSNumber *> *childPath =
                    [path mutableCopy];
                [childPath addObject:@(childIndex)];
                NSDictionary<NSString *, id> *child =
                    IOSUseViewTreeSerializeView(
                        subviews[childIndex],
                        childPath,
                        depth + 1,
                        (NSInteger)childIndex,
                        context
                    );
                if (child != nil) {
                    [children addObject:child];
                }
                if (context.nodeCount >= IOSUseViewTreeMaximumNodes) {
                    context.truncated = YES;
                    break;
                }
            }
        } else if (subviews.count > 0) {
            context.truncated = YES;
        }
        NSString *controllerClass = IOSUseViewTreeControllerClass(view);
        return @{
            @"nodeID": IOSUseViewTreeNodeID(path),
            @"path": path,
            @"depth": @(depth),
            @"index": @(index),
            @"childCount": @(subviews.count),
            @"class": NSStringFromClass(view.class) ?: @"UIView",
            @"viewControllerClass": controllerClass ?: NSNull.null,
            @"frame": IOSUseViewTreeRect(view.frame),
            @"bounds": IOSUseViewTreeRect(view.bounds),
            @"hidden": @(view.hidden),
            @"alpha": @(view.alpha),
            @"userInteractionEnabled": @(view.userInteractionEnabled),
            @"clipsToBounds": @(view.clipsToBounds),
            @"contentMode": IOSUseViewTreeContentMode(view.contentMode),
            @"accessibilityIdentifier":
                IOSUseViewTreeString(view.accessibilityIdentifier)
                    ?: NSNull.null,
            @"accessibilityLabel":
                IOSUseViewTreeString(view.accessibilityLabel)
                    ?: NSNull.null,
            @"layout": @{
                @"ambiguous": @(view.hasAmbiguousLayout),
                @"translatesAutoresizingMaskIntoConstraints":
                    @(view.translatesAutoresizingMaskIntoConstraints),
                @"constraintCount": @(view.constraints.count),
            },
            @"properties": IOSUseViewTreeProperties(view),
            @"subviews": children,
        };
    } @catch (NSException *exception) {
        context.failureMessage = [NSString stringWithFormat:
            @"%@ while reading %@",
            exception.name ?: @"Objective-C exception",
            NSStringFromClass(view.class) ?: @"UIView"];
        return nil;
    }
}

static NSDictionary<NSString *, id> *IOSUseViewTreeSnapshot(
    NSArray<UIView *> *roots,
    NSString * _Nullable target,
    NSInteger maximumDepth,
    NSDictionary<NSString *, id> **commandError
) {
    IOSUseViewTreeContext *context = [IOSUseViewTreeContext new];
    context.maximumDepth = maximumDepth;
    NSMutableArray<NSDictionary<NSString *, id> *> *serialized =
        [NSMutableArray array];
    for (NSUInteger index = 0; index < roots.count; index += 1) {
        NSDictionary<NSString *, id> *root =
            IOSUseViewTreeSerializeView(
                roots[index],
                @[@(index)],
                0,
                (NSInteger)index,
                context
            );
        if (context.failureMessage != nil) {
            if (commandError != NULL) {
                *commandError = IOSUseViewTreeError(
                    @"ui_tree_snapshot_failed",
                    context.failureMessage,
                    @"internal",
                    @"snapshot",
                    YES
                );
            }
            return nil;
        }
        if (root != nil) {
            [serialized addObject:root];
        }
    }
    return @{
        @"source": @"uikit-view-hierarchy",
        @"target": target ?: NSNull.null,
        @"maxDepth": @(maximumDepth),
        @"nodeCount": @(context.nodeCount),
        @"truncated": @(context.truncated),
        @"roots": serialized,
    };
}

static NSArray<UIView *> *IOSUseViewTreeWindowRoots(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            (scene.activationState != UISceneActivationStateForegroundActive &&
             scene.activationState != UISceneActivationStateForegroundInactive)) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.hidden && window.alpha > 0 &&
                !CGRectIsEmpty(window.bounds)) {
                [windows addObject:window];
            }
        }
    }
    return [windows sortedArrayUsingComparator:
        ^NSComparisonResult(UIWindow *left, UIWindow *right) {
            if (left.windowLevel < right.windowLevel) {
                return NSOrderedAscending;
            }
            if (left.windowLevel > right.windowLevel) {
                return NSOrderedDescending;
            }
            return NSOrderedSame;
        }];
}

NSDictionary<NSString *, id> * _Nullable
IOSUsePlayRuntimeViewTreeCommand(
    NSDictionary<NSString *, id> *arguments,
    NSDictionary<NSString *, id> **commandError
) {
    NSSet<NSString *> *keys = [NSSet setWithArray:@[
        @"target",
        @"depth",
    ]];
    if (![arguments isKindOfClass:NSDictionary.class] ||
        ![[NSSet setWithArray:arguments.allKeys] isEqualToSet:keys] ||
        !(arguments[@"target"] == NSNull.null ||
          [arguments[@"target"] isKindOfClass:NSString.class]) ||
        !IOSUseViewTreeIsInteger(arguments[@"depth"])) {
        if (commandError != NULL) {
            *commandError = IOSUseViewTreeError(
                @"invalid_arguments",
                @"ui-tree arguments must contain target (string or null) and integer depth",
                @"validation",
                @"validation",
                NO
            );
        }
        return nil;
    }
    NSInteger maximumDepth = [arguments[@"depth"] integerValue];
    if (maximumDepth < 0 || maximumDepth > IOSUseViewTreeMaximumDepth) {
        if (commandError != NULL) {
            *commandError = IOSUseViewTreeError(
                @"invalid_arguments",
                @"ui-tree depth must be between 0 and 20",
                @"validation",
                @"validation",
                NO
            );
        }
        return nil;
    }
    NSString *target = arguments[@"target"] == NSNull.null
        ? nil
        : arguments[@"target"];
    __block NSDictionary<NSString *, id> *result = nil;
    __block NSDictionary<NSString *, id> *failure = nil;
    void (^snapshot)(void) = ^{
        NSArray<UIView *> *roots;
        if (target != nil) {
            UIView *view = IOSUsePlayRuntimeDOMResolveTargetView(
                target,
                &failure
            );
            roots = view == nil ? nil : @[view];
        } else {
            roots = IOSUseViewTreeWindowRoots();
            if (roots.count == 0) {
                failure = IOSUseViewTreeError(
                    @"ui_tree_unavailable",
                    @"no visible foreground UIKit windows are available",
                    @"precondition",
                    @"snapshot",
                    YES
                );
            }
        }
        if (roots != nil && failure == nil) {
            result = IOSUseViewTreeSnapshot(
                roots,
                target,
                maximumDepth,
                &failure
            );
        }
    };
    if (NSThread.isMainThread) {
        snapshot();
    } else {
        dispatch_sync(dispatch_get_main_queue(), snapshot);
    }
    if (result == nil && commandError != NULL) {
        *commandError = failure ?: IOSUseViewTreeError(
            @"ui_tree_snapshot_failed",
            @"UIKit view hierarchy snapshot failed",
            @"internal",
            @"snapshot",
            YES
        );
    }
    return result;
}

#if defined(IOS_USE_PLAY_RUNTIME_VIEW_TREE_TESTING)
NSDictionary<NSString *, id> *
IOSUsePlayRuntimeViewTreeSnapshotForTesting(
    NSArray<UIView *> *roots,
    NSInteger maximumDepth
) {
    NSCAssert(NSThread.isMainThread, @"view-tree test snapshot is main-only");
    return IOSUseViewTreeSnapshot(
        roots,
        nil,
        maximumDepth,
        NULL
    );
}
#endif
