#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "IOSUsePlayHookRegistry.h"

@interface IOSUseHookParent : NSObject
- (NSInteger)value;
@end

@implementation IOSUseHookParent
- (NSInteger)value {
    return 1;
}
@end

@interface IOSUseHookInheritedChild : IOSUseHookParent
@end

@implementation IOSUseHookInheritedChild
@end

@interface IOSUseHookDirectOwnerChild : IOSUseHookParent
@end

@implementation IOSUseHookDirectOwnerChild
@end

@interface IOSUseHookReplacementOwner : NSObject
- (NSInteger)hook_value;
@end

@implementation IOSUseHookReplacementOwner
- (NSInteger)hook_value {
    NSInteger original = ((NSInteger (*)(id, SEL))objc_msgSend)(
        self,
        @selector(hook_value)
    );
    return original + 41;
}
@end

@interface IOSUseHookWrongReplacementOwner : NSObject
- (double)hook_value;
@end

@implementation IOSUseHookWrongReplacementOwner
- (double)hook_value {
    return 42.0;
}
@end

@interface IOSUseHookBypassBase : NSObject
- (NSInteger)value;
@end

@implementation IOSUseHookBypassBase
- (NSInteger)value {
    return 2;
}
@end

@interface IOSUseHookBypassChild : IOSUseHookBypassBase
@end

@implementation IOSUseHookBypassChild
- (NSInteger)value {
    return 3;
}
@end

@interface IOSUseHookFunctionTarget : NSObject
- (NSInteger)value;
@end

@implementation IOSUseHookFunctionTarget
- (NSInteger)value {
    return 4;
}
@end

static NSInteger IOSUseHookFunctionReplacement(
    __unused id receiver,
    __unused SEL selector
) {
    return 10;
}

static NSInteger IOSUseHookCollision(
    __unused id receiver,
    __unused SEL selector
) {
    return 7;
}

static BOOL IOSUseHookRequire(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(
            stderr,
            "[hook-registry-contract] %s\n",
            message.UTF8String
        );
    }
    return condition;
}

static void IOSUseHookReset(NSString *requiredIdentifier) {
    IOSUsePlayHookRegistryResetForTesting();
    IOSUsePlayHookRegistrySetExpectedRequiredIdentifiersForTesting(
        @[requiredIdentifier]
    );
}

int main(void) {
    @autoreleasepool {
        BOOL passed = YES;
        NSError *error = nil;

        passed &= IOSUseHookRequire(
            ![IOSUsePlayHookRegistryExpectedRequiredIdentifiers()
                containsObject:@"photos.authorization.request"],
            @"Photos feature hook was classified as Runtime/UI core"
        );
        passed &= IOSUseHookRequire(
            [IOSUsePlayHookRegistryExpectedRequiredIdentifiers()
                containsObject:
                    @"playtools.process-info.mac-catalyst-app"] &&
                [IOSUsePlayHookRegistryExpectedRequiredIdentifiers()
                    containsObject:
                        @"playtools.process-info.ios-app-on-mac"],
            @"ProcessInfo Catalyst identity hooks are not required"
        );

        IOSUseHookReset(@"missing.required");
        NSDictionary<NSString *, id> *missingDiagnostics =
            IOSUsePlayHookRegistryDiagnostics();
        passed &= IOSUseHookRequire(
            !IOSUsePlayHookRegistryRequiredReady() &&
                !IOSUsePlayHookRegistryHasRequiredFailure(
                    missingDiagnostics,
                    NO
                ) &&
                IOSUsePlayHookRegistryHasRequiredFailure(
                    missingDiagnostics,
                    YES
                ),
            @"missing declaration was not separated from configuration failure"
        );

        IOSUseHookReset(@"nil.target");
        passed &= IOSUseHookRequire(
            !IOSUsePlayHookRegistryInstallMethodAlias(
                @"nil.target",
                YES,
                @"test",
                Nil,
                @selector(value),
                IOSUseHookReplacementOwner.class,
                @selector(hook_value),
                NO,
                NO,
                NULL,
                &error
            ) &&
                error != nil &&
                !IOSUsePlayHookRegistryRequiredReady(),
            @"nil target did not produce a required failure"
        );

        IOSUseHookReset(@"abi.mismatch");
        error = nil;
        passed &= IOSUseHookRequire(
            !IOSUsePlayHookRegistryInstallMethodAlias(
                @"abi.mismatch",
                YES,
                @"test",
                IOSUseHookParent.class,
                @selector(value),
                IOSUseHookWrongReplacementOwner.class,
                @selector(hook_value),
                YES,
                NO,
                NULL,
                &error
            ) &&
                error != nil,
            @"ABI mismatch was accepted"
        );

        IOSUseHookReset(@"owner.direct");
        error = nil;
        passed &= IOSUseHookRequire(
            !IOSUsePlayHookRegistryInstallMethodAlias(
                @"owner.direct",
                YES,
                @"test",
                IOSUseHookDirectOwnerChild.class,
                @selector(value),
                IOSUseHookReplacementOwner.class,
                @selector(hook_value),
                YES,
                NO,
                NULL,
                &error
            ) &&
                error != nil,
            @"inherited selector passed an exact-owner policy"
        );

        IOSUseHookReset(@"inherited.install");
        error = nil;
        IMP parentBefore = class_getMethodImplementation(
            IOSUseHookParent.class,
            @selector(value)
        );
        IMP inheritedOriginal = NULL;
        passed &= IOSUseHookRequire(
            IOSUsePlayHookRegistryInstallMethodAlias(
                @"inherited.install",
                YES,
                @"test",
                IOSUseHookInheritedChild.class,
                @selector(value),
                IOSUseHookReplacementOwner.class,
                @selector(hook_value),
                NO,
                YES,
                &inheritedOriginal,
                &error
            ) &&
                error == nil &&
                !IOSUsePlayHookRegistryRequiredReady() &&
                !IOSUsePlayHookRegistryHasRequiredFailure(
                    IOSUsePlayHookRegistryDiagnostics(),
                    NO
                ),
            @"first-use gate did not block before invocation"
        );
        IOSUseHookInheritedChild *inherited =
            [IOSUseHookInheritedChild new];
        NSInteger inheritedValue =
            ((NSInteger (*)(id, SEL))objc_msgSend)(
                inherited,
                @selector(value)
            );
        NSInteger inheritedOriginalValue =
            inheritedOriginal == NULL
                ? NSIntegerMin
                : ((NSInteger (*)(id, SEL))inheritedOriginal)(
                    inherited,
                    @selector(value)
                );
        IOSUsePlayHookRegistryRecordFirstUse(
            @"inherited.install",
            inherited.class
        );
        passed &= IOSUseHookRequire(
            inheritedValue == 42 &&
                inheritedOriginalValue == 1 &&
                class_getMethodImplementation(
                    IOSUseHookParent.class,
                    @selector(value)
                ) == parentBefore &&
                IOSUsePlayHookRegistryRequiredReady(),
            @"inherited install mutated its superclass or missed first use"
        );
        Method childValue = class_getInstanceMethod(
            IOSUseHookInheritedChild.class,
            @selector(value)
        );
        IMP installed = class_getMethodImplementation(
            IOSUseHookInheritedChild.class,
            @selector(value)
        );
        class_replaceMethod(
            IOSUseHookInheritedChild.class,
            @selector(value),
            (IMP)IOSUseHookCollision,
            method_getTypeEncoding(childValue)
        );
        passed &= IOSUseHookRequire(
            !IOSUsePlayHookRegistryRequiredReady() &&
                IOSUsePlayHookRegistryHasRequiredFailure(
                    IOSUsePlayHookRegistryDiagnostics(),
                    NO
                ),
            @"post-install receiving-IMP collision was not detected"
        );
        class_replaceMethod(
            IOSUseHookInheritedChild.class,
            @selector(value),
            installed,
            method_getTypeEncoding(childValue)
        );
        passed &= IOSUseHookRequire(
            !IOSUsePlayHookRegistryRequiredReady(),
            @"receiving-IMP collision failure was not sticky"
        );

        IOSUseHookReset(@"subclass.bypass");
        error = nil;
        passed &= IOSUseHookRequire(
            IOSUsePlayHookRegistryInstallMethodAlias(
                @"subclass.bypass",
                YES,
                @"test",
                IOSUseHookBypassBase.class,
                @selector(value),
                IOSUseHookReplacementOwner.class,
                @selector(hook_value),
                YES,
                YES,
                NULL,
                &error
            ),
            @"base-class hook installation failed"
        );
        IOSUsePlayHookRegistryRecordFirstUse(
            @"subclass.bypass",
            IOSUseHookBypassChild.class
        );
        passed &= IOSUseHookRequire(
            !IOSUsePlayHookRegistryRequiredReady(),
            @"first receiver subclass bypass was not detected"
        );

        IOSUseHookReset(@"duplicate.install");
        const char **noArguments = NULL;
        error = nil;
        passed &= IOSUseHookRequire(
            IOSUsePlayHookRegistryInstallFunction(
                @"duplicate.install",
                YES,
                @"test",
                IOSUseHookFunctionTarget.class,
                NO,
                @selector(value),
                @encode(NSInteger),
                noArguments,
                0,
                YES,
                NO,
                (IMP)IOSUseHookFunctionReplacement,
                NULL,
                &error
            ) &&
                error == nil,
            @"fixture function hook installation failed"
        );
        error = nil;
        passed &= IOSUseHookRequire(
            !IOSUsePlayHookRegistryInstallFunction(
                @"duplicate.install",
                YES,
                @"test",
                IOSUseHookFunctionTarget.class,
                NO,
                @selector(value),
                @encode(NSInteger),
                noArguments,
                0,
                YES,
                NO,
                (IMP)IOSUseHookFunctionReplacement,
                NULL,
                &error
            ) &&
                error != nil &&
                !IOSUsePlayHookRegistryRequiredReady() &&
                [IOSUseHookFunctionTarget.new value] == 10,
            @"duplicate install was accepted or changed the first IMP"
        );

        IOSUseHookReset(@"preflight.refresh");
        error = nil;
        Method functionTargetMethod = class_getInstanceMethod(
            IOSUseHookFunctionTarget.class,
            @selector(value)
        );
        IMP preflightBaseline = class_getMethodImplementation(
            IOSUseHookFunctionTarget.class,
            @selector(value)
        );
        passed &= IOSUseHookRequire(
            IOSUsePlayHookRegistryObserveMethod(
                @"preflight.refresh",
                YES,
                @"test",
                IOSUseHookFunctionTarget.class,
                NO,
                @selector(value),
                @encode(NSInteger),
                noArguments,
                0,
                YES,
                NO,
                &error
            ) &&
                IOSUsePlayHookRegistryRequiredReady(),
            @"valid method preflight was not ready"
        );
        class_replaceMethod(
            IOSUseHookFunctionTarget.class,
            @selector(value),
            (IMP)IOSUseHookCollision,
            method_getTypeEncoding(functionTargetMethod)
        );
        error = nil;
        (void)IOSUsePlayHookRegistryObserveMethod(
            @"preflight.refresh",
            YES,
            @"test",
            IOSUseHookFunctionTarget.class,
            NO,
            @selector(value),
            @encode(NSInteger),
            noArguments,
            0,
            YES,
            NO,
            &error
        );
        passed &= IOSUseHookRequire(
            !IOSUsePlayHookRegistryRequiredReady(),
            @"preflight refresh rebased a changed receiving IMP"
        );
        class_replaceMethod(
            IOSUseHookFunctionTarget.class,
            @selector(value),
            preflightBaseline,
            method_getTypeEncoding(functionTargetMethod)
        );
        (void)IOSUsePlayHookRegistryObserveMethod(
            @"preflight.refresh",
            YES,
            @"test",
            IOSUseHookFunctionTarget.class,
            NO,
            @selector(value),
            @encode(NSInteger),
            noArguments,
            0,
            YES,
            NO,
            NULL
        );
        passed &= IOSUseHookRequire(
            !IOSUsePlayHookRegistryRequiredReady(),
            @"preflight collision failure was not sticky"
        );

        Class badSelfClass = objc_allocateClassPair(
            NSObject.class,
            "IOSUseHookBadSelfABI",
            0
        );
        class_addMethod(
            badSelfClass,
            @selector(value),
            (IMP)IOSUseHookCollision,
            "q16#0:8"
        );
        objc_registerClassPair(badSelfClass);
        IOSUseHookReset(@"implicit.self");
        error = nil;
        passed &= IOSUseHookRequire(
            !IOSUsePlayHookRegistryObserveMethod(
                @"implicit.self",
                YES,
                @"test",
                badSelfClass,
                NO,
                @selector(value),
                @encode(NSInteger),
                noArguments,
                0,
                YES,
                NO,
                &error
            ) &&
                error != nil,
            @"malformed implicit self ABI was accepted"
        );

        Class badCommandClass = objc_allocateClassPair(
            NSObject.class,
            "IOSUseHookBadCommandABI",
            0
        );
        class_addMethod(
            badCommandClass,
            @selector(value),
            (IMP)IOSUseHookCollision,
            "q16@0@8"
        );
        objc_registerClassPair(badCommandClass);
        IOSUseHookReset(@"implicit.command");
        error = nil;
        passed &= IOSUseHookRequire(
            !IOSUsePlayHookRegistryObserveMethod(
                @"implicit.command",
                YES,
                @"test",
                badCommandClass,
                NO,
                @selector(value),
                @encode(NSInteger),
                noArguments,
                0,
                YES,
                NO,
                &error
            ) &&
                error != nil,
            @"malformed implicit _cmd ABI was accepted"
        );

        IOSUseHookReset(@"state.refresh");
        IOSUsePlayHookRegistryRecordState(
            @"state.refresh",
            YES,
            @"readiness",
            @"fixture",
            @"dynamic-state",
            @"BOOL",
            NO,
            NO,
            @"not ready yet"
        );
        passed &= IOSUseHookRequire(
            !IOSUsePlayHookRegistryRequiredReady(),
            @"initial dynamic state failure was not retained"
        );
        IOSUsePlayHookRegistryRecordState(
            @"state.refresh",
            YES,
            @"readiness",
            @"fixture",
            @"dynamic-state",
            @"BOOL",
            NO,
            YES,
            nil
        );
        passed &= IOSUseHookRequire(
            IOSUsePlayHookRegistryRequiredReady(),
            @"same-contract dynamic state did not refresh"
        );

        IOSUseHookReset(@"state.conflict");
        IOSUsePlayHookRegistryRecordState(
            @"state.conflict",
            YES,
            @"readiness",
            @"fixture-a",
            @"dynamic-state",
            @"BOOL",
            NO,
            NO,
            @"original required failure"
        );
        IOSUsePlayHookRegistryRecordState(
            @"state.conflict",
            YES,
            @"readiness",
            @"fixture-b",
            @"dynamic-state",
            @"BOOL",
            NO,
            YES,
            nil
        );
        passed &= IOSUseHookRequire(
            !IOSUsePlayHookRegistryRequiredReady(),
            @"different-contract state masked a required failure"
        );
        IOSUsePlayHookRegistryRecordState(
            @"state.conflict",
            YES,
            @"readiness",
            @"fixture-a",
            @"dynamic-state",
            @"BOOL",
            NO,
            YES,
            nil
        );
        passed &= IOSUseHookRequire(
            !IOSUsePlayHookRegistryRequiredReady(),
            @"state identifier conflict was not sticky"
        );

        IOSUseHookReset(@"required.state");
        IOSUsePlayHookRegistryRecordState(
            @"required.state",
            YES,
            @"test",
            @"fixture",
            @"ready",
            @"BOOL",
            NO,
            YES,
            nil
        );
        IOSUsePlayHookRegistryRecordState(
            @"optional.failure",
            NO,
            @"test",
            @"fixture",
            @"optional",
            @"BOOL",
            NO,
            NO,
            @"optional failure"
        );
        passed &= IOSUseHookRequire(
            IOSUsePlayHookRegistryRequiredReady(),
            @"optional failure blocked required readiness"
        );
        IOSUsePlayHookRegistryDeclareObservedWrapper(
            @"duplicate.wrapper",
            @"test",
            @"fixture",
            @"wrapper",
            @"void(void)"
        );
        IOSUsePlayHookRegistryRecordInvocation(
            @"duplicate.wrapper"
        );
        IOSUsePlayHookRegistryDeclareObservedWrapper(
            @"duplicate.wrapper",
            @"test",
            @"fixture",
            @"wrapper",
            @"void(void)"
        );
        passed &= IOSUseHookRequire(
            !IOSUsePlayHookRegistryEntryReady(
                @"duplicate.wrapper"
            ) &&
                IOSUsePlayHookRegistryRequiredReady(),
            @"duplicate wrapper declaration did not fail closed"
        );

        IOSUseHookReset(@"required.state");
        IOSUsePlayHookRegistryRecordState(
            @"required.state",
            YES,
            @"test",
            @"fixture",
            @"ready",
            @"BOOL",
            NO,
            YES,
            nil
        );
        IOSUsePlayHookRegistryRecordPreMainInvocation(
            "dyld.active-platform"
        );
        IOSUsePlayHookRegistryDeclareObservedWrapper(
            @"dyld.active-platform",
            @"dyld-interpose",
            @"libSystem",
            @"dyld_get_active_platform",
            @"int(void)"
        );
        passed &= IOSUseHookRequire(
            IOSUsePlayHookRegistryEntryReady(
                @"dyld.active-platform"
            ) &&
                IOSUsePlayHookRegistryRequiredReady(),
            @"pre-main invocation was not retained until declaration"
        );

        IOSUseHookReset(@"required.state");
        IOSUsePlayHookRegistryRecordState(
            @"required.state",
            YES,
            @"test",
            @"fixture",
            @"ready",
            @"BOOL",
            NO,
            YES,
            nil
        );
        IOSUsePlayHookRegistryRecordPreMainInvocation(
            "unknown.wrapper"
        );
        IOSUsePlayHookRegistryDeclareObservedWrapper(
            @"unknown.wrapper",
            @"dyld-interpose",
            @"libSystem",
            @"unknown",
            @"void(void)"
        );
        passed &= IOSUseHookRequire(
            !IOSUsePlayHookRegistryEntryReady(
                @"unknown.wrapper"
            ) &&
                IOSUsePlayHookRegistryRequiredReady(),
            @"unknown pre-main invocation bypassed the fixed registry"
        );

        if (!passed) {
            return 1;
        }
        puts("[hook-registry-contract] PASS");
        return 0;
    }
}
