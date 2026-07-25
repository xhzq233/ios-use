#import "IOSUsePlayRuntimeDOM.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <stdatomic.h>
#import <unistd.h>

static const NSUInteger IOSUseDOMMaximumVisitedNodeCount = 8192;
static const NSUInteger IOSUseDOMMaximumCleanNodeCount = 4096;
static const NSUInteger IOSUseDOMMaximumDepth = 64;
static const NSUInteger IOSUseDOMMaximumChildrenPerNode = 2048;
static const NSUInteger IOSUseDOMMaximumStringLength = 4096;
static const NSUInteger IOSUseDOMMaximumTotalStringBytes = 512 * 1024;
static const NSUInteger IOSUseDOMMaximumRawStringBytes = 512 * 1024;
static const NSUInteger IOSUseDOMMaximumErrorCandidates = 5;
static const NSTimeInterval IOSUseDOMMainThreadTimeoutSeconds = 2.0;
static const NSTimeInterval IOSUseDOMWaitDefaultSeconds = 10.0;
static const NSTimeInterval IOSUseDOMWaitMaximumSeconds = 300.0;
static const useconds_t IOSUseDOMWaitPollMicroseconds = 100000;
static atomic_ullong IOSUseDOMGeneration = 0;

typedef id (*IOSUseDOMSendID)(id, SEL);
typedef id (*IOSUseDOMSendIDInteger)(id, SEL, NSInteger);
typedef BOOL (*IOSUseDOMSendBool)(id, SEL);
typedef NSInteger (*IOSUseDOMSendInteger)(id, SEL);
typedef unsigned long long (*IOSUseDOMSendUnsignedLongLong)(id, SEL);
typedef CGRect (*IOSUseDOMSendRect)(id, SEL);

@interface IOSUseDOMNode : NSObject
@property(nonatomic, copy) NSString *nodeID;
@property(nonatomic) NSInteger elementType;
@property(nonatomic, copy) NSString *typeName;
@property(nonatomic, copy, nullable) NSString *label;
@property(nonatomic, copy, nullable) NSString *value;
@property(nonatomic) CGRect rect;
@property(nonatomic) BOOL hasRect;
@property(nonatomic) BOOL disabled;
@property(nonatomic) BOOL invisible;
@property(nonatomic) BOOL selected;
@property(nonatomic) BOOL focused;
@property(nonatomic) BOOL opaque;
@property(nonatomic, copy) NSArray<IOSUseDOMNode *> *children;
@end

@implementation IOSUseDOMNode
@end

@interface IOSUseCleanNode : NSObject
@property(nonatomic, strong) IOSUseDOMNode *source;
@property(nonatomic, copy, nullable) NSString *displayLabel;
@property(nonatomic) BOOL opaque;
@property(nonatomic, copy) NSArray<NSString *> *traits;
@property(nonatomic, copy) NSArray<IOSUseCleanNode *> *children;
@property(nonatomic, weak, nullable) IOSUseCleanNode *parent;
@end

@implementation IOSUseCleanNode
@end

@interface IOSUseDOMSnapshot : NSObject
@property(nonatomic, copy) NSString *application;
@property(nonatomic) CGSize windowSize;
@property(nonatomic) CGRect screenBounds;
@property(nonatomic) unsigned long long generation;
@property(nonatomic, copy) NSArray<IOSUseDOMNode *> *rawRoots;
@property(nonatomic, copy) NSArray<IOSUseCleanNode *> *cleanRoots;
@property(nonatomic, copy) NSArray<IOSUseCleanNode *> *elements;
@end

@implementation IOSUseDOMSnapshot
@end

@interface IOSUseDOMCaptureContext : NSObject
@property(nonatomic, strong) NSHashTable<id> *visited;
@property(nonatomic) NSUInteger visitedCount;
@property(nonatomic) NSUInteger totalStringBytes;
@property(nonatomic) NSUInteger nextNodeOrdinal;
@property(nonatomic) unsigned long long generation;
@property(nonatomic, copy, nullable) NSString *failureMessage;
@end

@implementation IOSUseDOMCaptureContext
@end

@interface IOSUseDOMSnapshotRequest : NSObject
@property(nonatomic) CFAbsoluteTime expiresAt;
@property(nonatomic) BOOL cancelled;
@property(nonatomic) BOOL deadlineExpired;
@property(nonatomic, strong) dispatch_semaphore_t completion;
@property(nonatomic, strong, nullable) IOSUseDOMSnapshot *snapshot;
@property(nonatomic, copy, nullable) NSString *failureMessage;
@end

@implementation IOSUseDOMSnapshotRequest
@end

typedef NS_ENUM(NSInteger, IOSUseDOMSelectorState) {
    IOSUseDOMSelectorStateNotFound = 0,
    IOSUseDOMSelectorStateFound = 1,
    IOSUseDOMSelectorStateAmbiguous = 2,
};

@interface IOSUseDOMSelectorResult : NSObject
@property(nonatomic) IOSUseDOMSelectorState state;
@property(nonatomic, copy) NSArray<IOSUseCleanNode *> *matches;
@end

@implementation IOSUseDOMSelectorResult
@end

static BOOL IOSUseDOMIsBoolean(id value) {
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static BOOL IOSUseDOMIsNumber(id value) {
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID();
}

static BOOL IOSUseDOMIsInteger(id value) {
    if (!IOSUseDOMIsNumber(value)) {
        return NO;
    }
    NSNumber *number = value;
    double doubleValue = number.doubleValue;
    return isfinite(doubleValue) &&
        doubleValue == (double)number.longLongValue;
}

static BOOL IOSUseDOMRectIsFinite(CGRect rect) {
    return isfinite(rect.origin.x) &&
        isfinite(rect.origin.y) &&
        isfinite(rect.size.width) &&
        isfinite(rect.size.height) &&
        !CGRectIsNull(rect) &&
        !CGRectIsInfinite(rect);
}

static BOOL IOSUseDOMRectHasArea(CGRect rect) {
    return IOSUseDOMRectIsFinite(rect) &&
        rect.size.width > 0 &&
        rect.size.height > 0;
}

static NSDictionary<NSString *, NSNumber *> *IOSUseDOMRectJSON(CGRect rect) {
    return @{
        @"x": @(rect.origin.x),
        @"y": @(rect.origin.y),
        @"w": @(rect.size.width),
        @"h": @(rect.size.height),
    };
}

static dispatch_queue_t IOSUseDOMSnapshotCoordinator(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create(
            "io.ios-use.play-runtime.dom-snapshots",
            DISPATCH_QUEUE_SERIAL
        );
    });
    return queue;
}

static NSDictionary<NSString *, id> *IOSUseDOMTargetJSON(
    NSString *label,
    NSString *traits,
    NSNumber * _Nullable childIndex
) {
    NSMutableDictionary<NSString *, id> *target = [@{
        @"label": label,
        @"traits": traits,
    } mutableCopy];
    if (childIndex != nil) {
        target[@"cindex"] = childIndex;
    }
    return target;
}

static NSDictionary<NSString *, id> *IOSUseDOMErrorDetails(
    NSString *category,
    NSString *phase,
    BOOL retryable,
    NSDictionary<NSString *, id> * _Nullable target,
    NSUInteger candidateCount,
    NSArray<NSDictionary<NSString *, id> *> *candidates
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
    return details;
}

static NSDictionary<NSString *, id> *IOSUseDOMError(
    NSString *code,
    NSString *message,
    NSString *category,
    NSString *phase,
    BOOL retryable,
    NSDictionary<NSString *, id> * _Nullable target,
    NSUInteger candidateCount,
    NSArray<NSDictionary<NSString *, id> *> *candidates
) {
    return @{
        @"code": code,
        @"message": message,
        @"details": IOSUseDOMErrorDetails(
            category,
            phase,
            retryable,
            target,
            candidateCount,
            candidates
        ),
    };
}

static NSDictionary<NSString *, id> *IOSUseDOMValidationError(
    NSString *message,
    NSDictionary<NSString *, id> * _Nullable target
) {
    return IOSUseDOMError(
        @"invalid_arguments",
        message,
        @"validation",
        @"validation",
        NO,
        target,
        0,
        @[]
    );
}

static id _Nullable IOSUseDOMObjectValue(id object, SEL selector) {
    if (object == nil || ![object respondsToSelector:selector]) {
        return nil;
    }
    @try {
        return ((IOSUseDOMSendID)objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL IOSUseDOMBoolValue(
    id object,
    SEL selector,
    BOOL fallback
) {
    if (object == nil || ![object respondsToSelector:selector]) {
        return fallback;
    }
    @try {
        return ((IOSUseDOMSendBool)objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return fallback;
    }
}

static unsigned long long IOSUseDOMAccessibilityTraits(id object) {
    SEL selector = NSSelectorFromString(@"accessibilityTraits");
    if (object == nil || ![object respondsToSelector:selector]) {
        return 0;
    }
    @try {
        return ((IOSUseDOMSendUnsignedLongLong)objc_msgSend)(
            object,
            selector
        );
    } @catch (__unused NSException *exception) {
        return 0;
    }
}

static NSString * _Nullable IOSUseDOMBoundedString(
    id value,
    IOSUseDOMCaptureContext *context
) {
    if (value == nil || value == NSNull.null) {
        return nil;
    }
    NSString *string;
    if ([value isKindOfClass:NSString.class]) {
        string = value;
    } else if ([value isKindOfClass:NSNumber.class]) {
        string = [value stringValue];
    } else {
        @try {
            string = [value description];
        } @catch (__unused NSException *exception) {
            return nil;
        }
    }
    static NSCharacterSet *trimCharacters;
    static NSCharacterSet *invalidCharacters;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableCharacterSet *trim = [
            NSCharacterSet.whitespaceAndNewlineCharacterSet
            mutableCopy
        ];
        [trim addCharactersInString:@"\u200B\u200C\u200D\u2060\uFEFF"];
        trimCharacters = trim.copy;

        NSMutableCharacterSet *invalid = [
            NSCharacterSet.controlCharacterSet
            mutableCopy
        ];
        [invalid removeCharactersInString:@"\t\n\r"];
        [invalid addCharactersInString:@"\u200B\u200C\u200D\u2060\uFEFF"];
        invalidCharacters = invalid.copy;
    });
    string = [string stringByTrimmingCharactersInSet:trimCharacters];
    string = [[string componentsSeparatedByCharactersInSet:
        invalidCharacters] componentsJoinedByString:@""];
    string = [string stringByTrimmingCharactersInSet:trimCharacters];
    if (string.length == 0) {
        return nil;
    }
    if (string.length > IOSUseDOMMaximumStringLength) {
        context.failureMessage =
            @"accessibility string exceeded the 4096-character limit";
        return nil;
    }
    NSUInteger bytes = [string lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (bytes == 0 || bytes > IOSUseDOMMaximumTotalStringBytes ||
        context.totalStringBytes >
            IOSUseDOMMaximumTotalStringBytes - bytes) {
        context.failureMessage =
            @"accessibility strings exceeded the 524288-byte snapshot limit";
        return nil;
    }
    context.totalStringBytes += bytes;
    return [string copy];
}

static NSArray * _Nullable IOSUseDOMArrayFromObject(id value) {
    if ([value isKindOfClass:NSArray.class]) {
        return value;
    }
    if ([value isKindOfClass:NSOrderedSet.class]) {
        return [(NSOrderedSet *)value array];
    }
    if ([value isKindOfClass:NSSet.class]) {
        return [(NSSet *)value allObjects];
    }
    return nil;
}

static NSArray * _Nullable IOSUseDOMArrayForSelector(
    id object,
    SEL selector,
    BOOL *responds
) {
    BOOL hasSelector = object != nil &&
        [object respondsToSelector:selector];
    if (responds != NULL) {
        *responds = hasSelector;
    }
    if (!hasSelector) {
        return nil;
    }
    return IOSUseDOMArrayFromObject(IOSUseDOMObjectValue(object, selector));
}

static NSArray * _Nullable IOSUseDOMContainerElements(
    id object,
    IOSUseDOMCaptureContext *context
) {
    SEL countSelector = NSSelectorFromString(@"accessibilityElementCount");
    SEL elementSelector =
        NSSelectorFromString(@"accessibilityElementAtIndex:");
    if (![object respondsToSelector:countSelector] ||
        ![object respondsToSelector:elementSelector]) {
        return nil;
    }
    NSInteger count = 0;
    @try {
        count = ((IOSUseDOMSendInteger)objc_msgSend)(
            object,
            countSelector
        );
    } @catch (__unused NSException *exception) {
        return nil;
    }
    if (count < 0) {
        return nil;
    }
    if ((NSUInteger)count > IOSUseDOMMaximumChildrenPerNode) {
        context.failureMessage =
            @"accessibility container exceeded the 2048-child limit";
        return nil;
    }
    NSMutableArray *elements =
        [NSMutableArray arrayWithCapacity:(NSUInteger)count];
    for (NSInteger index = 0; index < count; index += 1) {
        id element = nil;
        @try {
            element = ((IOSUseDOMSendIDInteger)objc_msgSend)(
                object,
                elementSelector,
                index
            );
        } @catch (__unused NSException *exception) {
            element = nil;
        }
        if (element != nil) {
            [elements addObject:element];
        }
    }
    return elements;
}

static NSArray *IOSUseDOMUniqueChildren(
    NSArray *children,
    id owner,
    IOSUseDOMCaptureContext *context
) {
    if (children.count > IOSUseDOMMaximumChildrenPerNode) {
        context.failureMessage =
            @"accessibility node exceeded the 2048-child limit";
        return @[];
    }
    NSHashTable<id> *seen = [NSHashTable hashTableWithOptions:
        NSPointerFunctionsObjectPointerPersonality |
        NSPointerFunctionsStrongMemory];
    NSMutableArray *unique =
        [NSMutableArray arrayWithCapacity:children.count];
    for (id child in children) {
        if (child == nil ||
            child == owner ||
            child == NSNull.null ||
            [child isKindOfClass:NSString.class] ||
            [child isKindOfClass:NSNumber.class] ||
            [seen containsObject:child]) {
            continue;
        }
        [seen addObject:child];
        [unique addObject:child];
    }
    return unique;
}

static NSArray *IOSUseDOMChildren(
    id object,
    BOOL accessibilityElement,
    BOOL *hasAutomationChildren,
    IOSUseDOMCaptureContext *context
) {
    BOOL respondsToAutomation = NO;
    NSArray *automation = IOSUseDOMArrayForSelector(
        object,
        NSSelectorFromString(@"automationElements"),
        &respondsToAutomation
    );
    if (automation.count > 0) {
        if (hasAutomationChildren != NULL) {
            *hasAutomationChildren = YES;
        }
        return IOSUseDOMUniqueChildren(automation, object, context);
    }
    if (hasAutomationChildren != NULL) {
        *hasAutomationChildren = NO;
    }

    // UIKit accessibility elements are opaque leaves by default. Private
    // automationElements is the one explicit signal that their descendants
    // remain part of the automation tree.
    if (accessibilityElement && ![object isKindOfClass:UIWindow.class]) {
        return @[];
    }

    NSArray *accessibilityElements = IOSUseDOMArrayForSelector(
        object,
        NSSelectorFromString(@"accessibilityElements"),
        NULL
    );
    if (accessibilityElements.count > 0) {
        return IOSUseDOMUniqueChildren(
            accessibilityElements,
            object,
            context
        );
    }
    if (context.failureMessage != nil) {
        return @[];
    }

    NSArray *containerElements = IOSUseDOMContainerElements(object, context);
    if (containerElements.count > 0) {
        return IOSUseDOMUniqueChildren(containerElements, object, context);
    }
    if (context.failureMessage != nil) {
        return @[];
    }

    if ([object isKindOfClass:UIView.class]) {
        NSArray<UIView *> *subviews = [(UIView *)object subviews];
        return IOSUseDOMUniqueChildren(subviews, object, context);
    }
    (void)respondsToAutomation;
    return @[];
}

static BOOL IOSUseDOMObjectHierarchyVisible(id object) {
    if ([object isKindOfClass:UIView.class]) {
        UIView *view = object;
        @try {
            if (view.hidden || view.alpha <= 0.01 ||
                view.accessibilityElementsHidden) {
                return NO;
            }
        } @catch (__unused NSException *exception) {
            return NO;
        }
    } else if (IOSUseDOMBoolValue(
                   object,
                   NSSelectorFromString(@"accessibilityElementsHidden"),
                   NO
               )) {
        return NO;
    }
    return YES;
}

static BOOL IOSUseDOMObjectClipsDescendants(id object) {
    if (![object isKindOfClass:UIView.class]) {
        return NO;
    }
    if ([object isKindOfClass:UIWindow.class] ||
        [object isKindOfClass:UIScrollView.class]) {
        return YES;
    }
    @try {
        return [(UIView *)object clipsToBounds];
    } @catch (__unused NSException *exception) {
        return YES;
    }
}

static CGRect IOSUseDOMObjectRect(id object) {
    SEL accessibilityFrameSelector =
        NSSelectorFromString(@"accessibilityFrame");
    if ([object respondsToSelector:accessibilityFrameSelector]) {
        @try {
            CGRect frame = ((IOSUseDOMSendRect)objc_msgSend)(
                object,
                accessibilityFrameSelector
            );
            if (IOSUseDOMRectHasArea(frame)) {
                return frame;
            }
        } @catch (__unused NSException *exception) {
        }
    }
    if ([object isKindOfClass:UIView.class]) {
        UIView *view = object;
        @try {
            CGRect frame = [view convertRect:view.bounds toView:nil];
            if (IOSUseDOMRectHasArea(frame)) {
                return frame;
            }
        } @catch (__unused NSException *exception) {
        }
    }
    return CGRectZero;
}

static NSInteger IOSUseDOMElementType(
    id object,
    unsigned long long accessibilityTraits
) {
    if ([object isKindOfClass:UIWindow.class]) {
        return 4;
    }
    if ([object isKindOfClass:UIButton.class]) {
        return 9;
    }
    if ([object isKindOfClass:UISearchBar.class]) {
        return 45;
    }
    if ([object isKindOfClass:UITextField.class]) {
        UITextField *field = object;
        return field.secureTextEntry ? 50 : 49;
    }
    if ([object isKindOfClass:UITextView.class]) {
        return 52;
    }
    if ([object isKindOfClass:UISwitch.class]) {
        return 40;
    }
    if ([object isKindOfClass:UISlider.class]) {
        return 33;
    }
    if ([object isKindOfClass:UIPageControl.class]) {
        return 34;
    }
    if ([object isKindOfClass:UIProgressView.class]) {
        return 35;
    }
    if ([object isKindOfClass:UIActivityIndicatorView.class]) {
        return 36;
    }
    if ([object isKindOfClass:UISegmentedControl.class]) {
        return 37;
    }
    if ([object isKindOfClass:UIPickerView.class]) {
        return 38;
    }
    if ([object isKindOfClass:UIDatePicker.class]) {
        return 51;
    }
    if ([object isKindOfClass:UITableView.class]) {
        return 26;
    }
    if ([object isKindOfClass:UITableViewCell.class]) {
        return 75;
    }
    if ([object isKindOfClass:UICollectionView.class]) {
        return 32;
    }
    if ([object isKindOfClass:UICollectionViewCell.class]) {
        return 75;
    }
    if ([object isKindOfClass:UINavigationBar.class]) {
        return 21;
    }
    if ([object isKindOfClass:UITabBar.class]) {
        return 22;
    }
    if ([object isKindOfClass:UIToolbar.class]) {
        return 24;
    }
    Class webViewClass = NSClassFromString(@"WKWebView");
    if (webViewClass != Nil && [object isKindOfClass:webViewClass]) {
        return 58;
    }
    if ([object isKindOfClass:UIScrollView.class]) {
        return 46;
    }
    NSString *className = NSStringFromClass([object class]);
    if ([className rangeOfString:@"Keyboard"].location != NSNotFound) {
        return 19;
    }
    if ([className rangeOfString:@"Alert"].location != NSNotFound) {
        return 7;
    }
    if ((accessibilityTraits & UIAccessibilityTraitKeyboardKey) != 0) {
        return 20;
    }
    if ((accessibilityTraits & UIAccessibilityTraitButton) != 0) {
        return 9;
    }
    if ((accessibilityTraits & UIAccessibilityTraitLink) != 0) {
        return 42;
    }
    if ((accessibilityTraits & UIAccessibilityTraitImage) != 0) {
        return 43;
    }
    if ((accessibilityTraits & UIAccessibilityTraitSearchField) != 0) {
        return 45;
    }
    if ((accessibilityTraits & UIAccessibilityTraitStaticText) != 0 ||
        (accessibilityTraits & UIAccessibilityTraitHeader) != 0) {
        return 48;
    }
    if ((accessibilityTraits & UIAccessibilityTraitAdjustable) != 0) {
        return 33;
    }
    if ([object isKindOfClass:UILabel.class]) {
        return 48;
    }
    if ([object isKindOfClass:UIImageView.class]) {
        return 43;
    }
    if ([object isKindOfClass:UIStackView.class]) {
        return 3;
    }
    return 1;
}

static NSString *IOSUseDOMElementTypeName(NSInteger elementType) {
    switch (elementType) {
        case 1: return @"-";
        case 2: return @"App";
        case 3: return @"Group";
        case 4: return @"Window";
        case 7: return @"Alert";
        case 8: return @"Dialog";
        case 9: return @"Button";
        case 19: return @"Keyboard";
        case 20: return @"Key";
        case 21: return @"NavigationBar";
        case 22: return @"TabBar";
        case 24: return @"Toolbar";
        case 25: return @"StatusBar";
        case 26: return @"Table";
        case 32: return @"Collection";
        case 33: return @"Slider";
        case 34: return @"Page";
        case 35: return @"ProgressIndicator";
        case 36: return @"ActivityIndicator";
        case 37: return @"SegmentedControl";
        case 38: return @"Picker";
        case 39: return @"PickerWheel";
        case 40: return @"Switch";
        case 41: return @"Toggle";
        case 42: return @"Link";
        case 43: return @"Image";
        case 44: return @"Icon";
        case 45:
        case 49:
            return @"Input";
        case 46: return @"Scroll";
        case 48: return @"Text";
        case 50: return @"SecureInput";
        case 51: return @"DatePicker";
        case 52: return @"TextView";
        case 57: return @"Map";
        case 58: return @"Web";
        case 75: return @"Cell";
        default: return @"-";
    }
}

static BOOL IOSUseDOMObjectIsOpaqueSurface(
    id object,
    NSString * _Nullable label,
    NSString * _Nullable value
) {
    if (label.length > 0 || value.length > 0 ||
        ![object isKindOfClass:UIView.class]) {
        return NO;
    }
    UIView *view = object;
    NSString *viewClass = NSStringFromClass(view.class);
    NSString *layerClass = NSStringFromClass(view.layer.class);
    return [viewClass rangeOfString:@"MTKView"].location != NSNotFound ||
        [viewClass rangeOfString:@"Metal"].location != NSNotFound ||
        [layerClass rangeOfString:@"CAMetalLayer"].location != NSNotFound ||
        [layerClass rangeOfString:@"Metal"].location != NSNotFound;
}

static IOSUseDOMNode * _Nullable IOSUseDOMBuildNode(
    id object,
    NSUInteger depth,
    BOOL ancestorVisible,
    BOOL ancestorDisabled,
    CGRect ancestorClip,
    IOSUseDOMCaptureContext *context
) {
    if (context.failureMessage != nil || object == nil) {
        return nil;
    }
    if (depth > IOSUseDOMMaximumDepth) {
        context.failureMessage =
            @"accessibility tree exceeded the 64-level depth limit";
        return nil;
    }
    if ([context.visited containsObject:object]) {
        return nil;
    }
    if (context.visitedCount >= IOSUseDOMMaximumVisitedNodeCount) {
        context.failureMessage =
            @"accessibility tree exceeded the 8192-node traversal limit";
        return nil;
    }
    [context.visited addObject:object];
    context.visitedCount += 1;

    BOOL isAccessibilityElement = IOSUseDOMBoolValue(
        object,
        NSSelectorFromString(@"isAccessibilityElement"),
        NO
    );
    unsigned long long accessibilityTraits =
        IOSUseDOMAccessibilityTraits(object);
    id identifierObject = IOSUseDOMObjectValue(
        object,
        NSSelectorFromString(@"accessibilityIdentifier")
    );
    NSString *identifier = IOSUseDOMBoundedString(identifierObject, context);
    if (context.failureMessage != nil) {
        return nil;
    }
    NSString *label = identifier;
    if (label.length == 0) {
        id labelObject = IOSUseDOMObjectValue(
            object,
            NSSelectorFromString(@"accessibilityLabel")
        );
        label = IOSUseDOMBoundedString(labelObject, context);
        if (context.failureMessage != nil) {
            return nil;
        }
    }
    id valueObject = IOSUseDOMObjectValue(
        object,
        NSSelectorFromString(@"accessibilityValue")
    );
    NSString *value = IOSUseDOMBoundedString(valueObject, context);
    if (context.failureMessage != nil) {
        return nil;
    }
    if (value.length == 0 &&
        ([object isKindOfClass:UITextField.class] ||
         [object isKindOfClass:UISearchBar.class])) {
        id placeholderObject = IOSUseDOMObjectValue(
            object,
            NSSelectorFromString(@"placeholder")
        );
        value = IOSUseDOMBoundedString(placeholderObject, context);
        if (context.failureMessage != nil) {
            return nil;
        }
    }
    if ([value isEqualToString:label]) {
        value = nil;
    }

    BOOL hierarchyVisible =
        ancestorVisible && IOSUseDOMObjectHierarchyVisible(object);
    BOOL enabled = (accessibilityTraits & UIAccessibilityTraitNotEnabled) == 0;
    if ([object isKindOfClass:UIControl.class]) {
        enabled = enabled && [(UIControl *)object isEnabled];
    }
    BOOL disabled = ancestorDisabled || !enabled;
    BOOL selected =
        (accessibilityTraits & UIAccessibilityTraitSelected) != 0;
    if ([object isKindOfClass:UIControl.class]) {
        selected = selected || [(UIControl *)object isSelected];
    }
    BOOL focused = IOSUseDOMBoolValue(
        object,
        NSSelectorFromString(@"accessibilityElementIsFocused"),
        NO
    );
    if ([object isKindOfClass:UIResponder.class]) {
        focused = focused || [(UIResponder *)object isFirstResponder];
    }
    CGRect rect = IOSUseDOMObjectRect(object);
    BOOL hasRect = IOSUseDOMRectHasArea(rect);
    CGRect effectiveClip = ancestorClip;
    if (hasRect && IOSUseDOMObjectClipsDescendants(object)) {
        effectiveClip = CGRectIntersection(ancestorClip, rect);
    }
    BOOL intersectsVisibleClip = hasRect &&
        IOSUseDOMRectHasArea(
            CGRectIntersection(rect, effectiveClip)
        );
    BOOL invisible = !hierarchyVisible ||
        (hasRect && !intersectsVisibleClip) ||
        (isAccessibilityElement && !hasRect);

    BOOL hasAutomationChildren = NO;
    NSArray *childObjects = IOSUseDOMChildren(
        object,
        isAccessibilityElement,
        &hasAutomationChildren,
        context
    );
    if (context.failureMessage != nil) {
        return nil;
    }
    NSMutableArray<IOSUseDOMNode *> *children =
        [NSMutableArray arrayWithCapacity:childObjects.count];
    for (id childObject in childObjects) {
        IOSUseDOMNode *child = IOSUseDOMBuildNode(
            childObject,
            depth + 1,
            hierarchyVisible,
            disabled,
            effectiveClip,
            context
        );
        if (context.failureMessage != nil) {
            return nil;
        }
        if (child != nil) {
            [children addObject:child];
        }
    }

    IOSUseDOMNode *node = [IOSUseDOMNode new];
    node.nodeID = [NSString stringWithFormat:
        @"g%llu-n%lu",
        context.generation,
        (unsigned long)context.nextNodeOrdinal
    ];
    context.nextNodeOrdinal += 1;
    node.elementType = IOSUseDOMElementType(object, accessibilityTraits);
    node.typeName = IOSUseDOMElementTypeName(node.elementType);
    node.label = label;
    node.value = value;
    node.rect = rect;
    node.hasRect = hasRect;
    node.disabled = disabled;
    node.invisible = invisible;
    node.selected = selected;
    node.focused = focused;
    node.children = children;
    node.opaque = IOSUseDOMObjectIsOpaqueSurface(
        object,
        label,
        value
    );
    (void)hasAutomationChildren;
    return node;
}

static NSArray<NSString *> *IOSUseDOMTraitsForNode(
    IOSUseDOMNode *node,
    BOOL opaque
) {
    NSMutableArray<NSString *> *traits =
        [NSMutableArray arrayWithObject:node.typeName];
    if (opaque) {
        [traits addObject:@"opaque"];
    }
    if (node.disabled) {
        [traits addObject:@"disabled"];
    }
    if (node.invisible) {
        [traits addObject:@"invisible"];
    }
    if (node.selected) {
        [traits addObject:@"selected"];
    }
    if (node.focused) {
        [traits addObject:@"focused"];
    }
    return traits;
}

static BOOL IOSUseDOMRectsApproximatelyEqual(CGRect lhs, CGRect rhs) {
    return fabs(lhs.origin.x - rhs.origin.x) <= 0.5 &&
        fabs(lhs.origin.y - rhs.origin.y) <= 0.5 &&
        fabs(lhs.size.width - rhs.size.width) <= 0.5 &&
        fabs(lhs.size.height - rhs.size.height) <= 0.5;
}

static NSArray<IOSUseCleanNode *> *IOSUseDOMSortedCleanNodes(
    NSArray<IOSUseCleanNode *> *nodes
) {
    if (nodes.count < 2) {
        return nodes;
    }
    CGFloat previousY = nodes.firstObject.source.hasRect
        ? CGRectGetMinY(nodes.firstObject.source.rect)
        : 0;
    BOOL requiresSort = NO;
    for (IOSUseCleanNode *node in [nodes subarrayWithRange:
             NSMakeRange(1, nodes.count - 1)]) {
        CGFloat y = node.source.hasRect
            ? CGRectGetMinY(node.source.rect)
            : 0;
        if (y < previousY) {
            requiresSort = YES;
            break;
        }
        previousY = y;
    }
    if (!requiresSort) {
        return nodes;
    }
    return [nodes sortedArrayUsingComparator:
        ^NSComparisonResult(IOSUseCleanNode *lhs, IOSUseCleanNode *rhs) {
            CGFloat lhsY = lhs.source.hasRect
                ? CGRectGetMinY(lhs.source.rect)
                : 0;
            CGFloat rhsY = rhs.source.hasRect
                ? CGRectGetMinY(rhs.source.rect)
                : 0;
            if (lhsY < rhsY) {
                return NSOrderedAscending;
            }
            if (lhsY > rhsY) {
                return NSOrderedDescending;
            }
            return NSOrderedSame;
        }];
}

static NSArray<IOSUseCleanNode *> *IOSUseDOMCleanNode(IOSUseDOMNode *node) {
    NSMutableArray<IOSUseCleanNode *> *cleanChildren =
        [NSMutableArray array];
    for (IOSUseDOMNode *child in node.children) {
        [cleanChildren addObjectsFromArray:IOSUseDOMCleanNode(child)];
    }

    BOOL effectiveOpaque = node.opaque && cleanChildren.count == 0;
    BOOL promote = node.elementType == 4 ||
        (node.elementType == 1 &&
         node.label.length == 0 &&
         !effectiveOpaque);
    if (promote) {
        return IOSUseDOMSortedCleanNodes(cleanChildren);
    }

    if (node.label.length == 0 &&
        node.value.length == 0 &&
        cleanChildren.count == 0 &&
        !effectiveOpaque) {
        return @[];
    }

    NSArray<NSString *> *traits =
        IOSUseDOMTraitsForNode(node, effectiveOpaque);
    NSArray<IOSUseCleanNode *> *effectiveChildren = cleanChildren;
    if (effectiveChildren.count == 1) {
        IOSUseCleanNode *child = effectiveChildren.firstObject;
        BOOL sameLabel =
            (node.label == nil && child.source.label == nil) ||
            [node.label isEqualToString:child.source.label];
        if (node.elementType == child.source.elementType &&
            node.hasRect == child.source.hasRect &&
            (!node.hasRect ||
             IOSUseDOMRectsApproximatelyEqual(node.rect, child.source.rect)) &&
            sameLabel) {
            IOSUseCleanNode *merged = [IOSUseCleanNode new];
            merged.source = node;
            merged.displayLabel = node.label;
            merged.opaque = effectiveOpaque;
            merged.traits = traits;
            merged.children = child.children;
            return @[merged];
        }
        if (node.label.length > 0 &&
            [node.label isEqualToString:child.source.label]) {
            NSMutableArray<NSString *> *mergedTraits =
                [traits mutableCopy];
            for (NSString *trait in child.traits) {
                if (![mergedTraits containsObject:trait]) {
                    [mergedTraits addObject:trait];
                }
            }
            IOSUseCleanNode *merged = [IOSUseCleanNode new];
            merged.source = node;
            merged.displayLabel = node.label;
            merged.opaque = effectiveOpaque;
            merged.traits = mergedTraits;
            merged.children = child.children;
            return @[merged];
        }
    }
    effectiveChildren = IOSUseDOMSortedCleanNodes(effectiveChildren);
    IOSUseCleanNode *clean = [IOSUseCleanNode new];
    clean.source = node;
    clean.displayLabel = node.label;
    clean.opaque = effectiveOpaque;
    clean.traits = traits;
    clean.children = effectiveChildren;
    return @[clean];
}

static BOOL IOSUseDOMShouldAutoLabel(IOSUseCleanNode *node) {
    if (node.opaque) {
        return NO;
    }
    if (node.children.count > 0 || node.source.value.length > 0) {
        return YES;
    }
    switch (node.source.elementType) {
        case 9:
        case 26:
        case 32:
        case 33:
        case 34:
        case 37:
        case 38:
        case 39:
        case 40:
        case 42:
        case 43:
        case 44:
        case 45:
        case 46:
        case 49:
        case 52:
        case 58:
        case 75:
            return YES;
        default:
            return node.source.hasRect;
    }
}

static BOOL IOSUseDOMAssignChildLabels(
    IOSUseCleanNode *parent,
    NSMutableDictionary<NSString *, NSNumber *> *nextIndexByBaseLabel,
    IOSUseDOMCaptureContext *context
) {
    NSUInteger childCount = parent.children.count;
    for (NSUInteger index = 0; index < childCount; index += 1) {
        IOSUseCleanNode *child = parent.children[index];
        if (child.displayLabel.length == 0 &&
            IOSUseDOMShouldAutoLabel(child)) {
            NSString *parentPath = parent.displayLabel ?: @"";
            NSString *suffix = childCount > 1
                ? [NSString stringWithFormat:@"c%lu", (unsigned long)index + 1]
                : @"";
            NSString *generated = [NSString stringWithFormat:
                @"%@%@%@",
                parentPath,
                parent.source.typeName,
                suffix
            ];
            child.displayLabel =
                IOSUseDOMBoundedString(generated, context);
            if (context.failureMessage != nil) {
                return NO;
            }
        }
        NSString *baseLabel = child.displayLabel;
        if (baseLabel.length > 0) {
            NSInteger nextIndex =
                [nextIndexByBaseLabel[baseLabel] integerValue];
            nextIndexByBaseLabel[baseLabel] = @(nextIndex + 1);
            if (nextIndex > 0) {
                NSString *alias = [NSString stringWithFormat:
                    @"%@-%ld",
                    baseLabel,
                    (long)nextIndex
                ];
                child.displayLabel =
                    IOSUseDOMBoundedString(alias, context);
                if (context.failureMessage != nil) {
                    return NO;
                }
            }
        }
        if (!IOSUseDOMAssignChildLabels(
                child,
                nextIndexByBaseLabel,
                context
            )) {
            return NO;
        }
    }
    return YES;
}

static BOOL IOSUseDOMAssignAutoLabels(
    NSArray<IOSUseCleanNode *> *roots,
    NSString *application,
    IOSUseDOMCaptureContext *context
) {
    NSMutableDictionary<NSString *, NSNumber *> *nextIndexByBaseLabel =
        [NSMutableDictionary dictionary];
    IOSUseDOMNode *virtualSource = [IOSUseDOMNode new];
    virtualSource.elementType = 2;
    virtualSource.typeName = @"App";
    virtualSource.label = application;
    IOSUseCleanNode *virtualRoot = [IOSUseCleanNode new];
    virtualRoot.source = virtualSource;
    virtualRoot.displayLabel = application;
    virtualRoot.children = roots;
    return IOSUseDOMAssignChildLabels(
        virtualRoot,
        nextIndexByBaseLabel,
        context
    );
}

static BOOL IOSUseDOMFlattenCleanNode(
    IOSUseCleanNode *node,
    IOSUseCleanNode * _Nullable parent,
    NSMutableArray<IOSUseCleanNode *> *elements
) {
    if (elements.count >= IOSUseDOMMaximumCleanNodeCount) {
        return NO;
    }
    node.parent = parent;
    [elements addObject:node];
    for (IOSUseCleanNode *child in node.children) {
        if (!IOSUseDOMFlattenCleanNode(child, node, elements)) {
            return NO;
        }
    }
    return YES;
}

static NSArray<UIWindow *> *IOSUseDOMActiveWindows(void) {
    UIApplication *application = UIApplication.sharedApplication;
    NSMutableArray<UIWindowScene *> *scenes = [NSMutableArray array];
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        if (scene.activationState != UISceneActivationStateForegroundActive &&
            scene.activationState != UISceneActivationStateForegroundInactive) {
            continue;
        }
        [scenes addObject:(UIWindowScene *)scene];
    }
    [scenes sortUsingComparator:
        ^NSComparisonResult(UIWindowScene *lhs, UIWindowScene *rhs) {
            if (lhs.activationState < rhs.activationState) {
                return NSOrderedAscending;
            }
            if (lhs.activationState > rhs.activationState) {
                return NSOrderedDescending;
            }
            NSString *lhsID = lhs.session.persistentIdentifier ?: @"";
            NSString *rhsID = rhs.session.persistentIdentifier ?: @"";
            return [lhsID compare:rhsID];
        }];

    NSHashTable<UIWindow *> *seen = [NSHashTable hashTableWithOptions:
        NSPointerFunctionsObjectPointerPersonality |
        NSPointerFunctionsStrongMemory];
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIWindowScene *scene in scenes) {
        NSArray<UIWindow *> *sceneWindows =
            [scene.windows sortedArrayUsingComparator:
                ^NSComparisonResult(UIWindow *lhs, UIWindow *rhs) {
                    if (lhs.isKeyWindow != rhs.isKeyWindow) {
                        return lhs.isKeyWindow
                            ? NSOrderedAscending
                            : NSOrderedDescending;
                    }
                    if (lhs.windowLevel > rhs.windowLevel) {
                        return NSOrderedAscending;
                    }
                    if (lhs.windowLevel < rhs.windowLevel) {
                        return NSOrderedDescending;
                    }
                    return NSOrderedSame;
                }];
        for (UIWindow *window in sceneWindows) {
            if (![seen containsObject:window]) {
                [seen addObject:window];
                [windows addObject:window];
            }
        }
    }
    return windows;
}

static IOSUseDOMSnapshot * _Nullable IOSUseDOMBuildSnapshotOnMain(
    NSString * _Nullable *failureMessage
) {
    NSCAssert(NSThread.isMainThread, @"UIKit DOM traversal must run on main");
    NSArray<UIWindow *> *windows = IOSUseDOMActiveWindows();
    if (windows.count == 0) {
        if (failureMessage != NULL) {
            *failureMessage = @"no active UIWindowScene has a UIKit window";
        }
        return nil;
    }

    UIWindow *primaryWindow = nil;
    for (UIWindow *window in windows) {
        if (window.isKeyWindow) {
            primaryWindow = window;
            break;
        }
    }
    if (primaryWindow == nil) {
        primaryWindow = windows.firstObject;
    }
    CGRect screenBounds =
        primaryWindow.windowScene.coordinateSpace.bounds;
    if (!IOSUseDOMRectHasArea(screenBounds)) {
        screenBounds = UIScreen.mainScreen.bounds;
    }

    IOSUseDOMCaptureContext *context = [IOSUseDOMCaptureContext new];
    context.visited = [NSHashTable hashTableWithOptions:
        NSPointerFunctionsObjectPointerPersonality |
        NSPointerFunctionsStrongMemory];
    context.generation = atomic_fetch_add(&IOSUseDOMGeneration, 1) + 1;

    NSMutableArray<IOSUseDOMNode *> *rawRoots =
        [NSMutableArray arrayWithCapacity:windows.count];
    for (UIWindow *window in windows) {
        IOSUseDOMNode *root = IOSUseDOMBuildNode(
            window,
            0,
            YES,
            NO,
            screenBounds,
            context
        );
        if (context.failureMessage != nil) {
            if (failureMessage != NULL) {
                *failureMessage = context.failureMessage;
            }
            return nil;
        }
        if (root != nil) {
            [rawRoots addObject:root];
        }
    }

    NSMutableArray<IOSUseCleanNode *> *cleanRoots =
        [NSMutableArray array];
    for (IOSUseDOMNode *root in rawRoots) {
        [cleanRoots addObjectsFromArray:IOSUseDOMCleanNode(root)];
    }
    cleanRoots =
        [IOSUseDOMSortedCleanNodes(cleanRoots) mutableCopy];
    NSString *application =
        NSBundle.mainBundle.bundleIdentifier ?: @"";
    if (!IOSUseDOMAssignAutoLabels(
            cleanRoots,
            application,
            context
        )) {
        if (failureMessage != NULL) {
            *failureMessage = context.failureMessage ?:
                @"automatic DOM labels exceeded snapshot limits";
        }
        return nil;
    }
    NSMutableArray<IOSUseCleanNode *> *elements =
        [NSMutableArray array];
    for (IOSUseCleanNode *root in cleanRoots) {
        if (!IOSUseDOMFlattenCleanNode(root, nil, elements)) {
            if (failureMessage != NULL) {
                *failureMessage =
                    @"clean DOM exceeded the 4096-node response limit";
            }
            return nil;
        }
    }

    IOSUseDOMSnapshot *snapshot = [IOSUseDOMSnapshot new];
    snapshot.application = application;
    snapshot.windowSize = primaryWindow.bounds.size;
    snapshot.screenBounds = screenBounds;
    snapshot.generation = context.generation;
    snapshot.rawRoots = rawRoots;
    snapshot.cleanRoots = cleanRoots;
    snapshot.elements = elements;
    return snapshot;
}

static IOSUseDOMSnapshot * _Nullable IOSUseDOMFreshSnapshot(
    NSTimeInterval queueBudget,
    IOSUsePlayRuntimeCancellationCheck _Nullable cancellationCheck,
    NSDictionary<NSString *, id> * _Nullable *commandError
) {
    if (!isfinite(queueBudget) || queueBudget <= 0) {
        if (commandError != NULL) {
            *commandError = IOSUseDOMError(
                @"snapshot_queue_timeout",
                @"UIKit snapshot coordinator deadline expired",
                @"timeout",
                @"snapshot",
                YES,
                nil,
                0,
                @[]
            );
        }
        return nil;
    }
    if (NSThread.isMainThread) {
        NSString *failureMessage = nil;
        IOSUseDOMSnapshot *snapshot = nil;
        @try {
            snapshot = IOSUseDOMBuildSnapshotOnMain(&failureMessage);
        } @catch (NSException *exception) {
            failureMessage =
                @"UIKit accessibility getter raised an exception";
            NSLog(
                @"[ios-use-play] DOM traversal exception %@",
                exception.name
            );
        }
        if (snapshot == nil && commandError != NULL) {
            *commandError = IOSUseDOMError(
                @"snapshot_failed",
                failureMessage ?:
                    @"failed to take a fresh UIKit accessibility snapshot",
                @"lookup",
                @"snapshot",
                YES,
                nil,
                0,
                @[]
            );
        }
        return snapshot;
    }

    IOSUseDOMSnapshotRequest *request =
        [IOSUseDOMSnapshotRequest new];
    request.expiresAt = CFAbsoluteTimeGetCurrent() + queueBudget;
    request.completion = dispatch_semaphore_create(0);
    dispatch_async(IOSUseDOMSnapshotCoordinator(), ^{
        @autoreleasepool {
            @try {
                BOOL shouldStart = NO;
                @synchronized (request) {
                    shouldStart =
                        !request.cancelled &&
                        CFAbsoluteTimeGetCurrent() <= request.expiresAt;
                    if (!shouldStart && !request.cancelled) {
                        request.deadlineExpired = YES;
                    }
                }
                if (!shouldStart) {
                    return;
                }

                __block IOSUseDOMSnapshot *snapshot = nil;
                __block NSString *failureMessage = nil;
                dispatch_semaphore_t mainCompletion =
                    dispatch_semaphore_create(0);
                dispatch_async(dispatch_get_main_queue(), ^{
                    @try {
                        BOOL shouldCollect = NO;
                        @synchronized (request) {
                            shouldCollect =
                                !request.cancelled &&
                                CFAbsoluteTimeGetCurrent() <=
                                    request.expiresAt;
                            if (!shouldCollect && !request.cancelled) {
                                request.deadlineExpired = YES;
                            }
                        }
                        if (shouldCollect) {
                            snapshot = IOSUseDOMBuildSnapshotOnMain(
                                &failureMessage
                            );
                        }
                    } @catch (NSException *exception) {
                        failureMessage =
                            @"UIKit accessibility getter raised an exception";
                        NSLog(
                            @"[ios-use-play] DOM traversal exception %@",
                            exception.name
                        );
                    } @finally {
                        dispatch_semaphore_signal(mainCompletion);
                    }
                });
                dispatch_semaphore_wait(
                    mainCompletion,
                    DISPATCH_TIME_FOREVER
                );
                @synchronized (request) {
                    if (!request.cancelled) {
                        request.snapshot = snapshot;
                        request.failureMessage = failureMessage;
                    }
                }
            } @catch (NSException *exception) {
                @synchronized (request) {
                    if (!request.cancelled) {
                        request.failureMessage =
                            @"snapshot coordinator raised an exception";
                    }
                }
                NSLog(
                    @"[ios-use-play] DOM coordinator exception %@",
                    exception.name
                );
            } @finally {
                dispatch_semaphore_signal(request.completion);
            }
        }
    });

    for (;;) {
        NSTimeInterval remaining =
            request.expiresAt - CFAbsoluteTimeGetCurrent();
        if (remaining <= 0) {
            @synchronized (request) {
                request.cancelled = YES;
                request.deadlineExpired = YES;
            }
            if (commandError != NULL) {
                *commandError = IOSUseDOMError(
                    @"snapshot_queue_timeout",
                    @"UIKit snapshot coordinator deadline expired",
                    @"timeout",
                    @"snapshot",
                    YES,
                    nil,
                    0,
                    @[]
                );
            }
            return nil;
        }
        NSTimeInterval waitSlice = MIN(remaining, 0.1);
        dispatch_time_t sliceDeadline = dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)(waitSlice * NSEC_PER_SEC)
        );
        if (dispatch_semaphore_wait(
                request.completion,
                sliceDeadline
            ) == 0) {
            break;
        }
        if (cancellationCheck != nil && cancellationCheck()) {
            @synchronized (request) {
                request.cancelled = YES;
            }
            if (commandError != NULL) {
                *commandError = IOSUseDOMError(
                    @"request_cancelled",
                    @"waitFor client disconnected",
                    @"protocol",
                    @"wait",
                    NO,
                    nil,
                    0,
                    @[]
                );
            }
            return nil;
        }
    }

    IOSUseDOMSnapshot *snapshot = nil;
    NSString *failureMessage = nil;
    BOOL deadlineExpired = NO;
    @synchronized (request) {
        snapshot = request.snapshot;
        failureMessage = request.failureMessage;
        deadlineExpired = request.deadlineExpired;
    }
    if (snapshot == nil && commandError != NULL) {
        *commandError = IOSUseDOMError(
            deadlineExpired
                ? @"snapshot_queue_timeout"
                : @"snapshot_failed",
            failureMessage ?: (
                deadlineExpired
                    ? @"UIKit snapshot coordinator deadline expired"
                    : @"failed to take a fresh UIKit accessibility snapshot"
            ),
            deadlineExpired ? @"timeout" : @"lookup",
            @"snapshot",
            YES,
            nil,
            0,
            @[]
        );
    }
    return snapshot;
}

static BOOL IOSUseDOMAppendRawLine(
    NSMutableString *raw,
    NSString *line,
    NSUInteger *rawBytes
) {
    NSUInteger lineBytes =
        [line lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (lineBytes > IOSUseDOMMaximumRawStringBytes ||
        *rawBytes > IOSUseDOMMaximumRawStringBytes - lineBytes) {
        return NO;
    }
    [raw appendString:line];
    *rawBytes += lineBytes;
    return YES;
}

static BOOL IOSUseDOMAppendRawNode(
    IOSUseDOMNode *node,
    NSUInteger depth,
    NSMutableString *raw,
    NSUInteger *rawBytes
) {
    NSString *indent =
        [@"" stringByPaddingToLength:depth * 2
                          withString:@" "
                     startingAtIndex:0];
    NSArray<NSString *> *traits = IOSUseDOMTraitsForNode(
        node,
        node.opaque && node.children.count == 0
    );
    NSString *traitText = [traits componentsJoinedByString:@","];
    NSString *title = node.label.length > 0
        ? node.label
        : (node.value.length > 0 ? [@"=" stringByAppendingString:node.value]
                                 : node.typeName);
    if (node.label.length > 0 && node.value.length > 0) {
        title = [NSString stringWithFormat:@"%@=%@", node.label, node.value];
    }
    NSString *rect = node.hasRect
        ? [NSString stringWithFormat:
              @" (%.1f,%.1f,%.1f,%.1f)",
              node.rect.origin.x,
              node.rect.origin.y,
              node.rect.size.width,
              node.rect.size.height]
        : @"";
    NSString *line = [NSString stringWithFormat:
        @"%@- %@ [%@]%@\n",
        indent,
        title,
        traitText,
        rect
    ];
    if (!IOSUseDOMAppendRawLine(raw, line, rawBytes)) {
        return NO;
    }
    for (IOSUseDOMNode *child in node.children) {
        if (!IOSUseDOMAppendRawNode(
                child,
                depth + 1,
                raw,
                rawBytes
            )) {
            return NO;
        }
    }
    return YES;
}

static NSDictionary<NSString *, id> *IOSUseDOMElementJSON(
    IOSUseCleanNode *node
) {
    NSMutableDictionary<NSString *, id> *element = [@{
        @"nodeId": node.source.nodeID,
        @"elemType": @(node.source.elementType),
        @"traits": node.traits,
        @"childCount": @(node.children.count),
        @"label": node.displayLabel ?: @"",
        @"value": node.source.value ?: @"",
    } mutableCopy];
    if (node.source.hasRect) {
        element[@"rect"] = IOSUseDOMRectJSON(node.source.rect);
    }
    return element;
}

static NSArray<NSString *> *IOSUseDOMAncestorNames(
    IOSUseCleanNode *node
) {
    NSMutableArray<NSString *> *reversed = [NSMutableArray array];
    IOSUseCleanNode *parent = node.parent;
    while (parent != nil && reversed.count < IOSUseDOMMaximumDepth) {
        NSString *name = parent.displayLabel.length > 0
            ? [NSString stringWithFormat:
                  @"%@[%@]",
                  parent.source.typeName,
                  parent.displayLabel]
            : parent.source.typeName;
        [reversed addObject:name];
        parent = parent.parent;
    }
    return [[[reversed reverseObjectEnumerator] allObjects] copy];
}

static NSDictionary<NSString *, id> *IOSUseDOMElementSummary(
    IOSUseCleanNode * _Nullable node
) {
    if (node == nil) {
        return @{
            @"elemType": @0,
            @"label": @"",
            @"ancestors": @[],
        };
    }
    NSMutableDictionary<NSString *, id> *element = [@{
        @"elemType": @(node.source.elementType),
        @"label": node.displayLabel ?: @"",
        @"ancestors": IOSUseDOMAncestorNames(node),
    } mutableCopy];
    if (node.source.hasRect) {
        element[@"rect"] = IOSUseDOMRectJSON(node.source.rect);
    }
    return element;
}

static NSDictionary<NSString *, id> *IOSUseDOMFindMatchJSON(
    IOSUseCleanNode *node
) {
    NSMutableDictionary<NSString *, id> *element = [@{
        @"elemType": @(node.source.elementType),
        @"label": node.displayLabel ?: @"",
        @"traits": node.traits,
        @"value": node.source.value ?: @"",
        @"ancestors": IOSUseDOMAncestorNames(node),
    } mutableCopy];
    if (node.source.hasRect) {
        element[@"rect"] = IOSUseDOMRectJSON(node.source.rect);
    }
    return element;
}

static NSArray<NSDictionary<NSString *, id> *> *IOSUseDOMCandidatesJSON(
    NSArray<IOSUseCleanNode *> *matches,
    NSString * _Nullable rejection
) {
    NSMutableArray<NSDictionary<NSString *, id> *> *candidates =
        [NSMutableArray array];
    NSUInteger count = MIN(matches.count, IOSUseDOMMaximumErrorCandidates);
    for (NSUInteger index = 0; index < count; index += 1) {
        [candidates addObject:@{
            @"element": IOSUseDOMFindMatchJSON(matches[index]),
            @"rejectedBy": rejection == nil ? @[] : @[rejection],
        }];
    }
    return candidates;
}

static NSString *IOSUseDOMNormalizeSearchText(NSString *text) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) {
        return @"";
    }
    static NSCharacterSet *ignoredCharacters;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ignoredCharacters = [
            NSCharacterSet.whitespaceAndNewlineCharacterSet
            mutableCopy
        ];
        [(NSMutableCharacterSet *)ignoredCharacters
            addCharactersInString:@"-_:/()[]{}.,'\""];
    });
    NSArray<NSString *> *components =
        [trimmed componentsSeparatedByCharactersInSet:ignoredCharacters];
    return [[components componentsJoinedByString:@""] lowercaseString];
}

static NSArray<NSString *> *IOSUseDOMSearchTexts(IOSUseCleanNode *node) {
    NSMutableArray<NSString *> *texts = [NSMutableArray arrayWithCapacity:2];
    if (node.displayLabel.length > 0) {
        [texts addObject:node.displayLabel];
    }
    if (node.source.value.length > 0 &&
        ![texts containsObject:node.source.value]) {
        [texts addObject:node.source.value];
    }
    return texts;
}

static BOOL IOSUseDOMCleanNodeVisible(
    IOSUseCleanNode *node,
    CGRect bounds
) {
    return !node.source.invisible &&
        node.source.hasRect &&
        IOSUseDOMRectHasArea(
            CGRectIntersection(node.source.rect, bounds)
        );
}

static BOOL IOSUseDOMNodeHasRequiredTraits(
    IOSUseCleanNode *node,
    NSString *traits
) {
    if (traits.length == 0) {
        return YES;
    }
    NSArray<NSString *> *parts = [traits componentsSeparatedByString:@","];
    NSMutableSet<NSString *> *available = [NSMutableSet set];
    for (NSString *trait in node.traits) {
        [available addObject:trait.lowercaseString];
    }
    for (NSString *part in parts) {
        NSString *required = [[part stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceCharacterSet] lowercaseString];
        if (required.length > 0 && ![available containsObject:required]) {
            return NO;
        }
    }
    return YES;
}

static IOSUseDOMSelectorResult *IOSUseDOMSelect(
    IOSUseDOMSnapshot *snapshot,
    NSString *query,
    NSString *traits,
    NSNumber * _Nullable childIndex,
    NSInteger matchMode,
    NSRegularExpression * _Nullable expression
) {
    NSString *normalizedQuery = matchMode == 2
        ? query
        : IOSUseDOMNormalizeSearchText(query);
    NSMutableArray<IOSUseCleanNode *> *containsMatches =
        [NSMutableArray array];
    NSMutableArray<IOSUseCleanNode *> *contentMatches =
        [NSMutableArray array];

    for (IOSUseCleanNode *element in snapshot.elements) {
        if (!IOSUseDOMCleanNodeVisible(element, snapshot.screenBounds)) {
            continue;
        }
        NSArray<NSString *> *texts = IOSUseDOMSearchTexts(element);
        BOOL exact = NO;
        BOOL contains = NO;
        BOOL regex = NO;
        for (NSString *text in texts) {
            if (matchMode == 2) {
                NSRange range = NSMakeRange(0, text.length);
                regex = [expression firstMatchInString:text
                                               options:0
                                                 range:range] != nil;
                if (regex) {
                    break;
                }
                continue;
            }
            NSString *normalized = IOSUseDOMNormalizeSearchText(text);
            exact = [normalized isEqualToString:normalizedQuery];
            contains = !exact &&
                [normalized rangeOfString:normalizedQuery].location !=
                    NSNotFound;
            if (exact) {
                break;
            }
        }
        if (matchMode == 0 && exact) {
            // Standard mode deliberately keeps the first preorder exact match.
            [contentMatches addObject:element];
            break;
        }
        if (matchMode == 0 && contains) {
            [containsMatches addObject:element];
        } else if (matchMode == 1 && exact) {
            [contentMatches addObject:element];
        } else if (matchMode == 2 && regex) {
            [contentMatches addObject:element];
        }
    }
    if (matchMode == 0 && contentMatches.count == 0) {
        contentMatches = containsMatches;
    }

    NSMutableArray<IOSUseCleanNode *> *filtered =
        [NSMutableArray array];
    for (IOSUseCleanNode *element in contentMatches) {
        if (IOSUseDOMNodeHasRequiredTraits(element, traits)) {
            [filtered addObject:element];
        }
    }
    if (childIndex != nil) {
        NSMutableArray<IOSUseCleanNode *> *children =
            [NSMutableArray array];
        NSInteger requested = childIndex.integerValue;
        for (IOSUseCleanNode *parent in filtered) {
            NSInteger resolved = requested >= 0
                ? requested
                : (NSInteger)parent.children.count + requested;
            if (resolved < 0 ||
                resolved >= (NSInteger)parent.children.count) {
                continue;
            }
            IOSUseCleanNode *child = parent.children[(NSUInteger)resolved];
            if (IOSUseDOMCleanNodeVisible(child, snapshot.screenBounds)) {
                [children addObject:child];
            }
        }
        filtered = children;
    }

    IOSUseDOMSelectorResult *result = [IOSUseDOMSelectorResult new];
    result.matches = filtered;
    if (filtered.count == 0) {
        result.state = IOSUseDOMSelectorStateNotFound;
    } else if (filtered.count == 1) {
        result.state = IOSUseDOMSelectorStateFound;
    } else {
        result.state = IOSUseDOMSelectorStateAmbiguous;
    }
    return result;
}

static BOOL IOSUseDOMDictionaryHasExactlyKeys(
    NSDictionary<NSString *, id> *dictionary,
    NSSet<NSString *> *required,
    NSSet<NSString *> *optional
) {
    NSSet<NSString *> *actual =
        [NSSet setWithArray:dictionary.allKeys];
    if (![required isSubsetOfSet:actual]) {
        return NO;
    }
    NSMutableSet<NSString *> *allowed = [required mutableCopy];
    [allowed unionSet:optional];
    return [actual isSubsetOfSet:allowed];
}

NSDictionary<NSString *, id> *IOSUsePlayRuntimeDOMCommand(
    NSDictionary<NSString *, id> *arguments,
    NSDictionary<NSString *, id> **commandError
) {
    NSSet<NSString *> *keys = [NSSet setWithArray:@[
        @"raw",
        @"fresh",
        @"waitQuiescence",
    ]];
    if (![arguments isKindOfClass:NSDictionary.class] ||
        !IOSUseDOMDictionaryHasExactlyKeys(
            arguments,
            keys,
            [NSSet set]
        ) ||
        !IOSUseDOMIsBoolean(arguments[@"raw"]) ||
        !IOSUseDOMIsBoolean(arguments[@"fresh"]) ||
        !IOSUseDOMIsBoolean(arguments[@"waitQuiescence"])) {
        if (commandError != NULL) {
            *commandError = IOSUseDOMValidationError(
                @"dom arguments must contain raw, fresh, and waitQuiescence booleans",
                nil
            );
        }
        return nil;
    }
    BOOL waitQuiescence = [arguments[@"waitQuiescence"] boolValue];
    if (waitQuiescence) {
        if (commandError != NULL) {
            *commandError = IOSUseDOMValidationError(
                @"dom waitQuiescence is unavailable in the injected runtime",
                nil
            );
        }
        return nil;
    }
    // The injected runtime always traverses UIKit afresh, so both values of
    // `fresh` intentionally select the same stronger snapshot behavior.
    BOOL requestedFresh = [arguments[@"fresh"] boolValue];
    (void)requestedFresh;

    NSDictionary<NSString *, id> *snapshotError = nil;
    IOSUseDOMSnapshot *snapshot = IOSUseDOMFreshSnapshot(
        IOSUseDOMMainThreadTimeoutSeconds,
        nil,
        &snapshotError
    );
    if (snapshot == nil) {
        if (commandError != NULL) {
            *commandError = snapshotError;
        }
        return nil;
    }
    BOOL rawRequested = [arguments[@"raw"] boolValue];
    NSString *rawString = @"";
    NSArray<NSDictionary<NSString *, id> *> *elements = @[];
    if (rawRequested) {
        NSMutableString *raw = [NSMutableString string];
        NSUInteger rawBytes = 0;
        for (IOSUseDOMNode *root in snapshot.rawRoots) {
            if (!IOSUseDOMAppendRawNode(root, 0, raw, &rawBytes)) {
                if (commandError != NULL) {
                    *commandError = IOSUseDOMError(
                        @"snapshot_failed",
                        @"raw DOM exceeded the 524288-byte string limit",
                        @"lookup",
                        @"snapshot",
                        NO,
                        nil,
                        0,
                        @[]
                    );
                }
                return nil;
            }
        }
        rawString = raw;
    } else {
        NSMutableArray<NSDictionary<NSString *, id> *> *serialized =
            [NSMutableArray arrayWithCapacity:snapshot.elements.count];
        for (IOSUseCleanNode *element in snapshot.elements) {
            [serialized addObject:IOSUseDOMElementJSON(element)];
        }
        elements = serialized;
    }
    return @{
        @"app": snapshot.application,
        @"windowSize": @{
            @"x": @(snapshot.windowSize.width),
            @"y": @(snapshot.windowSize.height),
        },
        @"raw": rawString,
        @"snapshotGeneration": @(snapshot.generation),
        @"elements": elements,
    };
}

NSDictionary<NSString *, id> *IOSUsePlayRuntimeWaitForCommand(
    NSDictionary<NSString *, id> *arguments,
    IOSUsePlayRuntimeCancellationCheck cancellationCheck,
    NSDictionary<NSString *, id> **commandError
) {
    NSSet<NSString *> *argumentKeys = [NSSet setWithArray:@[
        @"target",
        @"timeout",
        @"gone",
        @"matchMode",
    ]];
    if (![arguments isKindOfClass:NSDictionary.class] ||
        !IOSUseDOMDictionaryHasExactlyKeys(
            arguments,
            argumentKeys,
            [NSSet set]
        ) ||
        ![arguments[@"target"] isKindOfClass:NSDictionary.class] ||
        !IOSUseDOMIsNumber(arguments[@"timeout"]) ||
        !IOSUseDOMIsBoolean(arguments[@"gone"]) ||
        !IOSUseDOMIsInteger(arguments[@"matchMode"])) {
        if (commandError != NULL) {
            *commandError = IOSUseDOMValidationError(
                @"waitFor arguments do not match the runtime schema",
                nil
            );
        }
        return nil;
    }
    NSDictionary<NSString *, id> *targetArguments = arguments[@"target"];
    NSSet<NSString *> *requiredTargetKeys =
        [NSSet setWithArray:@[@"label", @"traits"]];
    NSSet<NSString *> *optionalTargetKeys =
        [NSSet setWithObject:@"cindex"];
    if (!IOSUseDOMDictionaryHasExactlyKeys(
            targetArguments,
            requiredTargetKeys,
            optionalTargetKeys
        ) ||
        ![targetArguments[@"label"] isKindOfClass:NSString.class] ||
        ![targetArguments[@"traits"] isKindOfClass:NSString.class] ||
        (targetArguments[@"cindex"] != nil &&
         !IOSUseDOMIsInteger(targetArguments[@"cindex"]))) {
        if (commandError != NULL) {
            *commandError = IOSUseDOMValidationError(
                @"waitFor target must contain label, traits, and an optional integer cindex",
                nil
            );
        }
        return nil;
    }

    NSString *label = [targetArguments[@"label"]
        stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *traits = targetArguments[@"traits"];
    NSNumber *childIndex = targetArguments[@"cindex"];
    NSDictionary<NSString *, id> *target =
        IOSUseDOMTargetJSON(label, traits, childIndex);
    if (label.length == 0 || label.length > IOSUseDOMMaximumStringLength) {
        if (commandError != NULL) {
            *commandError = IOSUseDOMValidationError(
                @"waitFor target label must contain 1 to 4096 characters",
                target
            );
        }
        return nil;
    }
    if (traits.length > IOSUseDOMMaximumStringLength) {
        if (commandError != NULL) {
            *commandError = IOSUseDOMValidationError(
                @"waitFor traits must contain at most 4096 characters",
                target
            );
        }
        return nil;
    }
    if (childIndex != nil &&
        (childIndex.longLongValue < INT32_MIN ||
         childIndex.longLongValue > INT32_MAX)) {
        if (commandError != NULL) {
            *commandError = IOSUseDOMValidationError(
                @"waitFor cindex must fit a signed 32-bit integer",
                nil
            );
        }
        return nil;
    }
    double requestedTimeout = [arguments[@"timeout"] doubleValue];
    if (!isfinite(requestedTimeout) || requestedTimeout < 0) {
        if (commandError != NULL) {
            *commandError = IOSUseDOMValidationError(
                @"waitFor timeout must be a finite nonnegative number",
                target
            );
        }
        return nil;
    }
    double timeout = requestedTimeout > 0
        ? requestedTimeout
        : IOSUseDOMWaitDefaultSeconds;
    if (timeout > IOSUseDOMWaitMaximumSeconds) {
        if (commandError != NULL) {
            *commandError = IOSUseDOMValidationError(
                @"waitFor timeout must be at most 300 seconds",
                target
            );
        }
        return nil;
    }
    NSInteger matchMode = [arguments[@"matchMode"] integerValue];
    if (matchMode < 0 || matchMode > 2) {
        if (commandError != NULL) {
            *commandError = IOSUseDOMValidationError(
                @"waitFor matchMode must be 0, 1, or 2",
                target
            );
        }
        return nil;
    }
    NSString *normalizedLabel = matchMode == 2
        ? label
        : IOSUseDOMNormalizeSearchText(label);
    if (normalizedLabel.length == 0) {
        if (commandError != NULL) {
            *commandError = IOSUseDOMValidationError(
                @"waitFor target is empty after selector normalization",
                target
            );
        }
        return nil;
    }
    NSRegularExpression *expression = nil;
    if (matchMode == 2) {
        NSError *regexError = nil;
        expression = [NSRegularExpression regularExpressionWithPattern:label
                                                               options:0
                                                                 error:&regexError];
        if (expression == nil) {
            if (commandError != NULL) {
                *commandError = IOSUseDOMValidationError(
                    [NSString stringWithFormat:
                        @"waitFor regular expression is invalid: %@",
                        regexError.localizedDescription ?: @"unknown error"],
                    target
                );
            }
            return nil;
        }
    }

    BOOL gone = [arguments[@"gone"] boolValue];
    CFAbsoluteTime startedAt = CFAbsoluteTimeGetCurrent();
    __attribute__((objc_precise_lifetime))
    IOSUseDOMSnapshot *lastSnapshot = nil;
    NSArray<IOSUseCleanNode *> *lastMatches = @[];
    NSString *lastSnapshotFailure = nil;
    for (;;) {
        if (cancellationCheck()) {
            if (commandError != NULL) {
                *commandError = IOSUseDOMError(
                    @"request_cancelled",
                    @"waitFor client disconnected",
                    @"protocol",
                    @"wait",
                    NO,
                    target,
                    lastMatches.count,
                    IOSUseDOMCandidatesJSON(lastMatches, nil)
                );
            }
            return nil;
        }
        __strong NSDictionary<NSString *, id> *iterationResponse = nil;
        __strong NSDictionary<NSString *, id> *iterationError = nil;
        NSTimeInterval snapshotBudget = MAX(
            0.001,
            timeout - (CFAbsoluteTimeGetCurrent() - startedAt)
        );
        @autoreleasepool {
            NSDictionary<NSString *, id> *snapshotError = nil;
            IOSUseDOMSnapshot *snapshot = IOSUseDOMFreshSnapshot(
                snapshotBudget,
                cancellationCheck,
                &snapshotError
            );
            if (snapshot != nil) {
                lastSnapshot = snapshot;
                lastSnapshotFailure = nil;
                IOSUseDOMSelectorResult *result = IOSUseDOMSelect(
                    snapshot,
                    label,
                    traits,
                    childIndex,
                    matchMode,
                    expression
                );
                lastMatches = result.matches;
                if (!gone &&
                    result.state == IOSUseDOMSelectorStateFound) {
                    double waited =
                        CFAbsoluteTimeGetCurrent() - startedAt;
                    waited = round(waited * 10000.0) / 10000.0;
                    iterationResponse = @{
                        @"element": IOSUseDOMElementSummary(
                            result.matches.firstObject
                        ),
                        @"waited": @(waited),
                        @"snapshotGeneration": @(snapshot.generation),
                    };
                }
                if (!gone &&
                    result.state == IOSUseDOMSelectorStateAmbiguous) {
                    iterationError = IOSUseDOMError(
                        @"element_ambiguous",
                        [NSString stringWithFormat:
                            @"label '%@' is ambiguous (%lu matches)",
                            label,
                            (unsigned long)result.matches.count],
                        @"lookup",
                        @"lookup",
                        YES,
                        target,
                        result.matches.count,
                        IOSUseDOMCandidatesJSON(
                            result.matches,
                            nil
                        )
                    );
                }
                if (gone &&
                    result.state == IOSUseDOMSelectorStateNotFound) {
                    double waited =
                        CFAbsoluteTimeGetCurrent() - startedAt;
                    waited = round(waited * 10000.0) / 10000.0;
                    iterationResponse = @{
                        @"element": IOSUseDOMElementSummary(nil),
                        @"waited": @(waited),
                        @"snapshotGeneration": @(snapshot.generation),
                    };
                }
            } else {
                if ([snapshotError[@"code"]
                        isEqualToString:@"request_cancelled"]) {
                    iterationError = snapshotError;
                }
                lastSnapshotFailure =
                    snapshotError[@"message"] ?:
                    @"failed to take a fresh snapshot";
            }
        }
        if (iterationError != nil) {
            if (commandError != NULL) {
                *commandError = iterationError;
            }
            return nil;
        }
        if (iterationResponse != nil) {
            return iterationResponse;
        }

        double elapsed = CFAbsoluteTimeGetCurrent() - startedAt;
        if (elapsed >= timeout) {
            // Keep the cleaned parent graph alive while timeout candidates
            // materialize their weak ancestor links.
            (void)lastSnapshot;
            NSString *suffix = lastSnapshotFailure.length > 0
                ? [NSString stringWithFormat:
                      @"; last snapshot failure: %@",
                      lastSnapshotFailure]
                : @"";
            if (gone && lastMatches.count > 0) {
                suffix = [NSString stringWithFormat:
                    @"; %lu visible selector %@ remained%@",
                    (unsigned long)lastMatches.count,
                    lastMatches.count == 1 ? @"match" : @"matches",
                    suffix];
            }
            if (commandError != NULL) {
                *commandError = IOSUseDOMError(
                    @"wait_timed_out",
                    [NSString stringWithFormat:
                        @"waitFor '%@' timed out after %.3gs%@",
                        label,
                        timeout,
                        suffix],
                    @"timeout",
                    @"wait",
                    YES,
                    target,
                    lastMatches.count,
                    IOSUseDOMCandidatesJSON(lastMatches, nil)
                );
            }
            return nil;
        }
        if (cancellationCheck()) {
            if (commandError != NULL) {
                *commandError = IOSUseDOMError(
                    @"request_cancelled",
                    @"waitFor client disconnected",
                    @"protocol",
                    @"wait",
                    NO,
                    target,
                    lastMatches.count,
                    IOSUseDOMCandidatesJSON(lastMatches, nil)
                );
            }
            return nil;
        }
        double remaining = timeout - elapsed;
        useconds_t sleepTime = IOSUseDOMWaitPollMicroseconds;
        if (remaining < 0.1) {
            sleepTime = (useconds_t)MAX(1.0, remaining * 1000000.0);
        }
        usleep(sleepTime);
    }
}
