#import "XCTestPrivate.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static const NSUInteger XCMaxTextAbbrLen = 12;
static const NSUInteger XCMaxClearRetries = 3;
static const int XCSnapshotMaxChildrenLimit = 150;
static const NSUInteger XCSnapshotChildrenViewportPruneThreshold = 75;
static const CGFloat XCSnapshotChildrenViewportMargin = 3.0;
static const double XCTapLiftUpDelay = 0.08;
static const double XCDefaultLongPressDuration = 0.5;
static const CGFloat XCDetectionPointScreenRatio = 0.2;
static const int64_t XCSynthesizeEventTimeoutSeconds = 5;
static const int64_t XCScreenshotTimeoutSeconds = 20;

static id XCFirstNonEmptyValue(id primary, id fallback) {
    if ([primary isKindOfClass:[NSString class]] && [((NSString *)primary) length] > 0) {
        return primary;
    }
    if (primary != nil && ![primary isKindOfClass:[NSNull class]]) {
        return primary;
    }
    if ([fallback isKindOfClass:[NSString class]] && [((NSString *)fallback) length] > 0) {
        return fallback;
    }
    return fallback;
}

static BOOL XCSupportsInnerText(NSUInteger elementType) {
    switch ((XCUIElementType)elementType) {
        case XCUIElementTypeTextField:
        case XCUIElementTypeSecureTextField:
        case XCUIElementTypeSearchField:
        case XCUIElementTypeTextView:
            return YES;
        default:
            return NO;
    }
}

static NSString *XCSanitizedSnapshotString(NSString *value) {
    if (![value isKindOfClass:[NSString class]]) {
        return nil;
    }

    static NSCharacterSet *trimSet;
    static NSCharacterSet *invisibleSet;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableCharacterSet *trim = [NSMutableCharacterSet whitespaceAndNewlineCharacterSet].mutableCopy;
        [trim addCharactersInString:@"\u200B\u200C\u200D\u2060\uFEFF"];
        trimSet = trim.copy;

        NSMutableCharacterSet *invalid = [NSMutableCharacterSet controlCharacterSet].mutableCopy;
        [invalid removeCharactersInString:@"\t\n\r"];
        [invalid addCharactersInString:@"\u200B\u200C\u200D\u2060\uFEFF"];
        invisibleSet = invalid.copy;
    });

    NSString *trimmed = [value stringByTrimmingCharactersInSet:trimSet];
    if (trimmed.length == 0) {
        return nil;
    }
    return [[trimmed componentsSeparatedByCharactersInSet:invisibleSet] componentsJoinedByString:@""];
}

static id XCValueForKeySafely(id raw, NSString *key) {
    if (!raw || !key) return nil;
    @try {
        return [raw valueForKey:key];
    } @catch (NSException *e) {
        return nil;
    }
}

static CGRect XCRawSnapshotFrame(id raw) {
    NSValue *value = XCValueForKeySafely(raw, @"frame");
    if (![value isKindOfClass:[NSValue class]]) {
        return CGRectZero;
    }
    return [value CGRectValue];
}

static BOOL XCRawSnapshotIsVisibleInAppFrame(id raw, CGRect appFrame) {
    NSNumber *value = XCValueForKeySafely(raw, @"isVisible");
    if ([value isKindOfClass:[NSNumber class]]) {
        return [value boolValue];
    }

    CGRect frame = XCRawSnapshotFrame(raw);
    if (frame.size.width <= 0 || frame.size.height <= 0) {
        return NO;
    }
    if (CGRectIsEmpty(appFrame)) {
        return YES;
    }
    return CGRectIntersectsRect(frame, appFrame);
}

static NSArray *XCPrunedSnapshotChildren(NSArray *rawChildren, CGRect appFrame) {
    NSUInteger count = rawChildren.count;
    if (count <= XCSnapshotChildrenViewportPruneThreshold) {
        return rawChildren;
    }
    if (CGRectIsEmpty(appFrame)) {
        return rawChildren;
    }

    CGRect keepFrame = CGRectInset(appFrame,
                                   -appFrame.size.width * XCSnapshotChildrenViewportMargin,
                                   -appFrame.size.height * XCSnapshotChildrenViewportMargin);
    NSMutableArray *pruned = [NSMutableArray arrayWithCapacity:count];
    NSUInteger droppedCount = 0;
    for (NSUInteger i = 0; i < count; i++) {
        id child = rawChildren[i];
        CGRect frame = XCRawSnapshotFrame(child);
        if (frame.size.width > 0 && frame.size.height > 0 && !CGRectIntersectsRect(frame, keepFrame)) {
            droppedCount += 1;
            continue;
        }
        [pruned addObject:child];
    }

    if (droppedCount == 0) {
        return rawChildren;
    }

    NSLog(@"[driver] SafeSnapshot children pruned rawCount=%lu kept=%lu dropped=%lu threshold=%lu viewportMargin=%.1f",
          (unsigned long)count,
          (unsigned long)pruned.count,
          (unsigned long)droppedCount,
          (unsigned long)XCSnapshotChildrenViewportPruneThreshold,
          XCSnapshotChildrenViewportMargin);
    return pruned;
}

// MARK: - XCTest snapshot request parameters

static id (*XCOriginalDefaultParameters)(id, SEL) = NULL;
static id (*XCOriginalSnapshotParameters)(id, SEL) = NULL;
static NSDictionary *XCDefaultRequestParameters = nil;
static NSDictionary *XCAdditionalRequestParameters = nil;
static NSMutableDictionary *XCCustomRequestParameters = nil;

static void XCSetSnapshotRequestParameter(NSString *name, id value) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        XCCustomRequestParameters = [NSMutableDictionary dictionary];
    });
    if (name.length == 0 || !value) return;
    XCCustomRequestParameters[name] = value;
}

static id XCSwizzledDefaultParameters(id self, SEL _cmd) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!XCOriginalDefaultParameters) return;
        id defaults = XCOriginalDefaultParameters(self, _cmd);
        if ([defaults isKindOfClass:[NSDictionary class]]) {
            XCDefaultRequestParameters = defaults;
        }
    });

    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithDictionary:XCDefaultRequestParameters ?: @{}];
    if ([XCAdditionalRequestParameters isKindOfClass:[NSDictionary class]]) {
        [result addEntriesFromDictionary:XCAdditionalRequestParameters];
    }
    if ([XCCustomRequestParameters isKindOfClass:[NSDictionary class]]) {
        [result addEntriesFromDictionary:XCCustomRequestParameters];
    }
    return result.copy;
}

static id XCSwizzledSnapshotParameters(id self, SEL _cmd) {
    if (!XCOriginalSnapshotParameters) return nil;
    id result = XCOriginalSnapshotParameters(self, _cmd);
    if ([result isKindOfClass:[NSDictionary class]]) {
        XCAdditionalRequestParameters = result;
    }
    return result;
}

static void XCInstallSnapshotRequestParameterPatch(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        XCSetSnapshotRequestParameter(@"maxChildren", @(XCSnapshotMaxChildrenLimit));

        Class clientClass = NSClassFromString(@"XCAXClient_iOS");
        Method defaultParametersMethod = clientClass
            ? class_getInstanceMethod(clientClass, NSSelectorFromString(@"defaultParameters"))
            : NULL;
        if (defaultParametersMethod) {
            XCOriginalDefaultParameters = (id (*)(id, SEL))method_setImplementation(
                defaultParametersMethod,
                (IMP)XCSwizzledDefaultParameters
            );
        }

        Class queryClass = NSClassFromString(@"XCTElementQuery");
        Method snapshotParametersMethod = queryClass
            ? class_getInstanceMethod(queryClass, NSSelectorFromString(@"snapshotParameters"))
            : NULL;
        if (snapshotParametersMethod) {
            XCOriginalSnapshotParameters = (id (*)(id, SEL))method_setImplementation(
                snapshotParametersMethod,
                (IMP)XCSwizzledSnapshotParameters
            );
        }

        NSLog(@"[driver] snapshot request parameter maxChildren=%d defaultParameters=%@ snapshotParameters=%@",
              XCSnapshotMaxChildrenLimit,
              defaultParametersMethod ? @"patched" : @"missing",
              snapshotParametersMethod ? @"patched" : @"missing");
    });
}

// MARK: - Public: Gesture helpers

void XCPressAndDrag(XCUICoordinate *start, XCUICoordinate *end,
                    double pressDuration, double velocity, double holdDuration) {
    SEL sel = NSSelectorFromString(
        @"pressForDuration:thenDragToCoordinate:withVelocity:thenHoldForDuration:");
    NSMethodSignature *sig = [start methodSignatureForSelector:sel];
    if (!sig) {
        SEL fallbackSel = NSSelectorFromString(@"pressForDuration:thenDragToCoordinate:");
        NSMethodSignature *fallbackSig = [start methodSignatureForSelector:fallbackSel];
        if (!fallbackSig || ![start respondsToSelector:fallbackSel]) {
            NSLog(@"%@", @"[driver] XCPressAndDrag: neither private nor public press-drag API available");
            return;
        }
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:fallbackSig];
        [inv setTarget:start];
        [inv setSelector:fallbackSel];
        [inv setArgument:&pressDuration atIndex:2];
        [inv setArgument:&end atIndex:3];
        [inv invoke];
        return;
    }
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:start];
    [inv setSelector:sel];
    [inv setArgument:&pressDuration atIndex:2];
    [inv setArgument:&end atIndex:3];
    [inv setArgument:&velocity atIndex:4];
    [inv setArgument:&holdDuration atIndex:5];
    [inv invoke];
}

// MARK: - Public: GetActiveApplication

@protocol FBXCAccessibilityElement <NSObject>
@property(readonly) int processIdentifier;
@end

@protocol XCTestManager_ManagerInterface <NSObject>
- (void)_XCT_requestElementAtPoint:(CGPoint)point reply:(void (^)(id element, NSError *error))reply;
@end

@protocol XCApplicationProcessTracker <NSObject>
- (XCUIApplication *)monitoredApplicationWithProcessIdentifier:(pid_t)pid;
@end

@interface XCUIApplication (IOSUsePrivateRunning)
@property(readonly) BOOL running;
@end

static id XCTestRunnerProxy(void)
{
    Class daemonSessionClass = NSClassFromString(@"XCTRunnerDaemonSession");
    SEL sharedSel = NSSelectorFromString(@"sharedSession");
    if (!daemonSessionClass || ![daemonSessionClass respondsToSelector:sharedSel]) {
        return nil;
    }
    id session = ((id (*)(id, SEL))objc_msgSend)(daemonSessionClass, sharedSel);
    return [session valueForKey:@"daemonProxy"];
}

static id AccessibilityClient(void)
{
    static id client = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        client = [XCUIDevice.sharedDevice performSelector:NSSelectorFromString(@"accessibilityInterface")];
    });
    return client;
}

static id<FBXCAccessibilityElement> DetectionPointElement(void)
{
    CGSize screenSize = [UIScreen mainScreen].bounds.size;
    CGFloat pointDistance = MIN(screenSize.width, screenSize.height) * XCDetectionPointScreenRatio;
    CGPoint point = CGPointMake(pointDistance, pointDistance);

    __block id<FBXCAccessibilityElement> onScreenElement = nil;
    id<XCTestManager_ManagerInterface> proxy = XCTestRunnerProxy();
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [proxy _XCT_requestElementAtPoint:point
                                reply:^(id element, NSError *error) {
                                    if (nil == error) {
                                        onScreenElement = element;
                                    } else {
                                        NSLog(@"Cannot request the screen point at %@", NSStringFromCGPoint(point));
                                    }
                                    dispatch_semaphore_signal(sem);
                                }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)));
    return onScreenElement;
}

static XCUIApplication *ApplicationWithPID(pid_t pid)
{
    static NSMutableDictionary<NSNumber *, XCUIApplication *> *appsCache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        appsCache = [NSMutableDictionary dictionary];
    });

    NSMutableSet *terminatedAppIds = [NSMutableSet set];
    for (NSNumber *appPid in appsCache) {
        if (![appsCache[appPid] running]) {
            [terminatedAppIds addObject:appPid];
        }
    }
    for (NSNumber *appPid in terminatedAppIds) {
        [appsCache removeObjectForKey:appPid];
    }

    XCUIApplication *result = [appsCache objectForKey:@(pid)];
    if (nil != result) {
        return result;
    }

    id<XCApplicationProcessTracker> tracker = [AccessibilityClient() performSelector:NSSelectorFromString(@"applicationProcessTracker")];
    XCUIApplication *app = [tracker monitoredApplicationWithProcessIdentifier:pid];
    if (nil == app) {
        return nil;
    }

    [appsCache setObject:app forKey:@(pid)];
    return app;
}

XCUIApplication *GetActiveApplication(void)
{
    NSArray<id<FBXCAccessibilityElement>> *activeApplicationElements = [AccessibilityClient() performSelector:NSSelectorFromString(@"activeApplications")];
    id<FBXCAccessibilityElement> activeApplicationElement = nil;

    if (activeApplicationElements.count > 1) {
        id<FBXCAccessibilityElement> currentElement = DetectionPointElement();
        if (nil == currentElement) {
            NSLog(@"%@", @"Cannot precisely detect the current application. Will use the system's recently active one");
        } else {
            for (id<FBXCAccessibilityElement> appElement in activeApplicationElements) {
                if (appElement.processIdentifier == currentElement.processIdentifier) {
                    activeApplicationElement = appElement;
                    break;
                }
            }
        }
    }

    if (nil != activeApplicationElement) {
        XCUIApplication *application = ApplicationWithPID(activeApplicationElement.processIdentifier);
        if (nil != application) {
            return application;
        }
        NSLog(@"%@", @"Cannot translate the active process identifier into an application object");
    }

    if (activeApplicationElements.count > 0) {
        NSLog(@"Getting the most recent active application (out of %@ total items)", @(activeApplicationElements.count));
        for (id<FBXCAccessibilityElement> appElement in activeApplicationElements) {
            XCUIApplication *application = ApplicationWithPID(appElement.processIdentifier);
            if (nil != application) {
                return application;
            }
        }
    }

    NSLog(@"%@", @"Cannot retrieve any active applications. Assuming the system application is the active one");
    id<FBXCAccessibilityElement> systemApplication = [AccessibilityClient() performSelector:NSSelectorFromString(@"systemApplication")];
    return ApplicationWithPID(systemApplication.processIdentifier);
}

id SnapshotOfElement(XCUIElement *element) {
    if (!element) return nil;
    XCInstallSnapshotRequestParameterPatch();
    SEL sel = NSSelectorFromString(@"snapshotWithError:");
    if (![element respondsToSelector:sel]) return nil;
    NSMethodSignature *sig = [element methodSignatureForSelector:sel];
    if (!sig) return nil;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:element];
    [inv setSelector:sel];
    NSError *error = nil;
    [inv setArgument:&error atIndex:2];
    [inv invoke];
    __unsafe_unretained id tmp = nil;
    [inv getReturnValue:&tmp];
    return tmp;
}

NSUInteger XCDefaultTypingFrequency(void) {
    NSInteger defaultFreq = [[NSUserDefaults standardUserDefaults] integerForKey:@"com.apple.xctest.iOSMaximumTypingFrequency"];
    return defaultFreq > 0 ? (NSUInteger)defaultFreq : 60;
}

static BOOL XCSynthesizeEventRecord(id record, NSError **error) {
    id device = [XCUIDevice sharedDevice];
    id synthesizer = [device respondsToSelector:NSSelectorFromString(@"eventSynthesizer")]
        ? [device performSelector:NSSelectorFromString(@"eventSynthesizer")]
        : nil;
    if (!synthesizer) {
        if (error) {
            *error = [NSError errorWithDomain:@"ios-use"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"eventSynthesizer is unavailable"}];
        }
        return NO;
    }

    SEL synthSel = NSSelectorFromString(@"synthesizeEvent:completion:");
    NSMethodSignature *sig = [synthesizer methodSignatureForSelector:synthSel];
    if (!sig) {
        if (error) {
            *error = [NSError errorWithDomain:@"ios-use"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"synthesizeEvent:completion: is unavailable"}];
        }
        return NO;
    }

    __block NSError *innerError = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    id completion = ^(BOOL result, NSError *invokeError) {
        if (invokeError) {
            innerError = invokeError;
        }
        dispatch_semaphore_signal(sem);
    };

    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:synthesizer];
    [inv setSelector:synthSel];
    [inv setArgument:&record atIndex:2];
    [inv setArgument:&completion atIndex:3];
    [inv retainArguments];
    [inv invoke];

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, XCSynthesizeEventTimeoutSeconds * NSEC_PER_SEC));
    if (innerError) {
        if (error) *error = innerError;
        return NO;
    }
    return YES;
}

static BOOL XCSynthesizeTouchPath(CGPoint point, double holdDuration, NSString *name, NSError **error) {
    Class recordClass = NSClassFromString(@"XCSynthesizedEventRecord");
    Class pathClass = NSClassFromString(@"XCPointerEventPath");
    if (!recordClass || !pathClass) {
        if (error) {
            *error = [NSError errorWithDomain:@"ios-use"
                                         code:6
                                     userInfo:@{NSLocalizedDescriptionKey: @"Touch input private classes are unavailable"}];
        }
        return NO;
    }

    id record = [[recordClass alloc] init];
    SEL initSel = NSSelectorFromString(@"initWithName:");
    if ([record respondsToSelector:initSel]) {
        record = ((id (*)(id, SEL, id))objc_msgSend)(record, initSel, name);
    }

    SEL pathInitSel = NSSelectorFromString(@"initForTouchAtPoint:offset:");
    id path = [[pathClass alloc] init];
    if (![path respondsToSelector:pathInitSel]) {
        if (error) {
            *error = [NSError errorWithDomain:@"ios-use"
                                         code:7
                                     userInfo:@{NSLocalizedDescriptionKey: @"initForTouchAtPoint:offset: is unavailable"}];
        }
        return NO;
    }
    path = ((id (*)(id, SEL, CGPoint, double))objc_msgSend)(path, pathInitSel, point, 0.0);

    SEL liftSel = NSSelectorFromString(@"liftUpAtOffset:");
    if (![path respondsToSelector:liftSel]) {
        if (error) {
            *error = [NSError errorWithDomain:@"ios-use"
                                         code:8
                                     userInfo:@{NSLocalizedDescriptionKey: @"liftUpAtOffset: is unavailable"}];
        }
        return NO;
    }
    NSMethodSignature *liftSig = [path methodSignatureForSelector:liftSel];
    NSInvocation *liftInv = [NSInvocation invocationWithMethodSignature:liftSig];
    [liftInv setTarget:path];
    [liftInv setSelector:liftSel];
    [liftInv setArgument:&holdDuration atIndex:2];
    [liftInv invoke];

    SEL addPathSel = NSSelectorFromString(@"addPointerEventPath:");
    if (![record respondsToSelector:addPathSel]) {
        if (error) {
            *error = [NSError errorWithDomain:@"ios-use"
                                         code:9
                                     userInfo:@{NSLocalizedDescriptionKey: @"addPointerEventPath: is unavailable"}];
        }
        return NO;
    }
    ((void (*)(id, SEL, id))objc_msgSend)(record, addPathSel, path);
    return XCSynthesizeEventRecord(record, error);
}

BOOL XCSynthesizeTapAtPoint(CGPoint point, NSError **error) {
    return XCSynthesizeTouchPath(point, XCTapLiftUpDelay, @"Tap", error);
}

BOOL XCSynthesizeLongPressAtPoint(CGPoint point, double duration, NSError **error) {
    double effectiveDuration = duration > 0 ? duration : XCDefaultLongPressDuration;
    return XCSynthesizeTouchPath(point, effectiveDuration, @"Long Press", error);
}

NSData *XCRequestScreenshotJPEG(double compressionQuality, NSError **error) {
    Class daemonSessionClass = NSClassFromString(@"XCTRunnerDaemonSession");
    SEL sharedSel = NSSelectorFromString(@"sharedSession");
    if (!daemonSessionClass || ![daemonSessionClass respondsToSelector:sharedSel]) {
        if (error) {
            *error = [NSError errorWithDomain:@"ios-use"
                                         code:10
                                     userInfo:@{NSLocalizedDescriptionKey: @"XCTRunnerDaemonSession.sharedSession is unavailable"}];
        }
        return nil;
    }

    id session = ((id (*)(id, SEL))objc_msgSend)(daemonSessionClass, sharedSel);
    id proxy = [session valueForKey:@"daemonProxy"];
    SEL requestSel = NSSelectorFromString(@"_XCT_requestScreenshot:withReply:");
    NSMethodSignature *requestSig = [proxy methodSignatureForSelector:requestSel];
    if (!proxy || !requestSig) {
        if (error) {
            *error = [NSError errorWithDomain:@"ios-use"
                                         code:11
                                     userInfo:@{NSLocalizedDescriptionKey: @"_XCT_requestScreenshot:withReply: is unavailable"}];
        }
        return nil;
    }

    Class imageEncodingClass = NSClassFromString(@"XCTImageEncoding");
    Class screenshotRequestClass = NSClassFromString(@"XCTScreenshotRequest");
    if (!imageEncodingClass || !screenshotRequestClass) {
        if (error) {
            *error = [NSError errorWithDomain:@"ios-use"
                                         code:12
                                     userInfo:@{NSLocalizedDescriptionKey: @"XCTest screenshot private classes are unavailable"}];
        }
        return nil;
    }

    id imageEncodingAllocated = [imageEncodingClass alloc];
    SEL encodingInitSel = NSSelectorFromString(@"initWithUniformTypeIdentifier:compressionQuality:");
    if (![imageEncodingAllocated respondsToSelector:encodingInitSel]) {
        if (error) {
            *error = [NSError errorWithDomain:@"ios-use"
                                         code:13
                                     userInfo:@{NSLocalizedDescriptionKey: @"XCTImageEncoding initWithUniformTypeIdentifier:compressionQuality: is unavailable"}];
        }
        return nil;
    }
    NSString *utiIdentifier = UTTypeJPEG.identifier;
    NSMethodSignature *encodingSig = [imageEncodingAllocated methodSignatureForSelector:encodingInitSel];
    NSInvocation *encodingInv = [NSInvocation invocationWithMethodSignature:encodingSig];
    [encodingInv setTarget:imageEncodingAllocated];
    [encodingInv setSelector:encodingInitSel];
    [encodingInv setArgument:&utiIdentifier atIndex:2];
    [encodingInv setArgument:&compressionQuality atIndex:3];
    [encodingInv invoke];
    __unsafe_unretained id imageEncoding = nil;
    [encodingInv getReturnValue:&imageEncoding];
    if (!imageEncoding) {
        if (error) {
            *error = [NSError errorWithDomain:@"ios-use"
                                         code:14
                                     userInfo:@{NSLocalizedDescriptionKey: @"XCTImageEncoding init failed"}];
        }
        return nil;
    }

    id screenshotRequestAllocated = [screenshotRequestClass alloc];
    SEL requestInitSel = NSSelectorFromString(@"initWithScreenID:rect:encoding:");
    if (![screenshotRequestAllocated respondsToSelector:requestInitSel]) {
        if (error) {
            *error = [NSError errorWithDomain:@"ios-use"
                                         code:15
                                     userInfo:@{NSLocalizedDescriptionKey: @"XCTScreenshotRequest initWithScreenID:rect:encoding: is unavailable"}];
        }
        return nil;
    }
    id rawScreenID = [XCUIScreen.mainScreen valueForKey:@"displayID"];
    long long screenID = [rawScreenID respondsToSelector:@selector(longLongValue)] ? [rawScreenID longLongValue] : 0;
    CGRect rect = CGRectNull;
    NSMethodSignature *requestInitSig = [screenshotRequestAllocated methodSignatureForSelector:requestInitSel];
    NSInvocation *requestInitInv = [NSInvocation invocationWithMethodSignature:requestInitSig];
    [requestInitInv setTarget:screenshotRequestAllocated];
    [requestInitInv setSelector:requestInitSel];
    [requestInitInv setArgument:&screenID atIndex:2];
    [requestInitInv setArgument:&rect atIndex:3];
    [requestInitInv setArgument:&imageEncoding atIndex:4];
    [requestInitInv invoke];
    __unsafe_unretained id screenshotRequest = nil;
    [requestInitInv getReturnValue:&screenshotRequest];
    if (!screenshotRequest) {
        if (error) {
            *error = [NSError errorWithDomain:@"ios-use"
                                         code:16
                                     userInfo:@{NSLocalizedDescriptionKey: @"XCTScreenshotRequest init failed"}];
        }
        return nil;
    }

    __block NSData *screenshotData = nil;
    __block NSError *innerError = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    id reply = ^(id image, NSError *invokeError) {
        if (invokeError) {
            innerError = invokeError;
        } else if ([image respondsToSelector:NSSelectorFromString(@"data")]) {
            screenshotData = [image data];
        } else if ([image isKindOfClass:[NSData class]]) {
            screenshotData = image;
        } else {
            innerError = [NSError errorWithDomain:@"ios-use"
                                             code:17
                                         userInfo:@{NSLocalizedDescriptionKey: @"XCT screenshot reply has no data payload"}];
        }
        dispatch_semaphore_signal(sem);
    };

    NSInvocation *requestInv = [NSInvocation invocationWithMethodSignature:requestSig];
    [requestInv setTarget:proxy];
    [requestInv setSelector:requestSel];
    [requestInv setArgument:&screenshotRequest atIndex:2];
    [requestInv setArgument:&reply atIndex:3];
    [requestInv retainArguments];
    [requestInv invoke];

    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, XCScreenshotTimeoutSeconds * NSEC_PER_SEC)) != 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"ios-use"
                                         code:18
                                     userInfo:@{NSLocalizedDescriptionKey: @"_XCT_requestScreenshot timed out"}];
        }
        return nil;
    }
    if (innerError) {
        if (error) *error = innerError;
        return nil;
    }
    return screenshotData;
}

BOOL XCFBTypeText(NSString *text, NSUInteger typingSpeed, NSError **error) {
    Class recordClass = NSClassFromString(@"XCSynthesizedEventRecord");
    Class pathClass = NSClassFromString(@"XCPointerEventPath");
    if (!recordClass || !pathClass) {
        if (error) {
            *error = [NSError errorWithDomain:@"ios-use"
                                         code:3
                                     userInfo:@{NSLocalizedDescriptionKey: @"Text input private classes are unavailable"}];
        }
        return NO;
    }

    NSString *abbr = text.length <= XCMaxTextAbbrLen ? text : [text substringToIndex:XCMaxTextAbbrLen];
    NSString *name = text.length <= XCMaxTextAbbrLen
        ? [NSString stringWithFormat:@"Type '%@'", text]
        : [NSString stringWithFormat:@"Type '%@…'", abbr];

    id record = [[recordClass alloc] init];
    SEL initSel = NSSelectorFromString(@"initWithName:");
    if ([record respondsToSelector:initSel]) {
        record = ((id (*)(id, SEL, id))objc_msgSend)(record, initSel, name);
    }

    SEL pathInitSel = NSSelectorFromString(@"initForTextInput");
    if (![pathClass instancesRespondToSelector:pathInitSel]) {
        if (error) {
            *error = [NSError errorWithDomain:@"ios-use"
                                         code:4
                                     userInfo:@{NSLocalizedDescriptionKey: @"initForTextInput is unavailable"}];
        }
        return NO;
    }
    id path = ((id (*)(id, SEL))objc_msgSend)([pathClass alloc], pathInitSel);
    SEL typeSel = NSSelectorFromString(@"typeText:atOffset:typingSpeed:shouldRedact:");
    if (![path respondsToSelector:typeSel]) {
        if (error) {
            *error = [NSError errorWithDomain:@"ios-use"
                                         code:4
                                     userInfo:@{NSLocalizedDescriptionKey: @"typeText:atOffset:typingSpeed:shouldRedact: is unavailable"}];
        }
        return NO;
    }

    double offset = 0.0;
    BOOL redact = NO;
    NSMethodSignature *typeSig = [path methodSignatureForSelector:typeSel];
    if (!typeSig) {
        if (error) {
            *error = [NSError errorWithDomain:@"ios-use"
                                         code:4
                                     userInfo:@{NSLocalizedDescriptionKey: @"typeText method signature is unavailable"}];
        }
        return NO;
    }
    NSInvocation *typeInv = [NSInvocation invocationWithMethodSignature:typeSig];
    [typeInv setTarget:path];
    [typeInv setSelector:typeSel];
    [typeInv setArgument:&text atIndex:2];
    [typeInv setArgument:&offset atIndex:3];
    [typeInv setArgument:&typingSpeed atIndex:4];
    [typeInv setArgument:&redact atIndex:5];
    [typeInv invoke];

    SEL addPathSel = NSSelectorFromString(@"addPointerEventPath:");
    if (![record respondsToSelector:addPathSel]) {
        if (error) {
            *error = [NSError errorWithDomain:@"ios-use"
                                         code:5
                                     userInfo:@{NSLocalizedDescriptionKey: @"addPointerEventPath: is unavailable"}];
        }
        return NO;
    }
    ((void (*)(id, SEL, id))objc_msgSend)(record, addPathSel, path);
    return XCSynthesizeEventRecord(record, error);
}

// MARK: - Public: SnapshotMatchesElement (doc §5.4)

BOOL SnapshotMatchesElement(id a, id b) {
    if (!a || !b) return NO;
    if (a == b) return YES;
    static SEL sel = NULL;
    if (!sel) sel = NSSelectorFromString(@"_matchesElement:");
    if (![a respondsToSelector:sel]) return NO;
    return ((BOOL (*)(id, SEL, id))objc_msgSend)(a, sel, b);
}

// MARK: - SafeSnapshot

@interface SafeSnapshot ()
- (id)valueForKeySafely:(NSString *)key;
- (NSString *)copyStringForKey:(NSString *)key;
- (BOOL)getBoolForKey:(NSString *)key fallback:(BOOL)fallback hasValue:(BOOL *)hasValue;
- (NSUInteger)getUIntForKey:(NSString *)key;
@end

@implementation SafeSnapshot
{
    id _raw;
    CGRect _appFrame;
    NSString *_label;
    NSString *_identifier;
    NSString *_autoLabel;
    NSString *_displayLabelAlias;
    NSString *_value;
    NSString *_placeholderValue;
    CGRect _frame;
    CGRect _visibleFrame;
    NSUInteger _elementType;
    BOOL _isVisible;
    BOOL _isEnabled;
    BOOL _isSelected;
    BOOL _hasFocus;
    BOOL _hasKeyboardFocus;
    BOOL _frameCached;
    BOOL _visibleFrameCached;
    BOOL _typeCached;
    BOOL _visibleCached;
    BOOL _enabledCached;
    BOOL _selectedCached;
    BOOL _focusCached;
    BOOL _keyboardFocusCached;
    NSArray<SafeSnapshot *> *_children;
    SafeSnapshot *_parent;
    BOOL _parentResolved;
    NSArray<SafeSnapshot *> *_allDescendantsCache;
}

// MARK: Private helpers

- (id)valueForKeySafely:(NSString *)key {
    return XCValueForKeySafely(_raw, key);
}

- (NSString *)copyStringForKey:(NSString *)key {
    id v = [self valueForKeySafely:key];
    if (![v isKindOfClass:[NSString class]]) return nil;
    NSString *sanitized = XCSanitizedSnapshotString(v);
    return sanitized ? [sanitized copy] : nil;
}

- (BOOL)getBoolForKey:(NSString *)key fallback:(BOOL)fallback hasValue:(BOOL *)hasValue {
    NSNumber *v = [self valueForKeySafely:key];
    if (![v isKindOfClass:[NSNumber class]]) {
        if (hasValue) *hasValue = NO;
        return fallback;
    }
    if (hasValue) *hasValue = YES;
    return [v boolValue];
}

- (NSUInteger)getUIntForKey:(NSString *)key {
    NSNumber *v = [self valueForKeySafely:key];
    if (![v isKindOfClass:[NSNumber class]]) return 0;
    return [v unsignedIntegerValue];
}

// MARK: Factory

+ (instancetype)snapshotOfApp:(XCUIApplication *)app {
    XCInstallSnapshotRequestParameterPatch();
    __block id raw = nil;
    @autoreleasepool {
        SEL sel = NSSelectorFromString(@"snapshotWithError:");
        if (![app respondsToSelector:sel]) return nil;
        NSMethodSignature *sig = [app methodSignatureForSelector:sel];
        if (!sig) return nil;
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:app];
        [inv setSelector:sel];
        NSError *error = nil;
        [inv setArgument:&error atIndex:2];
        [inv invoke];
        __unsafe_unretained id tmp = nil;
        [inv getReturnValue:&tmp];
        raw = tmp;
    }
    if (!raw) return nil;
    // WDA: self.lastSnapshot = snapshot (XCUIElement private header, @property(retain))
    [app setValue:raw forKey:@"lastSnapshot"];
    CGRect appFrame = XCRawSnapshotFrame(raw);
    if (CGRectIsEmpty(appFrame)) {
        appFrame = [UIScreen mainScreen].bounds;
    }
    return [[SafeSnapshot alloc] initWithRaw:raw appFrame:appFrame];
}

- (instancetype)initWithRaw:(id)raw appFrame:(CGRect)appFrame {
    self = [super init];
    if (self) {
        _raw = raw;
        _appFrame = appFrame;
    }
    return self;
}

- (id)raw { return _raw; }

// MARK: Properties

- (NSString *)label {
    if (!_label) {
        _label = [self copyStringForKey:@"label"];
        if (_label.length == 0) _label = nil;
    }
    return _label;
}

- (NSString *)identifier {
    if (!_identifier) {
        _identifier = [self copyStringForKey:@"identifier"];
        if (_identifier.length == 0) _identifier = nil;
    }
    return _identifier;
}

- (NSString *)baseDisplayLabel {
    if (self.identifier.length > 0) return self.identifier;
    if (self.label.length > 0) return self.label;
    return nil;
}

- (NSString *)displayLabel {
    if (_displayLabelAlias.length > 0) return _displayLabelAlias;
    NSString *base = self.baseDisplayLabel;
    if (base.length > 0) return base;
    if (_autoLabel.length > 0) return _autoLabel;
    return nil;
}

- (void)setAutoLabelIfDisplayLabelNil:(NSString *)label {
    if (self.displayLabel.length > 0) return;
    NSString *sanitized = XCSanitizedSnapshotString(label);
    if (sanitized.length == 0) return;
    _autoLabel = [sanitized copy];
}

- (void)setDisplayLabelAliasIfNeeded:(NSString *)label {
    NSString *sanitized = XCSanitizedSnapshotString(label);
    if (sanitized.length == 0) return;
    NSString *current = self.displayLabel;
    if ([current isEqualToString:sanitized]) return;
    _displayLabelAlias = [sanitized copy];
}

- (NSString *)value {
    if (!_value) {
        id value = [self valueForKeySafely:@"value"];
        NSUInteger type = self.elementType;
        if (type == XCUIElementTypeStaticText) {
            value = XCFirstNonEmptyValue(value, self.label);
        } else if (type == XCUIElementTypeButton) {
            value = XCFirstNonEmptyValue(value, self.isSelected ? @YES : nil);
        } else if (type == XCUIElementTypeSwitch) {
            value = value == nil ? nil : @([value boolValue]);
        } else if (XCSupportsInnerText(type)) {
            value = XCFirstNonEmptyValue(value, self.placeholderValue);
        }
        if ([value isKindOfClass:[NSString class]] && [((NSString *)value) length] == 0) {
            value = nil;
        }
        if (value != nil && ![value isKindOfClass:[NSNull class]]) {
            _value = [[NSString stringWithFormat:@"%@", value] copy];
        }
        if (_value.length == 0) _value = nil;
    }
    return _value;
}

- (NSString *)placeholderValue {
    if (!_placeholderValue) {
        _placeholderValue = [self copyStringForKey:@"placeholderValue"];
        if (_placeholderValue.length == 0) _placeholderValue = nil;
    }
    return _placeholderValue;
}

- (NSUInteger)elementType {
    if (!_typeCached) {
        _elementType = [self getUIntForKey:@"elementType"];
        _typeCached = YES;
    }
    return _elementType;
}

- (CGRect)frame {
    if (!_frameCached) {
        _frame = CGRectZero;
        NSValue *v = [self valueForKeySafely:@"frame"];
        if ([v isKindOfClass:[NSValue class]]) {
            _frame = [v CGRectValue];
        }
        _frameCached = YES;
    }
    return _frame;
}

- (CGRect)visibleFrame {
    if (!_visibleFrameCached) {
        _visibleFrame = CGRectZero;
        NSValue *v = [self valueForKeySafely:@"visibleFrame"];
        if ([v isKindOfClass:[NSValue class]]) {
            _visibleFrame = [v CGRectValue];
        }
        _visibleFrameCached = YES;
    }
    return _visibleFrame;
}

- (BOOL)isVisible {
    if (!_visibleCached) {
        _isVisible = XCRawSnapshotIsVisibleInAppFrame(_raw, _appFrame);
        _visibleCached = YES;
    }
    return _isVisible;
}

- (BOOL)isEnabled {
    if (!_enabledCached) {
        BOOL has = NO;
        BOOL v = [self getBoolForKey:@"isEnabled" fallback:YES hasValue:&has];
        _isEnabled = has ? v : YES;
        _enabledCached = YES;
    }
    return _isEnabled;
}

- (BOOL)hasKeyboardFocus {
    if (!_keyboardFocusCached) {
        BOOL has = NO;
        _hasKeyboardFocus = [self getBoolForKey:@"hasKeyboardFocus" fallback:NO hasValue:&has];
        if (!has) _hasKeyboardFocus = NO;
        _keyboardFocusCached = YES;
    }
    return _hasKeyboardFocus;
}

- (BOOL)isSelected {
    if (!_selectedCached) {
        BOOL has = NO;
        _isSelected = [self getBoolForKey:@"isSelected" fallback:NO hasValue:&has];
        if (!has) _isSelected = NO;
        _selectedCached = YES;
    }
    return _isSelected;
}

- (BOOL)hasFocus {
    if (!_focusCached) {
        BOOL has = NO;
        _hasFocus = [self getBoolForKey:@"hasFocus" fallback:NO hasValue:&has];
        if (!has) _hasFocus = NO;
        _focusCached = YES;
    }
    return _hasFocus;
}

- (NSArray<SafeSnapshot *> *)children {
    if (!_children) {
        NSArray *rawChildren = [self valueForKeySafely:@"children"];
        if (![rawChildren isKindOfClass:[NSArray class]]) {
            _children = @[];
        } else {
            NSArray *childrenToWrap = XCPrunedSnapshotChildren(rawChildren, _appFrame);
            NSMutableArray *wrapped = [NSMutableArray arrayWithCapacity:childrenToWrap.count];
            for (id child in childrenToWrap) {
                @autoreleasepool {
                    SafeSnapshot *wrap = [[SafeSnapshot alloc] initWithRaw:child appFrame:_appFrame];
                    wrap->_parent = self;
                    wrap->_parentResolved = YES;
                    [wrapped addObject:wrap];
                }
            }
            _children = wrapped;
        }
    }
    return _children;
}

- (SafeSnapshot *)parent {
    if (!_parentResolved) {
        _parentResolved = YES;
        id rawParent = [self valueForKeySafely:@"parent"];
        if (rawParent) {
            _parent = [[SafeSnapshot alloc] initWithRaw:rawParent appFrame:_appFrame];
        }
    }
    return _parent;
}

- (NSArray<SafeSnapshot *> *)allDescendants {
    if (_allDescendantsCache) return _allDescendantsCache;
    NSMutableArray<SafeSnapshot *> *out = [NSMutableArray array];
    NSMutableArray<SafeSnapshot *> *stack = [NSMutableArray arrayWithArray:self.children];
    while (stack.count > 0) {
        SafeSnapshot *node = stack.lastObject;
        [stack removeLastObject];
        [out addObject:node];
        NSArray<SafeSnapshot *> *kids = node.children;
        for (SafeSnapshot *k in kids.reverseObjectEnumerator) {
            [stack addObject:k];
        }
    }
    _allDescendantsCache = [out copy];
    return _allDescendantsCache;
}

@end
