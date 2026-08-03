#import "IOSUsePlayRuntimeAutomation.h"
#import "IOSUsePlayAppKitBridge.h"
#import "IOSUsePlayRuntimeDOM.h"
#import "IOSUsePlayRuntimeSocket.h"
#import "IOSUsePlayDevice.h"
#import "IOSUsePlaySwiftBridge.h"
#import "PTFakeMetaTouch.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <math.h>
#import <stdint.h>

static const NSTimeInterval IOSUseAutomationMainTimeout = 40.0;

NSTimeInterval IOSUsePlayRuntimeAutomationMainThreadTimeout(void) {
    return IOSUseAutomationMainTimeout;
}

typedef BOOL (*IOSUseAutomationSendBool)(id, SEL);
typedef unsigned long long (*IOSUseAutomationSendTraits)(id, SEL);
typedef CGPoint (*IOSUseAutomationSendPoint)(id, SEL);
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
@property(nonatomic, strong, nullable) UIView *interactionView;
@property(nonatomic, copy, nullable) NSString *nativeAlertActionLabel;
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
static BOOL IOSUseAutomationDOMHasVisibleUIKitAlertMirror(
    NSDictionary<NSString *, id> *dom
);
static BOOL IOSUseAutomationRectHasArea(CGRect rect);
static NSArray<NSDictionary<NSString *, id> *> *
IOSUseAutomationUIKitAlertCandidates(
    UIAlertController *alert
);

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

static NSDictionary<NSString *, id> *
IOSUseAutomationErrorWithCandidateCount(
    NSString *code,
    NSString *message,
    NSString *category,
    NSString *phase,
    BOOL retryable,
    NSDictionary<NSString *, id> * _Nullable target,
    NSArray<NSDictionary<NSString *, id> *> *candidates,
    NSUInteger candidateCount
) {
    NSMutableDictionary<NSString *, id> *details = [@{
        @"category": category,
        @"phase": phase,
        @"retryable": @(retryable),
        @"fatal": @NO,
        @"candidateCount": @(candidateCount),
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

static NSDictionary<NSString *, id> *IOSUseAutomationError(
    NSString *code,
    NSString *message,
    NSString *category,
    NSString *phase,
    BOOL retryable,
    NSDictionary<NSString *, id> * _Nullable target,
    NSArray<NSDictionary<NSString *, id> *> *candidates
) {
    return IOSUseAutomationErrorWithCandidateCount(
        code,
        message,
        category,
        phase,
        retryable,
        target,
        candidates,
        candidates.count
    );
}

static NSDictionary<NSString *, id> *
IOSUseAutomationPostconditionError(
    NSDictionary<NSString *, id> *error
) {
    if (error == nil) {
        return IOSUseAutomationError(
            @"postcondition_failed",
            @"automation delivery completed without a verifiable postcondition",
            @"postcondition",
            @"postcondition",
            YES,
            nil,
            @[]
        );
    }
    NSMutableDictionary<NSString *, id> *normalized =
        [error mutableCopy];
    NSMutableDictionary<NSString *, id> *details =
        [error[@"details"] mutableCopy];
    if (details == nil) {
        details = [NSMutableDictionary dictionary];
    }
    details[@"category"] = @"postcondition";
    details[@"phase"] = @"postcondition";
    normalized[@"details"] = details;
    return normalized;
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
        NSArray<UIWindow *> *originalWindows = scene.windows;
        NSArray<UIWindow *> *sceneWindows =
            [originalWindows sortedArrayUsingComparator:
                ^NSComparisonResult(UIWindow *left, UIWindow *right) {
                    if (left.windowLevel > right.windowLevel) {
                        return NSOrderedAscending;
                    }
                    if (left.windowLevel < right.windowLevel) {
                        return NSOrderedDescending;
                    }
                    NSUInteger leftIndex =
                        [originalWindows
                            indexOfObjectIdenticalTo:left];
                    NSUInteger rightIndex =
                        [originalWindows
                            indexOfObjectIdenticalTo:right];
                    if (leftIndex > rightIndex) {
                        return NSOrderedAscending;
                    }
                    if (leftIndex < rightIndex) {
                        return NSOrderedDescending;
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

static
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

static
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
    BOOL deferSemanticTapPlacement,
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
        if (deferSemanticTapPlacement) {
            id liveObject = nil;
            UIView *interactionView = nil;
            NSString *nativeAlertActionLabel = nil;
            if (!IOSUsePlayRuntimeDOMResolveLiveIdentity(
                    selected.serialized,
                    &liveObject,
                    &interactionView,
                    &nativeAlertActionLabel
                )) {
                if (commandError != NULL) {
                    *commandError = IOSUseAutomationError(
                        @"element_stale",
                        @"fresh semantic target has no current live identity",
                        @"interaction",
                        @"identity",
                        YES,
                        target,
                        @[]
                    );
                }
                return nil;
            }
            selected.object = liveObject;
            selected.interactionView = interactionView;
            selected.nativeAlertActionLabel =
                nativeAlertActionLabel;
        }
    }
    BOOL placementDeferred =
        deferSemanticTapPlacement && explicitPoint == nil;
    if (!placementDeferred &&
        !IOSUseAutomationFinitePoint(resolvedPoint)) {
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
    if (placementDeferred) {
        if (point != NULL) {
            *point = resolvedPoint;
        }
        return selected;
    }
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

static BOOL IOSUseAutomationFramesMatchWithinTolerance(
    CGRect left,
    CGRect right
) {
    const CGFloat tolerance = 0.5;
    return !CGRectIsNull(left) &&
        !CGRectIsNull(right) &&
        fabs(left.origin.x - right.origin.x) <= tolerance &&
        fabs(left.origin.y - right.origin.y) <= tolerance &&
        fabs(left.size.width - right.size.width) <= tolerance &&
        fabs(left.size.height - right.size.height) <= tolerance;
}

static NSDictionary<NSString *, id> * _Nullable
IOSUseAutomationExactNativeAlertAction(
    NSString *label,
    CGRect frame
) {
    if (label.length == 0 ||
        ![IOSUsePlayAppKitBridge hasVisibleNativeAlert]) {
        return nil;
    }
    NSDictionary<NSString *, id> *matched = nil;
    for (NSDictionary<NSString *, id> *action in
         [IOSUsePlayAppKitBridge nativeAlertActions]) {
        CGRect actionFrame =
            IOSUseAutomationFrameDictionaryRect(action[@"frame"]);
        if (![action[@"label"] isEqualToString:label] ||
            !IOSUseAutomationFramesMatchWithinTolerance(
                actionFrame,
                frame
            )) {
            continue;
        }
        if (matched != nil) {
            return nil;
        }
        matched = action;
    }
    return matched;
}

static NSDictionary<NSString *, id> * _Nullable
IOSUseAutomationNativeAlertActionAtPoint(CGPoint point) {
    if (![IOSUsePlayAppKitBridge hasVisibleNativeAlert]) {
        return nil;
    }
    NSDictionary<NSString *, id> *matched = nil;
    for (NSDictionary<NSString *, id> *action in
         [IOSUsePlayAppKitBridge nativeAlertActions]) {
        CGRect frame =
            IOSUseAutomationFrameDictionaryRect(action[@"frame"]);
        CGRect unambiguousFrame = CGRectInset(frame, 0.5, 0.5);
        if (CGRectIsNull(frame) ||
            unambiguousFrame.size.width <= 0 ||
            unambiguousFrame.size.height <= 0 ||
            !CGRectContainsPoint(unambiguousFrame, point)) {
            continue;
        }
        if (matched != nil) {
            return nil;
        }
        matched = action;
    }
    return matched;
}

static BOOL IOSUseAutomationRectHasArea(CGRect rect) {
    return !CGRectIsNull(rect) &&
        !CGRectIsInfinite(rect) &&
        isfinite(rect.origin.x) &&
        isfinite(rect.origin.y) &&
        isfinite(rect.size.width) &&
        isfinite(rect.size.height) &&
        rect.size.width > 0 &&
        rect.size.height > 0;
}

static CGPoint IOSUseAutomationActivationPoint(id object) {
    SEL selector = @selector(accessibilityActivationPoint);
    if (object == nil || ![object respondsToSelector:selector]) {
        return CGPointMake(NAN, NAN);
    }
    @try {
        return ((IOSUseAutomationSendPoint)objc_msgSend)(
            object,
            selector
        );
    } @catch (__unused NSException *exception) {
        return CGPointMake(NAN, NAN);
    }
}

static void IOSUseAutomationAppendUniquePoint(
    NSMutableArray<NSValue *> *points,
    CGPoint point
) {
    if (!IOSUseAutomationFinitePoint(point)) {
        return;
    }
    for (NSValue *value in points) {
        CGPoint existing = value.CGPointValue;
        if (fabs(existing.x - point.x) < 0.001 &&
            fabs(existing.y - point.y) < 0.001) {
            return;
        }
    }
    [points addObject:[NSValue valueWithCGPoint:point]];
}

static BOOL IOSUseAutomationHitMatchesInteractionOwner(
    UIWindow *hitWindow,
    UIView *hitView,
    UIView *interactionView
) {
    if (hitWindow == nil ||
        hitView == nil ||
        interactionView == nil ||
        [interactionView isKindOfClass:UIWindow.class] ||
        interactionView.window == nil ||
        hitWindow != interactionView.window) {
        return NO;
    }
    return hitView == interactionView ||
        [hitView isDescendantOfView:interactionView];
}

static CGRect IOSUseAutomationElementFrame(
    NSDictionary<NSString *, id> *element
) {
    return IOSUseAutomationFrameDictionaryRect(element[@"frame"]);
}

static BOOL IOSUseAutomationElementIsActionable(
    NSDictionary<NSString *, id> *element
) {
    switch ([element[@"elementType"] integerValue]) {
        case 9:  // Button
        case 20: // Key
        case 33: // Slider
        case 37: // SegmentedControl
        case 38: // Picker
        case 39: // PickerWheel
        case 40: // Switch
        case 41: // Toggle
        case 42: // Link
        case 45: // Input
        case 49: // Input
        case 50: // SecureInput
        case 51: // DatePicker
        case 52: // TextView
        case 75: // Cell
            return YES;
        default:
            return NO;
    }
}

static BOOL IOSUseAutomationViewsShareInteractionDomain(
    UIView *left,
    UIView *right
) {
    if (left == nil ||
        right == nil ||
        left.window == nil ||
        right.window == nil ||
        left.window != right.window) {
        return NO;
    }
    return left == right ||
        [left isDescendantOfView:right] ||
        [right isDescendantOfView:left];
}

static BOOL IOSUseAutomationSemanticPointIsUnambiguous(
    NSDictionary<NSString *, id> *dom,
    IOSUseAutomationCandidate *candidate,
    CGPoint requestedPoint
) {
    if (![dom isKindOfClass:NSDictionary.class] ||
        ![dom[@"elements"] isKindOfClass:NSArray.class] ||
        [dom[@"snapshotGeneration"] unsignedLongLongValue] !=
            candidate.generation) {
        return NO;
    }
    CGRect unambiguousTargetFrame =
        CGRectInset(candidate.frame, 0.5, 0.5);
    if (unambiguousTargetFrame.size.width <= 0 ||
        unambiguousTargetFrame.size.height <= 0 ||
        !CGRectContainsPoint(
            unambiguousTargetFrame,
            requestedPoint
        )) {
        return NO;
    }
    if (IOSUsePlayRuntimeIsWebAccessibilityElement(
            candidate.serialized
        ) ||
        candidate.nativeAlertActionLabel.length > 0) {
        return YES;
    }
    for (NSDictionary<NSString *, id> *element in dom[@"elements"]) {
        if (![element isKindOfClass:NSDictionary.class] ||
            [element[@"nodeID"]
                isEqualToString:candidate.nodeID] ||
            [element[@"snapshotGeneration"]
                unsignedLongLongValue] != candidate.generation ||
            ![element[@"state"][@"visible"] boolValue] ||
            !IOSUseAutomationElementIsActionable(element)) {
            continue;
        }
        CGRect otherFrame = IOSUseAutomationElementFrame(element);
        if (CGRectIsNull(otherFrame) ||
            !CGRectContainsPoint(otherFrame, requestedPoint)) {
            continue;
        }
        id otherObject = nil;
        UIView *otherInteractionView = nil;
        NSString *otherNativeActionLabel = nil;
        if (!IOSUsePlayRuntimeDOMResolveLiveIdentity(
                element,
                &otherObject,
                &otherInteractionView,
                &otherNativeActionLabel
            )) {
            return NO;
        }
        (void)otherObject;
        if (otherNativeActionLabel.length > 0) {
            return NO;
        }
        if (otherInteractionView == nil) {
            return NO;
        }
        if (IOSUseAutomationViewsShareInteractionDomain(
                candidate.interactionView,
                otherInteractionView
            )) {
            return NO;
        }
    }
    return YES;
}

static BOOL IOSUseAutomationTapTargetPreflight(
    NSDictionary<NSString *, id> *arguments,
    NSDictionary<NSString *, id> *target,
    IOSUseAutomationCandidate *candidate,
    NSDictionary<NSString *, id> **commandError
) {
    if (target[@"point"] != nil) {
        return YES;
    }
    if ([candidate.serialized[@"state"]
            isKindOfClass:NSDictionary.class] &&
        [candidate.serialized[@"state"][@"enabled"]
            isKindOfClass:NSNumber.class] &&
        ![candidate.serialized[@"state"][@"enabled"] boolValue]) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationError(
                @"element_not_hittable",
                @"fresh semantic target is disabled",
                @"interaction",
                @"identity",
                NO,
                target,
                @[]
            );
        }
        return NO;
    }
    if (!IOSUseAutomationRectHasArea(candidate.frame)) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationError(
                @"element_not_hittable",
                @"fresh semantic target has no finite live frame",
                @"interaction",
                @"hit-test",
                YES,
                target,
                @[]
            );
        }
        return NO;
    }
    NSDictionary *offset = arguments[@"offset"];
    if (offset != nil &&
        (![offset isKindOfClass:NSDictionary.class] ||
         !IOSUseAutomationIsNumber(offset[@"x"]) ||
         !IOSUseAutomationIsNumber(offset[@"y"]) ||
         !isfinite([offset[@"x"] doubleValue]) ||
         !isfinite([offset[@"y"] doubleValue]))) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationError(
                @"invalid_arguments",
                @"tap offset must contain finite numeric x and y",
                @"validation",
                @"validation",
                NO,
                target,
                @[]
            );
        }
        return NO;
    }
    NSDictionary *ratio = arguments[@"ratio"];
    if (offset == nil &&
        ratio != nil &&
        (![ratio isKindOfClass:NSDictionary.class] ||
         !IOSUseAutomationIsNumber(ratio[@"x"]) ||
         !IOSUseAutomationIsNumber(ratio[@"y"]) ||
         !isfinite([ratio[@"x"] doubleValue]) ||
         !isfinite([ratio[@"y"] doubleValue]))) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationError(
                @"invalid_arguments",
                @"tap ratio must contain finite numeric x and y",
                @"validation",
                @"validation",
                NO,
                target,
                @[]
            );
        }
        return NO;
    }
    return YES;
}

static BOOL IOSUseAutomationPlaceTap(
    NSDictionary<NSString *, id> *arguments,
    NSDictionary<NSString *, id> *target,
    IOSUseAutomationCandidate *candidate,
    NSDictionary<NSString *, id> *dom,
    CGPoint *point,
    UIWindow **window,
    UIView **hitView,
    NSDictionary<NSString *, id> **commandError
) {
    BOOL nativeAlertCandidateVisible =
        [IOSUsePlayAppKitBridge
            hasVisibleNativeAlertCandidate];
    BOOL exactNativeAlertVisible =
        [IOSUsePlayAppKitBridge hasVisibleNativeAlert];
    if ((nativeAlertCandidateVisible ||
         IOSUseAutomationDOMHasVisibleUIKitAlertMirror(dom)) &&
        !exactNativeAlertVisible) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationError(
                @"element_not_hittable",
                @"the visible native alert mirror could not be bound to one exact AppKit panel and action geometry",
                @"interaction",
                @"identity",
                YES,
                target,
                @[]
            );
        }
        return NO;
    }
    NSDictionary *explicitPoint = target[@"point"];
    if (explicitPoint != nil) {
        CGPoint requested = CGPointMake(
            [explicitPoint[@"x"] doubleValue],
            [explicitPoint[@"y"] doubleValue]
        );
        if (exactNativeAlertVisible) {
            NSDictionary<NSString *, id> *nativeAction =
                IOSUseAutomationNativeAlertActionAtPoint(requested);
            if (nativeAction == nil) {
                if (commandError != NULL) {
                    *commandError = IOSUseAutomationError(
                        @"element_not_hittable",
                        @"absolute tap is blocked by the visible native alert and does not identify exactly one action",
                        @"interaction",
                        @"hit-test",
                        YES,
                        target,
                        @[]
                    );
                }
                return NO;
            }
            CGRect actionFrame =
                IOSUseAutomationFrameDictionaryRect(
                    nativeAction[@"frame"]
                );
            candidate.serialized = nil;
            candidate.object = nil;
            candidate.interactionView = nil;
            candidate.parent = nil;
            candidate.nodeID = @"";
            candidate.nativeAlertActionLabel =
                nativeAction[@"label"];
            candidate.label = nativeAction[@"label"] ?: @"";
            candidate.value = @"";
            candidate.identifier = @"";
            candidate.hint = @"";
            candidate.className =
                @"IOSUseDOMAppKitAccessibilityElement";
            candidate.frame = actionFrame;
            candidate.depth = 0;
            candidate.index = 0;
            candidate.path = @"";
            candidate.zOrder = 0;
            candidate.generation = 0;
            if (point != NULL) {
                *point = requested;
            }
            if (window != NULL) {
                *window = nil;
            }
            if (hitView != NULL) {
                *hitView = nil;
            }
            return YES;
        }
        if (point == NULL ||
            window == NULL ||
            hitView == NULL ||
            *window == nil ||
            *hitView == nil ||
            candidate.object != *hitView ||
            candidate.generation !=
                [dom[@"snapshotGeneration"]
                    unsignedLongLongValue]) {
            if (commandError != NULL) {
                *commandError = IOSUseAutomationError(
                    @"element_not_hittable",
                    @"absolute tap point has no live hit-test view",
                    @"interaction",
                    @"hit-test",
                    YES,
                    target,
                    @[]
                );
            }
            return NO;
        }
        return YES;
    }

    if (!IOSUseAutomationTapTargetPreflight(
            arguments,
            target,
            candidate,
            commandError
        )) {
        return NO;
    }

    CGRect frame = candidate.frame;
    NSDictionary *offset = arguments[@"offset"];
    NSDictionary *ratio = arguments[@"ratio"];

    if (exactNativeAlertVisible) {
        NSDictionary<NSString *, id> *nativeAction =
            IOSUseAutomationExactNativeAlertAction(
                candidate.nativeAlertActionLabel,
                frame
            );
        if (nativeAction == nil) {
            if (commandError != NULL) {
                *commandError = IOSUseAutomationError(
                    @"element_not_hittable",
                    @"semantic tap is blocked by the visible native alert and the target is not its exact current action proxy",
                    @"interaction",
                    @"identity",
                    YES,
                    target,
                    @[]
                );
            }
            return NO;
        }
        CGPoint requested = CGPointMake(
            CGRectGetMidX(frame),
            CGRectGetMidY(frame)
        );
        if (offset != nil) {
            requested = CGPointMake(
                CGRectGetMinX(frame) +
                    [offset[@"x"] doubleValue],
                CGRectGetMinY(frame) +
                    [offset[@"y"] doubleValue]
            );
        } else if (ratio != nil) {
            requested = CGPointMake(
                CGRectGetMinX(frame) +
                    frame.size.width *
                        [ratio[@"x"] doubleValue],
                CGRectGetMinY(frame) +
                    frame.size.height *
                        [ratio[@"y"] doubleValue]
            );
        }
        CGRect actionFrame =
            IOSUseAutomationFrameDictionaryRect(
                nativeAction[@"frame"]
            );
        CGRect unambiguousFrame =
            CGRectInset(actionFrame, 0.5, 0.5);
        if (unambiguousFrame.size.width <= 0 ||
            unambiguousFrame.size.height <= 0 ||
            !CGRectContainsPoint(unambiguousFrame, requested)) {
            if (commandError != NULL) {
                *commandError = IOSUseAutomationError(
                    @"element_not_hittable",
                    @"native alert tap placement is outside the exact current action frame",
                    @"interaction",
                    @"hit-test",
                    YES,
                    target,
                    @[]
                );
            }
            return NO;
        }
        if (point != NULL) {
            *point = requested;
        }
        if (window != NULL) {
            *window = nil;
        }
        if (hitView != NULL) {
            *hitView = nil;
        }
        return YES;
    }

    UIView *interactionView = candidate.interactionView;
    if (interactionView == nil ||
        [interactionView isKindOfClass:UIWindow.class]) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationError(
                @"element_not_hittable",
                @"fresh semantic target has no bounded live interaction owner",
                @"interaction",
                @"identity",
                YES,
                target,
                @[]
            );
        }
        return NO;
    }

    if (offset != nil || ratio != nil) {
        CGPoint requested = offset != nil
            ? CGPointMake(
                CGRectGetMinX(frame) + [offset[@"x"] doubleValue],
                CGRectGetMinY(frame) + [offset[@"y"] doubleValue]
            )
            : CGPointMake(
                CGRectGetMinX(frame) +
                    frame.size.width * [ratio[@"x"] doubleValue],
                CGRectGetMinY(frame) +
                    frame.size.height * [ratio[@"y"] doubleValue]
            );
        UIWindow *placedWindow = nil;
        UIView *placedHit = nil;
        CGPoint placed = CGPointZero;
        BOOL hasHit = IOSUseAutomationHitTestPoint(
            requested,
            &placedWindow,
            &placedHit,
            &placed
        );
        if (!hasHit ||
            !IOSUseAutomationHitMatchesInteractionOwner(
                placedWindow,
                placedHit,
                interactionView
            ) ||
            !IOSUseAutomationSemanticPointIsUnambiguous(
                dom,
                candidate,
                requested
            )) {
            if (commandError != NULL) {
                *commandError = IOSUseAutomationError(
                    @"element_not_hittable",
                    @"explicit tap placement is not owned by the fresh semantic target",
                    @"interaction",
                    @"hit-test",
                    YES,
                    target,
                    @[]
                );
            }
            return NO;
        }
        if (point != NULL) {
            *point = placed;
        }
        if (window != NULL) {
            *window = placedWindow;
        }
        if (hitView != NULL) {
            *hitView = placedHit;
        }
        return YES;
    }

    CGRect logicalScreen = CGRectMake(
        0,
        0,
        IOSUsePlayDeviceLogicalWidth,
        IOSUsePlayDeviceLogicalHeight
    );
    CGRect visibleFrame = CGRectIntersection(frame, logicalScreen);
    if (!IOSUseAutomationRectHasArea(visibleFrame)) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationError(
                @"element_not_hittable",
                @"fresh semantic target does not intersect the logical screen",
                @"interaction",
                @"hit-test",
                YES,
                target,
                @[]
            );
        }
        return NO;
    }
    NSMutableArray<NSValue *> *searchPoints =
        [NSMutableArray arrayWithCapacity:27];
    IOSUseAutomationAppendUniquePoint(
        searchPoints,
        CGPointMake(
            CGRectGetMidX(visibleFrame),
            CGRectGetMidY(visibleFrame)
        )
    );
    CGPoint activationPoint =
        IOSUseAutomationActivationPoint(candidate.object);
    if (CGRectContainsPoint(visibleFrame, activationPoint)) {
        IOSUseAutomationAppendUniquePoint(
            searchPoints,
            activationPoint
        );
    }
    const CGFloat ratios[] = {0.5, 0.25, 0.75, 0.1, 0.9};
    for (NSUInteger yIndex = 0;
         yIndex < sizeof(ratios) / sizeof(ratios[0]);
         yIndex += 1) {
        for (NSUInteger xIndex = 0;
             xIndex < sizeof(ratios) / sizeof(ratios[0]);
             xIndex += 1) {
            IOSUseAutomationAppendUniquePoint(
                searchPoints,
                CGPointMake(
                    CGRectGetMinX(visibleFrame) +
                        visibleFrame.size.width * ratios[xIndex],
                    CGRectGetMinY(visibleFrame) +
                        visibleFrame.size.height * ratios[yIndex]
                )
            );
        }
    }
    for (NSValue *value in searchPoints) {
        CGPoint requested = value.CGPointValue;
        UIWindow *placedWindow = nil;
        UIView *placedHit = nil;
        CGPoint placed = CGPointZero;
        if (!IOSUseAutomationHitTestPoint(
                requested,
                &placedWindow,
                &placedHit,
                &placed
            )) {
            continue;
        }
        if (!IOSUseAutomationHitMatchesInteractionOwner(
                placedWindow,
                placedHit,
                interactionView
            )) {
            continue;
        }
        if (!IOSUseAutomationSemanticPointIsUnambiguous(
                dom,
                candidate,
                requested
            )) {
            continue;
        }
        if (point != NULL) {
            *point = placed;
        }
        if (window != NULL) {
            *window = placedWindow;
        }
        if (hitView != NULL) {
            *hitView = placedHit;
        }
        return YES;
    }
    if (commandError != NULL) {
        *commandError = IOSUseAutomationError(
            @"element_not_hittable",
            @"fresh semantic target has no exposed owned hit-test point",
            @"interaction",
            @"hit-test",
            YES,
            target,
            @[]
        );
    }
    return NO;
}

static BOOL IOSUseAutomationDOMHasVisibleUIKitAlertMirror(
    NSDictionary<NSString *, id> *dom
) {
    for (NSDictionary<NSString *, id> *element in dom[@"elements"]) {
        NSString *className = element[@"class"];
        NSDictionary<NSString *, id> *state = element[@"state"];
        if ([className isKindOfClass:NSString.class] &&
            [className containsString:@"UIAlertController"] &&
            [className containsString:@"MacView"] &&
            [state[@"visible"] boolValue]) {
            return YES;
        }
    }
    return NO;
}

static NSDictionary<NSString *, id> *IOSUseAutomationDeliveryResult(
    IOSUseAutomationCandidate *candidate,
    UIView *hitView,
    CGPoint point,
    NSInteger touchID,
    NSString *phase,
    NSString * _Nullable firstResponderClass,
    NSDictionary<NSString *, id> * _Nullable extra
) {
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
    } mutableCopy];
    [result addEntriesFromDictionary:extra ?: @{}];
    return result;
}

static BOOL IOSUseAutomationUnsupportedTouchBlockedByNativeAlert(
    NSDictionary<NSString *, id> *dom,
    NSDictionary<NSString *, id> * _Nullable target,
    NSDictionary<NSString *, id> **commandError
) {
    if (![IOSUsePlayAppKitBridge
            hasVisibleNativeAlertCandidate] &&
        !IOSUseAutomationDOMHasVisibleUIKitAlertMirror(dom)) {
        return NO;
    }
    if (commandError != NULL) {
        *commandError = IOSUseAutomationError(
            @"element_not_hittable",
            @"a visible native alert blocks this touch command; use tap or dismissAlert on one exact alert action",
            @"interaction",
            @"identity",
            YES,
            target,
            @[]
        );
    }
    return YES;
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
    if (![command isEqualToString:@"tap"] &&
        IOSUseAutomationUnsupportedTouchBlockedByNativeAlert(
            preDOM,
            target,
            commandError
        )) {
        return nil;
    }
    IOSUseAutomationCandidate *candidate =
        IOSUseAutomationResolveWithDOM(
        target,
        preDOM,
        [command isEqualToString:@"tap"],
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
    BOOL isTap = [command isEqualToString:@"tap"];
    BOOL nativeAlertBlocksPreTouch =
        [IOSUsePlayAppKitBridge
            hasVisibleNativeAlertCandidate] ||
        IOSUseAutomationDOMHasVisibleUIKitAlertMirror(preDOM);
    if (isTap &&
        !nativeAlertBlocksPreTouch &&
        !IOSUseAutomationTapTargetPreflight(
            arguments,
            target,
            candidate,
            commandError
        )) {
        return nil;
    }
    UIView *bottomInteraction =
        candidate.interactionView ?: hitView;
    if (isTap &&
        !nativeAlertBlocksPreTouch &&
        IOSUseAutomationIsBottomInteraction(
            bottomInteraction
        )) {
        UIResponder *focused =
            IOSUseAutomationCurrentFirstResponder();
        NSString *beforeClass = focused == nil
            ? @""
            : NSStringFromClass(focused.class);
        BOOL requested = NO;
        BOOL focusReleased = NO;
        if (IOSUseAutomationBottomTouchRequiresFocusRelease(
                focused,
                bottomInteraction
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
                YES,
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
    if ([command isEqualToString:@"tap"] &&
        !IOSUseAutomationPlaceTap(
            arguments,
            target,
            candidate,
            preDOM,
            &point,
            &window,
            &hitView,
            commandError
        )) {
        return nil;
    }
    if ([command isEqualToString:@"tap"]) {
        if (candidate.nativeAlertActionLabel.length > 0) {
            NSError *nativeError = nil;
            NSDictionary<NSString *, id> *nativeDelivery =
                [IOSUsePlayAppKitBridge
                    performNativeAlertActionWithLabel:
                        candidate.nativeAlertActionLabel
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
                            hasVisibleNativeAlertCandidate]) {
                        if (deferredError != NULL) {
                            *deferredError =
                                IOSUseAutomationError(
                                    @"native_alert_action_failed",
                                    @"native alert target/action did not close the panel",
                                    @"postcondition",
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
                                    @"postcondition",
                                    @"postcondition",
                                    YES,
                                    target,
                                    @[]
                                );
                        }
                        return nil;
                    }
                    return IOSUseAutomationDeliveryResult(
                        candidate,
                        hitView,
                        point,
                        -1,
                        @"native-ended",
                        nil,
                        @{@"nativeAlertDelivery": nativeDelivery}
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
            return IOSUseAutomationDeliveryResult(
                candidate,
                hitView,
                point,
                -1,
                @"web-activated",
                nil,
                @{
                    @"actionEvidence": webEvidence,
                }
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
        return IOSUseAutomationDeliveryResult(
            candidate,
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
                }
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
        return IOSUseAutomationDeliveryResult(
            candidate,
            hitView,
            point,
            touchID,
            @"ended",
            nil,
            nil
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
            NO,
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
    unsigned long long deliveryAfterBegan =
        PTFakeMetaTouch.deliveryGeneration;
    BOOL beganDelivered = touchID >= 0 &&
        deliveryAfterBegan >= deliveryBefore + 1;
    const NSUInteger steps = 12;
    BOOL movesAccepted = YES;
    for (NSUInteger step = 1; step <= steps; step += 1) {
        CGFloat progress = (CGFloat)step / (CGFloat)steps;
        CGPoint current = CGPointMake(
            point.x + (endPoint.x - point.x) * progress,
            point.y + (endPoint.y - point.y) * progress
        );
        NSInteger movedTouchID = IOSUseAutomationSendTouch(
            current,
            UITouchPhaseMoved,
            touchID,
            window,
            deliveryView
        );
        movesAccepted = movesAccepted &&
            movedTouchID == touchID;
        IOSUseAutomationPump(duration / steps);
    }
    unsigned long long deliveryAfterMoves =
        PTFakeMetaTouch.deliveryGeneration;
    BOOL movesDelivered = movesAccepted &&
        deliveryAfterMoves >= deliveryAfterBegan + steps;
    unsigned long long deliveryBeforeEnd =
        PTFakeMetaTouch.deliveryGeneration;
    NSInteger endedTouchID = IOSUseAutomationSendTouch(
        endPoint,
        UITouchPhaseEnded,
        touchID,
        window,
        deliveryView
    );
    IOSUseAutomationPump(0.03);
    BOOL endDelivered = endedTouchID == -1 &&
        PTFakeMetaTouch.deliveryGeneration >= deliveryBeforeEnd + 1;
    if (!beganDelivered || !movesDelivered || !endDelivered) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationError(
                @"touch_delivery_failed",
                @"swipe began, moved, and ended phases were not all delivered to UIApplication",
                @"interaction",
                @"delivery",
                YES,
                target,
                @[]
            );
        }
        return nil;
    }
    return IOSUseAutomationDeliveryResult(
        candidate,
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
        }
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
            @"postcondition",
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
    if (IOSUseAutomationUnsupportedTouchBlockedByNativeAlert(
            preDOM,
            target,
            commandError
        )) {
        return nil;
    }
    generation =
        [preDOM[@"snapshotGeneration"] unsignedLongLongValue];
    if (target != nil) {
        UIWindow *window = nil;
        candidate = IOSUseAutomationResolveWithDOM(
            target,
            preDOM,
            NO,
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
    return IOSUseAutomationDeliveryResult(
        candidate,
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
        }
    );
}

static UIAlertController *
IOSUseAutomationVisibleAlertController(void) {
    NSCParameterAssert(NSThread.isMainThread);
    for (UIWindow *window in IOSUseAutomationWindows()) {
        UIViewController *controller = window.rootViewController;
        while (controller.presentedViewController != nil) {
            controller = controller.presentedViewController;
        }
        if (![controller isKindOfClass:UIAlertController.class]) {
            continue;
        }
        UIAlertController *alert = (UIAlertController *)controller;
        UIView *view = alert.viewIfLoaded;
        CGRect windowFrame = view == nil
            ? CGRectNull
            : [view convertRect:view.bounds toView:window];
        if (alert.isBeingDismissed ||
            view == nil ||
            view.window != window ||
            view.hidden ||
            view.alpha <= 0.01 ||
            !IOSUseAutomationRectHasArea(
                CGRectIntersection(window.bounds, windowFrame)
            )) {
            continue;
        }
        return alert;
    }
    return nil;
}

NSDictionary<NSString *, id> *
IOSUsePlayRuntimeUIKitAlertSnapshot(void) {
    NSCParameterAssert(NSThread.isMainThread);
    UIAlertController *alert =
        IOSUseAutomationVisibleAlertController();
    if (alert == nil) {
        return @{
            @"visible": @NO,
            @"actionableByIOSUse": @NO,
        };
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *actions =
        [NSMutableArray arrayWithCapacity:alert.actions.count];
    [alert.actions
        enumerateObjectsUsingBlock:^(
            UIAlertAction *action,
            NSUInteger index,
            BOOL *stop
        ) {
        (void)stop;
        [actions addObject:@{
            @"index": @(index),
            @"label": action.title ?: @"",
            @"enabled": @(action.enabled),
        }];
    }];
    NSMutableArray<NSString *> *textParts =
        [NSMutableArray array];
    if (alert.title.length > 0) {
        [textParts addObject:alert.title];
    }
    if (alert.message.length > 0) {
        [textParts addObject:alert.message];
    }
    return @{
        @"visible": @YES,
        @"actionableByIOSUse":
            IOSUseAutomationUIKitAlertCandidates(alert).count > 0
                ? @YES
                : @NO,
        @"source": @"uikit",
        @"controllerClass":
            NSStringFromClass([alert class]) ?: @"",
        @"text": [textParts componentsJoinedByString:@"\n"],
        @"actions": actions,
    };
}

static void IOSUseAutomationCollectControls(
    UIView *view,
    NSMutableArray<UIControl *> *controls
) {
    if (view.hidden ||
        view.alpha <= 0.01 ||
        !view.userInteractionEnabled) {
        return;
    }
    if ([view isKindOfClass:UIControl.class]) {
        [controls addObject:(UIControl *)view];
    }
    for (UIView *child in view.subviews) {
        IOSUseAutomationCollectControls(child, controls);
    }
}

static NSDictionary<NSString *, id> *
IOSUseAutomationAlertSelectionError(
    NSString *code,
    NSString *message,
    NSUInteger candidateCount
) {
    return IOSUseAutomationErrorWithCandidateCount(
        code,
        message,
        @"interaction",
        @"selection",
        NO,
        nil,
        @[],
        candidateCount
    );
}

static CGFloat IOSUseAutomationAlertOverlapRatio(
    CGFloat firstMinimum,
    CGFloat firstMaximum,
    CGFloat secondMinimum,
    CGFloat secondMaximum
) {
    CGFloat overlap = MAX(
        0,
        MIN(firstMaximum, secondMaximum) -
            MAX(firstMinimum, secondMinimum)
    );
    CGFloat shorter = MIN(
        firstMaximum - firstMinimum,
        secondMaximum - secondMinimum
    );
    return shorter > 0 ? overlap / shorter : 0;
}

static NSDictionary<NSString *, id> * _Nullable
IOSUseAutomationSelectAlertCandidate(
    NSArray<NSDictionary<NSString *, id> *> *candidates,
    NSString *selection,
    NSInteger requestedIndex,
    NSDictionary<NSString *, id> **commandError
) {
    if ([selection isEqualToString:@"index"]) {
        for (NSDictionary<NSString *, id> *candidate in candidates) {
            if ([candidate[@"index"] integerValue] ==
                requestedIndex) {
                return candidate;
            }
        }
        if (commandError != NULL) {
            *commandError = IOSUseAutomationAlertSelectionError(
                @"alert_selection_required",
                @"the requested alert index is not an actionable button",
                candidates.count
            );
        }
        return nil;
    }
    if ([selection isEqualToString:@"onlyButton"]) {
        if (candidates.count == 1) {
            return candidates.firstObject;
        }
        if (commandError != NULL) {
            NSString *message = candidates.count == 0
                ? @"the alert has no actionable buttons"
                : [NSString stringWithFormat:
                    @"the alert has %lu actionable buttons; choose one explicitly",
                    (unsigned long)candidates.count];
            *commandError = IOSUseAutomationAlertSelectionError(
                @"alert_selection_required",
                message,
                candidates.count
            );
        }
        return nil;
    }

    for (NSDictionary<NSString *, id> *candidate in candidates) {
        CGRect frame = IOSUseAutomationFrameDictionaryRect(
            candidate[@"frame"]
        );
        if (!IOSUseAutomationRectHasArea(frame)) {
            if (commandError != NULL) {
                *commandError =
                    IOSUseAutomationAlertSelectionError(
                        @"alert_primary_ambiguous",
                        @"an actionable alert button has invalid geometry",
                        candidates.count
                    );
            }
            return nil;
        }
    }
    if (candidates.count == 0) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationAlertSelectionError(
                @"alert_selection_required",
                @"the alert has no actionable buttons",
                0
            );
        }
        return nil;
    }
    if (candidates.count == 1) {
        return candidates.firstObject;
    }
    if (candidates.count > 2) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationAlertSelectionError(
                @"alert_primary_ambiguous",
                [NSString stringWithFormat:
                    @"visual primary is ambiguous for %lu actionable buttons",
                    (unsigned long)candidates.count],
                candidates.count
            );
        }
        return nil;
    }

    NSDictionary<NSString *, id> *first = candidates[0];
    NSDictionary<NSString *, id> *second = candidates[1];
    CGRect firstFrame = IOSUseAutomationFrameDictionaryRect(
        first[@"frame"]
    );
    CGRect secondFrame = IOSUseAutomationFrameDictionaryRect(
        second[@"frame"]
    );
    const CGFloat overlapThreshold = 0.6;
    const CGFloat centerTolerance = 1;
    BOOL horizontal =
        IOSUseAutomationAlertOverlapRatio(
            CGRectGetMinY(firstFrame),
            CGRectGetMaxY(firstFrame),
            CGRectGetMinY(secondFrame),
            CGRectGetMaxY(secondFrame)
        ) >= overlapThreshold;
    BOOL vertical =
        IOSUseAutomationAlertOverlapRatio(
            CGRectGetMinX(firstFrame),
            CGRectGetMaxX(firstFrame),
            CGRectGetMinX(secondFrame),
            CGRectGetMaxX(secondFrame)
        ) >= overlapThreshold;
    NSDictionary<NSString *, id> *selected = nil;
    if (horizontal && !vertical &&
        fabs(CGRectGetMidX(firstFrame) -
             CGRectGetMidX(secondFrame)) > centerTolerance) {
        BOOL rightToLeft =
            UIApplication.sharedApplication
                .userInterfaceLayoutDirection ==
            UIUserInterfaceLayoutDirectionRightToLeft;
        BOOL firstIsPrimary = rightToLeft
            ? CGRectGetMidX(firstFrame) <
                CGRectGetMidX(secondFrame)
            : CGRectGetMidX(firstFrame) >
                CGRectGetMidX(secondFrame);
        selected = firstIsPrimary ? first : second;
    } else if (vertical && !horizontal &&
               fabs(CGRectGetMidY(firstFrame) -
                    CGRectGetMidY(secondFrame)) >
                   centerTolerance) {
        selected = CGRectGetMidY(firstFrame) <
                CGRectGetMidY(secondFrame)
            ? first
            : second;
    }
    if (selected == nil && commandError != NULL) {
        *commandError = IOSUseAutomationAlertSelectionError(
            @"alert_primary_ambiguous",
            @"button geometry does not resolve one visual primary action",
            candidates.count
        );
    }
    return selected;
}

static NSArray<NSDictionary<NSString *, id> *> *
IOSUseAutomationUIKitAlertCandidates(
    UIAlertController *alert
) {
    UIWindow *window = alert.view.window;
    if (window == nil) {
        return @[];
    }
    NSMutableArray<UIControl *> *controls = [NSMutableArray array];
    IOSUseAutomationCollectControls(alert.view, controls);
    NSMutableDictionary<NSString *, NSNumber *> *actionLabelCounts =
        [NSMutableDictionary dictionary];
    for (UIAlertAction *action in alert.actions) {
        if (!action.enabled || action.title.length == 0) {
            continue;
        }
        actionLabelCounts[action.title] = @(
            [actionLabelCounts[action.title] unsignedIntegerValue] + 1
        );
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *candidates =
        [NSMutableArray array];
    [alert.actions
        enumerateObjectsUsingBlock:^(
            UIAlertAction *action,
            NSUInteger actionIndex,
            BOOL *stop
        ) {
        (void)stop;
        if (!action.enabled ||
            action.title.length == 0 ||
            [actionLabelCounts[action.title]
                unsignedIntegerValue] != 1) {
            return;
        }
        NSMutableArray<UIControl *> *matches =
            [NSMutableArray array];
        for (UIControl *control in controls) {
            if (control.enabled &&
                control.userInteractionEnabled &&
                control.window == window &&
                [control.accessibilityLabel
                    isEqualToString:action.title]) {
                [matches addObject:control];
            }
        }
        if (matches.count != 1) {
            return;
        }
        UIControl *control = matches.firstObject;
        CGRect frame = [control
            convertRect:control.bounds
              toView:window];
        if (!IOSUseAutomationRectHasArea(frame)) {
            return;
        }
        [candidates addObject:@{
            @"index": @(actionIndex),
            @"label": action.title,
            @"frame": @{
                @"x": @(frame.origin.x),
                @"y": @(frame.origin.y),
                @"width": @(frame.size.width),
                @"height": @(frame.size.height),
            },
            @"action": action,
            @"control": control,
            @"window": window,
        }];
    }];
    return candidates;
}

static NSDictionary<NSString *, id> *IOSUseAutomationDismissAlert(
    NSDictionary<NSString *, id> *arguments,
    BOOL labelOnly,
    NSDictionary<NSString *, id> **commandError
) {
    id rawIndex = arguments[@"index"];
    id rawLabel = arguments[@"label"];
    id rawSelection = arguments[@"selection"];
    NSString *requestedLabel = nil;
    NSString *selection = nil;
    NSInteger requestedIndex = NSNotFound;
    if (labelOnly) {
        NSSet<NSString *> *providedKeys =
            [NSSet setWithArray:arguments.allKeys];
        if (![providedKeys
                isEqualToSet:[NSSet setWithObject:@"label"]] ||
            ![rawLabel isKindOfClass:NSString.class] ||
            [(NSString *)rawLabel
                stringByTrimmingCharactersInSet:
                    NSCharacterSet.whitespaceAndNewlineCharacterSet]
                    .length == 0) {
            if (commandError != NULL) {
                *commandError = IOSUseAutomationError(
                    @"invalid_arguments",
                    @"dismissAlertByLabel requires exactly one non-empty string label",
                    @"validation",
                    @"validation",
                    NO,
                    nil,
                    @[]
                );
            }
            return nil;
        }
        requestedLabel = (NSString *)rawLabel;
        selection = @"label";
    } else {
        NSSet<NSString *> *providedKeys =
            [NSSet setWithArray:arguments.allKeys];
        NSSet<NSString *> *allowedKeys = [NSSet setWithArray:@[
            @"selection",
            @"index",
        ]];
        if (![providedKeys isSubsetOfSet:allowedKeys] ||
            (rawSelection != nil &&
             ![rawSelection isKindOfClass:NSString.class])) {
            if (commandError != NULL) {
                *commandError = IOSUseAutomationError(
                    @"invalid_arguments",
                    @"dismissAlert accepts only selection and index arguments",
                    @"validation",
                    @"validation",
                    NO,
                    nil,
                    @[]
                );
            }
            return nil;
        }
        selection = rawSelection == nil
            ? (rawIndex == nil ? @"onlyButton" : @"index")
            : (NSString *)rawSelection;
        if (![@[
                @"onlyButton",
                @"index",
                @"visualPrimary",
            ] containsObject:selection]) {
            if (commandError != NULL) {
                *commandError = IOSUseAutomationError(
                    @"invalid_arguments",
                    @"dismissAlert selection must be onlyButton, index, or visualPrimary",
                    @"validation",
                    @"validation",
                    NO,
                    nil,
                    @[]
                );
            }
            return nil;
        }
        if ([selection isEqualToString:@"index"]) {
            if (!IOSUseAutomationIsNumber(rawIndex)) {
                if (commandError != NULL) {
                    *commandError = IOSUseAutomationError(
                        @"invalid_arguments",
                        @"dismissAlert index selection requires one non-negative integer index",
                        @"validation",
                        @"validation",
                        NO,
                        nil,
                        @[]
                    );
                }
                return nil;
            }
            double indexValue = [rawIndex doubleValue];
            requestedIndex = [rawIndex integerValue];
            if (!isfinite(indexValue) ||
                indexValue < 0 ||
                floor(indexValue) != indexValue ||
                indexValue > (double)NSIntegerMax) {
                if (commandError != NULL) {
                    *commandError = IOSUseAutomationError(
                        @"invalid_arguments",
                        @"dismissAlert index selection requires one non-negative integer index",
                        @"validation",
                        @"validation",
                        NO,
                        nil,
                        @[]
                    );
                }
                return nil;
            }
        } else if (rawIndex != nil) {
            if (commandError != NULL) {
                *commandError = IOSUseAutomationError(
                    @"invalid_arguments",
                    @"dismissAlert index is valid only with index selection",
                    @"validation",
                    @"validation",
                    NO,
                    nil,
                    @[]
                );
            }
            return nil;
        }
    }
    BOOL nativeAlertCandidateVisible =
        [IOSUsePlayAppKitBridge
            hasVisibleNativeAlertCandidate];
    NSArray<NSDictionary<NSString *, id> *> *nativeActions =
        [IOSUsePlayAppKitBridge nativeAlertActions];
    if (nativeAlertCandidateVisible &&
        nativeActions.count == 0) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationError(
                @"alert_not_dismissed",
                @"a visible native alert candidate could not be bound to one exact panel and action list",
                @"interaction",
                @"identity",
                YES,
                nil,
                @[]
            );
        }
        return nil;
    }
    if (nativeActions.count == 0) {
        NSDictionary<NSString *, id> *snapshotError = nil;
        NSDictionary<NSString *, id> *freshDOM =
            IOSUseAutomationFreshDOM(&snapshotError);
        if (freshDOM == nil) {
            if (commandError != NULL) {
                *commandError = snapshotError;
            }
            return nil;
        }
        if (IOSUseAutomationDOMHasVisibleUIKitAlertMirror(
                freshDOM
            )) {
            if (commandError != NULL) {
                *commandError = IOSUseAutomationError(
                    @"alert_not_dismissed",
                    @"a visible native alert mirror could not be bound to one exact AppKit panel and action list",
                    @"interaction",
                    @"identity",
                    YES,
                    nil,
                    @[]
                );
            }
            return nil;
        }
    }
    if (nativeActions.count > 0) {
        NSString *nativeAlertText =
            [IOSUsePlayAppKitBridge nativeAlertText];
        NSMutableArray<NSDictionary<NSString *, id> *>
            *nativeCandidates = [NSMutableArray
                arrayWithCapacity:nativeActions.count];
        [nativeActions
            enumerateObjectsUsingBlock:^(
                NSDictionary<NSString *, id> *action,
                NSUInteger index,
                BOOL *stop
            ) {
            (void)stop;
            [nativeCandidates addObject:@{
                @"index": @(index),
                @"label": action[@"label"] ?: @"",
                @"frame": action[@"frame"] ?: @{},
            }];
        }];
        NSDictionary<NSString *, id> *nativeAction = nil;
        if (requestedLabel != nil) {
            NSMutableIndexSet *matches =
                [NSMutableIndexSet indexSet];
            [nativeCandidates
                enumerateObjectsUsingBlock:^(
                    NSDictionary<NSString *, id> *action,
                    NSUInteger index,
                    BOOL *stop
                ) {
                    (void)stop;
                    if ([action[@"label"]
                            isEqualToString:requestedLabel]) {
                        [matches addIndex:index];
                    }
                }];
            if (matches.count != 1) {
                if (commandError != NULL) {
                    *commandError =
                        IOSUseAutomationErrorWithCandidateCount(
                        matches.count == 0
                            ? @"alert_action_not_found"
                            : @"alert_action_ambiguous",
                        matches.count == 0
                            ? @"no visible native alert action has the exact requested label"
                            : @"multiple visible native alert actions have the exact requested label",
                        @"lookup",
                        @"lookup",
                        YES,
                        @{
                            @"label": requestedLabel,
                            @"traits": @"Button",
                        },
                        @[],
                        matches.count
                    );
                }
                return nil;
            }
            nativeAction =
                nativeCandidates[matches.firstIndex];
        } else {
            if ([selection isEqualToString:@"index"] &&
                requestedIndex >=
                    (NSInteger)nativeActions.count) {
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
            nativeAction = IOSUseAutomationSelectAlertCandidate(
                nativeCandidates,
                selection,
                requestedIndex,
                commandError
            );
        }
        if (nativeAction == nil) {
            return nil;
        }
        NSString *nativeActionLabel = nativeAction[@"label"];
        NSUInteger deliveryLabelMatches = 0;
        for (NSDictionary<NSString *, id> *candidate
             in nativeCandidates) {
            if ([candidate[@"label"]
                    isEqualToString:nativeActionLabel]) {
                deliveryLabelMatches += 1;
            }
        }
        if (deliveryLabelMatches != 1) {
            if (commandError != NULL) {
                *commandError =
                    IOSUseAutomationAlertSelectionError(
                        @"alert_selection_required",
                        @"the selected native alert button cannot be delivered by one unique exact label",
                        deliveryLabelMatches
                    );
            }
            return nil;
        }
        CGRect actionFrame =
            IOSUseAutomationFrameDictionaryRect(
                nativeAction[@"frame"]
            );
        NSDictionary<NSString *, id> *freshNativeAction =
            IOSUseAutomationExactNativeAlertAction(
                nativeActionLabel,
                actionFrame
            );
        if (freshNativeAction == nil) {
            if (commandError != NULL) {
                *commandError = IOSUseAutomationError(
                    @"alert_changed_before_action",
                    @"the selected native alert action changed before delivery",
                    @"interaction",
                    @"selection",
                    YES,
                    nil,
                    @[]
                );
            }
            return nil;
        }
        nativeAction = freshNativeAction;
        nativeActionLabel = nativeAction[@"label"];
        actionFrame = IOSUseAutomationFrameDictionaryRect(
            nativeAction[@"frame"]
        );
        NSError *nativeError = nil;
        NSDictionary<NSString *, id> *nativeDelivery =
            [IOSUsePlayAppKitBridge
                performNativeAlertActionWithLabel:
                    nativeActionLabel
                error:&nativeError];
        if (nativeDelivery == nil) {
            if (commandError != NULL) {
                *commandError = IOSUseAutomationError(
                    @"alert_not_dismissed",
                    nativeError.localizedDescription ?:
                        @"native alert action was not delivered",
                    @"action",
                    @"delivery",
                    YES,
                    nil,
                    @[]
                );
            }
            return nil;
        }
        CGPoint actionPoint = CGPointMake(
            CGRectGetMidX(actionFrame),
            CGRectGetMidY(actionFrame)
        );
        IOSUseAutomationDeferredFinalize finalize =
            ^NSDictionary<NSString *, id> *(
                NSDictionary<NSString *, id> **deferredError
            ) {
                if ([IOSUsePlayAppKitBridge
                        hasVisibleNativeAlertCandidate]) {
                    if (deferredError != NULL) {
                        *deferredError = IOSUseAutomationError(
                            @"alert_not_dismissed",
                            @"native alert target/action did not close the panel",
                            @"postcondition",
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
                            @"postcondition",
                            @"postcondition",
                            YES,
                            nil,
                            @[]
                        );
                    }
                    return nil;
                }
                return @{
                    @"dismissed": @YES,
                    @"text": nativeAlertText,
                    @"button": nativeActionLabel,
                    @"reason": selection,
                    @"nativeAlertDelivery": nativeDelivery,
                    @"finalState": @{
                        @"point": @{
                            @"x": @(actionPoint.x),
                            @"y": @(actionPoint.y),
                        },
                        @"touchID": @(-1),
                        @"phase": @"native-ended",
                    },
                };
            };
        return @{
            IOSUseAutomationDeferredFinalizeKey:
                [finalize copy],
        };
    }
    UIAlertController *alert =
        IOSUseAutomationVisibleAlertController();
    if (alert == nil) {
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
    NSInteger labelIndex = NSNotFound;
    if (requestedLabel != nil) {
        NSMutableIndexSet *matches =
            [NSMutableIndexSet indexSet];
        [alert.actions
            enumerateObjectsUsingBlock:^(
                UIAlertAction *action,
                NSUInteger actionIndex,
                BOOL *stop
            ) {
                (void)stop;
                if ([action.title isEqualToString:requestedLabel]) {
                    [matches addIndex:actionIndex];
                }
            }];
        if (matches.count != 1) {
            if (commandError != NULL) {
                *commandError =
                    IOSUseAutomationErrorWithCandidateCount(
                    matches.count == 0
                        ? @"alert_action_not_found"
                        : @"alert_action_ambiguous",
                    matches.count == 0
                        ? @"no visible alert action has the exact requested label"
                        : @"multiple visible alert actions have the exact requested label",
                    @"lookup",
                    @"lookup",
                    YES,
                    @{
                        @"label": requestedLabel,
                        @"traits": @"Button",
                    },
                    @[],
                    matches.count
                );
            }
            return nil;
        }
        labelIndex = (NSInteger)matches.firstIndex;
    }
    if ([selection isEqualToString:@"index"] &&
        requestedIndex >= (NSInteger)alert.actions.count) {
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
    NSArray<NSDictionary<NSString *, id> *> *candidates =
        IOSUseAutomationUIKitAlertCandidates(alert);
    NSDictionary<NSString *, id> *selectedCandidate = nil;
    if (requestedLabel != nil) {
        for (NSDictionary<NSString *, id> *candidate
             in candidates) {
            if ([candidate[@"index"] integerValue] ==
                labelIndex) {
                selectedCandidate = candidate;
                break;
            }
        }
        if (selectedCandidate == nil && commandError != NULL) {
            *commandError =
                IOSUseAutomationErrorWithCandidateCount(
                    @"alert_action_not_found",
                    @"the exact alert action has no unique enabled live UIControl and window frame",
                    @"interaction",
                    @"hit-test",
                    YES,
                    @{
                        @"label": requestedLabel,
                        @"traits": @"Button",
                    },
                    @[],
                    0
                );
        }
    } else {
        selectedCandidate =
            IOSUseAutomationSelectAlertCandidate(
                candidates,
                selection,
                requestedIndex,
                commandError
            );
    }
    if (selectedCandidate == nil) {
        return nil;
    }
    UIAlertAction *action = selectedCandidate[@"action"];
    UIControl *selectedControl =
        selectedCandidate[@"control"];
    UIWindow *window = selectedCandidate[@"window"];
    CGRect controlFrame =
        IOSUseAutomationFrameDictionaryRect(
            selectedCandidate[@"frame"]
        );
    if (action == nil ||
        selectedControl == nil ||
        window == nil ||
        !action.enabled ||
        !selectedControl.enabled ||
        !selectedControl.userInteractionEnabled ||
        selectedControl.window != window ||
        !IOSUseAutomationRectHasArea(controlFrame) ||
        IOSUseAutomationVisibleAlertController() != alert) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationError(
                @"alert_changed_before_action",
                @"the selected alert action changed before delivery",
                @"interaction",
                @"selection",
                YES,
                nil,
                @[]
            );
        }
        return nil;
    }
    CGPoint point = CGPointMake(
        CGRectGetMidX(controlFrame),
        CGRectGetMidY(controlFrame)
    );
    UIView *hitView = [window hitTest:point withEvent:nil];
    if (hitView == nil ||
        (hitView != selectedControl &&
         ![hitView isDescendantOfView:selectedControl])) {
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
        IOSUseAutomationVisibleAlertController() == alert) {
        if (commandError != NULL) {
            *commandError = IOSUseAutomationError(
                @"alert_not_dismissed",
                @"alert action was delivered but the alert remained visible",
                @"postcondition",
                @"postcondition",
                YES,
                nil,
                @[]
            );
        }
        return nil;
    }
    return @{
        @"dismissed": @YES,
        @"text": alert.message ?: alert.title ?: @"",
        @"button": action.title ?: @"",
        @"reason": selection,
        @"hitView": IOSUseAutomationHitViewJSON(hitView),
        @"finalState": @{
            @"point": @{
                @"x": @(point.x),
                @"y": @(point.y),
            },
            @"touchID": @(touchID),
            @"phase": @"ended",
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
    return @{
        @"delivered": @YES,
        @"url": url.absoluteString,
        @"deliveryBackend": deliveryBackend,
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
    NSDictionary<NSString *, id> * _Nullable (^runCommand)(
        NSDictionary<NSString *, id> * _Nullable * _Nullable
    ) = ^NSDictionary<NSString *, id> *(
        NSDictionary<NSString *, id> **localError
    ) {
        NSDictionary<NSString *, id> *localResult = nil;
        NSDictionary<NSString *, id> *readinessError =
            IOSUsePlayRuntimeUICommandError();
        if (readinessError != nil) {
            if (localError != NULL) {
                *localError = readinessError;
            }
            return nil;
        }
        @try {
            if ([command isEqualToString:@"tap"] ||
                [command isEqualToString:@"longPress"] ||
                [command isEqualToString:@"swipe"]) {
                localResult = IOSUseAutomationTouchCommand(
                    command,
                    arguments,
                    localError
                );
            } else if ([command isEqualToString:@"input"]) {
                localResult = IOSUseAutomationInput(
                    arguments,
                    localError
                );
            } else if (
                [command isEqualToString:@"dismissAlert"] ||
                [command
                    isEqualToString:@"dismissAlertByLabel"]
            ) {
                localResult = IOSUseAutomationDismissAlert(
                    arguments,
                    [command
                        isEqualToString:@"dismissAlertByLabel"],
                    localError
                );
            } else if ([command isEqualToString:@"open"]) {
                localResult = IOSUseAutomationOpen(
                    arguments,
                    localError
                );
            } else if (localError != NULL) {
                *localError = IOSUseAutomationError(
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
            if (localError != NULL) {
                *localError = IOSUseAutomationError(
                    @"automation_exception",
                    [NSString stringWithFormat:
                        @"automation raised %@",
                        exception.name],
                    @"action",
                    @"dispatch",
                    NO,
                    nil,
                    @[]
                );
            }
        }
        return localResult;
    };
    NSDictionary<NSString *, id> *result = nil;
    NSDictionary<NSString *, id> *blockError = nil;
    BOOL calledOnMainThread = NSThread.isMainThread;
    if (calledOnMainThread) {
        result = runCommand(&blockError);
    } else {
        NSLock *executionLock = [NSLock new];
        dispatch_semaphore_t completion = dispatch_semaphore_create(0);
        __block BOOL executionCancelled = NO;
        __block BOOL executionStarted = NO;
        __block BOOL executionCompleted = NO;
        __block NSDictionary<NSString *, id> *publishedResult = nil;
        __block NSDictionary<NSString *, id> *publishedError = nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            [executionLock lock];
            if (executionCancelled) {
                executionCompleted = YES;
                [executionLock unlock];
                dispatch_semaphore_signal(completion);
                return;
            }
            executionStarted = YES;
            [executionLock unlock];

            NSDictionary<NSString *, id> *localError = nil;
            NSDictionary<NSString *, id> *localResult =
                runCommand(&localError);

            [executionLock lock];
            if (!executionCancelled) {
                publishedResult = localResult;
                publishedError = localError;
            }
            executionCompleted = YES;
            [executionLock unlock];
            dispatch_semaphore_signal(completion);
        });
        dispatch_time_t deadline = dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)(IOSUseAutomationMainTimeout * NSEC_PER_SEC)
        );
        long waitResult =
            dispatch_semaphore_wait(completion, deadline);
        [executionLock lock];
        if (waitResult == 0 || executionCompleted) {
            result = publishedResult;
            blockError = publishedError;
        } else {
            BOOL mutationMayHaveApplied = executionStarted;
            executionCancelled = YES;
            blockError = IOSUseAutomationError(
                @"main_thread_timeout",
                mutationMayHaveApplied
                    ? @"automation exceeded its main-thread deadline after dispatch began; the mutation may still complete"
                    : @"automation did not begin before its main-thread deadline",
                mutationMayHaveApplied
                    ? @"action"
                    : @"timeout",
                @"dispatch",
                YES,
                nil,
                @[]
            );
        }
        [executionLock unlock];
    }
    IOSUseAutomationDeferredFinalize deferred =
        result[IOSUseAutomationDeferredFinalizeKey];
    if (deferred != nil) {
        result = nil;
        if (calledOnMainThread) {
            blockError = IOSUseAutomationError(
                @"deferred_postcondition_unavailable",
                @"native alert postcondition requires the Runtime socket worker",
                @"postcondition",
                @"postcondition",
                NO,
                nil,
                @[]
            );
        } else {
            NSLock *finalizeLock = [NSLock new];
            dispatch_semaphore_t completion =
                dispatch_semaphore_create(0);
            __block BOOL finalizeCancelled = NO;
            __block BOOL finalizeStarted = NO;
            __block BOOL finalizeCompleted = NO;
            __block NSDictionary<NSString *, id>
                *publishedFinalizeResult = nil;
            __block NSDictionary<NSString *, id>
                *publishedFinalizeError = nil;
            dispatch_after(
                dispatch_time(
                    DISPATCH_TIME_NOW,
                    (int64_t)(0.5 * NSEC_PER_SEC)
                ),
                dispatch_get_main_queue(),
                ^{
                    [finalizeLock lock];
                    if (finalizeCancelled) {
                        finalizeCompleted = YES;
                        [finalizeLock unlock];
                        dispatch_semaphore_signal(completion);
                        return;
                    }
                    finalizeStarted = YES;
                    [finalizeLock unlock];

                    NSDictionary<NSString *, id> *localError = nil;
                    NSDictionary<NSString *, id> *localResult = nil;
                    @try {
                        localResult = deferred(&localError);
                    } @catch (NSException *exception) {
                        localError = IOSUseAutomationError(
                            @"automation_exception",
                            [NSString stringWithFormat:
                                @"deferred automation raised %@",
                                exception.name],
                            @"postcondition",
                            @"postcondition",
                            NO,
                            nil,
                            @[]
                        );
                    }
                    if (localResult == nil) {
                        localError =
                            IOSUseAutomationPostconditionError(
                                localError
                            );
                    } else {
                        localError = nil;
                    }
                    [finalizeLock lock];
                    if (!finalizeCancelled) {
                        publishedFinalizeResult = localResult;
                        publishedFinalizeError = localError;
                    }
                    finalizeCompleted = YES;
                    [finalizeLock unlock];
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
            long waitResult = dispatch_semaphore_wait(
                completion,
                deadline
            );
            [finalizeLock lock];
            if (waitResult == 0 || finalizeCompleted) {
                result = publishedFinalizeResult;
                blockError = publishedFinalizeError;
            } else {
                finalizeCancelled = YES;
                blockError = IOSUseAutomationError(
                    @"main_thread_timeout",
                    finalizeStarted
                        ? @"deferred automation postcondition exceeded its main-thread deadline after evaluation began; the mutation may already have applied"
                        : @"deferred automation postcondition did not begin before its main-thread deadline; the mutation may already have applied",
                    @"postcondition",
                    @"postcondition",
                    YES,
                    nil,
                    @[]
                );
            }
            [finalizeLock unlock];
        }
    }
    if (result == nil && commandError != NULL) {
        *commandError = blockError ?: IOSUseAutomationError(
            @"automation_failed",
            @"automation did not produce a result",
            @"action",
            @"dispatch",
            NO,
            nil,
            @[]
        );
    }
    return result;
}
