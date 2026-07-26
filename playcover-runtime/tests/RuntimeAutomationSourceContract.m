#import "IOSUsePlayDevice.h"

#import <Foundation/Foundation.h>

static void Fail(NSString *message) {
    fprintf(
        stderr,
        "[runtime-automation-contract] %s\n",
        message.UTF8String
    );
    exit(1);
}

static void Require(BOOL condition, NSString *message) {
    if (!condition) {
        Fail(message);
    }
}

static NSString *FunctionBody(
    NSString *source,
    NSString *functionName
) {
    NSRange declaration = [source rangeOfString:functionName];
    Require(
        declaration.location != NSNotFound,
        [NSString stringWithFormat:
            @"missing function %@", functionName]
    );
    NSRange opening = [source
        rangeOfString:@"{"
              options:0
                range:NSMakeRange(
                    NSMaxRange(declaration),
                    source.length - NSMaxRange(declaration)
                )];
    Require(
        opening.location != NSNotFound,
        [NSString stringWithFormat:
            @"missing body for %@", functionName]
    );
    NSUInteger depth = 0;
    BOOL inString = NO;
    BOOL escaped = NO;
    for (NSUInteger index = opening.location;
         index < source.length;
         index += 1) {
        unichar character = [source characterAtIndex:index];
        if (inString) {
            if (escaped) {
                escaped = NO;
            } else if (character == '\\') {
                escaped = YES;
            } else if (character == '"') {
                inString = NO;
            }
            continue;
        }
        if (character == '"') {
            inString = YES;
        } else if (character == '{') {
            depth += 1;
        } else if (character == '}') {
            Require(depth > 0, @"unbalanced function body");
            depth -= 1;
            if (depth == 0) {
                return [source substringWithRange:NSMakeRange(
                    opening.location,
                    index - opening.location + 1
                )];
            }
        }
    }
    Fail(
        [NSString stringWithFormat:
            @"unterminated body for %@", functionName]
    );
    return @"";
}

static NSUInteger Count(
    NSString *source,
    NSString *needle
) {
    NSUInteger result = 0;
    NSRange remaining = NSMakeRange(0, source.length);
    while (remaining.length > 0) {
        NSRange match = [source
            rangeOfString:needle
                  options:0
                    range:remaining];
        if (match.location == NSNotFound) {
            break;
        }
        result += 1;
        NSUInteger next = NSMaxRange(match);
        remaining = NSMakeRange(next, source.length - next);
    }
    return result;
}

static NSUInteger Position(
    NSString *source,
    NSString *needle
) {
    return [source rangeOfString:needle].location;
}

static NSUInteger LastPosition(
    NSString *source,
    NSString *needle
) {
    return [source
        rangeOfString:needle
              options:NSBackwardsSearch].location;
}

static NSDictionary<NSString *, id> *StableFixtureElement(
    NSDictionary<NSString *, id> *element
) {
    NSMutableDictionary<NSString *, id> *stable =
        [element mutableCopy];
    [stable removeObjectForKey:@"nodeID"];
    [stable removeObjectForKey:@"snapshotGeneration"];
    [stable removeObjectForKey:@"zOrder"];
    NSMutableDictionary<NSString *, id> *hierarchy =
        [stable[@"hierarchy"] mutableCopy];
    [hierarchy removeObjectForKey:@"parentID"];
    [hierarchy removeObjectForKey:@"path"];
    [hierarchy removeObjectForKey:@"index"];
    stable[@"hierarchy"] = hierarchy;
    return stable;
}

static NSUInteger VisibleSemanticDifference(
    NSArray<NSDictionary<NSString *, id> *> *before,
    NSArray<NSDictionary<NSString *, id> *> *after
) {
    NSCountedSet *beforeSet = [NSCountedSet setWithArray:before];
    NSCountedSet *afterSet = [NSCountedSet setWithArray:after];
    NSMutableSet *all = [NSMutableSet setWithArray:before];
    [all addObjectsFromArray:after];
    NSUInteger difference = 0;
    for (NSDictionary *element in all) {
        NSUInteger left = [beforeSet countForObject:element];
        NSUInteger right = [afterSet countForObject:element];
        difference += left > right ? left - right : right - left;
    }
    return difference;
}

static void VerifyVisibleSemanticPostconditionUnit(void) {
    NSDictionary *countZero = @{
        @"nodeID": @"g1-n7",
        @"snapshotGeneration": @1,
        @"zOrder": @7,
        @"label": @"Count: 0",
        @"state": @{@"visible": @YES},
        @"hierarchy": @{
            @"parentID": @"g1-n2",
            @"path": @[@"g1-n2", @"g1-n7"],
            @"index": @4,
            @"depth": @2,
        },
    };
    NSMutableDictionary *ordinalDrift = [countZero mutableCopy];
    ordinalDrift[@"nodeID"] = @"g2-n19";
    ordinalDrift[@"snapshotGeneration"] = @2;
    ordinalDrift[@"zOrder"] = @19;
    ordinalDrift[@"hierarchy"] = @{
        @"parentID": @"g2-n3",
        @"path": @[@"g2-n3", @"g2-n19"],
        @"index": @11,
        @"depth": @2,
    };
    NSDictionary *stableZero = StableFixtureElement(countZero);
    NSDictionary *stableDrift =
        StableFixtureElement(ordinalDrift);
    Require(
        [stableZero isEqualToDictionary:stableDrift] &&
        VisibleSemanticDifference(
            @[stableZero],
            @[stableDrift]
        ) == 0,
        @"node ordinal/z-order drift must not satisfy a postcondition"
    );
    NSMutableDictionary *countOne = [ordinalDrift mutableCopy];
    countOne[@"label"] = @"Count: 1";
    Require(
        VisibleSemanticDifference(
            @[stableZero],
            @[StableFixtureElement(countOne)]
        ) == 2,
        @"Count: 0 -> Count: 1 must remain a real visible semantic change"
    );
    Require(
        VisibleSemanticDifference(
            @[stableZero, StableFixtureElement(countOne)],
            @[StableFixtureElement(countOne), stableDrift]
        ) == 0,
        @"semantic multiset comparison must ignore harmless reordering"
    );
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        Require(
            argc == 5,
            @"usage: RuntimeAutomationSourceContract "
             "<RuntimeAutomation.m> <FixedAdapter.swift> <RuntimeDOM.m> "
             "<AppKitBridge.m>"
        );
        NSError *error = nil;
        NSString *automation = [NSString
            stringWithContentsOfFile:
                [NSString stringWithUTF8String:argv[1]]
                            encoding:NSUTF8StringEncoding
                               error:&error];
        Require(
            automation != nil,
            [NSString stringWithFormat:
                @"could not read Runtime automation: %@",
                error.localizedDescription]
        );
        NSString *adapter = [NSString
            stringWithContentsOfFile:
                [NSString stringWithUTF8String:argv[2]]
                            encoding:NSUTF8StringEncoding
                               error:&error];
        Require(
            adapter != nil,
            [NSString stringWithFormat:
                @"could not read fixed adapter: %@",
                error.localizedDescription]
        );
        NSString *dom = [NSString
            stringWithContentsOfFile:
                [NSString stringWithUTF8String:argv[3]]
                            encoding:NSUTF8StringEncoding
                               error:&error];
        Require(
            dom != nil,
            [NSString stringWithFormat:
                @"could not read Runtime DOM: %@",
                error.localizedDescription]
        );
        NSString *appKitBridge = [NSString
            stringWithContentsOfFile:
                [NSString stringWithUTF8String:argv[4]]
                            encoding:NSUTF8StringEncoding
                               error:&error];
        Require(
            appKitBridge != nil,
            [NSString stringWithFormat:
                @"could not read AppKit bridge: %@",
                error.localizedDescription]
        );

        NSString *scrollDelivery = FunctionBody(
            automation,
            @"IOSUseAutomationScrollDeliveryView"
        );
        NSString *touchCommand = FunctionBody(
            automation,
            @"IOSUseAutomationTouchCommand"
        );
        NSString *sendTouch = FunctionBody(
            automation,
            @"IOSUseAutomationSendTouch"
        );
        NSString *stableElement = FunctionBody(
            automation,
            @"IOSUseAutomationStableElement"
        );
        NSString *stableDOM = FunctionBody(
            automation,
            @"IOSUseAutomationStableDOM"
        );
        NSString *stateEvidence = FunctionBody(
            automation,
            @"IOSUseAutomationStateEvidence"
        );
        NSString *input = FunctionBody(
            automation,
            @"IOSUseAutomationInput("
        );
        NSString *fixedWebScript = FunctionBody(
            dom,
            @"IOSUseDOMFixedWebBridgeScript"
        );
        NSString *evaluateWebBridge = FunctionBody(
            dom,
            @"IOSUseDOMEvaluateFixedWebBridge"
        );
        NSString *performWebAction = FunctionBody(
            dom,
            @"IOSUsePlayRuntimePerformWebAccessibilityAction"
        );
        NSString *loadAppKit = FunctionBody(
            appKitBridge,
            @"IOSUseBridgeLoadAppKit"
        );
        NSString *strictUIKitWindow = FunctionBody(
            appKitBridge,
            @"IOSUseBridgeKeyUIKitWindow"
        );
        NSString *windowForUIKitWindow = FunctionBody(
            appKitBridge,
            @"IOSUseBridgeWindowForUIKitWindow"
        );
        NSString *selectedAppKitWindow = FunctionBody(
            appKitBridge,
            @"IOSUseBridgeSelectedWindow"
        );
        NSString *activationUIKitWindowEligibility = FunctionBody(
            appKitBridge,
            @"IOSUseBridgeUIKitWindowCanBootstrapActivation"
        );
        NSString *activationSceneRank = FunctionBody(
            appKitBridge,
            @"IOSUseBridgeWindowActivationSceneRank"
        );
        NSString *backgroundActivationUIKitWindow = FunctionBody(
            appKitBridge,
            @"IOSUseBridgeBackgroundActivationUIKitWindow"
        );
        NSString *configureFixedWindow = FunctionBody(
            appKitBridge,
            @"configureFixedWindow:"
        );
        NSString *activeAppKitAccessibility = FunctionBody(
            appKitBridge,
            @"activeAccessibilityElementsWithError:"
        );
        NSString *appKitDiagnostics = FunctionBody(
            appKitBridge,
            @"+ (NSDictionary<NSString *, id> *)diagnostics"
        );
        NSString *appKitChildren = FunctionBody(
            appKitBridge,
            @"IOSUseBridgeAccessibilityChildren"
        );
        NSString *appKitLogicalFrame = FunctionBody(
            appKitBridge,
            @"IOSUseBridgeAccessibilityLogicalFrame"
        );
        NSString *collectAppKitAccessibility = FunctionBody(
            appKitBridge,
            @"IOSUseBridgeCollectAccessibilityElements"
        );
        NSString *domAppKitProxies = FunctionBody(
            dom,
            @"IOSUseDOMAppKitAccessibilityElements"
        );
        NSString *domAppKitElementType = FunctionBody(
            dom,
            @"IOSUseDOMAppKitElementType"
        );
        NSString *domAppKitDedupe = FunctionBody(
            dom,
            @"IOSUseDOMRawNodeDuplicatesAppKitProxy"
        );
        NSString *domChildren = FunctionBody(
            dom,
            @"IOSUseDOMChildren"
        );
        NSString *domHierarchyVisible = FunctionBody(
            dom,
            @"IOSUseDOMObjectHierarchyVisible"
        );
        NSString *domBuildNode = FunctionBody(
            dom,
            @"IOSUseDOMBuildNode"
        );
        NSString *domBuildSnapshot = FunctionBody(
            dom,
            @"IOSUseDOMBuildSnapshotOnMain"
        );
        Require(
            [loadAppKit containsString:@"dlopen("] &&
                [loadAppKit containsString:
                    @"/System/Library/Frameworks/AppKit.framework/AppKit"] &&
                [windowForUIKitWindow containsString:
                    @"NSSelectorFromString(@\"windows\")"] &&
                [windowForUIKitWindow containsString:
                    @"NSSelectorFromString(@\"uiWindows\")"] &&
                [windowForUIKitWindow containsString:@"objc_msgSend"] &&
                [selectedAppKitWindow containsString:
                    @"IOSUseBridgeKeyUIKitWindow()"] &&
                [selectedAppKitWindow containsString:@"YES"] &&
                [selectedAppKitWindow containsString:
                    @"IOSUseBridgeWindowForUIKitWindow"] &&
                [activeAppKitAccessibility containsString:
                    @"IOSUseBridgeCollectAccessibilityElements"] &&
                [activeAppKitAccessibility containsString:
                    @"IOSUseBridgeSelectedWindow()"] &&
                [appKitBridge containsString:
                    @"NSClassFromString(@\"NSApplication\")"] &&
                [appKitBridge containsString:@"NSSelectorFromString"] &&
                [appKitBridge containsString:@"objc_msgSend"],
            @"generic AppKit accessibility must stay in-process, use "
             "dynamically resolved selectors, and start from the AppKit "
             "window selected for the key UIKit window"
        );
        Require(
            [strictUIKitWindow containsString:
                @"UISceneActivationStateForegroundActive"] &&
                [strictUIKitWindow containsString:
                    @"UISceneActivationStateForegroundInactive"] &&
                [strictUIKitWindow containsString:
                    @"window.isKeyWindow"] &&
                ![strictUIKitWindow containsString:
                    @"UISceneActivationStateBackground"] &&
                ![selectedAppKitWindow containsString:
                    @"IOSUseBridgeBackgroundActivationUIKitWindow"] &&
                [activeAppKitAccessibility containsString:
                    @"IOSUseBridgeSelectedWindow()"] &&
                ![activeAppKitAccessibility containsString:
                    @"IOSUseBridgeBackgroundActivationUIKitWindow"] &&
                [appKitDiagnostics containsString:
                    @"IOSUseBridgeSelectedWindow()"] &&
                [appKitDiagnostics containsString:
                    @"IOSUseBridgeKeyUIKitWindow()"] &&
                ![appKitDiagnostics containsString:
                    @"IOSUseBridgeBackgroundActivationUIKitWindow"] &&
                ![dom containsString:
                    @"IOSUseBridgeBackgroundActivationUIKitWindow"] &&
                Count(
                    appKitBridge,
                    @"IOSUseBridgeBackgroundActivationUIKitWindow"
                ) == 2,
            @"DOM, AppKit accessibility, and diagnostics must retain "
             "foreground active/inactive key-window selection; the "
             "background candidate may only be defined and called by "
             "fixed-window activation"
        );
        Require(
            [activationSceneRank containsString:
                @"UISceneActivationStateForegroundActive"] &&
                [activationSceneRank containsString:
                    @"UISceneActivationStateForegroundInactive"] &&
                [activationSceneRank containsString:
                    @"UISceneActivationStateBackground"] &&
                [activationSceneRank containsString:
                    @"UISceneActivationStateUnattached"] &&
                [backgroundActivationUIKitWindow containsString:
                    @"IOSUseBridgeWindowActivationSceneRank(scene) < 0"] &&
                [backgroundActivationUIKitWindow containsString:
                    @"UIWindowSceneSessionRoleApplication"] &&
                [backgroundActivationUIKitWindow containsString:
                    @"scene.session.persistentIdentifier"] &&
                [backgroundActivationUIKitWindow containsString:
                    @"sortUsingComparator"] &&
                [backgroundActivationUIKitWindow containsString:
                    @"leftRank < rightRank"] &&
                [backgroundActivationUIKitWindow containsString:
                    @"leftRank > rightRank"] &&
                [backgroundActivationUIKitWindow containsString:
                    @"if (window.isKeyWindow &&"] &&
                [backgroundActivationUIKitWindow containsString:
                    @"NSSelectorFromString(@\"window\")"] &&
                Count(
                    backgroundActivationUIKitWindow,
                    @"IOSUseBridgeUIKitWindowCanBootstrapActivation"
                ) >= 3 &&
                [backgroundActivationUIKitWindow containsString:
                    @"if (candidates.count == 1)"] &&
                [backgroundActivationUIKitWindow containsString:
                    @"if (candidates.count > 1)"] &&
                Position(
                    activationSceneRank,
                    @"UISceneActivationStateForegroundActive"
                ) < Position(
                    activationSceneRank,
                    @"UISceneActivationStateForegroundInactive"
                ) &&
                Position(
                    activationSceneRank,
                    @"UISceneActivationStateForegroundInactive"
                ) < Position(
                    activationSceneRank,
                    @"UISceneActivationStateBackground"
                ),
            @"activation fallback must deterministically rank non-key "
             "foreground and background application scenes, then select "
             "only an unambiguous fixed-geometry app window"
        );
        Require(
            [activationUIKitWindowEligibility containsString:
                @"window.windowScene == scene"] &&
                [activationUIKitWindowEligibility containsString:
                    @"[scene.windows containsObject:window]"] &&
                [activationUIKitWindowEligibility containsString:
                    @"!window.hidden"] &&
                [activationUIKitWindowEligibility containsString:
                    @"window.alpha > 0.01"] &&
                [activationUIKitWindowEligibility containsString:
                    @"window.rootViewController != nil"] &&
                [activationUIKitWindowEligibility containsString:
                    @"UIWindowLevelNormal"] &&
                [activationUIKitWindowEligibility containsString:
                    @"IOSUseBridgeRectIsDeviceScreen(window.bounds)"],
            @"background activation may use only the scene-owned visible "
             "normal app window whose bounds still exactly match the fixed "
             "logical device screen"
        );
        Require(
            [windowForUIKitWindow containsString:
                @"allowApplicationKeyWindowFallback"] &&
                [windowForUIKitWindow containsString:
                    @"if (!allowApplicationKeyWindowFallback)"] &&
                Position(
                    windowForUIKitWindow,
                    @"NSSelectorFromString(@\"uiWindows\")"
                ) < Position(
                    windowForUIKitWindow,
                    @"if (!allowApplicationKeyWindowFallback)"
                ) &&
                Position(
                    windowForUIKitWindow,
                    @"NSSelectorFromString(@\"nsWindow\")"
                ) < Position(
                    windowForUIKitWindow,
                    @"if (!allowApplicationKeyWindowFallback)"
                ) &&
                Position(
                    windowForUIKitWindow,
                    @"if (!allowApplicationKeyWindowFallback)"
                ) < Position(
                    windowForUIKitWindow,
                    @"NSSelectorFromString(@\"keyWindow\")"
                ) &&
                [configureFixedWindow containsString:
                    @"IOSUseBridgeBackgroundActivationUIKitWindow()"] &&
                [configureFixedWindow containsString:
                    @"window = IOSUseBridgeWindowForUIKitWindow(\n"
                     "                uiWindow,\n"
                     "                NO\n"
                     "            );"] &&
                Position(
                    configureFixedWindow,
                    @"IOSUseBridgeBackgroundActivationUIKitWindow()"
                ) < Position(
                    configureFixedWindow,
                    @"window = IOSUseBridgeWindowForUIKitWindow("
                ) &&
                Position(
                    configureFixedWindow,
                    @"window = IOSUseBridgeWindowForUIKitWindow("
                ) < Position(
                    configureFixedWindow,
                    @"@\"activateIgnoringOtherApps:\""
                ) &&
                Position(
                    configureFixedWindow,
                    @"@\"activateIgnoringOtherApps:\""
                ) < Position(
                    configureFixedWindow,
                    @"@\"makeKeyAndOrderFront:\""
                ) &&
                Position(
                    configureFixedWindow,
                    @"@\"makeKeyAndOrderFront:\""
                ) < Position(
                    configureFixedWindow,
                    @"@\"orderFrontRegardless\""
                ),
            @"configureFixedWindow must exactly map the deterministic "
             "background UIKit candidate without an AppKit key-window "
             "fallback before activating and ordering that window"
        );
        Require(
            [configureFixedWindow containsString:
                @"BOOL exact ="] &&
                [configureFixedWindow containsString:
                    @"IOSUsePlayDeviceLogicalWidth"] &&
                [configureFixedWindow containsString:
                    @"IOSUsePlayDeviceLogicalHeight"] &&
                [configureFixedWindow containsString:
                    @"IOSUseBridgeRectIsDeviceScreen(content)"] &&
                [configureFixedWindow containsString:
                    @"IOSUseBridgeRectIsDeviceScreen(bounds)"] &&
                [configureFixedWindow containsString:
                    @"IOSUseBridgeWindowPolicyIsFixed(window)"] &&
                [configureFixedWindow containsString:
                    @"if (exact && usedBackgroundActivationFallback)"] &&
                [configureFixedWindow containsString:
                    @"@\"waiting-for-foreground-activation\""] &&
                [configureFixedWindow containsString:
                    @"strict foreground key-window selection"] &&
                Position(
                    configureFixedWindow,
                    @"@\"orderFrontRegardless\""
                ) < Position(
                    configureFixedWindow,
                    @"if (exact && usedBackgroundActivationFallback)"
                ) &&
                Position(
                    configureFixedWindow,
                    @"if (exact && usedBackgroundActivationFallback)"
                ) < LastPosition(
                    configureFixedWindow,
                    @"return NO;"
                ) &&
                LastPosition(
                    configureFixedWindow,
                    @"return NO;"
                ) < Position(
                    configureFixedWindow,
                    @"IOSUsePlayWindowStatus = exact "
                ),
            @"a background activation pass must retain every fixed-geometry "
             "check, then return transiently so screenshot settling retries "
             "through strict foreground selection"
        );
        Require(
            [appKitBridge containsString:
                @"IOSUseBridgeMaximumAccessibilityTraversalCount = 4096;"] &&
                [appKitBridge containsString:
                    @"IOSUseBridgeMaximumAccessibilityDepth = 64;"] &&
                [appKitBridge containsString:
                    @"IOSUseBridgeMaximumAccessibilityChildrenPerNode = 512;"] &&
                [appKitBridge containsString:
                    @"IOSUseBridgeMaximumAccessibilityElementCount = 512;"] &&
                Count(
                    collectAppKitAccessibility,
                    @"IOSUseBridgeMaximumAccessibilityTraversalCount"
                ) >= 2 &&
                [collectAppKitAccessibility containsString:
                    @"IOSUseBridgeMaximumAccessibilityDepth"] &&
                [appKitChildren containsString:
                    @"IOSUseBridgeMaximumAccessibilityChildrenPerNode"] &&
                [collectAppKitAccessibility containsString:
                    @"IOSUseBridgeMaximumAccessibilityElementCount"],
            @"AppKit accessibility traversal must retain fixed "
             "4096-node, 64-depth, 512-child, and 512-element bounds"
        );
        Require(
            [appKitChildren containsString:
                @"accessibilityArrayAttributeCount:"] &&
                [appKitChildren containsString:
                    @"accessibilityArrayAttributeValues:index:maxCount:"] &&
                [appKitChildren containsString:@"@\"AXChildren\""] &&
                [appKitChildren containsString:
                    @"if ([object respondsToSelector:countSelector]"] &&
                [appKitChildren containsString:@"id values ="] &&
                [appKitChildren containsString:
                    @"id childrenValue = nil;"] &&
                [appKitChildren containsString:
                    @"@\"accessibilityChildren\""] &&
                Position(
                    appKitChildren,
                    @"IOSUseBridgeMaximumAccessibilityChildrenPerNode"
                ) < Position(appKitChildren, @"id values =") &&
                Position(appKitChildren, @"id values =") <
                    Position(appKitChildren, @"id childrenValue = nil;"),
            @"AXChildren must prefer the bounded count/range selectors and "
             "enforce the child limit before materializing values or using "
             "the count-checked property fallback"
        );
        Require(
            [collectAppKitAccessibility containsString:
                @"@\"isAccessibilityProtectedContent\""] &&
                [collectAppKitAccessibility containsString:
                    @"if (!protectedContent &&"] &&
                Count(
                    collectAppKitAccessibility,
                    @"@\"accessibilityValue\""
                ) == 1 &&
                Position(
                    collectAppKitAccessibility,
                    @"if (!protectedContent &&"
                ) < Position(
                    collectAppKitAccessibility,
                    @"@\"accessibilityValue\""
                ),
            @"protected AppKit accessibility elements must never read "
             "accessibilityValue"
        );
        for (NSString *forbiddenAccessibilityPath in @[
            @"AXUIElement",
            @"AXIsProcessTrusted",
            @"System Events",
        ]) {
            Require(
                ![appKitBridge containsString:
                    forbiddenAccessibilityPath] &&
                    ![dom containsString:
                        forbiddenAccessibilityPath],
                [NSString stringWithFormat:
                    @"generic accessibility bridge must not use %@",
                    forbiddenAccessibilityPath]
            );
        }
        Require(
            IOSUsePlayDeviceLogicalHeight == 932 &&
                [appKitBridge containsString:
                    @"#import \"IOSUsePlayDevice.h\""] &&
                [appKitLogicalFrame containsString:
                    @"NSSelectorFromString(@\"convertRectFromScreen:\")"] &&
                [appKitLogicalFrame containsString:
                    @"IOSUsePlayDeviceLogicalHeight -"] &&
                [appKitLogicalFrame containsString:
                    @"CGRectGetMaxY(localFrame)"],
            @"AppKit screen frames must be converted through the selected "
             "window into the fixed 932-point top-left logical space"
        );
        Require(
            [dom containsString:
                @"@interface IOSUseDOMAppKitAccessibilityElement : "
                 "UIAccessibilityElement"] &&
                [domAppKitProxies containsString:
                    @"activeAccessibilityElementsWithError:&bridgeError"] &&
                [domAppKitProxies containsString:
                    @"initWithAccessibilityContainer:primaryWindow"] &&
                [domAppKitProxies containsString:
                    @"proxy.appKitRole = role"] &&
                [domAppKitProxies containsString:
                    @"proxy.accessibilityFrame = logicalFrame"] &&
                [domAppKitProxies containsString:
                    @"proxy.accessibilityTraits = traits"],
            @"Runtime DOM must adapt bounded AppKit descriptions into "
             "in-process UIAccessibilityElement proxies"
        );
        Require(
            [domAppKitElementType containsString:
                @"proxy.appKitRole"] &&
                [domAppKitDedupe containsString:
                    @"node.elementType == 58"] &&
                [domAppKitDedupe containsString:@"CGRectContainsPoint"] &&
                [domAppKitDedupe containsString:
                    @"IOSUseDOMAppKitElementType(proxy)"] &&
                [domAppKitDedupe containsString:@"sameIdentifier"] &&
                [domAppKitDedupe containsString:@"sameSemanticText"] &&
                [domAppKitDedupe containsString:
                    @"IOSUseDOMFramesSemanticallyOverlap"] &&
                [domAppKitDedupe containsString:
                    @"if (compatibleType && overlapping)"] &&
                Position(
                    domAppKitDedupe,
                    @"node.elementType == 58"
                ) < Position(
                    domAppKitDedupe,
                    @"BOOL sameIdentifier"
                ),
            @"UIKit and fixed WK semantics must outrank AppKit mirrors, "
             "whose dedupe must use role, semantic identity/text, and "
             "geometry"
        );
        Require(
            [domHierarchyVisible containsString:@"view.hidden"] &&
                [domHierarchyVisible containsString:
                    @"view.accessibilityElementsHidden"] &&
                [domChildren containsString:
                    @"if (!hierarchyVisible)"] &&
                [domChildren containsString:
                    @"*hasAutomationChildren = NO"] &&
                Position(domChildren, @"if (!hierarchyVisible)") <
                    Position(domChildren, @"return @[];") &&
                Position(domChildren, @"return @[];") <
                    Position(domChildren, @"WKWebView.class") &&
                Position(domChildren, @"if (!hierarchyVisible)") <
                    Position(
                        domChildren,
                        @"NSSelectorFromString(@\"automationElements\")"
                    ) &&
                [domBuildNode containsString:
                    @"ancestorVisible && "
                     "IOSUseDOMObjectHierarchyVisible(object)"] &&
                [domBuildNode containsString:
                    @"IOSUseDOMChildren("],
            @"hidden accessibility branches must terminate before Web, "
             "automation, accessibility-container, or UIView child traversal"
        );
        Require(
            [domBuildSnapshot containsString:
                @"for (UIWindow *window in windows)"] &&
                [domBuildSnapshot containsString:
                    @"IOSUseDOMAppKitAccessibilityElements("] &&
                [domBuildSnapshot containsString:
                    @"IOSUseDOMRawNodeDuplicatesAppKitProxy"] &&
                [domBuildSnapshot containsString:
                    @"IOSUseDOMCleanNode(root)"] &&
                Count(
                    domBuildSnapshot,
                    @"[rawRoots addObject:root]"
                ) >= 2 &&
                Position(
                    domBuildSnapshot,
                    @"for (UIWindow *window in windows)"
                ) < Position(
                    domBuildSnapshot,
                    @"IOSUseDOMAppKitAccessibilityElements("
                ) &&
                Position(
                    domBuildSnapshot,
                    @"[rawRoots addObject:root]"
                ) < Position(
                    domBuildSnapshot,
                    @"IOSUseDOMAppKitAccessibilityElements("
                ) &&
                Position(
                    domBuildSnapshot,
                    @"IOSUseDOMAppKitAccessibilityElements("
                ) < Position(
                    domBuildSnapshot,
                    @"IOSUseDOMCleanNode(root)"
                ) &&
                Position(
                    domBuildSnapshot,
                    @"IOSUseDOMRawNodeDuplicatesAppKitProxy"
                ) < Position(
                    domBuildSnapshot,
                    @"IOSUseDOMCleanNode(root)"
                ) &&
                LastPosition(
                    domBuildSnapshot,
                    @"[rawRoots addObject:root]"
                ) > Position(
                    domBuildSnapshot,
                    @"IOSUseDOMAppKitAccessibilityElements("
                ) &&
                LastPosition(
                    domBuildSnapshot,
                    @"[rawRoots addObject:root]"
                ) < Position(
                    domBuildSnapshot,
                    @"IOSUseDOMCleanNode(root)"
                ),
            @"AppKit fallback merge must run only after all raw UIKit/WK "
             "roots exist and before the clean DOM is built"
        );
        Require(
            [scrollDelivery containsString:@"UIScrollView.class"] &&
                [scrollDelivery containsString:@"scrollEnabled"] &&
                [scrollDelivery containsString:
                    @"userInteractionEnabled"] &&
                [scrollDelivery containsString:@".superview"],
            @"fixed-distance scroll delivery must select the nearest "
             "interactive, enabled UIScrollView ancestor"
        );
        Require(
            [touchCommand containsString:
                @"UIView *deliveryView = hitView"] &&
                [touchCommand containsString:
                    @"IOSUseAutomationScrollDeliveryView(hitView)"] &&
                Count(touchCommand, @"deliveryView") >= 5 &&
                [touchCommand containsString:
                    @"[toTarget isKindOfClass:NSDictionary.class]"],
            @"fixed-distance swipe must preserve the hit-test evidence "
             "while routing all PlayTools phases to its scroll ancestor"
        );
        Require(
            [sendTouch containsString:@"IOSUsePlayTouchBridge"] &&
                [adapter containsString:@"Toucher.touchcam"] &&
                ![automation containsString:@"setContentOffset:"] &&
                ![automation containsString:
                    @"sendActionsForControlEvents:"] &&
                ![automation containsString:
                    @"PTFakeMetaTouch fakeTouchId"],
            @"Runtime automation must use the pinned PlayTools touch "
             "frontend and must not mutate controls or scroll offsets"
        );
        Require(
            [evaluateWebBridge containsString:
                @"callAsyncJavaScript:IOSUseDOMFixedWebBridgeScript()"] &&
                [evaluateWebBridge containsString:
                    @"worldWithName:@\"io.ios-use.runtime.accessibility\""] &&
                ![dom containsString:@"querySelector"] &&
                ![dom containsString:@"querySelectorAll"] &&
                ![dom containsString:@"evaluateJavaScript:"] &&
                ![dom containsString:@"eval("] &&
                ![dom containsString:@"new Function"],
            @"Web bridge must run one Runtime-owned program in an isolated "
             "content world without scripts or selector entry points"
        );
        Require(
            [fixedWebScript containsString:@"elementLimit=512"] &&
                [fixedWebScript containsString:
                    @"traversalLimit=4096"] &&
                [fixedWebScript containsString:
                    @"structuralIdentity"] &&
                [fixedWebScript containsString:
                    @"item.identity!==expectedIdentity"] &&
                [fixedWebScript containsString:
                    @"item.role!==expectedRole"] &&
                [fixedWebScript containsString:
                    @"item.label!==expectedLabel"] &&
                [fixedWebScript containsString:
                    @"item.identifier!==expectedIdentifier"] &&
                [fixedWebScript containsString:
                    @"Math.abs(item.x-expectedX)<=0.5"] &&
                Position(
                    fixedWebScript,
                    @"item.identity!==expectedIdentity"
                ) < Position(
                    fixedWebScript,
                    @"HTMLElement.prototype.click.call"
                ) &&
                Position(
                    fixedWebScript,
                    @"item.identity!==expectedIdentity"
                ) < Position(
                    fixedWebScript,
                    @"HTMLElement.prototype.focus.call"
                ),
            @"Web actions must revalidate bounded ordinal/identity, role, "
             "label, id, and frame before activation or focus"
        );
        Require(
            [dom containsString:@"@property(nonatomic) NSUInteger webOrdinal"] &&
                [dom containsString:
                    @"@property(nonatomic, copy) NSString *webIdentity"] &&
                [dom containsString:
                    @"IOSUseDOMWebBridgeRecordForElement"] &&
                [performWebAction containsString:
                    @"IOSUseDOMFixedWebBridgeArguments(operation)"] &&
                [performWebAction containsString:
                    @"@\"wkwebview-runtime-fixed-accessibility-bridge\""] &&
                [performWebAction containsString:
                    @"rawEvidence[@\"performed\"]"] &&
                [performWebAction containsString:
                    @"rawEvidence[@\"freshValidated\"]"],
            @"only current Runtime proxies may act and success must require "
             "explicit fixed-bridge evidence"
        );
        Require(
            [automation containsString:
                @"@\"wkwebview-runtime-fixed-accessibility-bridge\""] &&
                [automation containsString:
                    @"details[@\"bridgeFailureCode\"]"] &&
                [automation containsString:
                    @"details[@\"syntheticFallbackAttempted\"] = @NO"],
            @"Web bridge failures must classify their backend and explicitly "
             "report that no synthetic fallback was attempted"
        );
        for (NSString *failureCode in @[
            @"@\"web_bridge_stale\"",
            @"@\"web_bridge_failed\"",
            @"@\"web_action_disabled\"",
            @"@\"web_action_unsupported\"",
            @"@\"web_secure_input\"",
            @"@\"web_custom_input\"",
            @"@\"web_focus_failed\"",
        ]) {
            Require(
                [performWebAction containsString:failureCode],
                [NSString stringWithFormat:
                    @"missing fixed Web bridge failure classification %@",
                    failureCode]
            );
        }
        Require(
            [fixedWebScript containsString:
                @"return {status:'unsupported',reason:'disabled'}"] &&
                [fixedWebScript containsString:
                    @"return {status:'unsupported',reason:'secure'}"] &&
                [fixedWebScript containsString:
                    @"return {status:'unsupported',reason:'custom'}"] &&
                [fixedWebScript containsString:
                    @"document.activeElement!==item.element"] &&
                [input containsString:
                    @"textInput.markedTextRange != nil"] &&
                [input containsString:
                    @"IOSUseAutomationIsSupportedWebInputResponder"] &&
                [automation containsString:
                    @"isEqualToString:@\"WKContentView\""],
            @"disabled, secure, custom, focus, exact WKContentView, and IME "
             "boundaries must fail closed"
        );
        Require(
            [touchCommand containsString:
                @"IOSUsePlayRuntimeIsWebAccessibilityElement"] &&
                [touchCommand containsString:
                    @"IOSUsePlayRuntimeWebAccessibilityActionActivate"] &&
                [touchCommand containsString:
                    @"@\"actionEvidence\": webEvidence"] &&
                Position(
                    touchCommand,
                    @"IOSUsePlayRuntimeWebAccessibilityActionActivate"
                ) < Position(
                    touchCommand,
                    @"PTFakeMetaTouch.deliveryGeneration"
                ) &&
                [input containsString:@"if (webTarget)"] &&
                [input containsString:
                    @"IOSUsePlayRuntimeWebAccessibilityActionFocusInput"] &&
                [input containsString:
                    @"IOSUseAutomationIsSupportedWebInputResponder(\n"
                     "                    expectedResponder"] &&
                [input containsString:
                    @"[expectedResponder becomeFirstResponder]"] &&
                [input containsString:
                    @"WKContentView.becomeFirstResponder-after-validated-web-focus"] &&
                Position(
                    input,
                    @"IOSUsePlayRuntimeWebAccessibilityActionFocusInput"
                ) < Position(
                    input,
                    @"[expectedResponder becomeFirstResponder]"
                ) &&
                [input containsString:
                    @"[(id<UIKeyInput>)firstResponder deleteBackward]"] &&
                [input containsString:
                    @"[(id<UIKeyInput>)firstResponder insertText:content]"] &&
                ![automation containsString:@"sendEvent:"],
            @"bridged tap/focus must validate the HTML target before entering "
             "the exact WKContentView responder and mutating through UIKeyInput"
        );
        Require(
            [stableElement containsString:
                @"removeObjectForKey:@\"zOrder\""] &&
                [stableElement containsString:
                    @"removeObjectForKey:@\"index\""] &&
                [stableElement containsString:
                    @"removeObjectForKey:@\"focused\""] &&
                [stableDOM containsString:
                    @"element[@\"state\"][@\"visible\"]"] &&
                [stateEvidence containsString:@"NSCountedSet"] &&
                [stateEvidence containsString:@"countForObject:"],
            @"postconditions must compare visible semantic multisets without "
             "ordinal/z-order delivery metadata"
        );
        NSString *boundedString = FunctionBody(
            dom,
            @"IOSUseDOMBoundedString"
        );
        Require(
            [boundedString containsString:
                @"NSCharacterSet.controlCharacterSet"] &&
                [boundedString containsString:
                    @"\\t\\n\\r\\u200C\\u200D"] &&
                [boundedString containsString:
                    @"\\u200B\\u2060\\uFEFF"],
            @"DOM sanitizer must preserve grapheme-shaping ZWNJ/ZWJ while "
             "removing non-rendering spacing controls"
        );
        NSMutableCharacterSet *invalid = [
            NSCharacterSet.controlCharacterSet
            mutableCopy
        ];
        [invalid removeCharactersInString:@"\t\n\r\u200C\u200D"];
        [invalid addCharactersInString:@"\u200B\u2060\uFEFF"];
        NSString *family = @"👨‍👩‍👧‍👦";
        NSString *sanitized = [[family
            componentsSeparatedByCharactersInSet:invalid]
            componentsJoinedByString:@""];
        Require(
            [sanitized isEqualToString:family] &&
                ![invalid characterIsMember:0x200C] &&
                ![invalid characterIsMember:0x200D] &&
                [invalid characterIsMember:0x200B],
            @"Foundation controlCharacterSet regression removed a "
             "grapheme-shaping ZWNJ/ZWJ"
        );
        VerifyVisibleSemanticPostconditionUnit();
        printf("[runtime-automation-contract] passed\n");
    }
    return 0;
}
