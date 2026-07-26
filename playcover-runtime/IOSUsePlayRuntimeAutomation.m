#import "IOSUsePlayRuntimeAutomation.h"
#import "IOSUsePlayAppKitBridge.h"
#import "IOSUsePlayRuntimeDOM.h"
#import "IOSUsePlayRuntimeScreenshot.h"
#import "IOSUsePlayDevice.h"
#import "IOSUsePlaySwiftBridge.h"
#import "PTFakeMetaTouch.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <math.h>
#import <stdint.h>

static const NSTimeInterval IOSUseAutomationMainTimeout = 40.0;

typedef BOOL (*IOSUseAutomationSendBool)(id, SEL);
typedef unsigned long long (*IOSUseAutomationSendTraits)(id, SEL);
typedef BOOL (*IOSUseAutomationOpenURLModern)(
    id,
    SEL,
    UIApplication *,
    NSURL *,
    NSDictionary *
);
typedef BOOL (*IOSUseAutomationOpenURLLegacy)(
    id,
    SEL,
    UIApplication *,
    NSURL *,
    NSString * _Nullable,
    id _Nullable
);
typedef NSDictionary<NSString *, id> * _Nullable
(^IOSUseAutomationDeferredFinalize)(
    NSDictionary<NSString *, id> * _Nullable * _Nullable
);

static NSString *const IOSUseAutomationDeferredFinalizeKey =
    @"__iosUseDeferredFinalize";

@interface IOSUseAutomationCandidate : NSObject
@property(nonatomic, strong) id object;
@property(nonatomic, weak, nullable) id parent;
@property(nonatomic, copy) NSString *nodeID;
@property(nonatomic, copy) NSString *label;
@property(nonatomic, copy) NSString *value;
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *hint;
@property(nonatomic, copy) NSString *className;
@property(nonatomic) CGRect frame;
@property(nonatomic) NSInteger depth;
@property(nonatomic) NSInteger index;
@property(nonatomic, copy) NSString *path;
@property(nonatomic) NSUInteger zOrder;
@property(nonatomic) unsigned long long generation;
@property(nonatomic, copy, nullable)
    NSDictionary<NSString *, id> *serialized;
@end

@implementation IOSUseAutomationCandidate
@end

static UIResponder *IOSUseAutomationCurrentFirstResponder(void);

static BOOL IOSUseAutomationIsNumber(id value) {
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID();
}

static BOOL IOSUseAutomationFinitePoint(CGPoint point) {
    return isfinite(point.x) && isfinite(point.y) &&
        point.x >= 0 && point.y >= 0 &&
        point.x <= IOSUsePlayDeviceLogicalWidth &&
        point.y <= IOSUsePlayDeviceLogicalHeight;
}

static NSDictionary<NSString *, id> *IOSUseAutomationError(
    NSString *code,
    NSString *message,
    NSString *category,
    NSString *phase,
    BOOL retryable,
    NSDictionary<NSString *, id> * _Nullable target,
    NSArray<NSDictionary<NSString *, id> *> *candidates
) {
    NSMutableDictionary<NSString *, id> *details = [@{
        @"category": category,
        @"phase": phase,
        @"retryable": @(retryable),
        @"fatal": @NO,
        @"candidateCount": @(candidates.count),
        @"candidates": candidates,
        @"suggestions": @[],
    } mutableCopy];
    if (target != nil) {
        details[@"target"] = target;
    }
    return @{
        @"code": code,
        @"message": message,
        @"details": details,
    };
}

static NSDictionary<NSString *, id> *
IOSUseAutomationWebBridgeFailure(
    NSDictionary<NSString *, id> *error,
    NSString *bridgeFailureCode
) {
    NSMutableDictionary<NSString *, id> *result =
        [error mutableCopy];
    NSMutableDictionary<NSString *, id> *details =
        [result[@"details"] mutableCopy];
    details[@"actionBackend"] =
        @"wkwebview-runtime-fixed-accessibility-bridge";
    details[@"bridgeFailureCode"] =
        bridgeFailureCode ?: @"web_bridge_failed";
    details[@"syntheticFallbackAttempted"] = @NO;
    result[@"details"] = details;
    return result;
}

static BOOL IOSUseAutomationBool(id object, SEL selector, BOOL fallback) {
    if (object == nil || ![object respondsToSelector:selector]) {
        return fallback;
    }
    @try {
        return ((IOSUseAutomationSendBool)objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return fallback;
    }
}

static NSString *IOSUseAutomationString(id value) {
    if (value == nil || value == NSNull.null) {
        return @"";
    }
    NSString *string = [value isKindOfClass:NSString.class]
        ? value
        : [value description];
    string = [string stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (string.length > 4096) {
        return [string substringToIndex:4096];
    }
    return string ?: @"";
}

static unsigned long long IOSUseAutomationTraits(id object) {
    SEL selector = @selector(accessibilityTraits);
    if (![object respondsToSelector:selector]) {
        return 0;
    }
    @try {
        return ((IOSUseAutomationSendTraits)objc_msgSend)(
            object,
            selector
        );
    } @catch (__unused NSException *exception) {
        return 0;
    }
}

static NSArray<NSString *> *IOSUseAutomationTraitNames(
    unsigned long long traits
) {
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    const struct {
        UIAccessibilityTraits bit;
        __unsafe_unretained NSString *name;
    } known[] = {
        {UIAccessibilityTraitButton, @"button"},
        {UIAccessibilityTraitLink, @"link"},
        {UIAccessibilityTraitImage, @"image"},
        {UIAccessibilityTraitSelected, @"selected"},
        {UIAccessibilityTraitHeader, @"header"},
        {UIAccessibilityTraitSearchField, @"searchField"},
        {UIAccessibilityTraitKeyboardKey, @"keyboardKey"},
        {UIAccessibilityTraitStaticText, @"staticText"},
        {UIAccessibilityTraitAdjustable, @"adjustable"},
        {UIAccessibilityTraitNotEnabled, @"notEnabled"},
    };
    for (NSUInteger index = 0;
         index < sizeof(known) / sizeof(known[0]);
         index += 1) {
        if ((traits & known[index].bit) != 0) {
            [result addObject:known[index].name];
        }
    }
    return result;
}

static NSArray<UIWindow *> *IOSUseAutomationWindows(void) {
    NSMutableArray<UIWindowScene *> *scenes =
        [NSMutableArray array];
    for (UIScene *scene in
         UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            (scene.activationState !=
                UISceneActivationStateForegroundActive &&
             scene.activationState !=
                UISceneActivationStateForegroundInactive)) {
            continue;
        }
        [scenes addObject:(UIWindowScene *)scene];
    }
    [scenes sortUsingComparator:^NSComparisonResult(
        UIWindowScene *left,
        UIWindowScene *right
    ) {
        if (left.activationState != right.activationState) {
            return left.activationState ==
                    UISceneActivationStateForegroundActive
                ? NSOrderedAscending
                : NSOrderedDescending;
        }
        NSString *leftIdentifier =
            left.session.persistentIdentifier ?: @"";
        NSString *rightIdentifier =
            right.session.persistentIdentifier ?: @"";
        return [leftIdentifier compare:rightIdentifier];
    }];

    NSHashTable<UIWindow *> *seen = [NSHashTable
        hashTableWithOptions:
            NSPointerFunctionsObjectPointerPersonality |
            NSPointerFunctionsStrongMemory];
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIWindowScene *scene in scenes) {
        NSArray<UIWindow *> *sceneWindows =
            [scene.windows sortedArrayUsingComparator:
                ^NSComparisonResult(UIWindow *left, UIWindow *right) {
                    if (left.windowLevel > right.windowLevel) {
                        return NSOrderedAscending;
                    }
                    if (left.windowLevel < right.windowLevel) {
                        return NSOrderedDescending;
                    }
                    if (left.isKeyWindow != right.isKeyWindow) {
                        return left.isKeyWindow
                            ? NSOrderedAscending
                            : NSOrderedDescending;
                    }
                    return NSOrderedSame;
                }];
        for (UIWindow *window in sceneWindows) {
            if (!window.hidden &&
                window.alpha > 0.01 &&
                window.userInteractionEnabled &&
                window.bounds.size.width > 0 &&
                window.bounds.size.height > 0 &&
                ![seen containsObject:window]) {
                [seen addObject:window];
                [windows addObject:window];
            }
        }
    }
    return windows;
}

static NSString *IOSUseAutomationType(
    IOSUseAutomationCandidate *candidate
) {
    unsigned long long traits = IOSUseAutomationTraits(candidate.object);
    if ((traits & UIAccessibilityTraitButton) != 0) {
        return @"Button";
    }
    if ((traits & UIAccessibilityTraitLink) != 0) {
        return @"Link";
    }
    if ((traits & UIAccessibilityTraitImage) != 0) {
        return @"Image";
    }
    if ((traits & UIAccessibilityTraitStaticText) != 0) {
        return @"StaticText";
    }
    if ([candidate.object conformsToProtocol:@protocol(UITextInput)] ||
        [candidate.object conformsToProtocol:@protocol(UIKeyInput)]) {
        return @"TextField";
    }
    return candidate.className;
}

static NSInteger IOSUseAutomationElementType(
    IOSUseAutomationCandidate *candidate
) {
    NSString *type = IOSUseAutomationType(candidate);
    if ([type isEqualToString:@"Button"]) {
        return 9;
    }
    if ([type isEqualToString:@"Link"]) {
        return 42;
    }
    if ([type isEqualToString:@"Image"]) {
        return 43;
    }
    if ([type isEqualToString:@"StaticText"]) {
        return 48;
    }
    if ([type isEqualToString:@"TextField"]) {
        return 45;
    }
    if ([candidate.object isKindOfClass:UIWindow.class]) {
        return 4;
    }
    if ([candidate.object isKindOfClass:UIScrollView.class]) {
        return 46;
    }
    return 1;
}

static NSDictionary<NSString *, id> *IOSUseAutomationElementJSON(
    IOSUseAutomationCandidate *candidate
) {
    if (candidate == nil) {
        return @{};
    }
    if (candidate.serialized != nil) {
        return candidate.serialized;
    }
    CGRect frame = candidate.frame;
    BOOL validFrame =
        !CGRectIsNull(frame) &&
        !CGRectIsInfinite(frame) &&
        isfinite(frame.origin.x) &&
        isfinite(frame.origin.y) &&
        isfinite(frame.size.width) &&
        isfinite(frame.size.height);
    if (!validFrame) {
        frame = CGRectZero;
    }
    unsigned long long rawTraits =
        IOSUseAutomationTraits(candidate.object);
    NSArray<NSString *> *traits =
        IOSUseAutomationTraitNames(rawTraits);
    BOOL enabled =
        ![traits containsObject:@"notEnabled"] &&
        IOSUseAutomationBool(
            candidate.object,
            @selector(isEnabled),
            YES
        );
    BOOL visible =
        validFrame &&
        frame.size.width > 0 &&
        frame.size.height > 0 &&
        CGRectIntersectsRect(
            frame,
            CGRectMake(
                0,
                0,
                IOSUsePlayDeviceLogicalWidth,
                IOSUsePlayDeviceLogicalHeight
            )
        );
    NSString *type = IOSUseAutomationType(candidate);
    NSInteger elementType =
        IOSUseAutomationElementType(candidate);
    NSArray<NSString *> *hierarchyPath =
        candidate.path.length == 0
            ? @[]
            : [candidate.path componentsSeparatedByString:@"."];
    return @{
        @"nodeID": candidate.nodeID,
        @"type": type,
        @"elementType": @(elementType),
        @"elemType": @(elementType),
        @"label": candidate.label,
        @"value": candidate.value,
        @"identifier": candidate.identifier,
        @"hint": candidate.hint,
        @"class": candidate.className,
        @"traits": traits,
        @"state": @{
            @"enabled": @(enabled),
            @"visible": @(visible),
            @"selected": @((BOOL)((rawTraits &
                UIAccessibilityTraitSelected) != 0)),
            @"focused": @((BOOL)(
                [candidate.object respondsToSelector:@selector(isFirstResponder)] &&
                IOSUseAutomationBool(
                    candidate.object,
                    @selector(isFirstResponder),
                    NO
                )
            )),
            @"opaque": @((BOOL)(
                [candidate.object isKindOfClass:UIView.class] &&
                ((UIView *)candidate.object).opaque
            )),
        },
        @"frame": @{
            @"x": @(frame.origin.x),
            @"y": @(frame.origin.y),
            @"width": @(frame.size.width),
            @"height": @(frame.size.height),
        },
        @"rect": @{
            @"x": @(frame.origin.x),
            @"y": @(frame.origin.y),
            @"w": @(frame.size.width),
            @"h": @(frame.size.height),
        },
        @"hierarchy": @{
            @"parentID": candidate.parent == nil
                ? NSNull.null
                : [NSString stringWithFormat:
                    @"%llu-%p",
                    candidate.generation,
                    candidate.parent],
            @"depth": @(candidate.depth),
            @"index": @(candidate.index),
            @"path": hierarchyPath,
        },
        @"ancestors": @[],
        @"zOrder": @(candidate.zOrder),
        @"snapshotGeneration": @(candidate.generation),
    };
}

static __attribute__((unused))
NSDictionary<NSString *, id> *IOSUseAutomationCandidateSummary(
    IOSUseAutomationCandidate *candidate
) {
    return @{
        @"element": IOSUseAutomationElementJSON(candidate),
        @"rejectedBy": @[],
    };
}

static BOOL IOSUseAutomationTargetValid(
    NSDictionary<NSString *, id> *target
) {
    if (![target isKindOfClass:NSDictionary.class] ||
        ![target[@"label"] isKindOfClass:NSString.class] ||
        ![target[@"traits"] isKindOfClass:NSString.class]) {
        return NO;
    }
    id cindex = target[@"cindex"];
    id mode = target[@"matchMode"];
    id point = target[@"point"];
    if (cindex != nil && !IOSUseAutomationIsNumber(cindex)) {
        return NO;
    }
    if (mode != nil &&
        (!IOSUseAutomationIsNumber(mode) ||
         [mode integerValue] < 0 ||
         [mode integerValue] > 2)) {
        return NO;
    }
    if (point != nil &&
        (![point isKindOfClass:NSDictionary.class] ||
         !IOSUseAutomationIsNumber(point[@"x"]) ||
         !IOSUseAutomationIsNumber(point[@"y"]))) {
        return NO;
    }
    return YES;
}

static NSDictionary<NSString *, id> *IOSUseAutomationFreshDOM(
    NSDictionary<NSString *, id> **commandError
) {
    return IOSUsePlayRuntimeDOMCommand(
        @{
            @"raw": @NO,
            @"fresh": @YES,
            @"waitQuiescence": @NO,
        },
        commandError
    );
}

static __attribute__((unused))
IOSUseAutomationCandidate *IOSUseAutomationCandidateFromElement(
    NSDictionary<NSString *, id> *element
) {
    if (![element isKindOfClass:NSDictionary.class]) {
        return nil;
    }
    IOSUseAutomationCandidate *candidate =
        [[IOSUseAutomationCandidate alloc] init];
    candidate.serialized = element;
    candidate.nodeID = element[@"nodeID"] ?: @"";
    candidate.label = element[@"label"] ?: @"";
    candidate.value = element[@"value"] ?: @"";
    candidate.identifier = element[@"identifier"] ?: @"";
    candidate.hint = element[@"hint"] ?: @"";
    candidate.className = element[@"class"] ?: @"NSObject";
    NSDictionary *frame = element[@"frame"];
    if (![frame isKindOfClass:NSDictionary.class]) {
        NSDictionary *rect = element[@"rect"];
        if ([rect isKindOfClass:NSDictionary.class]) {
            frame = @{
                @"x": rect[@"x"] ?: @0,
                @"y": rect[@"y"] ?: @0,
                @"width": rect[@"w"] ?: @0,
                @"height": rect[@"h"] ?: @0,
            };
        }
    }
    candidate.frame = [frame isKindOfClass:NSDictionary.class]
        ? CGRectMake(
            [frame[@"x"] doubleValue],
            [frame[@"y"] doubleValue],
            [frame[@"width"] doubleValue],
            [frame[@"height"] doubleValue]
        )
        : CGRectNull;
    NSDictionary *hierarchy = element[@"hierarchy"];
    candidate.depth = [hierarchy[@"depth"] integerValue];
    candidate.index = [hierarchy[@"index"] integerValue];
    NSArray *path = hierarchy[@"path"];
    candidate.path = [path isKindOfClass:NSArray.class]
        ? [path componentsJoinedByString:@"."]
        : @"";
    candidate.zOrder = [element[@"zOrder"] unsignedIntegerValue];
    candidate.generation =
        [element[@"snapshotGeneration"] unsignedLongLongValue];
    return candidate;
}

static NSString *IOSUseAutomationNormalizedText(NSString *text) {
    NSMutableCharacterSet *ignored = [
        NSCharacterSet.whitespaceAndNewlineCharacterSet mutableCopy
    ];
    [ignored addCharactersInString:@"-_:/()[]{}.,'\""];
    return [[text componentsSeparatedByCharactersInSet:ignored]
        componentsJoinedByString:@""].lowercaseString;
}

static BOOL IOSUseAutomationElementHasTraits(
    NSDictionary<NSString *, id> *element,
    NSString *requiredTraits
) {
    if (requiredTraits.length == 0) {
        return YES;
    }
    NSMutableSet<NSString *> *available = [NSMutableSet set];
    for (NSString *trait in element[@"traits"]) {
        if ([trait isKindOfClass:NSString.class]) {
            [available addObject:trait.lowercaseString];
        }
    }
    for (NSString *part in
         [requiredTraits componentsSeparatedByString:@","]) {
        NSString *required = [[part
            stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceCharacterSet] lowercaseString];
        if (required.length > 0 &&
            ![available containsObject:required]) {
            return NO;
        }
    }
    return YES;
}

static __attribute__((unused))
NSArray<NSDictionary<NSString *, id> *> *
IOSUseAutomationSelectElements(
    NSDictionary<NSString *, id> *dom,
    NSDictionary<NSString *, id> *target,
    NSDictionary<NSString *, id> **commandError
) {
    NSString *label = [target[@"label"]
        stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *traits = target[@"traits"];
    NSInteger mode = target[@"matchMode"] == nil
        ? 0
        : [target[@"matchMode"] integerValue];
    NSRegularExpression *expression = nil;
    if (mode == 2) {
        expression = [NSRegularExpression
            regularExpressionWithPattern:label
                                 options:0
                                   error:NULL];
        if (expression == nil) {
            if (commandError != NULL) {
                *commandError = IOSUseAutomationError(
                    @"invalid_arguments",
                    @"target regular expression is invalid",
                    @"validation",
                    @"validation",
                    NO,
                    target,
                    @[]
                );
            }
            return nil;
        }
    }
    NSString *normalizedLabel =
        IOSUseAutomationNormalizedText(label);
    NSMutableArray<NSDictionary<NSString *, id> *> *exact =
        [NSMutableArray array];
    NSMutableArray<NSDictionary<NSString *, id> *> *contains =
        [NSMutableArray array];
    for (NSDictionary<NSString *, id> *element in dom[@"elements"]) {
        if (![element isKindOfClass:NSDictionary.class] ||
            !IOSUseAutomationElementHasTraits(element, traits) ||
            ![element[@"state"][@"visible"] boolValue]) {
            continue;
        }
        BOOL exactMatch = NO;
        BOOL containsMatch = NO;
        BOOL regexMatch = NO;
        for (NSString *text in @[
            element[@"label"] ?: @"",
            element[@"identifier"] ?: @"",
            element[@"value"] ?: @"",
        ]) {
            if (mode == 2) {
                regexMatch =
                    [expression firstMatchInString:text
                                           options:0
                                             range:NSMakeRange(
                                                 0,
                                                 text.length
                                             )] != nil;
                if (regexMatch) {
                    break;
                }
            } else {
                NSString *normalized =
                    IOSUseAutomationNormalizedText(text);
                exactMatch =
                    [normalized isEqualToString:normalizedLabel];
                containsMatch =
                    !exactMatch &&
                    normalizedLabel.length > 0 &&
                    [normalized rangeOfString:normalizedLabel].location !=
                        NSNotFound;
                if (exactMatch) {
                    break;
                }
            }
        }
        if (mode == 2 && regexMatch) {
            [exact addObject:element];
        } else if (exactMatch) {
            [exact addObject:element];
            if (mode == 0) {
                break;
            }
        } else if (mode == 0 && containsMatch) {
            [contains addObject:element];
        }
    }
    NSMutableArray<NSDictionary<NSString *, id> *> *matches =
        exact.count > 0 ? exact : contains;
    NSNumber *childIndex = target[@"cindex"];
    if (childIndex != nil) {
        NSMutableArray<NSDictionary<NSString *, id> *> *children =
            [NSMutableArray array];
        for (NSDictionary *parent in matches) {
            NSMutableArray<NSDictionary<NSString *, id> *> *direct =
                [NSMutableArray array];
            for (NSDictionary *element in dom[@"elements"]) {
                if ([element[@"hierarchy"][@"parentID"]
                        isEqualToString:parent[@"nodeID"]]) {
                    [direct addObject:element];
                }
            }
            [direct sortUsingComparator:^NSComparisonResult(
                NSDictionary *left,
                NSDictionary *right
            ) {
                return [left[@"hierarchy"][@"index"]
                    compare:right[@"hierarchy"][@"index"]];
            }];
            NSInteger requested = childIndex.integerValue;
            NSInteger resolved = requested >= 0
                ? requested
                : (NSInteger)direct.count + requested;
            if (resolved >= 0 &&
                resolved < (NSInteger)direct.count) {
                [children addObject:direct[(NSUInteger)resolved]];
            }
        }
        matches = children;
    }
    return matches;
}

static IOSUseAutomationCandidate *IOSUseAutomationResolveWithDOM(
    NSDictionary<NSString *, id> *target,
    NSDictionary<NSString *, id> *dom,
    CGPoint *point,
    UIWindow **window,
    UIView **hitView,
    unsigned long long *generation,
    NSDictionary<NSString *, id> **commandError
) {
    if (!IOSUseAutomationTargetValid(target)) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationError(
                @"invalid_arguments",
                @"target must contain label and traits, with optional point, cindex, and matchMode",
                @"validation",
                @"validation",
                NO,
                target,
                @[]
            );
        }
        return nil;
    }
    if (![dom isKindOfClass:NSDictionary.class] ||
        ![dom[@"snapshotGeneration"] isKindOfClass:NSNumber.class] ||
        ![dom[@"elements"] isKindOfClass:NSArray.class]) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationError(
                @"snapshot_failed",
                @"target resolution requires a fresh DOM snapshot",
                @"lookup",
                @"snapshot",
                YES,
                target,
                @[]
            );
        }
        return nil;
    }
    if (generation != NULL) {
        *generation =
            [dom[@"snapshotGeneration"] unsignedLongLongValue];
    }
    NSArray<IOSUseAutomationCandidate *> *snapshot = @[];
    NSDictionary *explicitPoint = target[@"point"];
    CGPoint resolvedPoint = CGPointZero;
    IOSUseAutomationCandidate *selected = nil;
    if (explicitPoint != nil) {
        resolvedPoint = CGPointMake(
            [explicitPoint[@"x"] doubleValue],
            [explicitPoint[@"y"] doubleValue]
        );
    } else {
        NSArray<NSDictionary<NSString *, id> *> *matches =
            IOSUseAutomationSelectElements(
                dom,
                target,
                commandError
            );
        if (matches == nil) {
            return nil;
        }
        if (matches.count == 1) {
            selected = IOSUseAutomationCandidateFromElement(
                matches.firstObject
            );
        }
        if (selected == nil) {
            NSMutableArray *candidates = [NSMutableArray array];
            for (NSDictionary<NSString *, id> *element in
                 [matches subarrayWithRange:
                    NSMakeRange(0, MIN(matches.count, (NSUInteger)5))]) {
                [candidates addObject:@{
                    @"element": element,
                    @"rejectedBy": @[],
                }];
            }
            if (commandError != NULL) {
                *commandError = IOSUseAutomationError(
                    matches.count > 1
                        ? @"element_ambiguous"
                        : @"element_not_found",
                    matches.count > 1
                        ? @"target resolved to multiple live elements"
                        : @"target did not resolve in a fresh live snapshot",
                    @"lookup",
                    @"lookup",
                    YES,
                    target,
                    candidates
                );
            }
            return nil;
        }
        CGRect frame = selected.frame;
        resolvedPoint = CGPointMake(
            CGRectGetMidX(frame),
            CGRectGetMidY(frame)
        );
    }
    if (!IOSUseAutomationFinitePoint(resolvedPoint)) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationError(
                @"invalid_target_point",
                [NSString stringWithFormat:
                    @"resolved point is outside the %ld x %ld logical screen",
                    (long)IOSUsePlayDeviceLogicalWidth,
                    (long)IOSUsePlayDeviceLogicalHeight],
                @"validation",
                @"lookup",
                NO,
                target,
                @[]
            );
        }
        return nil;
    }
    UIWindow *resolvedWindow = nil;
    UIView *resolvedHit = nil;
    for (UIWindow *candidateWindow in IOSUseAutomationWindows()) {
        CGPoint candidatePoint =
            [candidateWindow convertPoint:resolvedPoint
                               fromWindow:nil];
        UIView *candidateHit =
            [candidateWindow hitTest:candidatePoint withEvent:nil];
        if (candidateHit != nil) {
            resolvedWindow = candidateWindow;
            resolvedHit = candidateHit;
            resolvedPoint = candidatePoint;
            break;
        }
    }
    if (resolvedWindow == nil || resolvedHit == nil) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationError(
                @"element_not_hittable",
                @"fresh target point has no live hit-test view",
                @"interaction",
                @"hit-test",
                YES,
                target,
                @[]
            );
        }
        return nil;
    }
    if (selected == nil) {
        for (IOSUseAutomationCandidate *candidate in snapshot) {
            if (candidate.object == resolvedHit) {
                selected = candidate;
                break;
            }
        }
        if (selected == nil) {
            selected = [[IOSUseAutomationCandidate alloc] init];
            selected.object = resolvedHit;
            selected.nodeID = [NSString stringWithFormat:
                @"%llu-%p",
                *generation,
                resolvedHit
            ];
            selected.label =
                resolvedHit.accessibilityLabel ?: @"";
            selected.value =
                IOSUseAutomationString(resolvedHit.accessibilityValue);
            selected.identifier =
                resolvedHit.accessibilityIdentifier ?: @"";
            selected.hint = resolvedHit.accessibilityHint ?: @"";
            selected.className =
                NSStringFromClass(resolvedHit.class);
            selected.frame =
                [resolvedHit convertRect:resolvedHit.bounds toView:nil];
            selected.path = @"hit-test";
            selected.generation = *generation;
        }
    }
    if (point != NULL) {
        *point = resolvedPoint;
    }
    if (window != NULL) {
        *window = resolvedWindow;
    }
    if (hitView != NULL) {
        *hitView = resolvedHit;
    }
    return selected;
}

static __attribute__((unused))
IOSUseAutomationCandidate *IOSUseAutomationResolve(
    NSDictionary<NSString *, id> *target,
    CGPoint *point,
    UIWindow **window,
    UIView **hitView,
    unsigned long long *generation,
    NSDictionary<NSString *, id> **commandError
) {
    NSDictionary<NSString *, id> *dom =
        IOSUseAutomationFreshDOM(commandError);
    if (dom == nil) {
        return nil;
    }
    return IOSUseAutomationResolveWithDOM(
        target,
        dom,
        point,
        window,
        hitView,
        generation,
        commandError
    );
}

static void IOSUseAutomationPump(NSTimeInterval duration) {
    CFAbsoluteTime deadline =
        CFAbsoluteTimeGetCurrent() + MAX(0.001, duration);
    do {
        CFRunLoopRunInMode(
            kCFRunLoopDefaultMode,
            MIN(0.01, deadline - CFAbsoluteTimeGetCurrent()),
            true
        );
    } while (CFAbsoluteTimeGetCurrent() < deadline);
}

static NSInteger IOSUseAutomationSendTouch(
    CGPoint point,
    UITouchPhase phase,
    NSInteger touchID,
    UIWindow *window,
    UIView *view
) {
    NSNumber *identifier = phase == UITouchPhaseBegan
        ? nil
        : @(touchID);
    NSNumber *result = [IOSUsePlayTouchBridge
        sendAtPoint:point
        phase:phase
        touchID:identifier
        window:window
        view:view];
    return result == nil ? -1 : result.integerValue;
}

static UIView *IOSUseAutomationScrollDeliveryView(UIView *hitView) {
    UIView *candidate = hitView;
    while (candidate != nil) {
        if ([candidate isKindOfClass:UIScrollView.class]) {
            UIScrollView *scrollView = (UIScrollView *)candidate;
            if (scrollView.scrollEnabled &&
                scrollView.userInteractionEnabled) {
                return scrollView;
            }
        }
        candidate = candidate.superview;
    }
    return hitView;
}

static NSDictionary<NSString *, id> *IOSUseAutomationHitViewJSON(
    UIView *view
) {
    CGRect frame = [view convertRect:view.bounds toView:nil];
    return @{
        @"class": NSStringFromClass(view.class) ?: @"UIView",
        @"frame": @{
            @"x": @(frame.origin.x),
            @"y": @(frame.origin.y),
            @"width": @(frame.size.width),
            @"height": @(frame.size.height),
        },
        @"accessibilityIdentifier":
            view.accessibilityIdentifier ?: @"",
        @"label": view.accessibilityLabel ?: @"",
    };
}

static NSDictionary<NSString *, id> *IOSUseAutomationStableElement(
    NSDictionary<NSString *, id> *element
) {
    if (![element isKindOfClass:NSDictionary.class]) {
        return @{};
    }
    NSMutableDictionary<NSString *, id> *stable =
        [element mutableCopy];
    [stable removeObjectForKey:@"snapshotGeneration"];
    [stable removeObjectForKey:@"zOrder"];
    // Runtime node IDs intentionally include the snapshot generation. They
    // prove freshness to clients but are not semantic UI state and therefore
    // must not make every no-op mutation look changed. Web proxy ordinals can
    // also move when an unrelated sibling is inserted, so z-order and sibling
    // indexes are delivery metadata rather than a postcondition.
    [stable removeObjectForKey:@"nodeID"];
    NSDictionary<NSString *, id> *hierarchy = stable[@"hierarchy"];
    if ([hierarchy isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary<NSString *, id> *stableHierarchy =
            [hierarchy mutableCopy];
        [stableHierarchy removeObjectForKey:@"parentID"];
        [stableHierarchy removeObjectForKey:@"path"];
        [stableHierarchy removeObjectForKey:@"index"];
        stable[@"hierarchy"] = stableHierarchy;
    }
    NSDictionary<NSString *, id> *state = stable[@"state"];
    if ([state isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary<NSString *, id> *stableState =
            [state mutableCopy];
        // Focus transfer is delivery evidence and may have no visible effect.
        // A Web button that merely becomes active must not make a no-op click
        // pass; visible focus rings are still covered by stable pixels.
        [stableState removeObjectForKey:@"focused"];
        stable[@"state"] = stableState;
    }
    return stable;
}

static NSArray<NSDictionary<NSString *, id> *> *
IOSUseAutomationStableDOM(NSDictionary<NSString *, id> *dom) {
    NSMutableArray<NSDictionary<NSString *, id> *> *result =
        [NSMutableArray array];
    for (NSDictionary<NSString *, id> *element in dom[@"elements"]) {
        // A DOM postcondition must describe a visible UI change. Filtering
        // both sides still records appearance and disappearance, while a
        // hidden script-only mutation cannot make an action succeed.
        if (![element[@"state"][@"visible"] boolValue]) {
            continue;
        }
        [result addObject:IOSUseAutomationStableElement(element)];
    }
    return result;
}

static NSDictionary<NSString *, id> *IOSUseAutomationStateEvidence(
    NSDictionary<NSString *, id> *preDOM,
    NSDictionary<NSString *, id> *postDOM,
    NSDictionary<NSString *, id> * _Nullable preTarget,
    NSDictionary<NSString *, id> * _Nullable postTarget
) {
    NSArray<NSDictionary<NSString *, id> *> *before =
        IOSUseAutomationStableDOM(preDOM);
    NSArray<NSDictionary<NSString *, id> *> *after =
        IOSUseAutomationStableDOM(postDOM);
    NSUInteger changedCount = 0;
    NSMutableArray<NSDictionary<NSString *, id> *> *changes =
        [NSMutableArray array];
    NSCountedSet<NSDictionary<NSString *, id> *> *beforeSet =
        [NSCountedSet setWithArray:before];
    NSCountedSet<NSDictionary<NSString *, id> *> *afterSet =
        [NSCountedSet setWithArray:after];
    NSMutableArray<NSDictionary<NSString *, id> *> *ordered =
        [before mutableCopy];
    [ordered addObjectsFromArray:after];
    NSMutableSet<NSDictionary<NSString *, id> *> *seen =
        [NSMutableSet set];
    for (NSDictionary<NSString *, id> *stableElement in ordered) {
        if ([seen containsObject:stableElement]) {
            continue;
        }
        [seen addObject:stableElement];
        NSUInteger beforeCount =
            [beforeSet countForObject:stableElement];
        NSUInteger afterCount =
            [afterSet countForObject:stableElement];
        if (beforeCount == afterCount) {
            continue;
        }
        changedCount += beforeCount > afterCount
            ? beforeCount - afterCount
            : afterCount - beforeCount;
        if (changes.count < 16) {
            [changes addObject:@{
                @"index": @(-1),
                @"before": beforeCount > 0
                    ? stableElement
                    : (id)NSNull.null,
                @"after": afterCount > 0
                    ? stableElement
                    : (id)NSNull.null,
                @"beforeCount": @(beforeCount),
                @"afterCount": @(afterCount),
            }];
        }
    }
    NSDictionary<NSString *, id> *stablePreTarget =
        preTarget == nil
            ? nil
            : IOSUseAutomationStableElement(preTarget);
    NSDictionary<NSString *, id> *stablePostTarget =
        postTarget == nil
            ? nil
            : IOSUseAutomationStableElement(postTarget);
    BOOL targetChanged = NO;
    if ((stablePreTarget == nil) != (stablePostTarget == nil)) {
        targetChanged = YES;
    } else if (stablePreTarget != nil &&
               stablePostTarget != nil) {
        targetChanged = ![
            stablePreTarget
            isEqualToDictionary:stablePostTarget
        ];
    }
    return @{
        @"beforeSnapshotGeneration":
            preDOM[@"snapshotGeneration"] ?: @0,
        @"afterSnapshotGeneration":
            postDOM[@"snapshotGeneration"] ?: @0,
        @"beforeElementCount": @(before.count),
        @"afterElementCount": @(after.count),
        @"changedElementCount": @(changedCount),
        @"changes": changes,
        @"targetChanged": @(targetChanged),
    };
}

static NSDictionary<NSString *, id> *IOSUseAutomationPostElement(
    NSDictionary<NSString *, id> *dom,
    NSDictionary<NSString *, id> *target
) {
    if (![target isKindOfClass:NSDictionary.class] ||
        target[@"point"] != nil) {
        return nil;
    }
    NSArray<NSDictionary<NSString *, id> *> *matches =
        IOSUseAutomationSelectElements(dom, target, NULL);
    return matches.count == 1 ? matches.firstObject : nil;
}

static BOOL IOSUseAutomationHitTestPoint(
    CGPoint point,
    UIWindow **window,
    UIView **hitView,
    CGPoint *windowPoint
) {
    if (!IOSUseAutomationFinitePoint(point)) {
        return NO;
    }
    for (UIWindow *candidateWindow in IOSUseAutomationWindows()) {
        CGPoint candidatePoint =
            [candidateWindow convertPoint:point fromWindow:nil];
        UIView *candidateHit =
            [candidateWindow hitTest:candidatePoint withEvent:nil];
        if (candidateHit == nil) {
            continue;
        }
        if (window != NULL) {
            *window = candidateWindow;
        }
        if (hitView != NULL) {
            *hitView = candidateHit;
        }
        if (windowPoint != NULL) {
            *windowPoint = candidatePoint;
        }
        return YES;
    }
    return NO;
}

static BOOL IOSUseAutomationViewHasAncestorOfClass(
    UIView *view,
    Class ancestorClass
) {
    for (UIView *candidate = view;
         candidate != nil;
         candidate = candidate.superview) {
        if ([candidate isKindOfClass:ancestorClass]) {
            return YES;
        }
    }
    return NO;
}

static BOOL IOSUseAutomationIsBottomInteraction(
    UIView *hitView
) {
    return IOSUseAutomationViewHasAncestorOfClass(
        hitView,
        UITabBar.class
    );
}

static BOOL IOSUseAutomationBottomTouchRequiresFocusRelease(
    UIResponder *responder,
    UIView *hitView
) {
    if (!IOSUseAutomationIsBottomInteraction(hitView) ||
        responder == nil ||
        ![responder conformsToProtocol:@protocol(UIKeyInput)] ||
        !responder.isFirstResponder) {
        return NO;
    }
    if ([responder isKindOfClass:UIView.class]) {
        UIView *responderView = (UIView *)responder;
        if (hitView == responderView ||
            [hitView isDescendantOfView:responderView] ||
            [responderView isDescendantOfView:hitView]) {
            return NO;
        }
    }
    return YES;
}

static CGRect IOSUseAutomationFrameDictionaryRect(id value) {
    if (![value isKindOfClass:NSDictionary.class] ||
        !IOSUseAutomationIsNumber(value[@"x"]) ||
        !IOSUseAutomationIsNumber(value[@"y"]) ||
        !IOSUseAutomationIsNumber(value[@"width"]) ||
        !IOSUseAutomationIsNumber(value[@"height"])) {
        return CGRectNull;
    }
    return CGRectMake(
        [value[@"x"] doubleValue],
        [value[@"y"] doubleValue],
        [value[@"width"] doubleValue],
        [value[@"height"] doubleValue]
    );
}

static NSDictionary<NSString *, id> *
IOSUseAutomationNativeAlertAction(
    NSString *label,
    CGPoint point
) {
    for (NSDictionary<NSString *, id> *action in
         [IOSUsePlayAppKitBridge nativeAlertActions]) {
        if (label.length > 0 &&
            [action[@"label"] isEqualToString:label]) {
            return action;
        }
        CGRect frame =
            IOSUseAutomationFrameDictionaryRect(action[@"frame"]);
        if (!CGRectIsNull(frame) && CGRectContainsPoint(frame, point)) {
            return action;
        }
    }
    return nil;
}

static BOOL IOSUseAutomationDOMHasVisibleUIKitAlertMirror(
    NSDictionary<NSString *, id> *dom
) {
    for (NSDictionary<NSString *, id> *element in dom[@"elements"]) {
        NSString *className = element[@"class"];
        NSDictionary<NSString *, id> *state = element[@"state"];
        if ([className isKindOfClass:NSString.class] &&
            [className containsString:@"UIAlertController"] &&
            [state[@"visible"] boolValue]) {
            return YES;
        }
    }
    return NO;
}

static CGRect IOSUseAutomationFingerprintRect(
    CGPoint start,
    CGPoint end,
    CGRect targetFrame
) {
    CGRect device = CGRectMake(
        0,
        0,
        IOSUsePlayDeviceLogicalWidth,
        IOSUsePlayDeviceLogicalHeight
    );
    CGRect aroundStart = CGRectMake(
        start.x - 96,
        start.y - 96,
        192,
        192
    );
    CGRect aroundEnd = CGRectMake(
        end.x - 96,
        end.y - 96,
        192,
        192
    );
    CGRect region = CGRectUnion(aroundStart, aroundEnd);
    if (!CGRectIsNull(targetFrame) &&
        !CGRectIsInfinite(targetFrame) &&
        isfinite(targetFrame.origin.x) &&
        isfinite(targetFrame.origin.y) &&
        isfinite(targetFrame.size.width) &&
        isfinite(targetFrame.size.height) &&
        targetFrame.size.width > 0 &&
        targetFrame.size.height > 0) {
        region = CGRectUnion(
            region,
            CGRectInset(targetFrame, -32, -32)
        );
    }
    region = CGRectIntersection(region, device);
    CGFloat minimumX = floor(CGRectGetMinX(region));
    CGFloat minimumY = floor(CGRectGetMinY(region));
    CGFloat maximumX = ceil(CGRectGetMaxX(region));
    CGFloat maximumY = ceil(CGRectGetMaxY(region));
    return CGRectMake(
        minimumX,
        minimumY,
        maximumX - minimumX,
        maximumY - minimumY
    );
}

static NSDictionary<NSString *, id> *
IOSUseAutomationPreFingerprint(
    CGRect logicalRect,
    NSDictionary<NSString *, id> *target,
    NSDictionary<NSString *, id> **commandError
) {
    NSString *failureCode = nil;
    NSString *failureMessage = nil;
    NSDictionary<NSString *, id> *fingerprint =
        IOSUsePlayRuntimeScreenshotFingerprint(
            logicalRect,
            &failureCode,
            &failureMessage
        );
    if (fingerprint != nil) {
        return fingerprint;
    }
    if (commandError != NULL) {
        NSMutableDictionary<NSString *, id> *error = [
            IOSUseAutomationError(
                @"postcondition_capture_failed",
                failureMessage ?:
                    @"could not capture the pre-action pixel fingerprint",
                @"capture",
                @"precondition",
                YES,
                target,
                @[]
            )
            mutableCopy
        ];
        NSMutableDictionary<NSString *, id> *details =
            [error[@"details"] mutableCopy];
        details[@"captureCode"] =
            failureCode ?: @"fingerprint_unavailable";
        error[@"details"] = details;
        *commandError = error;
    }
    return nil;
}

static NSDictionary<NSString *, id> *IOSUseAutomationActionResult(
    IOSUseAutomationCandidate *candidate,
    NSDictionary<NSString *, id> *target,
    NSDictionary<NSString *, id> *preDOM,
    NSDictionary<NSString *, id> * _Nullable preFingerprint,
    CGRect fingerprintRect,
    BOOL requireChangedPostcondition,
    UIView *hitView,
    CGPoint point,
    NSInteger touchID,
    NSString *phase,
    NSString * _Nullable firstResponderClass,
    NSDictionary<NSString *, id> * _Nullable extra,
    NSDictionary<NSString *, id> **commandError
) {
    NSDictionary<NSString *, id> *snapshotError = nil;
    NSDictionary<NSString *, id> *postDOM =
        IOSUseAutomationFreshDOM(&snapshotError);
    for (NSNumber *delay in @[@0.1, @0.25]) {
        if (postDOM != nil) {
            break;
        }
        IOSUseAutomationPump(delay.doubleValue);
        snapshotError = nil;
        postDOM = IOSUseAutomationFreshDOM(&snapshotError);
    }
    if (postDOM == nil) {
        if (commandError != NULL) {
            *commandError = snapshotError ?:
                IOSUseAutomationError(
                    @"postcondition_failed",
                    @"fresh post-action DOM snapshot failed",
                    @"lookup",
                    @"postcondition",
                    YES,
                    target,
                    @[]
                );
        }
        return nil;
    }
    NSDictionary<NSString *, id> *postElement =
        IOSUseAutomationPostElement(postDOM, target);
    NSDictionary<NSString *, id> *preElement =
        IOSUseAutomationElementJSON(candidate);
    NSDictionary<NSString *, id> *stateEvidence =
        IOSUseAutomationStateEvidence(
            preDOM,
            postDOM,
            preElement,
            postElement
        );
    BOOL domChanged =
        [stateEvidence[@"changedElementCount"]
            unsignedIntegerValue] > 0;
    NSDictionary<NSString *, id> *pixelEvidence = nil;
    BOOL pixelChanged = NO;
    if (preFingerprint != nil) {
        NSString *failureCode = nil;
        NSString *failureMessage = nil;
        NSDictionary<NSString *, id> *initialPostFingerprint =
            IOSUsePlayRuntimeScreenshotFingerprint(
                fingerprintRect,
                &failureCode,
                &failureMessage
            );
        if (initialPostFingerprint == nil) {
            // A control directly beneath transparent system chrome can
            // transiently make a status glyph pixel-indistinguishable while
            // its pressed highlight is live. Retry only after the UIKit
            // highlight window; the compositor verifier remains strict for
            // the stable sample.
            IOSUseAutomationPump(0.2);
            initialPostFingerprint =
                IOSUsePlayRuntimeScreenshotFingerprint(
                    fingerprintRect,
                    &failureCode,
                    &failureMessage
                );
        }
        if (initialPostFingerprint == nil) {
            if (commandError != NULL) {
                NSMutableDictionary<NSString *, id> *error = [
                    IOSUseAutomationError(
                        @"postcondition_capture_failed",
                        failureMessage ?:
                            @"could not capture the post-action pixel fingerprint",
                        @"capture",
                        @"postcondition",
                        YES,
                        target,
                        @[]
                    )
                    mutableCopy
                ];
                NSMutableDictionary<NSString *, id> *details =
                    [error[@"details"] mutableCopy];
                details[@"captureCode"] =
                    failureCode ?: @"fingerprint_unavailable";
                details[@"preFingerprint"] = preFingerprint;
                error[@"details"] = details;
                *commandError = error;
            }
            return nil;
        }
        NSDictionary<NSString *, id> *postFingerprint =
            initialPostFingerprint;
        if (!domChanged) {
            // A UIButton highlight or scroll deceleration is delivery
            // evidence, not an action postcondition. Sample once more after
            // the transient window. Re-read the DOM as well: UIControl target
            // actions can be queued behind the touch event on Catalyst, so
            // the first fresh snapshot is delivery evidence but is not
            // necessarily the settled postcondition.
            IOSUseAutomationPump(0.15);
            snapshotError = nil;
            NSDictionary<NSString *, id> *settledDOM =
                IOSUseAutomationFreshDOM(&snapshotError);
            if (settledDOM == nil) {
                IOSUseAutomationPump(0.2);
                snapshotError = nil;
                settledDOM =
                    IOSUseAutomationFreshDOM(&snapshotError);
            }
            if (settledDOM == nil) {
                if (commandError != NULL) {
                    *commandError = snapshotError ?:
                        IOSUseAutomationError(
                            @"postcondition_failed",
                            @"settled post-action DOM snapshot failed",
                            @"lookup",
                            @"postcondition",
                            YES,
                            target,
                            @[]
                        );
                }
                return nil;
            }
            postDOM = settledDOM;
            postElement =
                IOSUseAutomationPostElement(postDOM, target);
            stateEvidence = IOSUseAutomationStateEvidence(
                preDOM,
                postDOM,
                preElement,
                postElement
            );
            domChanged =
                [stateEvidence[@"changedElementCount"]
                    unsignedIntegerValue] > 0;
            NSDictionary<NSString *, id> *verifiedFingerprint =
                IOSUsePlayRuntimeScreenshotFingerprint(
                    fingerprintRect,
                    &failureCode,
                    &failureMessage
                );
            if (verifiedFingerprint == nil) {
                if (commandError != NULL) {
                    *commandError = IOSUseAutomationError(
                        @"postcondition_capture_failed",
                        failureMessage ?:
                            @"could not verify the stable post-action pixel fingerprint",
                        @"capture",
                        @"postcondition",
                        YES,
                        target,
                        @[]
                    );
                }
                return nil;
            }
            postFingerprint = verifiedFingerprint;
        }
        NSString *beforeHash = preFingerprint[@"hash"];
        NSString *initialAfterHash =
            initialPostFingerprint[@"hash"];
        NSString *afterHash = postFingerprint[@"hash"];
        BOOL stablePixelSample =
            domChanged ||
            [initialAfterHash isEqualToString:afterHash] ||
            [initialAfterHash isEqualToString:beforeHash];
        pixelChanged =
            [beforeHash isKindOfClass:NSString.class] &&
            [afterHash isKindOfClass:NSString.class] &&
            ![beforeHash isEqualToString:afterHash] &&
            stablePixelSample;
        pixelEvidence = @{
            @"before": preFingerprint,
            @"after": postFingerprint,
            @"initialAfter": initialPostFingerprint,
            @"stable": @(stablePixelSample),
            @"changed": @(pixelChanged),
        };
    }
    BOOL changed = domChanged || pixelChanged;
    NSDictionary<NSString *, id> *postcondition = @{
        @"snapshotGeneration":
            postDOM[@"snapshotGeneration"],
        @"element": postElement ?: (id)NSNull.null,
        @"changed": @(changed),
        @"stateEvidence": stateEvidence,
        @"pixelEvidence": pixelEvidence ?: (id)NSNull.null,
    };
    if (requireChangedPostcondition && !changed) {
        if (commandError != NULL) {
            NSMutableDictionary<NSString *, id> *error = [
                IOSUseAutomationError(
                    @"postcondition_failed",
                    @"the action backend reported delivery but neither visible live DOM state nor stable compositor pixels changed",
                    @"interaction",
                    @"postcondition",
                    YES,
                    target,
                    @[]
                )
                mutableCopy
            ];
            NSMutableDictionary<NSString *, id> *details =
                [error[@"details"] mutableCopy];
            details[@"postcondition"] = postcondition;
            error[@"details"] = details;
            *commandError = error;
        }
        return nil;
    }
    NSMutableDictionary<NSString *, id> *finalState = [@{
        @"point": @{
            @"x": @(point.x),
            @"y": @(point.y),
        },
        @"touchID": @(touchID),
        @"phase": phase,
    } mutableCopy];
    if (firstResponderClass.length > 0) {
        finalState[@"firstResponderClass"] = firstResponderClass;
    }
    NSMutableDictionary<NSString *, id> *result = [@{
        @"element": IOSUseAutomationElementJSON(candidate),
        @"hitView": IOSUseAutomationHitViewJSON(hitView),
        @"finalState": finalState,
        @"postcondition": postcondition,
    } mutableCopy];
    [result addEntriesFromDictionary:extra ?: @{}];
    return result;
}

static NSDictionary<NSString *, id> *IOSUseAutomationTouchCommand(
    NSString *command,
    NSDictionary<NSString *, id> *arguments,
    NSDictionary<NSString *, id> **commandError
) {
    NSDictionary *target =
        [command isEqualToString:@"swipe"]
            ? arguments[@"fromTarget"]
            : arguments[@"target"];
    CGPoint point = CGPointZero;
    UIWindow *window = nil;
    UIView *hitView = nil;
    unsigned long long generation = 0;
    NSDictionary<NSString *, id> *snapshotError = nil;
    NSDictionary<NSString *, id> *preDOM =
        IOSUseAutomationFreshDOM(&snapshotError);
    if (preDOM == nil) {
        if (commandError != NULL) {
            *commandError = snapshotError;
        }
        return nil;
    }
    IOSUseAutomationCandidate *candidate =
        IOSUseAutomationResolveWithDOM(
        target,
        preDOM,
        &point,
        &window,
        &hitView,
        &generation,
        commandError
    );
    if (candidate == nil) {
        return nil;
    }
    NSDictionary<NSString *, id> *focusTransition = nil;
    if ([command isEqualToString:@"tap"] &&
        IOSUseAutomationIsBottomInteraction(hitView)) {
        UIResponder *focused =
            IOSUseAutomationCurrentFirstResponder();
        NSString *beforeClass = focused == nil
            ? @""
            : NSStringFromClass(focused.class);
        BOOL requested = NO;
        BOOL focusReleased = NO;
        if (IOSUseAutomationBottomTouchRequiresFocusRelease(
                focused,
                hitView
            )) {
            requested = [focused resignFirstResponder];
            for (UIWindow *candidateWindow in
                 IOSUseAutomationWindows()) {
                requested =
                    [candidateWindow endEditing:YES] ||
                    requested;
            }
            IOSUseAutomationPump(0.1);
            UIResponder *after =
                IOSUseAutomationCurrentFirstResponder();
            if (after != nil &&
                [after conformsToProtocol:
                    @protocol(UIKeyInput)] &&
                after.isFirstResponder) {
                if (commandError != NULL) {
                    *commandError = IOSUseAutomationError(
                        @"first_responder_release_failed",
                        @"the active text responder retained the tab-bar interaction",
                        @"interaction",
                        @"first-responder",
                        YES,
                        target,
                        @[]
                    );
                }
                return nil;
            }
            focusReleased = YES;
        }
        NSError *transientError = nil;
        NSDictionary<NSString *, id> *transientDismissal =
            [IOSUsePlayAppKitBridge
                dismissTransientTextInputWindows:&transientError];
        if (transientDismissal == nil) {
            if (commandError != NULL) {
                *commandError = IOSUseAutomationError(
                    @"text_input_transient_dismissal_failed",
                    transientError.localizedDescription ?:
                        @"could not dismiss the AppKit text-input transient before a tab-bar interaction",
                    @"interaction",
                    @"first-responder",
                    YES,
                    target,
                    @[]
                );
            }
            return nil;
        }
        NSUInteger dismissedCount =
            [transientDismissal[@"dismissedCount"]
                unsignedIntegerValue];
        if (focusReleased || dismissedCount > 0) {
            IOSUseAutomationPump(0.1);
            UIResponder *after =
                IOSUseAutomationCurrentFirstResponder();
            focusTransition = @{
                @"reason": @"tab-bar-interaction",
                @"requested": @(requested),
                @"focusReleased": @(focusReleased),
                @"beforeClass": beforeClass ?: @"",
                @"afterClass": after == nil
                    ? @""
                    : NSStringFromClass(after.class),
                @"transientDismissal": transientDismissal,
            };
            snapshotError = nil;
            preDOM = IOSUseAutomationFreshDOM(&snapshotError);
            if (preDOM == nil) {
                if (commandError != NULL) {
                    *commandError = snapshotError;
                }
                return nil;
            }
            candidate = IOSUseAutomationResolveWithDOM(
                target,
                preDOM,
                &point,
                &window,
                &hitView,
                &generation,
                commandError
            );
            if (candidate == nil) {
                return nil;
            }
        }
    }
    if ([command isEqualToString:@"tap"]) {
        NSDictionary *offset = arguments[@"offset"];
        NSDictionary *ratio = arguments[@"ratio"];
        if (ratio != nil) {
            if (!IOSUseAutomationIsNumber(ratio[@"x"]) ||
                !IOSUseAutomationIsNumber(ratio[@"y"])) {
                if (commandError != NULL) {
                    *commandError = IOSUseAutomationError(
                        @"invalid_arguments",
                        @"tap ratio must contain numeric x and y",
                        @"validation",
                        @"validation",
                        NO,
                        target,
                        @[]
                    );
                }
                return nil;
            }
            CGRect frame = candidate.frame;
            point = CGPointMake(
                frame.origin.x +
                    frame.size.width * [ratio[@"x"] doubleValue],
                frame.origin.y +
                    frame.size.height * [ratio[@"y"] doubleValue]
            );
        }
        if (offset != nil) {
            if (!IOSUseAutomationIsNumber(offset[@"x"]) ||
                !IOSUseAutomationIsNumber(offset[@"y"])) {
                if (commandError != NULL) {
                    *commandError = IOSUseAutomationError(
                        @"invalid_arguments",
                        @"tap offset must contain numeric x and y",
                        @"validation",
                        @"validation",
                        NO,
                        target,
                        @[]
                    );
                }
                return nil;
            }
            point.x += [offset[@"x"] doubleValue];
            point.y += [offset[@"y"] doubleValue];
        }
        CGPoint adjustedPoint = CGPointZero;
        if (!IOSUseAutomationHitTestPoint(
                point,
                &window,
                &hitView,
                &adjustedPoint
            )) {
            if (commandError != NULL) {
                *commandError = IOSUseAutomationError(
                    @"element_not_hittable",
                    @"tap ratio/offset resolved outside a live hit-test view",
                    @"interaction",
                    @"hit-test",
                    YES,
                    target,
                    @[]
                );
            }
            return nil;
        }
        point = adjustedPoint;
        CGRect fingerprintRect =
            IOSUseAutomationFingerprintRect(
                point,
                point,
                candidate.frame
            );
        NSDictionary<NSString *, id> *preFingerprint =
            IOSUseAutomationPreFingerprint(
                fingerprintRect,
                target,
                commandError
            );
        if (preFingerprint == nil) {
            return nil;
        }
        NSDictionary<NSString *, id> *nativeAlertAction =
            IOSUseAutomationNativeAlertAction(
                candidate.label,
                point
            );
        if (nativeAlertAction != nil) {
            NSError *nativeError = nil;
            NSDictionary<NSString *, id> *nativeDelivery =
                [IOSUsePlayAppKitBridge
                    performNativeAlertActionWithLabel:
                        nativeAlertAction[@"label"]
                    error:&nativeError];
            if (nativeDelivery == nil) {
                if (commandError != NULL) {
                    *commandError = IOSUseAutomationError(
                        @"native_alert_action_failed",
                        nativeError.localizedDescription ?:
                            @"native alert action was not delivered",
                        @"interaction",
                        @"delivery",
                        YES,
                        target,
                        @[]
                    );
                }
                return nil;
            }
            IOSUseAutomationDeferredFinalize finalize =
                ^NSDictionary<NSString *, id> *(
                    NSDictionary<NSString *, id> **deferredError
                ) {
                    if ([IOSUsePlayAppKitBridge
                            hasVisibleNativeAlert]) {
                        if (deferredError != NULL) {
                            *deferredError =
                                IOSUseAutomationError(
                                    @"native_alert_action_failed",
                                    @"native alert target/action did not close the panel",
                                    @"interaction",
                                    @"postcondition",
                                    YES,
                                    target,
                                    @[]
                                );
                        }
                        return nil;
                    }
                    NSDictionary<NSString *, id> *settledDOM =
                        IOSUseAutomationFreshDOM(deferredError);
                    if (settledDOM == nil ||
                        IOSUseAutomationDOMHasVisibleUIKitAlertMirror(
                            settledDOM
                        )) {
                        if (deferredError != NULL &&
                            *deferredError == nil) {
                            *deferredError =
                                IOSUseAutomationError(
                                    @"native_alert_action_failed",
                                    @"native alert UIKit mirror did not settle",
                                    @"interaction",
                                    @"postcondition",
                                    YES,
                                    target,
                                    @[]
                                );
                        }
                        return nil;
                    }
                    return IOSUseAutomationActionResult(
                        candidate,
                        target,
                        preDOM,
                        preFingerprint,
                        fingerprintRect,
                        YES,
                        hitView,
                        point,
                        -1,
                        @"native-ended",
                        nil,
                        @{@"nativeAlertDelivery": nativeDelivery},
                        deferredError
                    );
                };
            NSMutableDictionary<NSString *, id> *deferred = [@{
                IOSUseAutomationDeferredFinalizeKey:
                    [finalize copy],
            } mutableCopy];
            if (focusTransition != nil) {
                deferred[@"preTouchFocusTransition"] =
                    focusTransition;
            }
            return deferred;
        }
        if (IOSUsePlayRuntimeIsWebAccessibilityElement(
                candidate.serialized
            )) {
            NSString *webFailureCode = nil;
            NSString *webFailureMessage = nil;
            NSDictionary<NSString *, id> *webEvidence =
                IOSUsePlayRuntimePerformWebAccessibilityAction(
                    hitView,
                    candidate.serialized,
                    IOSUsePlayRuntimeWebAccessibilityActionActivate,
                    &webFailureCode,
                    &webFailureMessage
                );
            if (webEvidence == nil) {
                if (commandError != NULL) {
                    *commandError =
                        IOSUseAutomationWebBridgeFailure(
                            IOSUseAutomationError(
                                webFailureCode ?:
                                    @"web_bridge_failed",
                                webFailureMessage ?:
                                    @"the fixed Web accessibility activation did not report successful delivery",
                                @"interaction",
                                @"delivery",
                                YES,
                                target,
                                @[]
                            ),
                            webFailureCode
                        );
                }
                return nil;
            }
            IOSUseAutomationPump(0.03);
            return IOSUseAutomationActionResult(
                candidate,
                target,
                preDOM,
                preFingerprint,
                fingerprintRect,
                YES,
                hitView,
                point,
                -1,
                @"web-activated",
                nil,
                @{
                    @"actionEvidence": webEvidence,
                },
                commandError
            );
        }
        unsigned long long deliveryBefore =
            PTFakeMetaTouch.deliveryGeneration;
        NSInteger touchID = IOSUseAutomationSendTouch(
            point,
            UITouchPhaseBegan,
            -1,
            window,
            hitView
        );
        IOSUseAutomationPump(0.015);
        IOSUseAutomationSendTouch(
            point,
            UITouchPhaseEnded,
            touchID,
            window,
            hitView
        );
        IOSUseAutomationPump(0.03);
        if (PTFakeMetaTouch.deliveryGeneration <
            deliveryBefore + 2) {
            if (commandError != NULL) {
                *commandError = IOSUseAutomationError(
                    @"touch_delivery_failed",
                    @"tap touch phases were not delivered to UIApplication",
                    @"interaction",
                    @"delivery",
                    YES,
                    target,
                    @[]
                );
            }
            return nil;
        }
        return IOSUseAutomationActionResult(
            candidate,
            target,
            preDOM,
            preFingerprint,
            fingerprintRect,
            YES,
            hitView,
            point,
            touchID,
            @"ended",
            nil,
            focusTransition == nil
                ? nil
                : @{
                    @"preTouchFocusTransition":
                        focusTransition,
                },
            commandError
        );
    }
    if ([command isEqualToString:@"longPress"]) {
        id durationValue = arguments[@"durationMs"];
        if (!IOSUseAutomationIsNumber(durationValue) ||
            [durationValue doubleValue] < 0 ||
            [durationValue doubleValue] > 30000) {
            if (commandError != NULL) {
                *commandError = IOSUseAutomationError(
                    @"invalid_arguments",
                    @"longPress durationMs must be between 0 and 30000",
                    @"validation",
                    @"validation",
                    NO,
                    target,
                    @[]
                );
            }
            return nil;
        }
        CGRect fingerprintRect =
            IOSUseAutomationFingerprintRect(
                point,
                point,
                candidate.frame
            );
        NSDictionary<NSString *, id> *preFingerprint =
            IOSUseAutomationPreFingerprint(
                fingerprintRect,
                target,
                commandError
            );
        if (preFingerprint == nil) {
            return nil;
        }
        unsigned long long deliveryBefore =
            PTFakeMetaTouch.deliveryGeneration;
        NSInteger touchID = IOSUseAutomationSendTouch(
            point,
            UITouchPhaseBegan,
            -1,
            window,
            hitView
        );
        double durationMilliseconds = [durationValue doubleValue];
        if (durationMilliseconds == 0) {
            durationMilliseconds = 1000;
        }
        IOSUseAutomationPump(durationMilliseconds / 1000.0);
        IOSUseAutomationSendTouch(
            point,
            UITouchPhaseEnded,
            touchID,
            window,
            hitView
        );
        IOSUseAutomationPump(0.03);
        if (PTFakeMetaTouch.deliveryGeneration <
            deliveryBefore + 2) {
            if (commandError != NULL) {
                *commandError = IOSUseAutomationError(
                    @"touch_delivery_failed",
                    @"longPress touch phases were not delivered to UIApplication",
                    @"interaction",
                    @"delivery",
                    YES,
                    target,
                    @[]
                );
            }
            return nil;
        }
        return IOSUseAutomationActionResult(
            candidate,
            target,
            preDOM,
            preFingerprint,
            fingerprintRect,
            YES,
            hitView,
            point,
            touchID,
            @"ended",
            nil,
            nil,
            commandError
        );
    }
    NSDictionary *toTarget = arguments[@"toTarget"];
    CGPoint endPoint = CGPointZero;
    IOSUseAutomationCandidate *toCandidate = nil;
    UIView *deliveryView = hitView;
    if ([toTarget isKindOfClass:NSDictionary.class]) {
        UIWindow *endWindow = nil;
        UIView *endHitView = nil;
        unsigned long long endGeneration = 0;
        toCandidate = IOSUseAutomationResolveWithDOM(
            toTarget,
            preDOM,
            &endPoint,
            &endWindow,
            &endHitView,
            &endGeneration,
            commandError
        );
        if (toCandidate == nil || endWindow != window) {
            if (toCandidate != nil && commandError != NULL) {
                *commandError = IOSUseAutomationError(
                    @"invalid_target_point",
                    @"swipe endpoints must resolve in the same UIWindow",
                    @"interaction",
                    @"lookup",
                    NO,
                    toTarget,
                    @[]
                );
            }
            return nil;
        }
    } else {
        if (!IOSUseAutomationIsNumber(arguments[@"distance"]) ||
            !IOSUseAutomationIsNumber(arguments[@"direction"])) {
            if (commandError != NULL) {
                *commandError = IOSUseAutomationError(
                    @"invalid_arguments",
                    @"swipe requires toTarget or numeric distance and direction",
                    @"validation",
                    @"validation",
                    NO,
                    target,
                    @[]
                );
            }
            return nil;
        }
        CGFloat distance = [arguments[@"distance"] doubleValue];
        NSInteger direction = [arguments[@"direction"] integerValue];
        if (direction < -1 || direction > 1 || distance <= 0) {
            if (commandError != NULL) {
                *commandError = IOSUseAutomationError(
                    @"invalid_arguments",
                    @"swipe direction must be unspecified (-1), forth (0), or back (1), and distance must be positive",
                    @"validation",
                    @"validation",
                    NO,
                    target,
                    @[]
                );
            }
            return nil;
        }
        BOOL isBack =
            direction == 1;
        endPoint = CGPointMake(
            point.x,
            point.y + (isBack ? distance : -distance)
        );
        deliveryView =
            IOSUseAutomationScrollDeliveryView(hitView);
    }
    if (!IOSUseAutomationFinitePoint(endPoint)) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationError(
                @"invalid_target_point",
                @"swipe endpoint is outside the logical screen",
                @"validation",
                @"validation",
                NO,
                target,
                @[]
            );
        }
        return nil;
    }
    double duration = IOSUseAutomationIsNumber(arguments[@"durationMs"])
        ? [arguments[@"durationMs"] doubleValue] / 1000.0
        : 0.35;
    if (!isfinite(duration) || duration < 0.05 || duration > 30) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationError(
                @"invalid_arguments",
                @"swipe durationMs must be between 50 and 30000",
                @"validation",
                @"validation",
                NO,
                target,
                @[]
            );
        }
        return nil;
    }
    CGRect fingerprintRect =
        IOSUseAutomationFingerprintRect(
            point,
            endPoint,
            candidate.frame
        );
    NSDictionary<NSString *, id> *preFingerprint =
        IOSUseAutomationPreFingerprint(
            fingerprintRect,
            target,
            commandError
        );
    if (preFingerprint == nil) {
        return nil;
    }
    unsigned long long deliveryBefore =
        PTFakeMetaTouch.deliveryGeneration;
    NSInteger touchID = IOSUseAutomationSendTouch(
        point,
        UITouchPhaseBegan,
        -1,
        window,
        deliveryView
    );
    IOSUseAutomationPump(0.015);
    const NSUInteger steps = 12;
    for (NSUInteger step = 1; step <= steps; step += 1) {
        CGFloat progress = (CGFloat)step / (CGFloat)steps;
        CGPoint current = CGPointMake(
            point.x + (endPoint.x - point.x) * progress,
            point.y + (endPoint.y - point.y) * progress
        );
        IOSUseAutomationSendTouch(
            current,
            UITouchPhaseMoved,
            touchID,
            window,
            deliveryView
        );
        IOSUseAutomationPump(duration / steps);
    }
    IOSUseAutomationSendTouch(
        endPoint,
        UITouchPhaseEnded,
        touchID,
        window,
        deliveryView
    );
    IOSUseAutomationPump(0.03);
    if (PTFakeMetaTouch.deliveryGeneration <
        deliveryBefore + 3) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationError(
                @"touch_delivery_failed",
                @"swipe phases were not delivered to UIApplication",
                @"interaction",
                @"delivery",
                YES,
                target,
                @[]
            );
        }
        return nil;
    }
    return IOSUseAutomationActionResult(
        candidate,
        target,
        preDOM,
        preFingerprint,
        fingerprintRect,
        YES,
        hitView,
        endPoint,
        touchID,
        @"ended",
        nil,
        @{
            @"scrolls": @1,
            @"direction":
                [arguments[@"direction"] integerValue] == 0
                    ? @"forth"
                    : (
                        [arguments[@"direction"] integerValue] == 1
                            ? @"back"
                            : @"unspecified"
                    ),
            @"toElement": IOSUseAutomationElementJSON(toCandidate),
        },
        commandError
    );
}

static UIResponder *IOSUseAutomationFirstResponder(UIView *view) {
    if (view.isFirstResponder) {
        return view;
    }
    for (UIView *child in view.subviews) {
        UIResponder *found = IOSUseAutomationFirstResponder(child);
        if (found != nil) {
            return found;
        }
    }
    return nil;
}

static UIResponder *IOSUseAutomationCurrentFirstResponder(void) {
    for (UIWindow *window in IOSUseAutomationWindows()) {
        UIResponder *firstResponder =
            IOSUseAutomationFirstResponder(window);
        if (firstResponder != nil) {
            return firstResponder;
        }
    }
    return nil;
}

static UIResponder *IOSUseAutomationKeyInputResponder(
    IOSUseAutomationCandidate *candidate,
    UIView *hitView
) {
    NSArray *objects = @[
        candidate.object ?: NSNull.null,
        hitView ?: NSNull.null,
    ];
    // Prefer a standard text control over an accessibility proxy or an
    // implementation-specific UIKeyInput descendant. The selected object is
    // only an expectation; the live first responder is verified again before
    // any text mutation.
    for (id object in objects) {
        if ([object isKindOfClass:UITextField.class] ||
            [object isKindOfClass:UITextView.class]) {
            return object;
        }
    }
    for (UIView *view = hitView;
         view != nil;
         view = view.superview) {
        if ([view isKindOfClass:UITextField.class] ||
            [view isKindOfClass:UITextView.class]) {
            return view;
        }
    }
    for (id object in objects) {
        if (object != NSNull.null &&
            [object isKindOfClass:UIResponder.class] &&
            [object conformsToProtocol:@protocol(UIKeyInput)]) {
            return object;
        }
    }
    for (UIView *view = hitView;
         view != nil;
         view = view.superview) {
        if ([view conformsToProtocol:@protocol(UIKeyInput)]) {
            return view;
        }
    }
    return nil;
}

static BOOL IOSUseAutomationResponderMatches(
    UIResponder *responder,
    UIResponder *expected
) {
    if (responder == expected) {
        return YES;
    }
    if (![responder isKindOfClass:UIView.class] ||
        ![expected isKindOfClass:UIView.class]) {
        return NO;
    }
    UIView *responderView = (UIView *)responder;
    UIView *expectedView = (UIView *)expected;
    return [responderView isDescendantOfView:expectedView] ||
        [expectedView isDescendantOfView:responderView];
}

static NSDictionary<NSString *, id> *
IOSUseAutomationUnsupportedInputError(
    NSString *reason,
    NSString *message,
    NSDictionary<NSString *, id> * _Nullable target,
    UIResponder *responder
) {
    NSMutableDictionary<NSString *, id> *error = [
        IOSUseAutomationError(
            @"input_unsupported",
            message,
            @"action",
            @"interaction",
            NO,
            target,
            @[]
        )
        mutableCopy
    ];
    NSMutableDictionary<NSString *, id> *details =
        [error[@"details"] mutableCopy];
    details[@"unsupportedReason"] = reason;
    details[@"responderClass"] =
        NSStringFromClass(responder.class) ?: @"";
    error[@"details"] = details;
    return error;
}

static NSString * _Nullable IOSUseAutomationExactTextValue(
    UIResponder *responder
) {
    if ([responder isKindOfClass:UITextField.class]) {
        return ((UITextField *)responder).text ?: @"";
    }
    if ([responder isKindOfClass:UITextView.class]) {
        return ((UITextView *)responder).text ?: @"";
    }
    if ([responder conformsToProtocol:@protocol(UITextInput)]) {
        id<UITextInput> textInput = (id<UITextInput>)responder;
        UITextRange *document = [
            textInput
            textRangeFromPosition:textInput.beginningOfDocument
            toPosition:textInput.endOfDocument
        ];
        return document == nil
            ? nil
            : [textInput textInRange:document];
    }
    return nil;
}

static BOOL IOSUseAutomationIsSupportedWebInputResponder(
    UIResponder *responder
) {
    return [NSStringFromClass(responder.class)
        isEqualToString:@"WKContentView"] &&
        [responder conformsToProtocol:@protocol(UITextInput)] &&
        [responder conformsToProtocol:@protocol(UIKeyInput)];
}

static NSRange IOSUseAutomationSuffixRange(
    NSString *value,
    NSInteger requestedDeleteCount,
    NSInteger *appliedDeleteCount
) {
    NSUInteger start = value.length;
    NSInteger applied = 0;
    while (applied < requestedDeleteCount && start > 0) {
        NSRange composedRange =
            [value rangeOfComposedCharacterSequenceAtIndex:start - 1];
        start = composedRange.location;
        applied += 1;
    }
    if (appliedDeleteCount != NULL) {
        *appliedDeleteCount = applied;
    }
    return NSMakeRange(start, value.length - start);
}

static BOOL IOSUseAutomationSelectTextRange(
    id<UITextInput> textInput,
    NSRange utf16Range
) {
    UITextPosition *beginning = textInput.beginningOfDocument;
    UITextPosition *start = [textInput
        positionFromPosition:beginning
                     offset:(NSInteger)utf16Range.location];
    UITextPosition *end = start == nil
        ? nil
        : [textInput
            positionFromPosition:start
                         offset:(NSInteger)utf16Range.length];
    if (start == nil || end == nil) {
        return NO;
    }
    UITextRange *selection = [textInput
        textRangeFromPosition:start
                   toPosition:end];
    if (selection == nil) {
        return NO;
    }
    textInput.selectedTextRange = selection;
    UITextRange *actualSelection = textInput.selectedTextRange;
    if (actualSelection == nil) {
        return NO;
    }
    NSInteger actualLocation = [textInput
        offsetFromPosition:beginning
                toPosition:actualSelection.start];
    NSInteger actualLength = [textInput
        offsetFromPosition:actualSelection.start
                toPosition:actualSelection.end];
    return actualLocation == (NSInteger)utf16Range.location &&
        actualLength == (NSInteger)utf16Range.length;
}

static BOOL IOSUseAutomationTextDocumentMatchesValue(
    id<UITextInput> textInput,
    NSString *value
) {
    UITextRange *documentRange = [textInput
        textRangeFromPosition:textInput.beginningOfDocument
                   toPosition:textInput.endOfDocument];
    if (documentRange == nil) {
        return NO;
    }
    NSString *documentValue = [textInput textInRange:documentRange];
    return documentValue != nil &&
        [documentValue isEqualToString:value];
}

static NSDictionary<NSString *, id> *
IOSUseAutomationInputPostconditionError(
    NSString *expectedValue,
    NSString *actualValue,
    NSDictionary<NSString *, id> * _Nullable target
) {
    NSMutableDictionary<NSString *, id> *error = [
        IOSUseAutomationError(
            @"input_not_applied",
            @"text input did not produce the exact expected value",
            @"interaction",
            @"postcondition",
            YES,
            target,
            @[]
        )
        mutableCopy
    ];
    NSMutableDictionary<NSString *, id> *details =
        [error[@"details"] mutableCopy];
    details[@"expectedValue"] = expectedValue;
    details[@"actualValue"] = actualValue;
    details[@"expectedUTF16Length"] = @(expectedValue.length);
    details[@"actualUTF16Length"] = @(actualValue.length);
    error[@"details"] = details;
    return error;
}

static NSDictionary<NSString *, id> *IOSUseAutomationInput(
    NSDictionary<NSString *, id> *arguments,
    NSDictionary<NSString *, id> **commandError
) {
    NSString *content = arguments[@"content"];
    if (![content isKindOfClass:NSString.class] ||
        [content lengthOfBytesUsingEncoding:NSUTF8StringEncoding] >
            1024 * 1024) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationError(
                @"invalid_arguments",
                @"input content must be a UTF-8 string no larger than 1 MiB",
                @"validation",
                @"validation",
                NO,
                arguments[@"target"],
                @[]
            );
        }
        return nil;
    }
    id deleteValue = arguments[@"deleteCount"];
    if (!IOSUseAutomationIsNumber(deleteValue) ||
        [deleteValue doubleValue] < 0 ||
        [deleteValue doubleValue] > 1024 * 1024 ||
        floor([deleteValue doubleValue]) != [deleteValue doubleValue]) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationError(
                @"invalid_arguments",
                @"input deleteCount must be between 0 and 1048576",
                @"validation",
                @"validation",
                NO,
                arguments[@"target"],
                @[]
            );
        }
        return nil;
    }
    id enterValue = arguments[@"enter"];
    if (![enterValue isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)enterValue) !=
            CFBooleanGetTypeID()) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationError(
                @"invalid_arguments",
                @"input enter must be a boolean",
                @"validation",
                @"validation",
                NO,
                arguments[@"target"],
                @[]
            );
        }
        return nil;
    }
    NSInteger requestedDeleteCount = [deleteValue integerValue];
    BOOL enter = [enterValue boolValue];
    IOSUseAutomationCandidate *candidate = nil;
    BOOL webTarget = NO;
    BOOL webNativeResponderActivated = NO;
    NSDictionary<NSString *, id> *webFocusEvidence = nil;
    UIView *hitView = nil;
    CGPoint point = CGPointZero;
    unsigned long long generation = 0;
    NSDictionary *target = arguments[@"target"];
    NSDictionary<NSString *, id> *snapshotError = nil;
    NSDictionary<NSString *, id> *preDOM =
        IOSUseAutomationFreshDOM(&snapshotError);
    if (preDOM == nil) {
        if (commandError != NULL) {
            *commandError = snapshotError;
        }
        return nil;
    }
    generation =
        [preDOM[@"snapshotGeneration"] unsignedLongLongValue];
    if (target != nil) {
        UIWindow *window = nil;
        candidate = IOSUseAutomationResolveWithDOM(
            target,
            preDOM,
            &point,
            &window,
            &hitView,
            &generation,
            commandError
        );
        if (candidate == nil) {
            return nil;
        }
        webTarget = IOSUsePlayRuntimeIsWebAccessibilityElement(
            candidate.serialized
        );
        if (webTarget) {
            NSString *webFailureCode = nil;
            NSString *webFailureMessage = nil;
            webFocusEvidence =
                IOSUsePlayRuntimePerformWebAccessibilityAction(
                    hitView,
                    candidate.serialized,
                    IOSUsePlayRuntimeWebAccessibilityActionFocusInput,
                    &webFailureCode,
                    &webFailureMessage
                );
            if (webFocusEvidence == nil) {
                if (commandError != NULL) {
                    NSDictionary<NSString *, id> *webCommandError =
                        nil;
                    if ([webFailureCode
                            isEqualToString:@"web_secure_input"]) {
                        webCommandError =
                            IOSUseAutomationUnsupportedInputError(
                                @"secure_text",
                                webFailureMessage ?:
                                    @"secure Web text input is unsupported",
                                target,
                                hitView
                            );
                    } else if ([webFailureCode
                                   isEqualToString:
                                       @"web_custom_input"]) {
                        webCommandError =
                            IOSUseAutomationUnsupportedInputError(
                                @"custom_text_input",
                                webFailureMessage ?:
                                    @"custom Web text controls are unsupported",
                                target,
                                hitView
                            );
                    } else if ([webFailureCode
                                   isEqualToString:
                                       @"web_action_disabled"]) {
                        webCommandError =
                            IOSUseAutomationUnsupportedInputError(
                                @"disabled_text_input",
                                webFailureMessage ?:
                                    @"disabled Web text input is unsupported",
                                target,
                                hitView
                            );
                    } else {
                        webCommandError = IOSUseAutomationError(
                            webFailureCode ?: @"web_bridge_failed",
                            webFailureMessage ?:
                                @"the fixed Web input focus bridge did not report successful delivery",
                            @"interaction",
                            @"first-responder",
                            YES,
                            target,
                            @[]
                        );
                    }
                    *commandError =
                        IOSUseAutomationWebBridgeFailure(
                            webCommandError,
                            webFailureCode
                        );
                }
                return nil;
            }
            IOSUseAutomationPump(0.05);
        } else {
            unsigned long long deliveryBefore =
                PTFakeMetaTouch.deliveryGeneration;
            NSInteger touchID = IOSUseAutomationSendTouch(
                point,
                UITouchPhaseBegan,
                -1,
                window,
                hitView
            );
            IOSUseAutomationPump(0.015);
            IOSUseAutomationSendTouch(
                point,
                UITouchPhaseEnded,
                touchID,
                window,
                hitView
            );
            IOSUseAutomationPump(0.05);
            if (PTFakeMetaTouch.deliveryGeneration <
                deliveryBefore + 2) {
                if (commandError != NULL) {
                    *commandError = IOSUseAutomationError(
                        @"touch_delivery_failed",
                        @"input target tap was not delivered to UIApplication",
                        @"interaction",
                        @"delivery",
                        YES,
                        target,
                        @[]
                    );
                }
                return nil;
            }
        }
    }
    UIResponder *expectedResponder = target == nil
        ? nil
        : IOSUseAutomationKeyInputResponder(candidate, hitView);
    if (target != nil && expectedResponder == nil) {
        if (commandError != NULL) {
            NSDictionary<NSString *, id> *error =
                IOSUseAutomationError(
                    @"input_not_ready",
                    @"the input target does not resolve to a text responder",
                    @"interaction",
                    @"first-responder",
                    YES,
                    target,
                    @[]
                );
            *commandError = webTarget
                ? IOSUseAutomationWebBridgeFailure(
                    error,
                    @"web_responder_not_ready"
                )
                : error;
        }
        return nil;
    }
    UIResponder *firstResponder =
        IOSUseAutomationCurrentFirstResponder();
    if (expectedResponder != nil &&
        !IOSUseAutomationResponderMatches(
            firstResponder,
            expectedResponder
        )) {
        if (webTarget) {
            // The fixed isolated bridge has already revalidated and focused
            // the exact HTML input. Catalyst still requires its public
            // WKContentView UIResponder to enter the native editing session;
            // this is the second half of the same verified focus operation,
            // not a fallback to synthetic touch or an unbound responder.
            if (IOSUseAutomationIsSupportedWebInputResponder(
                    expectedResponder
                )) {
                webNativeResponderActivated =
                    [expectedResponder becomeFirstResponder];
            }
        } else {
            [expectedResponder becomeFirstResponder];
        }
        IOSUseAutomationPump(0.05);
        firstResponder =
            IOSUseAutomationCurrentFirstResponder();
    }
    if (firstResponder == nil ||
        ![firstResponder conformsToProtocol:@protocol(UIKeyInput)] ||
        ![firstResponder respondsToSelector:@selector(insertText:)]) {
        if (commandError != NULL) {
            NSDictionary<NSString *, id> *error =
                IOSUseAutomationError(
                    @"input_not_ready",
                    @"the active target has no live UIKeyInput first responder",
                    @"interaction",
                    @"first-responder",
                    YES,
                    target,
                    @[]
                );
            *commandError = webTarget
                ? IOSUseAutomationWebBridgeFailure(
                    error,
                    @"web_responder_not_ready"
                )
                : error;
        }
        return nil;
    }
    if (expectedResponder != nil &&
        !IOSUseAutomationResponderMatches(
            firstResponder,
            expectedResponder
        )) {
        if (commandError != NULL) {
            NSDictionary<NSString *, id> *error =
                IOSUseAutomationError(
                    @"input_not_ready",
                    @"the input target did not become the live UIKeyInput first responder",
                    @"interaction",
                    @"first-responder",
                    YES,
                    target,
                    @[]
                );
            *commandError = webTarget
                ? IOSUseAutomationWebBridgeFailure(
                    error,
                    @"web_responder_not_ready"
                )
                : error;
        }
        return nil;
    }
    BOOL supportedWebInput =
        IOSUseAutomationIsSupportedWebInputResponder(firstResponder);
    if (![firstResponder isKindOfClass:UITextField.class] &&
        ![firstResponder isKindOfClass:UITextView.class] &&
        !supportedWebInput) {
        if (commandError != NULL) {
            NSString *reason =
                [firstResponder
                    conformsToProtocol:@protocol(UITextInput)]
                    ? @"custom_text_input"
                    : @"custom_key_input";
            NSDictionary<NSString *, id> *error =
                IOSUseAutomationUnsupportedInputError(
                    reason,
                    @"custom UIKeyInput/UITextInput responders are unsupported because exact text semantics cannot be guaranteed",
                    target,
                    firstResponder
                );
            *commandError = webTarget
                ? IOSUseAutomationWebBridgeFailure(
                    error,
                    @"web_exact_wkcontentview_required"
                )
                : error;
        }
        return nil;
    }
    if ([firstResponder isKindOfClass:UITextField.class] &&
        ((UITextField *)firstResponder).secureTextEntry) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationUnsupportedInputError(
                @"secure_text",
                @"secure text input is unsupported",
                target,
                firstResponder
            );
        }
        return nil;
    }
    if (supportedWebInput &&
        [candidate.hint isEqualToString:@"ios-use:secure-web-input"]) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationUnsupportedInputError(
                @"secure_text",
                @"secure text input is unsupported",
                target,
                firstResponder
            );
        }
        return nil;
    }
    id<UITextInput> textInput = (id<UITextInput>)firstResponder;
    if (textInput.markedTextRange != nil) {
        if (commandError != NULL) {
            NSDictionary<NSString *, id> *error =
                IOSUseAutomationUnsupportedInputError(
                    @"marked_text",
                    @"text input with active marked text or IME composition is unsupported",
                    target,
                    firstResponder
                );
            *commandError = webTarget
                ? IOSUseAutomationWebBridgeFailure(
                    error,
                    @"web_ime_unsupported"
                )
                : error;
        }
        return nil;
    }
    if (!firstResponder.isFirstResponder ||
        IOSUseAutomationCurrentFirstResponder() != firstResponder) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationError(
                @"input_not_ready",
                @"the verified text responder lost first responder before input",
                @"interaction",
                @"first-responder",
                YES,
                target,
                @[]
            );
        }
        return nil;
    }
    NSString *webStateFailure = nil;
    NSDictionary<NSString *, id> *webState = supportedWebInput
        ? IOSUsePlayRuntimeWebInputState(
            (UIView *)firstResponder,
            webTarget ? candidate.serialized : nil,
            &webStateFailure
        )
        : nil;
    if (supportedWebInput && [webState[@"secure"] boolValue]) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationWebBridgeFailure(
                IOSUseAutomationUnsupportedInputError(
                    @"secure_text",
                    @"secure text input is unsupported",
                    target,
                    firstResponder
                ),
                @"web_secure_input"
            );
        }
        return nil;
    }
    if (supportedWebInput && [webState[@"disabled"] boolValue]) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationWebBridgeFailure(
                IOSUseAutomationUnsupportedInputError(
                    @"disabled_text_input",
                    @"disabled Web text input is unsupported",
                    target,
                    firstResponder
                ),
                @"web_action_disabled"
            );
        }
        return nil;
    }
    if (supportedWebInput && [webState[@"readOnly"] boolValue]) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationWebBridgeFailure(
                IOSUseAutomationUnsupportedInputError(
                    @"custom_text_input",
                    @"read-only Web text input is unsupported",
                    target,
                    firstResponder
                ),
                @"web_custom_input"
            );
        }
        return nil;
    }
    NSString *beforeValue = supportedWebInput
        ? webState[@"value"]
        : IOSUseAutomationExactTextValue(firstResponder);
    if (beforeValue == nil ||
        (!supportedWebInput &&
         !IOSUseAutomationTextDocumentMatchesValue(
             textInput,
             beforeValue
         ))) {
        if (commandError != NULL) {
            NSDictionary<NSString *, id> *error =
                IOSUseAutomationUnsupportedInputError(
                    @"inconsistent_text_document",
                    webStateFailure ?:
                        @"the text responder does not expose an exact, self-consistent document value",
                    target,
                    firstResponder
                );
            *commandError = webTarget
                ? IOSUseAutomationWebBridgeFailure(
                    error,
                    @"web_input_identity_unverified"
                )
                : error;
        }
        return nil;
    }
    NSInteger appliedDeleteCount = 0;
    NSRange replacementRange = IOSUseAutomationSuffixRange(
        beforeValue,
        requestedDeleteCount,
        &appliedDeleteCount
    );
    NSString *retainedPrefix = [beforeValue
        substringToIndex:replacementRange.location];
    NSString *expectedValue = [retainedPrefix
        stringByAppendingString:content];
    BOOL selectionReady = NO;
    if (supportedWebInput) {
        selectionReady =
            [webState[@"selectionStart"] integerValue] ==
                (NSInteger)beforeValue.length &&
            [webState[@"selectionEnd"] integerValue] ==
                (NSInteger)beforeValue.length;
    } else {
        selectionReady = IOSUseAutomationSelectTextRange(
            textInput,
            replacementRange
        );
    }
    if (!selectionReady) {
        if (commandError != NULL) {
            NSDictionary<NSString *, id> *error =
                IOSUseAutomationUnsupportedInputError(
                    @"unverifiable_selection",
                    supportedWebInput
                        ? @"the active Web input selection is not at the verified document end"
                        : @"the text responder could not select the exact replacement range",
                    target,
                    firstResponder
                );
            *commandError = webTarget
                ? IOSUseAutomationWebBridgeFailure(
                    error,
                    @"web_selection_unverified"
                )
                : error;
        }
        return nil;
    }
    if (!firstResponder.isFirstResponder ||
        IOSUseAutomationCurrentFirstResponder() != firstResponder) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationError(
                @"input_not_ready",
                @"the verified text responder lost first responder before mutation",
                @"interaction",
                @"first-responder",
                YES,
                target,
                @[]
            );
        }
        return nil;
    }
    if (supportedWebInput) {
        for (NSInteger index = 0;
             index < appliedDeleteCount;
             index += 1) {
            [(id<UIKeyInput>)firstResponder deleteBackward];
        }
        if (content.length > 0) {
            [(id<UIKeyInput>)firstResponder insertText:content];
        }
    } else if (content.length > 0) {
        [(id<UIKeyInput>)firstResponder insertText:content];
    } else if (replacementRange.length > 0) {
        [(id<UIKeyInput>)firstResponder deleteBackward];
    }
    IOSUseAutomationPump(0.03);
    if (supportedWebInput) {
        webStateFailure = nil;
        webState = IOSUsePlayRuntimeWebInputState(
            (UIView *)firstResponder,
            webTarget ? candidate.serialized : nil,
            &webStateFailure
        );
    }
    NSString *afterValue = supportedWebInput
        ? webState[@"value"] ?: @""
        : IOSUseAutomationExactTextValue(firstResponder) ?: @"";
    if (![afterValue isEqualToString:expectedValue]) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationInputPostconditionError(
                expectedValue,
                afterValue,
                target
            );
        }
        return nil;
    }
    if (enter) {
        if (!firstResponder.isFirstResponder ||
            IOSUseAutomationCurrentFirstResponder() !=
                firstResponder) {
            if (commandError != NULL) {
                *commandError = IOSUseAutomationError(
                    @"input_not_ready",
                    @"the verified text responder lost first responder before Return",
                    @"interaction",
                    @"first-responder",
                    YES,
                    target,
                    @[]
                );
            }
            return nil;
        }
        BOOL returnSelectionReady = supportedWebInput
            ? [webState[@"selectionStart"] integerValue] ==
                    (NSInteger)expectedValue.length &&
                [webState[@"selectionEnd"] integerValue] ==
                    (NSInteger)expectedValue.length
            : IOSUseAutomationSelectTextRange(
                textInput,
                NSMakeRange(expectedValue.length, 0)
            );
        if (!returnSelectionReady) {
            if (commandError != NULL) {
                *commandError =
                    IOSUseAutomationUnsupportedInputError(
                        @"unverifiable_selection",
                        @"the text responder could not select the exact Return insertion point",
                        target,
                        firstResponder
                    );
            }
            return nil;
        }
        [(id<UIKeyInput>)firstResponder insertText:@"\n"];
        if ([firstResponder isKindOfClass:UITextView.class] ||
            (supportedWebInput &&
             [webState[@"tag"] isEqualToString:@"textarea"])) {
            expectedValue = [expectedValue
                stringByAppendingString:@"\n"];
        }
        IOSUseAutomationPump(0.03);
        if (supportedWebInput) {
            webStateFailure = nil;
            webState = IOSUsePlayRuntimeWebInputState(
                (UIView *)firstResponder,
                webTarget ? candidate.serialized : nil,
                &webStateFailure
            );
        }
        afterValue = supportedWebInput
            ? webState[@"value"] ?: @""
            : IOSUseAutomationExactTextValue(firstResponder) ?: @"";
        if (![afterValue isEqualToString:expectedValue]) {
            if (commandError != NULL) {
                *commandError =
                    IOSUseAutomationInputPostconditionError(
                        expectedValue,
                        afterValue,
                        target
                    );
            }
            return nil;
        }
    }
    if (textInput.markedTextRange != nil) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationInputPostconditionError(
                expectedValue,
                afterValue,
                target
            );
        }
        return nil;
    }
    if (candidate == nil) {
        candidate = [[IOSUseAutomationCandidate alloc] init];
        candidate.object = firstResponder;
        candidate.nodeID = [NSString stringWithFormat:
            @"%llu-%p", generation, firstResponder];
        candidate.label = @"";
        candidate.value = @"";
        candidate.identifier = @"";
        candidate.hint = @"";
        candidate.className = NSStringFromClass(firstResponder.class);
        candidate.frame = [firstResponder isKindOfClass:UIView.class]
            ? [(UIView *)firstResponder
                convertRect:((UIView *)firstResponder).bounds
                     toView:nil]
            : CGRectZero;
        candidate.path = @"first-responder";
        candidate.generation = generation;
        hitView = [firstResponder isKindOfClass:UIView.class]
            ? (UIView *)firstResponder
            : IOSUseAutomationWindows().firstObject;
        point = CGPointMake(
            CGRectGetMidX(candidate.frame),
            CGRectGetMidY(candidate.frame)
        );
    }
    return IOSUseAutomationActionResult(
        candidate,
        target,
        preDOM,
        nil,
        CGRectNull,
        NO,
        hitView,
        point,
        -1,
        @"inserted",
        NSStringFromClass(firstResponder.class),
        @{
            @"contentLength": @(content.length),
            @"requestedDeleteCount": @(requestedDeleteCount),
            @"appliedDeleteCount": @(appliedDeleteCount),
            @"enter": @(enter),
            @"editMode": requestedDeleteCount > 0
                ? @"replace"
                : @"append",
            @"beforeValue": beforeValue,
            @"value": afterValue,
            @"exactValueVerified": @YES,
                @"actionEvidence": @{
                @"backend": supportedWebInput
                    ? @"wkcontentview-ui-key-input"
                    : @"uikit-ui-key-input",
                @"focusBackend": webFocusEvidence == nil
                    ? @"existing-or-native-first-responder"
                    : webFocusEvidence[@"backend"],
                @"webFocus": webFocusEvidence ?:
                    (id)NSNull.null,
                @"nativeResponderBackend": supportedWebInput
                    ? @"WKContentView.becomeFirstResponder-after-validated-web-focus"
                    : @"UIKit responder focus",
                @"nativeResponderActivated":
                    @(webNativeResponderActivated),
                @"deletePath": supportedWebInput
                    ? @"WKContentView.deleteBackward"
                    : @"UITextInput.selection-delete",
                @"insertPath": supportedWebInput
                    ? @"WKContentView.insertText"
                    : @"UIKeyInput.insertText",
            },
        },
        commandError
    );
}

static UIViewController *IOSUseAutomationPresentedController(void) {
    for (UIWindow *window in IOSUseAutomationWindows()) {
        UIViewController *controller = window.rootViewController;
        while (controller.presentedViewController != nil) {
            controller = controller.presentedViewController;
        }
        if (controller != nil) {
            return controller;
        }
    }
    return nil;
}

static void IOSUseAutomationCollectControls(
    UIView *view,
    NSMutableArray<UIControl *> *controls
) {
    if ([view isKindOfClass:UIControl.class] &&
        !view.hidden &&
        view.alpha > 0) {
        [controls addObject:(UIControl *)view];
    }
    for (UIView *child in view.subviews) {
        IOSUseAutomationCollectControls(child, controls);
    }
}

static NSDictionary<NSString *, id> *IOSUseAutomationDismissAlert(
    NSDictionary<NSString *, id> *arguments,
    NSDictionary<NSString *, id> **commandError
) {
    NSArray<NSDictionary<NSString *, id> *> *nativeActions =
        [IOSUsePlayAppKitBridge nativeAlertActions];
    if (nativeActions.count > 0) {
        NSString *nativeAlertText =
            [IOSUsePlayAppKitBridge nativeAlertText];
        NSInteger nativeIndex = arguments[@"index"] == nil
            ? (NSInteger)nativeActions.count - 1
            : [arguments[@"index"] integerValue];
        if (arguments[@"index"] != nil &&
            (!IOSUseAutomationIsNumber(arguments[@"index"]) ||
             nativeIndex < 0 ||
             nativeIndex >= (NSInteger)nativeActions.count)) {
            if (commandError != NULL) {
                *commandError = IOSUseAutomationError(
                    @"invalid_arguments",
                    @"dismissAlert index is outside the visible native action list",
                    @"validation",
                    @"validation",
                    NO,
                    nil,
                    @[]
                );
            }
            return nil;
        }
        NSDictionary<NSString *, id> *snapshotError = nil;
        NSDictionary<NSString *, id> *preDOM =
            IOSUseAutomationFreshDOM(&snapshotError);
        if (preDOM == nil) {
            if (commandError != NULL) {
                *commandError = snapshotError;
            }
            return nil;
        }
        NSDictionary<NSString *, id> *nativeAction =
            nativeActions[(NSUInteger)nativeIndex];
        NSError *nativeError = nil;
        NSDictionary<NSString *, id> *nativeDelivery =
            [IOSUsePlayAppKitBridge
                performNativeAlertActionWithLabel:
                    nativeAction[@"label"]
                error:&nativeError];
        if (nativeDelivery == nil) {
            if (commandError != NULL) {
                *commandError = IOSUseAutomationError(
                    @"alert_not_dismissed",
                    nativeError.localizedDescription ?:
                        @"native alert action was not delivered",
                    @"interaction",
                    @"delivery",
                    YES,
                    nil,
                    @[]
                );
            }
            return nil;
        }
        CGRect actionFrame =
            IOSUseAutomationFrameDictionaryRect(
                nativeAction[@"frame"]
            );
        CGPoint actionPoint = CGPointMake(
            CGRectGetMidX(actionFrame),
            CGRectGetMidY(actionFrame)
        );
        IOSUseAutomationDeferredFinalize finalize =
            ^NSDictionary<NSString *, id> *(
                NSDictionary<NSString *, id> **deferredError
            ) {
                if ([IOSUsePlayAppKitBridge hasVisibleNativeAlert]) {
                    if (deferredError != NULL) {
                        *deferredError = IOSUseAutomationError(
                            @"alert_not_dismissed",
                            @"native alert target/action did not close the panel",
                            @"interaction",
                            @"postcondition",
                            YES,
                            nil,
                            @[]
                        );
                    }
                    return nil;
                }
                NSDictionary<NSString *, id> *postDOM =
                    IOSUseAutomationFreshDOM(deferredError);
                if (postDOM == nil ||
                    IOSUseAutomationDOMHasVisibleUIKitAlertMirror(
                        postDOM
                    )) {
                    if (deferredError != NULL &&
                        *deferredError == nil) {
                        *deferredError = IOSUseAutomationError(
                            @"alert_not_dismissed",
                            @"native alert UIKit mirror did not settle",
                            @"interaction",
                            @"postcondition",
                            YES,
                            nil,
                            @[]
                        );
                    }
                    return nil;
                }
                NSDictionary<NSString *, id> *stateEvidence =
                    IOSUseAutomationStateEvidence(
                        preDOM,
                        postDOM,
                        nil,
                        nil
                    );
                return @{
                    @"dismissed": @YES,
                    @"text": nativeAlertText,
                    @"button": nativeAction[@"label"],
                    @"reason": arguments[@"index"] == nil
                        ? @"default"
                        : @"index",
                    @"nativeAlertDelivery": nativeDelivery,
                    @"finalState": @{
                        @"point": @{
                            @"x": @(actionPoint.x),
                            @"y": @(actionPoint.y),
                        },
                        @"touchID": @(-1),
                        @"phase": @"native-ended",
                    },
                    @"postcondition": @{
                        @"snapshotGeneration":
                            postDOM[@"snapshotGeneration"],
                        @"changed": @((BOOL)(
                            [stateEvidence[@"changedElementCount"]
                                unsignedIntegerValue] > 0
                        )),
                        @"stateEvidence": stateEvidence,
                    },
                };
            };
        return @{
            IOSUseAutomationDeferredFinalizeKey:
                [finalize copy],
        };
    }
    UIViewController *controller =
        IOSUseAutomationPresentedController();
    if (![controller isKindOfClass:UIAlertController.class]) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationError(
                @"alert_not_found",
                @"no foreground UIAlertController is presented",
                @"lookup",
                @"lookup",
                YES,
                nil,
                @[]
            );
        }
        return nil;
    }
    UIAlertController *alert = (UIAlertController *)controller;
    if (alert.actions.count == 0) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationError(
                @"alert_action_unavailable",
                @"visible alert has no actions",
                @"interaction",
                @"lookup",
                NO,
                nil,
                @[]
            );
        }
        return nil;
    }
    NSInteger index = arguments[@"index"] == nil
        ? NSNotFound
        : [arguments[@"index"] integerValue];
    if (arguments[@"index"] != nil &&
        (!IOSUseAutomationIsNumber(arguments[@"index"]) ||
         index < 0 ||
         index >= (NSInteger)alert.actions.count)) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationError(
                @"invalid_arguments",
                @"dismissAlert index is outside the visible action list",
                @"validation",
                @"validation",
                NO,
                nil,
                @[]
            );
        }
        return nil;
    }
    if (index == NSNotFound) {
        index = (NSInteger)alert.actions.count - 1;
    }
    UIAlertAction *action = alert.actions[(NSUInteger)index];
    NSMutableArray<UIControl *> *controls = [NSMutableArray array];
    IOSUseAutomationCollectControls(alert.view, controls);
    UIControl *selectedControl = nil;
    for (UIControl *control in controls) {
        if ([control.accessibilityLabel isEqualToString:action.title]) {
            selectedControl = control;
            break;
        }
    }
    if (selectedControl == nil) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationError(
                @"alert_action_unavailable",
                @"visible alert action has no live UIControl",
                @"interaction",
                @"hit-test",
                YES,
                nil,
                @[]
            );
        }
        return nil;
    }
    UIWindow *window = alert.view.window;
    CGRect controlFrame =
        [selectedControl convertRect:selectedControl.bounds toView:nil];
    CGPoint screenPoint = CGPointMake(
        CGRectGetMidX(controlFrame),
        CGRectGetMidY(controlFrame)
    );
    CGPoint point = [window convertPoint:screenPoint fromWindow:nil];
    UIView *hitView = [window hitTest:point withEvent:nil];
    if (window == nil || hitView == nil) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationError(
                @"alert_action_unavailable",
                @"visible alert action failed live hit testing",
                @"interaction",
                @"hit-test",
                YES,
                nil,
                @[]
            );
        }
        return nil;
    }
    NSDictionary<NSString *, id> *snapshotError = nil;
    NSDictionary<NSString *, id> *preDOM =
        IOSUseAutomationFreshDOM(&snapshotError);
    if (preDOM == nil) {
        if (commandError != NULL) {
            *commandError = snapshotError;
        }
        return nil;
    }
    unsigned long long deliveryBefore =
        PTFakeMetaTouch.deliveryGeneration;
    NSInteger touchID = IOSUseAutomationSendTouch(
        point,
        UITouchPhaseBegan,
        -1,
        window,
        hitView
    );
    IOSUseAutomationPump(0.015);
    IOSUseAutomationSendTouch(
        point,
        UITouchPhaseEnded,
        touchID,
        window,
        hitView
    );
    IOSUseAutomationPump(0.35);
    if (PTFakeMetaTouch.deliveryGeneration <
        deliveryBefore + 2 ||
        alert.presentingViewController != nil ||
        IOSUseAutomationPresentedController() == alert) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationError(
                @"alert_not_dismissed",
                @"alert action was delivered but the alert remained visible",
                @"interaction",
                @"postcondition",
                YES,
                nil,
                @[]
            );
        }
        return nil;
    }
    NSDictionary<NSString *, id> *postDOM =
        IOSUseAutomationFreshDOM(&snapshotError);
    if (postDOM == nil) {
        if (commandError != NULL) {
            *commandError = snapshotError;
        }
        return nil;
    }
    NSDictionary<NSString *, id> *stateEvidence =
        IOSUseAutomationStateEvidence(
            preDOM,
            postDOM,
            nil,
            nil
        );
    return @{
        @"dismissed": @YES,
        @"text": alert.message ?: alert.title ?: @"",
        @"button": action.title ?: @"",
        @"reason": arguments[@"index"] == nil
            ? @"default"
            : @"index",
        @"hitView": IOSUseAutomationHitViewJSON(hitView),
        @"finalState": @{
            @"point": @{
                @"x": @(point.x),
                @"y": @(point.y),
            },
            @"touchID": @(touchID),
            @"phase": @"ended",
        },
        @"postcondition": @{
            @"snapshotGeneration":
                postDOM[@"snapshotGeneration"],
            @"changed": @((BOOL)(
                [stateEvidence[@"changedElementCount"]
                    unsignedIntegerValue] > 0
            )),
            @"stateEvidence": stateEvidence,
        },
    };
}

static NSDictionary<NSString *, id> *IOSUseAutomationOpen(
    NSDictionary<NSString *, id> *arguments,
    NSDictionary<NSString *, id> **commandError
) {
    NSString *urlString = arguments[@"url"];
    NSURL *url = [urlString isKindOfClass:NSString.class]
        ? [NSURL URLWithString:urlString]
        : nil;
    if (url == nil || url.scheme.length == 0) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationError(
                @"invalid_arguments",
                @"open url must be an absolute URL",
                @"validation",
                @"validation",
                NO,
                nil,
                @[]
            );
        }
        return nil;
    }
    NSMutableSet<NSString *> *ownSchemes = [NSMutableSet set];
    for (NSDictionary *type in
         NSBundle.mainBundle.infoDictionary[@"CFBundleURLTypes"]) {
        for (NSString *scheme in type[@"CFBundleURLSchemes"]) {
            if ([scheme isKindOfClass:NSString.class]) {
                [ownSchemes addObject:scheme.lowercaseString];
            }
        }
    }
    if (![ownSchemes containsObject:url.scheme.lowercaseString]) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationError(
                @"open_target_mismatch",
                @"Runtime open only delivers URLs registered by the active target",
                @"validation",
                @"delivery",
                NO,
                nil,
                @[]
            );
        }
        return nil;
    }
    NSDictionary<NSString *, id> *snapshotError = nil;
    NSDictionary<NSString *, id> *preDOM =
        IOSUseAutomationFreshDOM(&snapshotError);
    if (preDOM == nil) {
        if (commandError != NULL) {
            *commandError = snapshotError;
        }
        return nil;
    }
    UIApplication *application =
        UIApplication.sharedApplication;
    id delegate = application.delegate;
    SEL modernSelector =
        @selector(application:openURL:options:);
    SEL legacySelector = NSSelectorFromString(
        @"application:openURL:sourceApplication:annotation:"
    );
    BOOL delivered = NO;
    NSString *deliveryBackend = @"";
    if ([delegate respondsToSelector:modernSelector]) {
        delivered =
            ((IOSUseAutomationOpenURLModern)objc_msgSend)(
                delegate,
                modernSelector,
                application,
                url,
                @{}
            );
        deliveryBackend =
            @"active-application-delegate-openURL-options";
    } else if ([delegate respondsToSelector:legacySelector]) {
        delivered =
            ((IOSUseAutomationOpenURLLegacy)objc_msgSend)(
                delegate,
                legacySelector,
                application,
                url,
                nil,
                nil
            );
        deliveryBackend =
            @"active-application-delegate-openURL-legacy";
    } else {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationError(
                @"open_unsupported",
                @"active target exposes no in-process application URL handler",
                @"interaction",
                @"delivery",
                NO,
                nil,
                @[]
            );
        }
        return nil;
    }
    if (!delivered) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationError(
                @"open_rejected",
                @"active target rejected the URL",
                @"interaction",
                @"delivery",
                NO,
                nil,
                @[]
            );
        }
        return nil;
    }
    IOSUseAutomationPump(0.05);
    NSDictionary<NSString *, id> *postDOM =
        IOSUseAutomationFreshDOM(&snapshotError);
    if (postDOM == nil) {
        if (commandError != NULL) {
            *commandError = snapshotError;
        }
        return nil;
    }
    NSDictionary<NSString *, id> *stateEvidence =
        IOSUseAutomationStateEvidence(
            preDOM,
            postDOM,
            nil,
            nil
        );
    return @{
        @"delivered": @YES,
        @"url": url.absoluteString,
        @"deliveryBackend": deliveryBackend,
        @"postcondition": @{
            @"snapshotGeneration":
                postDOM[@"snapshotGeneration"],
            @"changed": @((BOOL)(
                [stateEvidence[@"changedElementCount"]
                    unsignedIntegerValue] > 0
            )),
            @"stateEvidence": stateEvidence,
        },
    };
}

NSDictionary<NSString *, id> *IOSUsePlayRuntimeAutomationCommand(
    NSString *command,
    NSDictionary<NSString *, id> *arguments,
    NSDictionary<NSString *, id> **commandError
) {
    if (![command isKindOfClass:NSString.class] ||
        ![arguments isKindOfClass:NSDictionary.class]) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationError(
                @"invalid_arguments",
                @"automation command requires an arguments object",
                @"validation",
                @"validation",
                NO,
                nil,
                @[]
            );
        }
        return nil;
    }
    __block NSDictionary<NSString *, id> *result;
    __block NSDictionary<NSString *, id> *blockError;
    void (^work)(void) = ^{
        @try {
            if ([command isEqualToString:@"tap"] ||
                [command isEqualToString:@"longPress"] ||
                [command isEqualToString:@"swipe"]) {
                result = IOSUseAutomationTouchCommand(
                    command,
                    arguments,
                    &blockError
                );
            } else if ([command isEqualToString:@"input"]) {
                result = IOSUseAutomationInput(arguments, &blockError);
            } else if ([command isEqualToString:@"dismissAlert"]) {
                result = IOSUseAutomationDismissAlert(
                    arguments,
                    &blockError
                );
            } else if ([command isEqualToString:@"open"]) {
                result = IOSUseAutomationOpen(arguments, &blockError);
            } else {
                blockError = IOSUseAutomationError(
                    @"unsupported_command",
                    @"unsupported Runtime automation command",
                    @"protocol",
                    @"dispatch",
                    NO,
                    nil,
                    @[]
                );
            }
        } @catch (NSException *exception) {
            blockError = IOSUseAutomationError(
                @"automation_exception",
                [NSString stringWithFormat:
                    @"automation raised %@",
                    exception.name],
                @"internal",
                @"dispatch",
                NO,
                nil,
                @[]
            );
        }
    };
    BOOL calledOnMainThread = NSThread.isMainThread;
    if (calledOnMainThread) {
        work();
    } else {
        dispatch_semaphore_t completion = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_main_queue(), ^{
            work();
            dispatch_semaphore_signal(completion);
        });
        dispatch_time_t deadline = dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)(IOSUseAutomationMainTimeout * NSEC_PER_SEC)
        );
        if (dispatch_semaphore_wait(completion, deadline) != 0) {
            blockError = IOSUseAutomationError(
                @"main_thread_timeout",
                @"automation exceeded its main-thread deadline",
                @"timeout",
                @"dispatch",
                YES,
                nil,
                @[]
            );
        }
    }
    IOSUseAutomationDeferredFinalize deferred =
        result[IOSUseAutomationDeferredFinalizeKey];
    if (deferred != nil) {
        result = nil;
        if (calledOnMainThread) {
            blockError = IOSUseAutomationError(
                @"deferred_postcondition_unavailable",
                @"native alert postcondition requires the Runtime socket worker",
                @"internal",
                @"postcondition",
                NO,
                nil,
                @[]
            );
        } else {
            dispatch_semaphore_t completion =
                dispatch_semaphore_create(0);
            dispatch_after(
                dispatch_time(
                    DISPATCH_TIME_NOW,
                    (int64_t)(0.5 * NSEC_PER_SEC)
                ),
                dispatch_get_main_queue(),
                ^{
                    @try {
                        result = deferred(&blockError);
                    } @catch (NSException *exception) {
                        blockError = IOSUseAutomationError(
                            @"automation_exception",
                            [NSString stringWithFormat:
                                @"deferred automation raised %@",
                                exception.name],
                            @"internal",
                            @"postcondition",
                            NO,
                            nil,
                            @[]
                        );
                    }
                    dispatch_semaphore_signal(completion);
                }
            );
            dispatch_time_t deadline = dispatch_time(
                DISPATCH_TIME_NOW,
                (int64_t)(
                    IOSUseAutomationMainTimeout *
                    NSEC_PER_SEC
                )
            );
            if (dispatch_semaphore_wait(
                    completion,
                    deadline
                ) != 0) {
                blockError = IOSUseAutomationError(
                    @"main_thread_timeout",
                    @"deferred automation postcondition exceeded its main-thread deadline",
                    @"timeout",
                    @"postcondition",
                    YES,
                    nil,
                    @[]
                );
            }
        }
    }
    if (result == nil && commandError != NULL) {
        *commandError = blockError ?: IOSUseAutomationError(
            @"automation_failed",
            @"automation did not produce a result",
            @"internal",
            @"dispatch",
            NO,
            nil,
            @[]
        );
    }
    return result;
}
