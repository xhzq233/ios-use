#import "IOSUsePlayRuntimeDOM.h"
#import "IOSUsePlayAppKitBridge.h"

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
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
static const NSUInteger IOSUseDOMMaximumWebElementCount = 512;
static const NSUInteger IOSUseDOMMaximumWebTraversalCount = 4096;
static const NSUInteger IOSUseDOMMaximumAppKitElementCount = 512;
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
@property(nonatomic, weak, nullable) id object;
@property(nonatomic, copy) NSString *nodeID;
@property(nonatomic) unsigned long long generation;
@property(nonatomic) NSInteger elementType;
@property(nonatomic, copy) NSString *typeName;
@property(nonatomic, copy, nullable) NSString *label;
@property(nonatomic, copy, nullable) NSString *value;
@property(nonatomic, copy, nullable) NSString *identifier;
@property(nonatomic, copy, nullable) NSString *hint;
@property(nonatomic, copy) NSString *className;
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
@property(nonatomic, copy)
    NSArray<NSDictionary<NSString *, id> *> *nativeAlertActions;
@property(nonatomic, copy, nullable) NSString *failureMessage;
@end

@implementation IOSUseDOMCaptureContext
@end

@interface IOSUseDOMWebAccessibilityElement : UIAccessibilityElement
@property(nonatomic, weak) WKWebView *webView;
@property(nonatomic) NSUInteger webOrdinal;
@property(nonatomic, copy) NSString *webIdentity;
@property(nonatomic, copy) NSString *webRole;
@property(nonatomic, copy) NSString *webTag;
@property(nonatomic, copy) NSString *webLabel;
@property(nonatomic, copy) NSString *webIdentifier;
@property(nonatomic) CGRect webLocalFrame;
@property(nonatomic) CGRect webScreenFrame;
@property(nonatomic) BOOL webDisabled;
@property(nonatomic) BOOL webSecure;
@end

@implementation IOSUseDOMWebAccessibilityElement
@end

@interface IOSUseDOMAppKitAccessibilityElement : UIAccessibilityElement
@property(nonatomic, copy) NSString *appKitRole;
@property(nonatomic) BOOL appKitFocused;
@end

@implementation IOSUseDOMAppKitAccessibilityElement

- (BOOL)accessibilityElementIsFocused {
    return self.appKitFocused;
}

@end

@interface IOSUseDOMWebBridgeRecord : NSObject
@property(nonatomic, weak) WKWebView *webView;
@property(nonatomic) unsigned long long generation;
@property(nonatomic, copy) NSString *nodeID;
@property(nonatomic) NSUInteger ordinal;
@property(nonatomic, copy) NSString *identity;
@property(nonatomic, copy) NSString *role;
@property(nonatomic, copy) NSString *tag;
@property(nonatomic, copy) NSString *label;
@property(nonatomic, copy) NSString *serializedLabel;
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic) CGRect localFrame;
@property(nonatomic) CGRect screenFrame;
@property(nonatomic) BOOL disabled;
@property(nonatomic) BOOL secure;
@end

@implementation IOSUseDOMWebBridgeRecord
@end

@interface IOSUseDOMLiveIdentityRecord : NSObject
@property(nonatomic, weak, nullable) id object;
@property(nonatomic, weak, nullable) UIView *interactionView;
@property(nonatomic, weak, nullable) UIView *rawViewAncestor;
@property(nonatomic, weak, nullable) UIView *snapshotSuperview;
@property(nonatomic, weak, nullable) UIWindow *snapshotWindow;
@property(nonatomic, weak, nullable) id snapshotAccessibilityContainer;
@property(nonatomic, copy, nullable) NSString *nativeAlertActionLabel;
@property(nonatomic) CGRect nativeAlertActionFrame;
@property(nonatomic) NSInteger nativeAlertActionIndex;
@property(nonatomic, copy, nullable) NSString *semanticLabel;
@property(nonatomic, copy, nullable) NSString *identifier;
@property(nonatomic) CGRect frame;
@property(nonatomic) NSInteger elementType;
@property(nonatomic) unsigned long long accessibilityTraits;
@property(nonatomic) BOOL controlEnabled;
@property(nonatomic) NSUInteger kind;
@property(nonatomic) unsigned long long generation;
@end

@implementation IOSUseDOMLiveIdentityRecord
@end

static NSMutableDictionary<
    NSString *,
    IOSUseDOMWebBridgeRecord *
> *IOSUseDOMWebBridgeRecords;
static unsigned long long IOSUseDOMWebBridgeGeneration;
static NSMutableDictionary<
    NSString *,
    IOSUseDOMLiveIdentityRecord *
> *IOSUseDOMLiveIdentityRecords;
static unsigned long long IOSUseDOMLiveIdentityGeneration;

typedef NS_ENUM(NSUInteger, IOSUseDOMLiveIdentityKind) {
    IOSUseDOMLiveIdentityKindGeneric = 0,
    IOSUseDOMLiveIdentityKindWebProxy = 1,
    IOSUseDOMLiveIdentityKindAppKitProxy = 2,
    IOSUseDOMLiveIdentityKindNativeAlertMirror = 3,
};

static BOOL IOSUseDOMObjectBelongsToNativeAlertMirror(
    id object,
    UIView * _Nullable rawViewAncestor
);
static BOOL IOSUseDOMObjectHasNativeAlertMirrorShape(
    id object,
    UIView * _Nullable rawViewAncestor
);
static CGRect IOSUseDOMNativeAlertActionFrame(id value);
static NSDictionary<NSString *, id> * _Nullable
IOSUseDOMExactNativeAlertAction(
    IOSUseDOMLiveIdentityKind kind,
    NSInteger elementType,
    NSString *label,
    CGRect frame,
    NSArray<NSDictionary<NSString *, id> *> * _Nullable actions
);
static BOOL IOSUseDOMFramesMatchWithinTolerance(
    CGRect left,
    CGRect right
);
static BOOL IOSUseDOMViewIsActuallyVisibleInWindow(UIView *view);
static CGRect IOSUseDOMObjectRect(id object);

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

static NSString * _Nullable IOSUseDOMLiveInputValue(id object) {
    @try {
        if ([object isKindOfClass:UITextField.class]) {
            UITextField *field = object;
            if (field.secureTextEntry) {
                return field.hasText ? @"••••" : nil;
            }
            return field.text;
        }
        if ([object isKindOfClass:UITextView.class]) {
            return [(UITextView *)object text];
        }
        if ([object isKindOfClass:UISearchBar.class]) {
            return [(UISearchBar *)object text];
        }
        if (![object conformsToProtocol:@protocol(UITextInput)]) {
            return nil;
        }
        id<UITextInput> textInput = object;
        if (IOSUseDOMBoolValue(
                object,
                @selector(isSecureTextEntry),
                NO
            )) {
            return [(id<UIKeyInput>)object hasText]
                ? @"••••"
                : nil;
        }
        UITextRange *document = [
            textInput
            textRangeFromPosition:textInput.beginningOfDocument
            toPosition:textInput.endOfDocument
        ];
        return document == nil
            ? nil
            : [textInput textInRange:document];
    } @catch (__unused NSException *exception) {
        return nil;
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
        // ZWNJ and ZWJ participate in rendered grapheme shaping and must
        // survive DOM serialization (for example, family emoji). Strip only
        // zero-width spacing/control marks that do not carry that meaning.
        [trim addCharactersInString:@"\u200B\u2060\uFEFF"];
        trimCharacters = trim.copy;

        NSMutableCharacterSet *invalid = [
            NSCharacterSet.controlCharacterSet
            mutableCopy
        ];
        // Foundation includes Unicode format controls in
        // controlCharacterSet. Preserve the two shaping controls explicitly
        // while continuing to remove other accessibility-string controls.
        [invalid removeCharactersInString:@"\t\n\r\u200C\u200D"];
        [invalid addCharactersInString:@"\u200B\u2060\uFEFF"];
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
    if (count < 0 || count == NSNotFound) {
        return nil;
    }
    if ((NSUInteger)count > IOSUseDOMMaximumChildrenPerNode) {
        context.failureMessage = [NSString stringWithFormat:
            @"accessibility container %@ reported %ld children, exceeding "
             "the 2048-child limit",
            NSStringFromClass([object class]) ?: @"NSObject",
            (long)count
        ];
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

static NSString *IOSUseDOMFixedWebBridgeScript(void) {
    static NSString *script;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // This is the bridge's complete program. callAsyncJavaScript passes
        // only fixed-name data arguments into an isolated WKContentWorld;
        // callers cannot supply JavaScript, selectors, or DOM paths.
        script =
            @"const elementLimit=512,traversalLimit=4096;"
             "const allowedRoles=new Set("
               "['button','link','input','heading','text']);"
             "const normalize=value=>{"
               "const raw=String(value??'');"
               "if(raw.length>4096)return null;"
               "return raw.replace(/\\s+/g,' ').trim();"
             "};"
             "const structuralIdentity=element=>{"
               "const parts=[];let current=element,depth=0;"
               "while(current&&current.nodeType===Node.ELEMENT_NODE){"
                 "if(depth>=64)return null;"
                 "let index=0,sibling=current;"
                 "while((sibling=sibling.previousElementSibling)!==null)"
                   "index+=1;"
                 "parts.push(current.tagName.toLowerCase()+':'+index);"
                 "current=current.parentElement;depth+=1;"
               "}"
               "return parts.reverse().join('/');"
             "};"
             "const describe=element=>{"
               "const tag=element.tagName.toLowerCase();"
               "const declaredRole=normalize("
                 "element.getAttribute('role'));"
               "if(declaredRole===null)return {invalid:true};"
               "const implicitRole=({"
                 "button:'button',a:'link',input:'input',"
                 "textarea:'input',select:'input',h1:'heading',"
                 "h2:'heading',h3:'heading',h4:'heading',"
                 "h5:'heading',h6:'heading',p:'text'"
               "})[tag]||'';"
               "const role=declaredRole||implicitRole;"
               "if(!allowedRoles.has(role))return null;"
               "const style=getComputedStyle(element);"
               "const frame=element.getBoundingClientRect();"
               "const viewport=window.visualViewport;"
               "const viewportWidth=viewport?"
                 "viewport.width:window.innerWidth;"
               "const viewportHeight=viewport?"
                 "viewport.height:window.innerHeight;"
               "if(element.hidden||"
                  "element.getAttribute('aria-hidden')==='true'||"
                  "style.display==='none'||"
                  "style.visibility==='hidden'||"
                  "Number(style.opacity)<=0||"
                  "frame.width<=0||frame.height<=0||"
                  "frame.right<=0||frame.bottom<=0||"
                  "frame.left>=viewportWidth||"
                  "frame.top>=viewportHeight)return null;"
               "const rendered=normalize("
                 "element.innerText||element.textContent);"
               "const ariaLabel=normalize("
                 "element.getAttribute('aria-label'));"
               "const placeholder=normalize("
                 "element.getAttribute('placeholder'));"
               "const identifier=normalize(element.id);"
               "if(rendered===null||ariaLabel===null||"
                  "placeholder===null||identifier===null)"
                 "return {invalid:true};"
               "const label=ariaLabel||placeholder||rendered;"
               "const rawValue=('value'in element)?"
                 "String(element.value??''):"
                 "((role==='text'||role==='heading')?"
                   "rendered:'');"
               "if(rawValue.length>4096)return {invalid:true};"
               "if(!label&&!rawValue)return null;"
               "const identity=structuralIdentity(element);"
               "if(identity===null||identity.length>4096)"
                 "return {invalid:true};"
               "const viewportOffsetX=viewport?"
                 "viewport.offsetLeft:0;"
               "const viewportOffsetY=viewport?"
                 "viewport.offsetTop:0;"
               "const viewportScale=viewport?viewport.scale:1;"
               "const inputType=tag==='input'?"
                 "(normalize(element.getAttribute('type'))||'text')"
                   ".toLowerCase():'';"
               "return {element,identity,role,tag,label,"
                 "value:rawValue,identifier,inputType,"
                 "secure:tag==='input'&&inputType==='password',"
                 "disabled:Boolean(element.disabled)||"
                   "element.getAttribute('aria-disabled')==='true',"
                 "readOnly:Boolean(element.readOnly),"
                 "selected:element.getAttribute("
                   "'aria-selected')==='true',"
                 "focused:document.activeElement===element,"
                 "x:(frame.left-viewportOffsetX)*viewportScale,"
                 "y:(frame.top-viewportOffsetY)*viewportScale,"
                 "width:frame.width*viewportScale,"
                 "height:frame.height*viewportScale};"
             "};"
             "const enumerate=()=>{"
               "const out=[];"
               "const walker=document.createTreeWalker("
                 "document.documentElement,NodeFilter.SHOW_ELEMENT);"
               "let element=walker.currentNode,visited=0,invalid=false;"
               "while(element&&out.length<elementLimit&&"
                     "visited<traversalLimit){"
                 "const descriptor=describe(element);"
                 "if(descriptor&&descriptor.invalid)invalid=true;"
                 "else if(descriptor){"
                   "descriptor.ordinal=out.length;"
                   "out.push(descriptor);"
                 "}"
                 "visited+=1;element=walker.nextNode();"
               "}"
               "return {elements:out,invalid,"
                 "truncated:Boolean(element),visited};"
             "};"
             "if(operation==='snapshot'){"
               "const scan=enumerate();"
               "return {"
                 "elements:scan.elements.map(item=>({"
                   "ordinal:item.ordinal,identity:item.identity,"
                   "role:item.role,tag:item.tag,label:item.label,"
                   "value:item.value,identifier:item.identifier,"
                   "inputType:item.inputType,secure:item.secure,"
                   "disabled:item.disabled,readOnly:item.readOnly,"
                   "selected:item.selected,focused:item.focused,"
                   "x:item.x,y:item.y,width:item.width,"
                   "height:item.height"
                 "})),"
                 "invalid:scan.invalid,truncated:scan.truncated,"
                 "visited:scan.visited"
               "};"
             "}"
             "if(operation==='inputState'){"
               "const element=document.activeElement;"
               "if(!element||"
                  "!['INPUT','TEXTAREA'].includes(element.tagName))"
                 "return {status:'inactive'};"
               "const item=describe(element);"
               "if(!item||item.invalid||item.role!=='input')"
                 "return {status:'inactive'};"
               "const value=String(element.value??'');"
               "const inputType=element.tagName==='INPUT'?"
                 "(normalize(element.getAttribute('type'))||'text')"
                   ".toLowerCase():'';"
               "return {status:'active',value,inputType,"
                 "identity:item.identity,role:item.role,tag:item.tag,"
                 "label:item.label,identifier:item.identifier,"
                 "x:item.x,y:item.y,width:item.width,height:item.height,"
                 "secure:element.tagName==='INPUT'&&"
                   "inputType==='password',"
                 "disabled:Boolean(element.disabled)||"
                   "element.getAttribute('aria-disabled')==='true',"
                 "readOnly:Boolean(element.readOnly),"
                 "selectionStart:Number.isInteger("
                   "element.selectionStart)?element.selectionStart:-1,"
                 "selectionEnd:Number.isInteger("
                   "element.selectionEnd)?element.selectionEnd:-1};"
             "}"
             "if(operation!=='activate'&&operation!=='focusInput')"
               "return {status:'failed',reason:'operation'};"
             "if(!Number.isInteger(ordinal)||ordinal<0||"
                "ordinal>=elementLimit)"
               "return {status:'failed',reason:'ordinal'};"
             "const scan=enumerate();"
             "if(scan.invalid||scan.truncated)"
               "return {status:'failed',reason:'bounded-scan'};"
             "const item=scan.elements[ordinal];"
             "if(!item)return {status:'stale',reason:'ordinal'};"
             "const frameMatches="
               "Math.abs(item.x-expectedX)<=0.5&&"
               "Math.abs(item.y-expectedY)<=0.5&&"
               "Math.abs(item.width-expectedWidth)<=0.5&&"
               "Math.abs(item.height-expectedHeight)<=0.5;"
             "if(item.identity!==expectedIdentity||"
                "item.role!==expectedRole||item.tag!==expectedTag||"
                "item.label!==expectedLabel||"
                "item.identifier!==expectedIdentifier||"
                "item.disabled!==expectedDisabled||"
                "item.secure!==expectedSecure||!frameMatches)"
               "return {status:'stale',reason:'identity'};"
             "if(item.disabled)"
               "return {status:'unsupported',reason:'disabled'};"
             "if(operation==='activate'){"
               "if(!['button','link'].includes(item.role))"
                 "return {status:'unsupported',reason:'role'};"
               "if(!(item.element instanceof HTMLElement))"
                 "return {status:'unsupported',reason:'custom'};"
               "HTMLElement.prototype.click.call(item.element);"
               "return {status:'performed',operation:'activate',"
                 "freshValidated:true,performed:true};"
             "}"
             "if(item.role!=='input')"
               "return {status:'unsupported',reason:'role'};"
             "if(item.secure)"
               "return {status:'unsupported',reason:'secure'};"
             "if(!['input','textarea'].includes(item.tag))"
               "return {status:'unsupported',reason:'custom'};"
             "const textTypes=new Set("
               "['text','search','email','url','tel']);"
             "if(item.tag==='input'&&!textTypes.has(item.inputType))"
               "return {status:'unsupported',reason:'custom'};"
             "if(item.readOnly)"
               "return {status:'unsupported',reason:'read-only'};"
             "HTMLElement.prototype.focus.call("
               "item.element,{preventScroll:true});"
             "if(document.activeElement!==item.element)"
               "return {status:'failed',reason:'focus'};"
             "return {status:'performed',operation:'focusInput',"
               "freshValidated:true,performed:true,focused:true};";
    });
    return script;
}

static NSDictionary<NSString *, id> *
IOSUseDOMFixedWebBridgeArguments(NSString *operation) {
    return @{
        @"operation": operation,
        @"ordinal": @0,
        @"expectedIdentity": @"",
        @"expectedRole": @"",
        @"expectedTag": @"",
        @"expectedLabel": @"",
        @"expectedIdentifier": @"",
        @"expectedDisabled": @NO,
        @"expectedSecure": @NO,
        @"expectedX": @0,
        @"expectedY": @0,
        @"expectedWidth": @0,
        @"expectedHeight": @0,
    };
}

static id _Nullable IOSUseDOMEvaluateFixedWebBridge(
    WKWebView *webView,
    NSDictionary<NSString *, id> *arguments,
    NSTimeInterval timeout,
    NSString * _Nullable *failureMessage
) {
    NSCAssert(
        NSThread.isMainThread,
        @"WKWebView accessibility bridge is main-only"
    );
    __block id rawResult = nil;
    __block NSError *evaluationError = nil;
    __block BOOL completed = NO;
    if (@available(iOS 14.0, macCatalyst 14.0, *)) {
        WKContentWorld *contentWorld = [WKContentWorld
            worldWithName:@"io.ios-use.runtime.accessibility"];
        [webView
            callAsyncJavaScript:IOSUseDOMFixedWebBridgeScript()
                       arguments:arguments
                         inFrame:nil
                  inContentWorld:contentWorld
               completionHandler:^(id result, NSError *error) {
            rawResult = result;
            evaluationError = error;
            completed = YES;
        }];
    } else {
        if (failureMessage != NULL) {
            *failureMessage =
                @"WKWebView fixed accessibility bridge requires iOS 14 or newer";
        }
        return nil;
    }
    CFAbsoluteTime deadline =
        CFAbsoluteTimeGetCurrent() + timeout;
    while (!completed && CFAbsoluteTimeGetCurrent() < deadline) {
        CFRunLoopRunInMode(
            kCFRunLoopDefaultMode,
            MIN(0.01, deadline - CFAbsoluteTimeGetCurrent()),
            true
        );
    }
    if (!completed) {
        if (failureMessage != NULL) {
            *failureMessage =
                @"WKWebView accessibility bridge timed out";
        }
        return nil;
    }
    if (evaluationError != nil) {
        if (failureMessage != NULL) {
            *failureMessage =
                evaluationError.localizedDescription ?:
                    @"WKWebView accessibility bridge failed";
        }
        return nil;
    }
    return rawResult;
}

static NSArray * _Nullable IOSUseDOMWebAccessibilityElements(
    WKWebView *webView,
    IOSUseDOMCaptureContext *context
) {
    // A tab selection can instantiate and start a WKWebView in the same
    // touch turn. Do not turn that bounded, observable loading state into a
    // snapshot failure: the native WKWebView node remains in the DOM and
    // waitFor will take a fresh bridged snapshot after navigation settles.
    if (webView.loading ||
        webView.URL == nil ||
        webView.estimatedProgress < 1.0) {
        return @[];
    }
    NSString *failureMessage = nil;
    id rawResult = IOSUseDOMEvaluateFixedWebBridge(
        webView,
        IOSUseDOMFixedWebBridgeArguments(@"snapshot"),
        0.75,
        &failureMessage
    );
    if (![rawResult isKindOfClass:NSDictionary.class]) {
        context.failureMessage =
            failureMessage ?:
                @"WKWebView accessibility bridge returned invalid data";
        return nil;
    }
    NSDictionary *result = rawResult;
    NSArray *elements = [result[@"elements"] isKindOfClass:NSArray.class]
        ? result[@"elements"]
        : nil;
    if (elements == nil ||
        [result[@"invalid"] boolValue] ||
        [result[@"truncated"] boolValue] ||
        !IOSUseDOMIsInteger(result[@"visited"]) ||
        [result[@"visited"] unsignedIntegerValue] >
            IOSUseDOMMaximumWebTraversalCount ||
        elements.count > IOSUseDOMMaximumWebElementCount) {
        context.failureMessage =
            elements == nil
                ? @"WKWebView accessibility bridge omitted its element list"
                : @"WKWebView accessibility bridge exceeded its fixed bounds";
        return nil;
    }

    NSMutableArray *proxies =
        [NSMutableArray arrayWithCapacity:elements.count];
    for (id candidate in elements) {
        if (![candidate isKindOfClass:NSDictionary.class]) {
            context.failureMessage =
                @"WKWebView accessibility bridge returned a non-object element";
            return nil;
        }
        NSDictionary *entry = candidate;
        NSArray<NSString *> *numberKeys = @[
            @"ordinal", @"x", @"y", @"width", @"height"
        ];
        BOOL validNumbers = YES;
        for (NSString *key in numberKeys) {
            if (!IOSUseDOMIsNumber(entry[key]) ||
                !isfinite([entry[key] doubleValue])) {
                validNumbers = NO;
                break;
            }
        }
        NSString *role = [entry[@"role"] isKindOfClass:NSString.class]
            ? entry[@"role"]
            : nil;
        NSString *label = [entry[@"label"] isKindOfClass:NSString.class]
            ? entry[@"label"]
            : nil;
        NSString *value = [entry[@"value"] isKindOfClass:NSString.class]
            ? entry[@"value"]
            : nil;
        NSString *identity =
            [entry[@"identity"] isKindOfClass:NSString.class]
                ? entry[@"identity"]
                : nil;
        NSString *tag = [entry[@"tag"] isKindOfClass:NSString.class]
            ? entry[@"tag"]
            : nil;
        NSString *identifier =
            [entry[@"identifier"] isKindOfClass:NSString.class]
                ? entry[@"identifier"]
                : nil;
        if (!validNumbers ||
            role.length == 0 ||
            ![@[
                @"button", @"link", @"input", @"heading", @"text"
            ] containsObject:role] ||
            identity.length == 0 ||
            tag.length == 0 ||
            identifier == nil ||
            (label.length == 0 && value.length == 0) ||
            [entry[@"ordinal"] unsignedIntegerValue] != proxies.count ||
            [entry[@"width"] doubleValue] <= 0 ||
            [entry[@"height"] doubleValue] <= 0 ||
            !IOSUseDOMIsBoolean(entry[@"secure"]) ||
            !IOSUseDOMIsBoolean(entry[@"disabled"]) ||
            !IOSUseDOMIsBoolean(entry[@"selected"]) ||
            !IOSUseDOMIsBoolean(entry[@"focused"])) {
            context.failureMessage =
                @"WKWebView accessibility bridge returned an invalid element";
            return nil;
        }
        CGRect localFrame = CGRectMake(
            [entry[@"x"] doubleValue],
            [entry[@"y"] doubleValue],
            [entry[@"width"] doubleValue],
            [entry[@"height"] doubleValue]
        );
        CGRect screenFrame = [webView convertRect:localFrame toView:nil];
        if (!IOSUseDOMRectHasArea(screenFrame)) {
            context.failureMessage =
                @"WKWebView accessibility bridge returned invalid geometry";
            return nil;
        }
        IOSUseDOMWebAccessibilityElement *proxy = [
            [IOSUseDOMWebAccessibilityElement alloc]
            initWithAccessibilityContainer:webView
        ];
        proxy.webView = webView;
        proxy.webOrdinal = [entry[@"ordinal"] unsignedIntegerValue];
        proxy.webIdentity = identity;
        proxy.webRole = role;
        proxy.webTag = tag;
        proxy.webLabel = label ?: @"";
        proxy.webIdentifier = identifier;
        proxy.webLocalFrame = localFrame;
        proxy.webScreenFrame = screenFrame;
        proxy.webDisabled = [entry[@"disabled"] boolValue];
        proxy.webSecure = [entry[@"secure"] boolValue];
        proxy.isAccessibilityElement = YES;
        proxy.accessibilityLabel = label;
        proxy.accessibilityValue = value;
        proxy.accessibilityIdentifier =
            identifier;
        proxy.accessibilityHint = [entry[@"secure"] boolValue]
            ? @"ios-use:secure-web-input"
            : nil;
        proxy.accessibilityFrame = screenFrame;
        UIAccessibilityTraits traits = UIAccessibilityTraitNone;
        if ([role isEqualToString:@"button"]) {
            traits |= UIAccessibilityTraitButton;
        } else if ([role isEqualToString:@"link"]) {
            traits |= UIAccessibilityTraitLink;
        } else if ([role isEqualToString:@"heading"] ||
                   [role isEqualToString:@"text"]) {
            traits |= UIAccessibilityTraitStaticText;
        }
        if ([entry[@"disabled"] boolValue]) {
            traits |= UIAccessibilityTraitNotEnabled;
        }
        if ([entry[@"selected"] boolValue]) {
            traits |= UIAccessibilityTraitSelected;
        }
        proxy.accessibilityTraits = traits;
        [proxies addObject:proxy];
    }
    return proxies;
}

static NSArray<IOSUseDOMAppKitAccessibilityElement *> * _Nullable
IOSUseDOMAppKitAccessibilityElements(
    UIWindow *primaryWindow,
    IOSUseDOMCaptureContext *context
) {
    NSError *bridgeError = nil;
    NSArray<NSDictionary<NSString *, id> *> *entries = [
        IOSUsePlayAppKitBridge
        activeAccessibilityElementsWithError:&bridgeError
    ];
    if (entries == nil) {
        context.failureMessage = bridgeError.localizedDescription ?:
            @"AppKit accessibility bridge failed";
        return nil;
    }
    if (entries.count > IOSUseDOMMaximumAppKitElementCount) {
        context.failureMessage =
            @"AppKit accessibility bridge exceeded 512 elements";
        return nil;
    }
    NSMutableArray<IOSUseDOMAppKitAccessibilityElement *> *proxies =
        [NSMutableArray arrayWithCapacity:entries.count];
    NSSet<NSString *> *allowedRoles = [NSSet setWithArray:@[
        @"button",
        @"link",
        @"text",
        @"heading",
    ]];
    for (id candidate in entries) {
        if (![candidate isKindOfClass:NSDictionary.class]) {
            context.failureMessage =
                @"AppKit accessibility bridge returned a non-object element";
            return nil;
        }
        NSDictionary<NSString *, id> *entry = candidate;
        NSString *role = [entry[@"role"] isKindOfClass:NSString.class]
            ? entry[@"role"]
            : nil;
        NSString *label = [entry[@"label"] isKindOfClass:NSString.class]
            ? entry[@"label"]
            : nil;
        NSString *value = [entry[@"value"] isKindOfClass:NSString.class]
            ? entry[@"value"]
            : nil;
        NSString *identifier =
            [entry[@"identifier"] isKindOfClass:NSString.class]
                ? entry[@"identifier"]
                : nil;
        NSDictionary<NSString *, id> *frame =
            [entry[@"frame"] isKindOfClass:NSDictionary.class]
                ? entry[@"frame"]
                : nil;
        NSArray<NSString *> *numberKeys =
            @[@"x", @"y", @"width", @"height"];
        BOOL validNumbers = frame != nil;
        for (NSString *key in numberKeys) {
            if (!IOSUseDOMIsNumber(frame[key]) ||
                !isfinite([frame[key] doubleValue])) {
                validNumbers = NO;
                break;
            }
        }
        if (![allowedRoles containsObject:role ?: @""] ||
            label == nil ||
            value == nil ||
            identifier == nil ||
            (label.length == 0 &&
             value.length == 0 &&
             identifier.length == 0) ||
            !validNumbers ||
            [frame[@"width"] doubleValue] <= 0 ||
            [frame[@"height"] doubleValue] <= 0 ||
            !IOSUseDOMIsBoolean(entry[@"enabled"]) ||
            !IOSUseDOMIsBoolean(entry[@"selected"]) ||
            !IOSUseDOMIsBoolean(entry[@"focused"])) {
            context.failureMessage =
                @"AppKit accessibility bridge returned an invalid element";
            return nil;
        }
        if (([role isEqualToString:@"text"] ||
             [role isEqualToString:@"heading"]) &&
            label.length == 0 &&
            value.length > 0) {
            label = value;
            value = @"";
        } else if (label.length > 0 &&
                   [label isEqualToString:value]) {
            value = @"";
        }
        CGRect logicalFrame = CGRectMake(
            [frame[@"x"] doubleValue],
            [frame[@"y"] doubleValue],
            [frame[@"width"] doubleValue],
            [frame[@"height"] doubleValue]
        );
        if (!IOSUseDOMRectHasArea(logicalFrame)) {
            context.failureMessage =
                @"AppKit accessibility bridge returned invalid geometry";
            return nil;
        }
        IOSUseDOMAppKitAccessibilityElement *proxy = [
            [IOSUseDOMAppKitAccessibilityElement alloc]
            initWithAccessibilityContainer:primaryWindow
        ];
        proxy.appKitRole = role;
        proxy.appKitFocused = [entry[@"focused"] boolValue];
        proxy.isAccessibilityElement = YES;
        proxy.accessibilityLabel = label.length > 0
            ? label
            : identifier;
        proxy.accessibilityValue =
            value.length > 0 ? value : nil;
        proxy.accessibilityIdentifier =
            identifier.length > 0 ? identifier : nil;
        proxy.accessibilityFrame = logicalFrame;
        UIAccessibilityTraits traits = UIAccessibilityTraitNone;
        if ([role isEqualToString:@"button"]) {
            traits |= UIAccessibilityTraitButton;
        } else if ([role isEqualToString:@"link"]) {
            traits |= UIAccessibilityTraitLink;
        } else {
            traits |= UIAccessibilityTraitStaticText;
            if ([role isEqualToString:@"heading"]) {
                traits |= UIAccessibilityTraitHeader;
            }
        }
        if (![entry[@"enabled"] boolValue]) {
            traits |= UIAccessibilityTraitNotEnabled;
        }
        if ([entry[@"selected"] boolValue]) {
            traits |= UIAccessibilityTraitSelected;
        }
        proxy.accessibilityTraits = traits;
        [proxies addObject:proxy];
    }
    return proxies;
}

static IOSUseDOMWebBridgeRecord * _Nullable
IOSUseDOMWebBridgeRecordForElement(
    NSDictionary<NSString *, id> *element
);

static BOOL IOSUseDOMWebFrameMatches(
    CGRect left,
    CGRect right,
    CGFloat tolerance
);

NSDictionary<NSString *, id> *IOSUsePlayRuntimeWebInputState(
    UIView *hitView,
    NSDictionary<NSString *, id> *bridgedElement,
    NSString **failureMessage
) {
    NSCAssert(NSThread.isMainThread, @"Web input state is main-only");
    WKWebView *webView = nil;
    for (UIView *view = hitView;
         view != nil;
         view = view.superview) {
        if ([view isKindOfClass:WKWebView.class]) {
            webView = (WKWebView *)view;
            break;
        }
    }
    if (webView == nil) {
        if (failureMessage != NULL) {
            *failureMessage =
                @"active text responder is not contained by a WKWebView";
        }
        return nil;
    }
    NSString *evaluationFailure = nil;
    id rawState = IOSUseDOMEvaluateFixedWebBridge(
        webView,
        IOSUseDOMFixedWebBridgeArguments(@"inputState"),
        0.75,
        &evaluationFailure
    );
    if (![rawState isKindOfClass:NSDictionary.class] ||
        ![rawState[@"status"] isEqualToString:@"active"]) {
        if (failureMessage != NULL) {
            *failureMessage = evaluationFailure ?:
                @"WKWebView has no active public HTML text control";
        }
        return nil;
    }
    NSDictionary *state = rawState;
    if (![state[@"value"] isKindOfClass:NSString.class] ||
        [state[@"value"] length] > IOSUseDOMMaximumStringLength ||
        ![state[@"identity"] isKindOfClass:NSString.class] ||
        ![state[@"role"] isEqualToString:@"input"] ||
        ![state[@"tag"] isKindOfClass:NSString.class] ||
        ![state[@"label"] isKindOfClass:NSString.class] ||
        ![state[@"identifier"] isKindOfClass:NSString.class] ||
        !IOSUseDOMIsNumber(state[@"x"]) ||
        !IOSUseDOMIsNumber(state[@"y"]) ||
        !IOSUseDOMIsNumber(state[@"width"]) ||
        !IOSUseDOMIsNumber(state[@"height"]) ||
        !IOSUseDOMIsBoolean(state[@"secure"]) ||
        !IOSUseDOMIsBoolean(state[@"disabled"]) ||
        !IOSUseDOMIsBoolean(state[@"readOnly"]) ||
        !IOSUseDOMIsInteger(state[@"selectionStart"]) ||
        !IOSUseDOMIsInteger(state[@"selectionEnd"])) {
        if (failureMessage != NULL) {
            *failureMessage =
                @"WKWebView returned malformed active text state";
        }
        return nil;
    }
    if (bridgedElement != nil) {
        IOSUseDOMWebBridgeRecord *record =
            IOSUseDOMWebBridgeRecordForElement(bridgedElement);
        BOOL selectedInputStillActive =
            record != nil &&
            record.webView == webView &&
            [state[@"identity"] isEqualToString:record.identity] &&
            [state[@"role"] isEqualToString:record.role] &&
            [state[@"tag"] isEqualToString:record.tag] &&
            [state[@"label"] isEqualToString:record.label] &&
            [state[@"identifier"]
                isEqualToString:record.identifier];
        if (!selectedInputStillActive) {
            if (failureMessage != NULL) {
                *failureMessage =
                    @"the active HTML input no longer matches the freshly selected Web proxy";
            }
            return nil;
        }
    }
    return state;
}

static IOSUseDOMWebBridgeRecord * _Nullable
IOSUseDOMWebBridgeRecordForElement(
    NSDictionary<NSString *, id> *element
) {
    if (![element isKindOfClass:NSDictionary.class] ||
        ![element[@"class"]
            isEqualToString:
                NSStringFromClass(
                    IOSUseDOMWebAccessibilityElement.class
                )] ||
        ![element[@"nodeID"] isKindOfClass:NSString.class] ||
        !IOSUseDOMIsInteger(element[@"snapshotGeneration"])) {
        return nil;
    }
    IOSUseDOMWebBridgeRecord *record =
        IOSUseDOMWebBridgeRecords[element[@"nodeID"]];
    if (record == nil ||
        record.generation !=
            [element[@"snapshotGeneration"] unsignedLongLongValue] ||
        record.generation != IOSUseDOMWebBridgeGeneration) {
        return nil;
    }
    return record;
}

BOOL IOSUsePlayRuntimeIsWebAccessibilityElement(
    NSDictionary<NSString *, id> *element
) {
    NSCAssert(
        NSThread.isMainThread,
        @"Web accessibility provenance is main-only"
    );
    return IOSUseDOMWebBridgeRecordForElement(element) != nil;
}

static BOOL IOSUseDOMWebFrameMatches(
    CGRect left,
    CGRect right,
    CGFloat tolerance
) {
    return fabs(left.origin.x - right.origin.x) <= tolerance &&
        fabs(left.origin.y - right.origin.y) <= tolerance &&
        fabs(left.size.width - right.size.width) <= tolerance &&
        fabs(left.size.height - right.size.height) <= tolerance;
}

NSDictionary<NSString *, id> *
IOSUsePlayRuntimePerformWebAccessibilityAction(
    UIView *hitView,
    NSDictionary<NSString *, id> *element,
    IOSUsePlayRuntimeWebAccessibilityAction action,
    NSString **failureCode,
    NSString **failureMessage
) {
    NSCAssert(
        NSThread.isMainThread,
        @"Web accessibility actions are main-only"
    );
    IOSUseDOMWebBridgeRecord *record =
        IOSUseDOMWebBridgeRecordForElement(element);
    if (record == nil) {
        if (failureCode != NULL) {
            *failureCode = @"web_bridge_stale";
        }
        if (failureMessage != NULL) {
            *failureMessage =
                @"the selected Web element is not from the current fresh Runtime snapshot";
        }
        return nil;
    }
    WKWebView *webView = nil;
    for (UIView *view = hitView;
         view != nil;
         view = view.superview) {
        if ([view isKindOfClass:WKWebView.class]) {
            webView = (WKWebView *)view;
            break;
        }
    }
    NSDictionary *frame = element[@"frame"];
    CGRect serializedFrame =
        [frame isKindOfClass:NSDictionary.class] &&
        IOSUseDOMIsNumber(frame[@"x"]) &&
        IOSUseDOMIsNumber(frame[@"y"]) &&
        IOSUseDOMIsNumber(frame[@"width"]) &&
        IOSUseDOMIsNumber(frame[@"height"])
            ? CGRectMake(
                [frame[@"x"] doubleValue],
                [frame[@"y"] doubleValue],
                [frame[@"width"] doubleValue],
                [frame[@"height"] doubleValue]
            )
            : CGRectNull;
    NSString *expectedType = @{
        @"button": @"Button",
        @"link": @"Link",
        @"input": @"Input",
        @"heading": @"Text",
        @"text": @"Text",
    }[record.role];
    BOOL serializedMatches =
        webView != nil &&
        webView == record.webView &&
        [element[@"label"]
            isEqualToString:record.serializedLabel] &&
        [element[@"identifier"] isEqualToString:record.identifier] &&
        [element[@"type"] isEqualToString:expectedType] &&
        !CGRectIsNull(serializedFrame) &&
        IOSUseDOMWebFrameMatches(
            serializedFrame,
            record.screenFrame,
            0.01
        );
    if (!serializedMatches) {
        if (failureCode != NULL) {
            *failureCode = @"web_bridge_stale";
        }
        if (failureMessage != NULL) {
            *failureMessage =
                @"the selected Web element metadata no longer matches its Runtime proxy";
        }
        return nil;
    }
    NSString *operation = nil;
    switch (action) {
        case IOSUsePlayRuntimeWebAccessibilityActionActivate:
            operation = @"activate";
            break;
        case IOSUsePlayRuntimeWebAccessibilityActionFocusInput:
            operation = @"focusInput";
            break;
        default:
            if (failureCode != NULL) {
                *failureCode = @"web_action_unsupported";
            }
            if (failureMessage != NULL) {
                *failureMessage =
                    @"the requested Web accessibility action is unsupported";
            }
            return nil;
    }
    NSMutableDictionary<NSString *, id> *arguments =
        [IOSUseDOMFixedWebBridgeArguments(operation) mutableCopy];
    [arguments addEntriesFromDictionary:@{
        @"ordinal": @(record.ordinal),
        @"expectedIdentity": record.identity,
        @"expectedRole": record.role,
        @"expectedTag": record.tag,
        @"expectedLabel": record.label,
        @"expectedIdentifier": record.identifier,
        @"expectedDisabled": @(record.disabled),
        @"expectedSecure": @(record.secure),
        @"expectedX": @(record.localFrame.origin.x),
        @"expectedY": @(record.localFrame.origin.y),
        @"expectedWidth": @(record.localFrame.size.width),
        @"expectedHeight": @(record.localFrame.size.height),
    }];
    NSString *evaluationFailure = nil;
    id rawEvidence = IOSUseDOMEvaluateFixedWebBridge(
        webView,
        arguments,
        0.75,
        &evaluationFailure
    );
    if (![rawEvidence isKindOfClass:NSDictionary.class]) {
        if (failureCode != NULL) {
            *failureCode = @"web_bridge_failed";
        }
        if (failureMessage != NULL) {
            *failureMessage = evaluationFailure ?:
                @"the fixed Web accessibility bridge returned invalid evidence";
        }
        return nil;
    }
    NSString *status =
        [rawEvidence[@"status"] isKindOfClass:NSString.class]
            ? rawEvidence[@"status"]
            : @"";
    NSString *reason =
        [rawEvidence[@"reason"] isKindOfClass:NSString.class]
            ? rawEvidence[@"reason"]
            : @"";
    BOOL performed =
        [status isEqualToString:@"performed"] &&
        IOSUseDOMIsBoolean(rawEvidence[@"performed"]) &&
        [rawEvidence[@"performed"] boolValue] &&
        IOSUseDOMIsBoolean(rawEvidence[@"freshValidated"]) &&
        [rawEvidence[@"freshValidated"] boolValue] &&
        [rawEvidence[@"operation"] isEqualToString:operation];
    if (action ==
        IOSUsePlayRuntimeWebAccessibilityActionFocusInput) {
        performed = performed &&
            IOSUseDOMIsBoolean(rawEvidence[@"focused"]) &&
            [rawEvidence[@"focused"] boolValue];
    }
    if (!performed) {
        if (failureCode != NULL) {
            if ([status isEqualToString:@"stale"]) {
                *failureCode = @"web_bridge_stale";
            } else if ([reason isEqualToString:@"disabled"]) {
                *failureCode = @"web_action_disabled";
            } else if ([reason isEqualToString:@"secure"]) {
                *failureCode = @"web_secure_input";
            } else if ([reason isEqualToString:@"custom"] ||
                       [reason isEqualToString:@"read-only"] ||
                       [reason isEqualToString:@"role"]) {
                *failureCode =
                    action ==
                        IOSUsePlayRuntimeWebAccessibilityActionFocusInput
                        ? @"web_custom_input"
                        : @"web_action_unsupported";
            } else if ([reason isEqualToString:@"focus"]) {
                *failureCode = @"web_focus_failed";
            } else {
                *failureCode = @"web_bridge_failed";
            }
        }
        if (failureMessage != NULL) {
            if ([reason isEqualToString:@"disabled"]) {
                *failureMessage = @"the fresh Web element is disabled";
            } else if ([reason isEqualToString:@"secure"]) {
                *failureMessage =
                    @"secure Web text input is unsupported";
            } else if ([reason isEqualToString:@"custom"] ||
                       [reason isEqualToString:@"read-only"] ||
                       [reason isEqualToString:@"role"]) {
                *failureMessage =
                    @"the Web element does not expose a supported public accessibility action";
            } else if ([reason isEqualToString:@"focus"]) {
                *failureMessage =
                    @"the fresh Web input did not become the active HTML control";
            } else if ([status isEqualToString:@"stale"]) {
                *failureMessage =
                    @"the selected Web element changed during fresh action revalidation";
            } else {
                *failureMessage = evaluationFailure ?:
                    @"the fixed Web accessibility action did not report successful delivery";
            }
        }
        return nil;
    }
    return @{
        @"backend":
            @"wkwebview-runtime-fixed-accessibility-bridge",
        @"operation": operation,
        @"freshElementValidated": @YES,
        @"snapshotGeneration": @(record.generation),
        @"nodeID": record.nodeID,
        @"role": record.role,
        @"tag": record.tag,
        @"label": record.serializedLabel,
        @"identifier": record.identifier,
        @"frame": @{
            @"x": @(record.screenFrame.origin.x),
            @"y": @(record.screenFrame.origin.y),
            @"width": @(record.screenFrame.size.width),
            @"height": @(record.screenFrame.size.height),
        },
        @"performed": @YES,
    };
}

static void IOSUseDOMResetWebBridgeRecords(
    unsigned long long generation
) {
    NSCAssert(
        NSThread.isMainThread,
        @"Web accessibility registry is main-only"
    );
    IOSUseDOMWebBridgeRecords = [NSMutableDictionary dictionary];
    IOSUseDOMWebBridgeGeneration = generation;
}

static void IOSUseDOMResetLiveIdentityRecords(
    unsigned long long generation
) {
    NSCAssert(
        NSThread.isMainThread,
        @"DOM live identity registry is main-only"
    );
    IOSUseDOMLiveIdentityRecords = [NSMutableDictionary dictionary];
    IOSUseDOMLiveIdentityGeneration = generation;
}

static UIView * _Nullable IOSUseDOMNormalizedInteractionView(
    UIView * _Nullable view
) {
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

static UIView * _Nullable IOSUseDOMInteractionView(
    id object,
    UIView * _Nullable rawViewAncestor
) {
    NSCAssert(
        NSThread.isMainThread,
        @"DOM interaction owner resolution is main-only"
    );
    if ([object isKindOfClass:UIView.class]) {
        return IOSUseDOMNormalizedInteractionView(object);
    }
    NSHashTable<id> *visited = [NSHashTable hashTableWithOptions:
        NSPointerFunctionsObjectPointerPersonality |
        NSPointerFunctionsStrongMemory];
    id current = object;
    for (NSUInteger depth = 0;
         current != nil && depth < IOSUseDOMMaximumDepth;
         depth += 1) {
        if ([visited containsObject:current]) {
            break;
        }
        [visited addObject:current];
        id container = IOSUseDOMObjectValue(
            current,
            NSSelectorFromString(@"accessibilityContainer")
        );
        if (container == nil || container == current) {
            break;
        }
        if ([container isKindOfClass:UIView.class]) {
            return IOSUseDOMNormalizedInteractionView(container);
        }
        current = container;
    }
    return IOSUseDOMNormalizedInteractionView(rawViewAncestor);
}

static NSString * _Nullable IOSUseDOMIdentityString(id value) {
    IOSUseDOMCaptureContext *context =
        [IOSUseDOMCaptureContext new];
    return IOSUseDOMBoundedString(value, context);
}

static NSString * _Nullable IOSUseDOMCurrentSemanticLabel(
    id object
) {
    NSString *identifier = IOSUseDOMIdentityString(
        IOSUseDOMObjectValue(
            object,
            NSSelectorFromString(@"accessibilityIdentifier")
        )
    );
    NSString *label = IOSUseDOMIdentityString(
        IOSUseDOMObjectValue(
            object,
            NSSelectorFromString(@"accessibilityLabel")
        )
    );
    id visibleLabelObject = nil;
    if ([object isKindOfClass:UILabel.class]) {
        visibleLabelObject = [(UILabel *)object text];
    } else if ([object isKindOfClass:UIButton.class]) {
        visibleLabelObject = [(UIButton *)object currentTitle];
    } else if ([object isKindOfClass:UITextField.class]) {
        visibleLabelObject = [(UITextField *)object placeholder];
    } else if ([object isKindOfClass:UISearchBar.class]) {
        visibleLabelObject = [(UISearchBar *)object placeholder];
    }
    NSString *visibleLabel =
        IOSUseDOMIdentityString(visibleLabelObject);
    if (visibleLabel.length > 0 &&
        (label.length == 0 ||
         [label isEqualToString:identifier])) {
        label = visibleLabel;
    }
    return label.length > 0 ? label : identifier;
}

static BOOL IOSUseDOMNullableStringsEqual(
    NSString * _Nullable left,
    NSString * _Nullable right
) {
    return left == right || [left isEqualToString:right];
}

static void IOSUseDOMRegisterLiveIdentity(
    IOSUseDOMNode *node,
    id object,
    UIView * _Nullable rawViewAncestor,
    IOSUseDOMCaptureContext *context
) {
    NSCAssert(
        NSThread.isMainThread,
        @"DOM live identity registry is main-only"
    );
    if (node == nil ||
        object == nil ||
        node.nodeID.length == 0 ||
        node.generation != IOSUseDOMLiveIdentityGeneration ||
        IOSUseDOMLiveIdentityRecords.count >=
            IOSUseDOMMaximumVisitedNodeCount) {
        return;
    }
    IOSUseDOMLiveIdentityRecord *record =
        [IOSUseDOMLiveIdentityRecord new];
    record.object = object;
    record.rawViewAncestor = rawViewAncestor;
    record.interactionView = IOSUseDOMInteractionView(
        object,
        rawViewAncestor
    );
    record.snapshotSuperview =
        [object isKindOfClass:UIView.class]
            ? [(UIView *)object superview]
            : nil;
    record.snapshotAccessibilityContainer =
        [object isKindOfClass:UIView.class]
            ? nil
            : IOSUseDOMObjectValue(
                object,
                NSSelectorFromString(@"accessibilityContainer")
            );
    record.snapshotWindow =
        record.interactionView.window ?:
        ([object isKindOfClass:UIView.class]
            ? [(UIView *)object window]
            : rawViewAncestor.window);
    if ([object isKindOfClass:
            IOSUseDOMWebAccessibilityElement.class]) {
        record.kind = IOSUseDOMLiveIdentityKindWebProxy;
    } else if ([object isKindOfClass:
                   IOSUseDOMAppKitAccessibilityElement.class]) {
        record.kind = IOSUseDOMLiveIdentityKindAppKitProxy;
    } else if (context.nativeAlertActions.count > 0 &&
               IOSUseDOMObjectHasNativeAlertMirrorShape(
                   object,
                   rawViewAncestor
               )) {
        record.kind = IOSUseDOMLiveIdentityKindNativeAlertMirror;
    } else {
        record.kind = IOSUseDOMLiveIdentityKindGeneric;
    }
    record.frame = node.rect;
    record.elementType = node.elementType;
    record.semanticLabel = node.label;
    record.identifier = node.identifier;
    record.accessibilityTraits =
        IOSUseDOMAccessibilityTraits(object);
    record.controlEnabled =
        ![object isKindOfClass:UIControl.class] ||
        [(UIControl *)object isEnabled];
    record.nativeAlertActionFrame = CGRectNull;
    record.nativeAlertActionIndex = NSNotFound;
    NSDictionary<NSString *, id> *nativeAlertAction =
        IOSUseDOMExactNativeAlertAction(
            (IOSUseDOMLiveIdentityKind)record.kind,
            node.elementType,
            node.label,
            node.rect,
            context.nativeAlertActions
        );
    if (nativeAlertAction != nil) {
        record.nativeAlertActionLabel =
            nativeAlertAction[@"label"];
        record.nativeAlertActionFrame =
            IOSUseDOMNativeAlertActionFrame(
                nativeAlertAction[@"frame"]
            );
        record.nativeAlertActionIndex =
            [nativeAlertAction[@"index"] integerValue];
    }
    record.generation = node.generation;
    IOSUseDOMLiveIdentityRecords[node.nodeID] = record;
}

BOOL IOSUsePlayRuntimeDOMResolveLiveIdentity(
    NSDictionary<NSString *, id> *element,
    id _Nullable *object,
    UIView * _Nullable *interactionView,
    NSString * _Nullable *nativeAlertActionLabel
) {
    NSCAssert(
        NSThread.isMainThread,
        @"DOM live identity lookup is main-only"
    );
    if (![element isKindOfClass:NSDictionary.class] ||
        ![element[@"nodeID"] isKindOfClass:NSString.class] ||
        !IOSUseDOMIsInteger(element[@"snapshotGeneration"])) {
        return NO;
    }
    unsigned long long generation =
        [element[@"snapshotGeneration"] unsignedLongLongValue];
    if (generation == 0 ||
        generation != IOSUseDOMLiveIdentityGeneration) {
        return NO;
    }
    IOSUseDOMLiveIdentityRecord *record =
        IOSUseDOMLiveIdentityRecords[element[@"nodeID"]];
    if (record == nil || record.generation != generation) {
        return NO;
    }
    NSDictionary<NSString *, id> *frame = element[@"frame"];
    if (![frame isKindOfClass:NSDictionary.class] ||
        !IOSUseDOMIsNumber(frame[@"x"]) ||
        !IOSUseDOMIsNumber(frame[@"y"]) ||
        !IOSUseDOMIsNumber(frame[@"width"]) ||
        !IOSUseDOMIsNumber(frame[@"height"])) {
        return NO;
    }
    CGRect serializedFrame = CGRectMake(
        [frame[@"x"] doubleValue],
        [frame[@"y"] doubleValue],
        [frame[@"width"] doubleValue],
        [frame[@"height"] doubleValue]
    );
    if (fabs(serializedFrame.origin.x - record.frame.origin.x) >
            0.001 ||
        fabs(serializedFrame.origin.y - record.frame.origin.y) >
            0.001 ||
        fabs(serializedFrame.size.width - record.frame.size.width) >
            0.001 ||
        fabs(serializedFrame.size.height - record.frame.size.height) >
            0.001) {
        return NO;
    }
    if (!IOSUseDOMIsInteger(element[@"elementType"]) ||
        [element[@"elementType"] integerValue] !=
            record.elementType) {
        return NO;
    }
    NSString *serializedIdentifier =
        [element[@"identifier"] isKindOfClass:NSString.class]
            ? element[@"identifier"]
            : nil;
    if (!IOSUseDOMNullableStringsEqual(
            serializedIdentifier,
            record.identifier ?: @""
        )) {
        return NO;
    }

    id liveObject = record.object;
    UIView *recordedInteractionView = record.interactionView;
    IOSUseDOMLiveIdentityKind kind =
        (IOSUseDOMLiveIdentityKind)record.kind;
    NSDictionary<NSString *, id> *currentNativeAction =
        IOSUseDOMExactNativeAlertAction(
            kind,
            record.elementType,
            [element[@"label"] isKindOfClass:NSString.class]
                ? element[@"label"]
                : @"",
            serializedFrame,
            nil
        );
    NSString *currentNativeActionLabel =
        currentNativeAction[@"label"];
    if (record.nativeAlertActionLabel.length > 0) {
        if (![currentNativeActionLabel
                isEqualToString:
                    record.nativeAlertActionLabel] ||
            !IOSUseDOMFramesMatchWithinTolerance(
                IOSUseDOMNativeAlertActionFrame(
                    currentNativeAction[@"frame"]
                ),
                record.nativeAlertActionFrame
            ) ||
            [currentNativeAction[@"index"] integerValue] !=
                record.nativeAlertActionIndex) {
            return NO;
        }
    } else {
        currentNativeActionLabel = nil;
    }

    if (kind == IOSUseDOMLiveIdentityKindAppKitProxy) {
        if (record.nativeAlertActionLabel.length == 0) {
            return NO;
        }
    } else if (kind == IOSUseDOMLiveIdentityKindWebProxy) {
        if (recordedInteractionView == nil ||
            recordedInteractionView.window == nil ||
            recordedInteractionView.window !=
                record.snapshotWindow ||
            IOSUseDOMNormalizedInteractionView(
                recordedInteractionView
            ) != recordedInteractionView) {
            return NO;
        }
    } else {
        if (liveObject == nil) {
            return NO;
        }
        NSString *currentIdentifier = IOSUseDOMIdentityString(
            IOSUseDOMObjectValue(
                liveObject,
                NSSelectorFromString(
                    @"accessibilityIdentifier"
                )
            )
        );
        if (!IOSUseDOMNullableStringsEqual(
                currentIdentifier,
                record.identifier
            ) ||
            !IOSUseDOMNullableStringsEqual(
                IOSUseDOMCurrentSemanticLabel(liveObject),
                record.semanticLabel
            ) ||
            IOSUseDOMAccessibilityTraits(liveObject) !=
                record.accessibilityTraits ||
            ([liveObject isKindOfClass:UIControl.class] &&
             [(UIControl *)liveObject isEnabled] !=
                record.controlEnabled)) {
            return NO;
        }
        if (kind ==
                IOSUseDOMLiveIdentityKindNativeAlertMirror &&
            !IOSUseDOMObjectBelongsToNativeAlertMirror(
                liveObject,
                record.rawViewAncestor
            )) {
            return NO;
        }
        UIView *currentInteractionView =
            IOSUseDOMInteractionView(
                liveObject,
                record.rawViewAncestor
            );
        if (currentInteractionView != recordedInteractionView) {
            return NO;
        }
        UIWindow *currentWindow =
            currentInteractionView.window ?:
            ([liveObject isKindOfClass:UIView.class]
                ? [(UIView *)liveObject window]
                : record.rawViewAncestor.window);
        if (currentWindow == nil ||
            currentWindow != record.snapshotWindow) {
            return NO;
        }
        if ([liveObject isKindOfClass:UIView.class]) {
            UIView *liveView = liveObject;
            if (liveView.window == nil ||
                liveView.superview !=
                    record.snapshotSuperview ||
                (recordedInteractionView != nil &&
                 liveView.window !=
                    recordedInteractionView.window)) {
                return NO;
            }
        } else {
            id currentContainer = IOSUseDOMObjectValue(
                liveObject,
                NSSelectorFromString(
                    @"accessibilityContainer"
                )
            );
            if (currentContainer == nil ||
                currentContainer !=
                record.snapshotAccessibilityContainer) {
                return NO;
            }
        }
        if (recordedInteractionView != nil) {
            if (recordedInteractionView.window == nil) {
                return NO;
            }
        } else if (record.rawViewAncestor == nil ||
                   record.rawViewAncestor.window == nil) {
            return NO;
        }
        UIView *visibilityView =
            [liveObject isKindOfClass:UIView.class]
                ? liveObject
                : (recordedInteractionView ?:
                    record.rawViewAncestor);
        if (visibilityView == nil ||
            !IOSUseDOMViewIsActuallyVisibleInWindow(
                visibilityView
            )) {
            return NO;
        }
        if (kind == IOSUseDOMLiveIdentityKindGeneric &&
            !IOSUseDOMFramesMatchWithinTolerance(
                IOSUseDOMObjectRect(liveObject),
                record.frame
            )) {
            return NO;
        }
    }
    if (object != NULL) {
        *object = liveObject;
    }
    if (interactionView != NULL) {
        *interactionView = recordedInteractionView;
    }
    if (nativeAlertActionLabel != NULL) {
        *nativeAlertActionLabel = currentNativeActionLabel;
    }
    return YES;
}

static void IOSUseDOMRegisterWebBridgeElement(
    IOSUseDOMWebAccessibilityElement *proxy,
    IOSUseDOMNode *node
) {
    NSCAssert(
        NSThread.isMainThread,
        @"Web accessibility registry is main-only"
    );
    if (proxy == nil ||
        node == nil ||
        proxy.webView == nil ||
        proxy.webIdentity.length == 0 ||
        IOSUseDOMWebBridgeRecords.count >=
            IOSUseDOMMaximumWebElementCount ||
        IOSUseDOMWebBridgeGeneration != node.generation) {
        return;
    }
    IOSUseDOMWebBridgeRecord *record =
        [IOSUseDOMWebBridgeRecord new];
    record.webView = proxy.webView;
    record.generation = node.generation;
    record.nodeID = node.nodeID;
    record.ordinal = proxy.webOrdinal;
    record.identity = proxy.webIdentity;
    record.role = proxy.webRole;
    record.tag = proxy.webTag;
    record.label = node.label ?: proxy.webLabel ?: @"";
    record.serializedLabel = record.label;
    record.identifier =
        node.identifier ?: proxy.webIdentifier ?: @"";
    record.localFrame = proxy.webLocalFrame;
    record.screenFrame = proxy.webScreenFrame;
    record.disabled = proxy.webDisabled;
    record.secure = proxy.webSecure;
    IOSUseDOMWebBridgeRecords[node.nodeID] = record;
}

static BOOL IOSUseDOMViewIsActuallyVisibleInWindow(UIView *view);

static NSArray *IOSUseDOMChildren(
    id object,
    BOOL accessibilityElement,
    BOOL hierarchyVisible,
    BOOL *hasAutomationChildren,
    IOSUseDOMCaptureContext *context
) {
    if (!hierarchyVisible) {
        if (hasAutomationChildren != NULL) {
            *hasAutomationChildren = NO;
        }
        return @[];
    }
    if (hierarchyVisible &&
        [object isKindOfClass:WKWebView.class] &&
        IOSUseDOMViewIsActuallyVisibleInWindow(object)) {
        NSArray *webAccessibilityElements =
            IOSUseDOMWebAccessibilityElements(
                object,
                context
            );
        if (context.failureMessage != nil) {
            return @[];
        }
        if (webAccessibilityElements.count > 0) {
            if (hasAutomationChildren != NULL) {
                *hasAutomationChildren = YES;
            }
            return IOSUseDOMUniqueChildren(
                webAccessibilityElements,
                object,
                context
            );
        }
    }

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
        return IOSUseDOMUniqueChildren(
            automation,
            object,
            context
        );
    }
    if (hasAutomationChildren != NULL) {
        *hasAutomationChildren = NO;
    }

    // Accessibility elements are opaque leaves unless the XCTest-style
    // automation source above explicitly exposes descendants. Recursing into
    // every backing SwiftUI hosting subview in addition to its accessibility
    // container is both duplicate work and can exceed the bounded main-thread
    // snapshot deadline.
    if (accessibilityElement &&
        ![object isKindOfClass:UIWindow.class]) {
        return @[];
    }

    NSArray *accessibilityElements = IOSUseDOMArrayForSelector(
        object,
        NSSelectorFromString(@"accessibilityElements"),
        NULL
    );
    if (context.failureMessage != nil) {
        return @[];
    }
    if (accessibilityElements.count > 0) {
        return IOSUseDOMUniqueChildren(
            accessibilityElements,
            object,
            context
        );
    }

    NSArray *containerElements = IOSUseDOMContainerElements(object, context);
    if (context.failureMessage != nil) {
        return @[];
    }
    if (containerElements.count > 0) {
        return IOSUseDOMUniqueChildren(
            containerElements,
            object,
            context
        );
    }

    if ([object isKindOfClass:UIView.class]) {
        NSArray<UIView *> *subviews = [(UIView *)object subviews];
        return IOSUseDOMUniqueChildren(
            subviews ?: @[],
            object,
            context
        );
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

static BOOL IOSUseDOMViewIsActuallyVisibleInWindow(UIView *view) {
    UIWindow *window = view.window;
    if (window == nil || window.hidden || window.alpha <= 0.01) {
        return NO;
    }
    for (UIView *current = view;
         current != nil;
         current = current.superview) {
        if (current.hidden ||
            current.alpha <= 0.01 ||
            current.accessibilityElementsHidden) {
            return NO;
        }
    }
    CGRect rect = [view convertRect:view.bounds toView:window];
    return IOSUseDOMRectHasArea(rect) &&
        IOSUseDOMRectHasArea(
            CGRectIntersection(rect, window.bounds)
        );
}

static BOOL IOSUseDOMIsNativeAlertMirrorRootShape(id object) {
    if (![object isKindOfClass:UIView.class]) {
        return NO;
    }
    NSString *className = NSStringFromClass([object class]) ?: @"";
    return [className containsString:@"UIAlertController"] &&
        [className containsString:@"MacView"];
}

static BOOL IOSUseDOMIsNativeAlertMirrorRoot(id object) {
    return IOSUseDOMIsNativeAlertMirrorRootShape(object) &&
        [IOSUsePlayAppKitBridge hasVisibleNativeAlert];
}

static BOOL IOSUseDOMViewHasNativeAlertMirrorShape(
    UIView * _Nullable view
) {
    for (UIView *candidate = view;
         candidate != nil;
         candidate = candidate.superview) {
        if (IOSUseDOMIsNativeAlertMirrorRootShape(candidate)) {
            return YES;
        }
    }
    return NO;
}

static BOOL IOSUseDOMObjectHasNativeAlertMirrorShape(
    id object,
    UIView * _Nullable rawViewAncestor
) {
    if ([object isKindOfClass:UIView.class] &&
        IOSUseDOMViewHasNativeAlertMirrorShape(object)) {
        return YES;
    }
    NSHashTable<id> *visited = [NSHashTable
        hashTableWithOptions:
            NSPointerFunctionsObjectPointerPersonality |
            NSPointerFunctionsStrongMemory];
    id current = object;
    for (NSUInteger depth = 0;
         current != nil && depth < IOSUseDOMMaximumDepth;
         depth += 1) {
        if ([visited containsObject:current]) {
            break;
        }
        [visited addObject:current];
        id container = IOSUseDOMObjectValue(
            current,
            NSSelectorFromString(@"accessibilityContainer")
        );
        if (container == nil || container == current) {
            break;
        }
        if ([container isKindOfClass:UIView.class]) {
            return IOSUseDOMViewHasNativeAlertMirrorShape(
                container
            );
        }
        current = container;
    }
    return IOSUseDOMViewHasNativeAlertMirrorShape(
        rawViewAncestor
    );
}

static BOOL IOSUseDOMObjectBelongsToNativeAlertMirror(
    id object,
    UIView * _Nullable rawViewAncestor
) {
    return IOSUseDOMObjectHasNativeAlertMirrorShape(
        object,
        rawViewAncestor
    ) && [IOSUsePlayAppKitBridge hasVisibleNativeAlert];
}

static CGRect IOSUseDOMNativeAlertActionFrame(id value) {
    if (![value isKindOfClass:NSDictionary.class] ||
        !IOSUseDOMIsNumber(value[@"x"]) ||
        !IOSUseDOMIsNumber(value[@"y"]) ||
        !IOSUseDOMIsNumber(value[@"width"]) ||
        !IOSUseDOMIsNumber(value[@"height"])) {
        return CGRectNull;
    }
    CGRect frame = CGRectMake(
        [value[@"x"] doubleValue],
        [value[@"y"] doubleValue],
        [value[@"width"] doubleValue],
        [value[@"height"] doubleValue]
    );
    return IOSUseDOMRectHasArea(frame) ? frame : CGRectNull;
}

static BOOL IOSUseDOMFramesMatchWithinTolerance(
    CGRect left,
    CGRect right
) {
    const CGFloat tolerance = 0.5;
    return IOSUseDOMRectHasArea(left) &&
        IOSUseDOMRectHasArea(right) &&
        fabs(left.origin.x - right.origin.x) <= tolerance &&
        fabs(left.origin.y - right.origin.y) <= tolerance &&
        fabs(left.size.width - right.size.width) <= tolerance &&
        fabs(left.size.height - right.size.height) <= tolerance;
}

static BOOL IOSUseDOMNativeAlertActionContainsProxyFrame(
    CGRect actionFrame,
    CGRect proxyFrame
) {
    const CGFloat tolerance = 0.5;
    const CGFloat maximumInset = 5.5;
    if (!IOSUseDOMRectHasArea(actionFrame) ||
        !IOSUseDOMRectHasArea(proxyFrame) ||
        fabs(CGRectGetMidX(actionFrame) -
             CGRectGetMidX(proxyFrame)) > tolerance ||
        fabs(CGRectGetMidY(actionFrame) -
             CGRectGetMidY(proxyFrame)) > tolerance) {
        return NO;
    }
    CGFloat leftInset =
        CGRectGetMinX(proxyFrame) - CGRectGetMinX(actionFrame);
    CGFloat topInset =
        CGRectGetMinY(proxyFrame) - CGRectGetMinY(actionFrame);
    CGFloat rightInset =
        CGRectGetMaxX(actionFrame) - CGRectGetMaxX(proxyFrame);
    CGFloat bottomInset =
        CGRectGetMaxY(actionFrame) - CGRectGetMaxY(proxyFrame);
    return leftInset >= -tolerance &&
        leftInset <= maximumInset &&
        topInset >= -tolerance &&
        topInset <= maximumInset &&
        rightInset >= -tolerance &&
        rightInset <= maximumInset &&
        bottomInset >= -tolerance &&
        bottomInset <= maximumInset;
}

static NSDictionary<NSString *, id> * _Nullable
IOSUseDOMExactNativeAlertAction(
    IOSUseDOMLiveIdentityKind kind,
    NSInteger elementType,
    NSString *label,
    CGRect frame,
    NSArray<NSDictionary<NSString *, id> *> * _Nullable actions
) {
    if ((kind != IOSUseDOMLiveIdentityKindAppKitProxy &&
         kind != IOSUseDOMLiveIdentityKindNativeAlertMirror) ||
        elementType != 9 ||
        label.length == 0) {
        return nil;
    }
    if (actions == nil) {
        if (![IOSUsePlayAppKitBridge
                hasVisibleNativeAlertCandidate]) {
            return nil;
        }
        actions = [IOSUsePlayAppKitBridge nativeAlertActions];
    }
    NSDictionary<NSString *, id> *matchedAction = nil;
    for (NSDictionary<NSString *, id> *action in actions) {
        CGRect actionFrame =
            IOSUseDOMNativeAlertActionFrame(action[@"frame"]);
        if (![action[@"label"] isKindOfClass:NSString.class] ||
            ![action[@"label"] isEqualToString:label] ||
            !(IOSUseDOMFramesMatchWithinTolerance(
                  actionFrame,
                  frame
              ) ||
              (kind == IOSUseDOMLiveIdentityKindAppKitProxy &&
               IOSUseDOMNativeAlertActionContainsProxyFrame(
                   actionFrame,
                   frame
               )))) {
            continue;
        }
        if (matchedAction != nil) {
            return nil;
        }
        matchedAction = action;
    }
    return matchedAction;
}

static CGRect IOSUseDOMNativeAlertAdjustedRect(
    id object,
    NSString *label,
    CGRect fallback,
    UIView * _Nullable rawViewAncestor,
    NSArray<NSDictionary<NSString *, id> *> *nativeAlertActions
) {
    if (IOSUseDOMIsNativeAlertMirrorRoot(object)) {
        CGRect panelFrame = [IOSUsePlayAppKitBridge nativeAlertFrame];
        return CGRectIsNull(panelFrame) ? fallback : panelFrame;
    }
    if (label.length == 0 ||
        nativeAlertActions.count == 0 ||
        !IOSUseDOMObjectHasNativeAlertMirrorShape(
            object,
            rawViewAncestor
        )) {
        return fallback;
    }
    for (NSDictionary<NSString *, id> *action in
         nativeAlertActions) {
        if (![action[@"label"] isEqualToString:label]) {
            continue;
        }
        CGRect actionFrame =
            IOSUseDOMNativeAlertActionFrame(action[@"frame"]);
        if (CGRectIsNull(actionFrame)) {
            return fallback;
        }
        return actionFrame;
    }
    return fallback;
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
    if ([object isKindOfClass:IOSUseDOMWebAccessibilityElement.class]) {
        NSString *role =
            ((IOSUseDOMWebAccessibilityElement *)object).webRole;
        if ([role isEqualToString:@"input"]) {
            return 49;
        }
        if ([role isEqualToString:@"button"]) {
            return 9;
        }
        if ([role isEqualToString:@"link"]) {
            return 42;
        }
        if ([role isEqualToString:@"heading"] ||
            [role isEqualToString:@"text"]) {
            return 48;
        }
    }
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
    UIView * _Nullable rawViewAncestor,
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
    id labelObject = IOSUseDOMObjectValue(
        object,
        NSSelectorFromString(@"accessibilityLabel")
    );
    NSString *label = IOSUseDOMBoundedString(labelObject, context);
    if (context.failureMessage != nil) {
        return nil;
    }
    id visibleLabelObject = nil;
    if ([object isKindOfClass:UILabel.class]) {
        visibleLabelObject = [(UILabel *)object text];
    } else if ([object isKindOfClass:UIButton.class]) {
        visibleLabelObject = [(UIButton *)object currentTitle];
    } else if ([object isKindOfClass:UITextField.class]) {
        visibleLabelObject = [(UITextField *)object placeholder];
    } else if ([object isKindOfClass:UISearchBar.class]) {
        visibleLabelObject = [(UISearchBar *)object placeholder];
    }
    NSString *visibleLabel = IOSUseDOMBoundedString(
        visibleLabelObject,
        context
    );
    if (context.failureMessage != nil) {
        return nil;
    }
    // UIKitMacHelper can report accessibilityIdentifier as
    // accessibilityLabel for ordinary UIKit views. Preserve an explicit
    // semantic label, but prefer the actual rendered control text when the
    // reported label is empty or merely duplicates the identifier.
    if (visibleLabel.length > 0 &&
        (label.length == 0 ||
         [label isEqualToString:identifier])) {
        label = visibleLabel;
    }
    id hintObject = IOSUseDOMObjectValue(
        object,
        NSSelectorFromString(@"accessibilityHint")
    );
    NSString *hint = IOSUseDOMBoundedString(hintObject, context);
    if (context.failureMessage != nil) {
        return nil;
    }
    NSString *liveInputValue =
        IOSUseDOMLiveInputValue(object);
    id valueObject = liveInputValue.length > 0
        ? liveInputValue
        : IOSUseDOMObjectValue(
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
        IOSUseDOMIsNativeAlertMirrorRoot(object) ||
        (ancestorVisible && IOSUseDOMObjectHierarchyVisible(object));
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
    CGRect rect = IOSUseDOMNativeAlertAdjustedRect(
        object,
        label,
        IOSUseDOMObjectRect(object),
        rawViewAncestor,
        context.nativeAlertActions
    );
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
        hierarchyVisible,
        &hasAutomationChildren,
        context
    );
    if (context.failureMessage != nil) {
        return nil;
    }
    NSMutableArray<IOSUseDOMNode *> *children =
        [NSMutableArray arrayWithCapacity:childObjects.count];
    UIView *nearestRawView = [object isKindOfClass:UIView.class]
        ? object
        : rawViewAncestor;
    for (id childObject in childObjects) {
        IOSUseDOMNode *child = IOSUseDOMBuildNode(
            childObject,
            depth + 1,
            hierarchyVisible,
            disabled,
            effectiveClip,
            nearestRawView,
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
    node.object = object;
    node.nodeID = [NSString stringWithFormat:
        @"g%llu-n%lu",
        context.generation,
        (unsigned long)context.nextNodeOrdinal
    ];
    context.nextNodeOrdinal += 1;
    node.generation = context.generation;
    node.elementType = IOSUseDOMElementType(object, accessibilityTraits);
    node.typeName = IOSUseDOMElementTypeName(node.elementType);
    node.label = label.length > 0 ? label : identifier;
    node.value = value;
    node.identifier = identifier;
    node.hint = hint;
    node.className = NSStringFromClass([object class]) ?: @"NSObject";
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
    IOSUseDOMRegisterLiveIdentity(
        node,
        object,
        rawViewAncestor,
        context
    );
    if ([object
            isKindOfClass:
                IOSUseDOMWebAccessibilityElement.class]) {
        IOSUseDOMRegisterWebBridgeElement(
            (IOSUseDOMWebAccessibilityElement *)object,
            node
        );
    }
    (void)hasAutomationChildren;
    return node;
}

static NSInteger IOSUseDOMAppKitElementType(
    IOSUseDOMAppKitAccessibilityElement *proxy
) {
    if ([proxy.appKitRole isEqualToString:@"button"]) {
        return 9;
    }
    if ([proxy.appKitRole isEqualToString:@"link"]) {
        return 42;
    }
    return 48;
}

static BOOL IOSUseDOMFramesSemanticallyOverlap(
    CGRect left,
    CGRect right
) {
    if (!IOSUseDOMRectHasArea(left) ||
        !IOSUseDOMRectHasArea(right)) {
        return NO;
    }
    CGRect intersection = CGRectIntersection(left, right);
    if (!IOSUseDOMRectHasArea(intersection)) {
        return NO;
    }
    CGFloat intersectionArea =
        intersection.size.width * intersection.size.height;
    CGFloat smallerArea = MIN(
        left.size.width * left.size.height,
        right.size.width * right.size.height
    );
    return smallerArea > 0 &&
        intersectionArea / smallerArea >= 0.8;
}

static BOOL IOSUseDOMRawNodeDuplicatesAppKitProxy(
    IOSUseDOMNode *node,
    IOSUseDOMAppKitAccessibilityElement *proxy
) {
    if (!node.invisible) {
        CGRect proxyFrame = proxy.accessibilityFrame;
        if (node.elementType == 58 &&
            IOSUseDOMRectHasArea(node.rect) &&
            CGRectContainsPoint(
                node.rect,
                CGPointMake(
                    CGRectGetMidX(proxyFrame),
                    CGRectGetMidY(proxyFrame)
                )
            )) {
            // WKWebView semantics are owned exclusively by the fixed isolated
            // Web bridge, including when AppKit mirrors the same descendants.
            return YES;
        }
        NSString *proxyIdentifier =
            proxy.accessibilityIdentifier ?: @"";
        NSString *proxyLabel = proxy.accessibilityLabel ?: @"";
        BOOL compatibleType =
            node.elementType == IOSUseDOMAppKitElementType(proxy);
        BOOL overlapping = IOSUseDOMFramesSemanticallyOverlap(
            node.rect,
            proxyFrame
        );
        BOOL sameIdentifier =
            proxyIdentifier.length > 0 &&
            [node.identifier isEqualToString:proxyIdentifier];
        BOOL sameSemanticText =
            proxyLabel.length > 0 &&
            ([node.label isEqualToString:proxyLabel] ||
             [node.value isEqualToString:proxyLabel]);
        if (sameIdentifier) {
            // Matching identity is covered when geometry/type agree. A
            // conflicting native node still suppresses the lower-priority
            // AppKit mirror rather than creating an ambiguous duplicate.
            return YES;
        }
        if (compatibleType && overlapping) {
            // Equal semantics are a mirror. Conflicting non-empty semantics at
            // the same role/frame are also dropped fail-closed.
            if (sameSemanticText ||
                node.label.length > 0 ||
                node.value.length > 0) {
                return YES;
            }
        }
        if (IOSUseDOMAppKitElementType(proxy) == 48 &&
            node.elementType == 9 &&
            sameSemanticText &&
            IOSUseDOMFramesSemanticallyOverlap(
                node.rect,
                proxyFrame
            )) {
            // AppKit often exposes a native button's title as a nested
            // AXStaticText. The canonical UIKit button already carries it.
            return YES;
        }
    }
    for (IOSUseDOMNode *child in node.children) {
        if (IOSUseDOMRawNodeDuplicatesAppKitProxy(child, proxy)) {
            return YES;
        }
    }
    return NO;
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
             IOSUseDOMFramesMatchWithinTolerance(
                 node.rect,
                 child.source.rect
             )) &&
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
            if (lhs.activationState != rhs.activationState) {
                return lhs.activationState ==
                        UISceneActivationStateForegroundActive
                    ? NSOrderedAscending
                    : NSOrderedDescending;
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
        NSArray<UIWindow *> *originalWindows = scene.windows;
        NSArray<UIWindow *> *sceneWindows =
            [originalWindows sortedArrayUsingComparator:
                ^NSComparisonResult(UIWindow *lhs, UIWindow *rhs) {
                    if (lhs.windowLevel > rhs.windowLevel) {
                        return NSOrderedAscending;
                    }
                    if (lhs.windowLevel < rhs.windowLevel) {
                        return NSOrderedDescending;
                    }
                    NSUInteger lhsIndex =
                        [originalWindows
                            indexOfObjectIdenticalTo:lhs];
                    NSUInteger rhsIndex =
                        [originalWindows
                            indexOfObjectIdenticalTo:rhs];
                    if (lhsIndex > rhsIndex) {
                        return NSOrderedAscending;
                    }
                    if (lhsIndex < rhsIndex) {
                        return NSOrderedDescending;
                    }
                    return NSOrderedSame;
                }];
        for (UIWindow *window in sceneWindows) {
            if (!window.hidden &&
                window.alpha > 0.01 &&
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
    context.nativeAlertActions =
        [IOSUsePlayAppKitBridge hasVisibleNativeAlertCandidate]
            ? [IOSUsePlayAppKitBridge nativeAlertActions]
            : @[];
    IOSUseDOMResetWebBridgeRecords(context.generation);
    IOSUseDOMResetLiveIdentityRecords(context.generation);

    NSMutableArray<IOSUseDOMNode *> *rawRoots =
        [NSMutableArray arrayWithCapacity:windows.count];
    for (UIWindow *window in windows) {
        IOSUseDOMNode *root = IOSUseDOMBuildNode(
            window,
            0,
            YES,
            NO,
            screenBounds,
            nil,
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

    NSArray<IOSUseDOMAppKitAccessibilityElement *> *appKitElements =
        IOSUseDOMAppKitAccessibilityElements(
            primaryWindow,
            context
        );
    if (context.failureMessage != nil || appKitElements == nil) {
        if (failureMessage != NULL) {
            *failureMessage = context.failureMessage ?:
                @"AppKit accessibility bridge failed";
        }
        return nil;
    }
    for (IOSUseDOMAppKitAccessibilityElement *proxy in
         appKitElements) {
        BOOL duplicate = NO;
        for (IOSUseDOMNode *root in rawRoots) {
            if (IOSUseDOMRawNodeDuplicatesAppKitProxy(root, proxy)) {
                duplicate = YES;
                break;
            }
        }
        if (duplicate) {
            continue;
        }
        IOSUseDOMNode *root = IOSUseDOMBuildNode(
            proxy,
            0,
            YES,
            NO,
            screenBounds,
            nil,
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

static NSArray<NSString *> *IOSUseDOMAncestorNames(
    IOSUseCleanNode *node
);

static NSDictionary<NSString *, id> *IOSUseDOMElementJSON(
    IOSUseCleanNode *node
) {
    IOSUseDOMWebBridgeRecord *webRecord =
        IOSUseDOMWebBridgeRecords[node.source.nodeID];
    if (webRecord != nil &&
        webRecord.generation == node.source.generation) {
        webRecord.serializedLabel =
            node.displayLabel ?: webRecord.label;
    }
    NSMutableArray<NSString *> *path = [NSMutableArray array];
    IOSUseCleanNode *cursor = node;
    while (cursor != nil && path.count <= IOSUseDOMMaximumDepth) {
        [path addObject:cursor.source.nodeID ?: @""];
        cursor = cursor.parent;
    }
    path = [[[path reverseObjectEnumerator] allObjects] mutableCopy];
    NSInteger depth = MAX(0, (NSInteger)path.count - 1);
    NSInteger siblingIndex = 0;
    if (node.parent != nil) {
        NSUInteger index = [node.parent.children indexOfObjectIdenticalTo:node];
        siblingIndex =
            index == NSNotFound ? 0 : (NSInteger)index;
    }
    NSInteger zOrder = 0;
    NSRange ordinalMarker =
        [node.source.nodeID rangeOfString:@"-n"
                                 options:NSBackwardsSearch];
    if (ordinalMarker.location != NSNotFound) {
        zOrder = [[node.source.nodeID substringFromIndex:
            NSMaxRange(ordinalMarker)] integerValue];
    }
    CGRect rect = node.source.hasRect
        ? node.source.rect
        : CGRectZero;
    NSMutableDictionary<NSString *, id> *element = [@{
        @"nodeID": node.source.nodeID ?: @"",
        @"type": node.source.typeName ?: @"-",
        @"elementType": @(node.source.elementType),
        @"elemType": @(node.source.elementType),
        @"label": node.displayLabel ?: @"",
        @"value": node.source.value ?: @"",
        @"identifier": node.source.identifier ?: @"",
        @"hint": node.source.hint ?: @"",
        @"class": node.source.className ?: @"NSObject",
        @"traits": node.traits ?: @[],
        @"state": @{
            @"enabled": @((BOOL)!node.source.disabled),
            @"visible": @((BOOL)!node.source.invisible),
            @"selected": @(node.source.selected),
            @"focused": @(node.source.focused),
            @"opaque": @(node.opaque),
        },
        @"hierarchy": @{
            @"parentID": node.parent == nil
                ? (id)NSNull.null
                : node.parent.source.nodeID,
            @"depth": @(depth),
            @"index": @(siblingIndex),
            @"path": path,
        },
        @"ancestors": IOSUseDOMAncestorNames(node),
        @"zOrder": @(zOrder),
        @"snapshotGeneration": @(node.source.generation),
    } mutableCopy];
    if (node.source.hasRect) {
        element[@"frame"] = @{
            @"x": @(rect.origin.x),
            @"y": @(rect.origin.y),
            @"width": @(rect.size.width),
            @"height": @(rect.size.height),
        };
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
            @"nodeID": @"",
            @"type": @"-",
            @"elementType": @0,
            @"elemType": @0,
            @"label": @"",
            @"value": @"",
            @"identifier": @"",
            @"hint": @"",
            @"class": @"NSObject",
            @"traits": @[],
            @"state": @{
                @"enabled": @NO,
                @"visible": @NO,
                @"selected": @NO,
                @"focused": @NO,
                @"opaque": @NO,
            },
            @"hierarchy": @{
                @"parentID": NSNull.null,
                @"depth": @0,
                @"index": @0,
                @"path": @[],
            },
            @"zOrder": @0,
            @"snapshotGeneration": @0,
            @"ancestors": @[],
        };
    }
    return IOSUseDOMElementJSON(node);
}

static NSDictionary<NSString *, id> *IOSUseDOMFindMatchJSON(
    IOSUseCleanNode *node
) {
    return IOSUseDOMElementJSON(node);
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

static NSArray<NSDictionary<NSString *, id> *> *
IOSUseDOMSnapshotFingerprint(IOSUseDOMSnapshot *snapshot) {
    NSMutableArray<NSDictionary<NSString *, id> *> *fingerprint =
        [NSMutableArray arrayWithCapacity:snapshot.elements.count + 1];
    [fingerprint addObject:@{
        @"application": snapshot.application ?: @"",
        @"windowSize": @[
            @(snapshot.windowSize.width),
            @(snapshot.windowSize.height),
        ],
    }];
    for (IOSUseCleanNode *element in snapshot.elements) {
        IOSUseDOMNode *source = element.source;
        NSArray<NSString *> *ancestors =
            IOSUseDOMAncestorNames(element);
        [fingerprint addObject:@{
            @"elementType": @(source.elementType),
            @"type": source.typeName ?: @"",
            @"label": source.label ?: @"",
            @"value": source.value ?: @"",
            @"identifier": source.identifier ?: @"",
            @"hint": source.hint ?: @"",
            @"class": source.className ?: @"",
            @"rect": source.hasRect
                ? @[
                    @(source.rect.origin.x),
                    @(source.rect.origin.y),
                    @(source.rect.size.width),
                    @(source.rect.size.height),
                ]
                : @[],
            @"state": @[
                @(!source.disabled),
                @(!source.invisible),
                @(source.selected),
                @(source.focused),
                @(element.opaque),
            ],
            @"traits": element.traits ?: @[],
            @"ancestors": ancestors ?: @[],
        }];
    }
    return fingerprint;
}

static void IOSUseDOMQuiescencePause(void) {
    const NSTimeInterval interval = 0.05;
    if (NSThread.isMainThread) {
        [NSRunLoop.currentRunLoop
            runUntilDate:[NSDate dateWithTimeIntervalSinceNow:interval]];
    } else {
        usleep((useconds_t)(interval * 1000000.0));
    }
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
    if (waitQuiescence) {
        CFAbsoluteTime deadline =
            CFAbsoluteTimeGetCurrent() +
            IOSUseDOMMainThreadTimeoutSeconds;
        NSArray<NSDictionary<NSString *, id> *> *previous =
            IOSUseDOMSnapshotFingerprint(snapshot);
        BOOL stabilized = NO;
        while (CFAbsoluteTimeGetCurrent() < deadline) {
            IOSUseDOMQuiescencePause();
            NSTimeInterval remaining =
                deadline - CFAbsoluteTimeGetCurrent();
            if (remaining <= 0) {
                break;
            }
            NSDictionary<NSString *, id> *nextError = nil;
            IOSUseDOMSnapshot *next = IOSUseDOMFreshSnapshot(
                remaining,
                nil,
                &nextError
            );
            if (next == nil) {
                if (commandError != NULL) {
                    *commandError = nextError;
                }
                return nil;
            }
            NSArray<NSDictionary<NSString *, id> *> *current =
                IOSUseDOMSnapshotFingerprint(next);
            snapshot = next;
            if ([previous isEqualToArray:current]) {
                stabilized = YES;
                break;
            }
            previous = current;
        }
        if (!stabilized) {
            if (commandError != NULL) {
                *commandError = IOSUseDOMError(
                    @"quiescence_timed_out",
                    @"DOM did not produce two consecutive stable snapshots within 2 seconds",
                    @"timeout",
                    @"quiescence",
                    YES,
                    nil,
                    snapshot.elements.count,
                    IOSUseDOMCandidatesJSON(snapshot.elements, nil)
                );
            }
            return nil;
        }
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
