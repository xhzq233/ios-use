#import "IOSUsePlayHookRegistry.h"

#import <os/lock.h>
#import <stdatomic.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>

static NSString *const IOSUsePlayHookRegistryErrorDomain =
    @"io.ios-use.play-runtime.hook-registry";

@interface IOSUsePlayHookEntry : NSObject
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *kind;
@property(nonatomic) BOOL required;
@property(nonatomic, copy) NSString *phase;
@property(nonatomic, copy) NSString *target;
@property(nonatomic, copy) NSString *selector;
@property(nonatomic, copy) NSString *abi;
@property(nonatomic, copy, nullable) NSString *owner;
@property(nonatomic) BOOL installed;
@property(nonatomic) BOOL originalIMPRecorded;
@property(nonatomic) BOOL installedIMPRecorded;
@property(nonatomic) BOOL currentIMPMatchesInstalled;
@property(nonatomic) BOOL requiresFirstUseBeforeReady;
@property(nonatomic) NSUInteger invocationCount;
@property(nonatomic, copy, nullable) NSString *firstReceiverClass;
@property(nonatomic, copy, nullable) NSString *failure;
@property(nonatomic) BOOL identifierConflict;
@property(nonatomic) Class targetClass;
@property(nonatomic) BOOL classMethod;
@property(nonatomic) SEL targetSelector;
@property(nonatomic) IMP installedIMP;
@end

@implementation IOSUsePlayHookEntry
@end

static os_unfair_lock IOSUsePlayHookRegistryLock =
    OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString *, IOSUsePlayHookEntry *> *
    IOSUsePlayHookEntries;

typedef struct {
    const char *identifier;
    _Atomic(uint64_t) invocationCount;
} IOSUsePlayPreMainInvocationCounter;

static IOSUsePlayPreMainInvocationCounter
    IOSUsePlayPreMainInvocationCounters[] = {
        {"dyld.active-platform", 0},
        {"dyld.uname", 0},
        {"dyld.sysctl", 0},
        {"dyld.sysctlbyname", 0},
    };

#if defined(IOS_USE_PLAY_HOOK_REGISTRY_TESTING)
static NSArray<NSString *> *
    IOSUsePlayHookExpectedRequiredIdentifiersForTesting;
#endif

NSArray<NSString *> *
IOSUsePlayHookRegistryExpectedRequiredIdentifiers(void) {
#if defined(IOS_USE_PLAY_HOOK_REGISTRY_TESTING)
    if (IOSUsePlayHookExpectedRequiredIdentifiersForTesting != nil) {
        return IOSUsePlayHookExpectedRequiredIdentifiersForTesting;
    }
#endif
    static NSArray<NSString *> *identifiers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        identifiers = @[
            @"safe-area.provider",
            @"playtools.screen.scene-frame",
            @"playtools.screen.scene-bounds",
            @"playtools.screen.display-size",
            @"playtools.screen.native-bounds",
            @"playtools.screen.native-scale",
            @"playtools.screen.scale",
            @"playtools.device.orientation",
            @"playtools.device.idiom",
            @"playtools.device.model",
            @"playtools.device.localized-model",
            @"playtools.trait.idiom",
            @"photos.authorization.legacy",
            @"photos.authorization.access-level",
            @"fake-touch.runloop-source",
            @"fake-touch.application-event",
            @"fake-touch.event-clear",
            @"fake-touch.event-add",
            @"fake-touch.set-window",
            @"fake-touch.set-view",
            @"fake-touch.set-location",
            @"fake-touch.set-first-touch",
            @"fake-touch.set-is-tap",
            @"fake-touch.set-timestamp",
            @"fake-touch.set-phase",
            @"fake-touch.set-hid-event",
            @"uikitmac.scale.idiom-setter",
            @"uikitmac.scale.idiom-getter",
            @"uikitmac.scale.windows-setter",
            @"uikitmac.scale.windows-getter",
            @"uikitmac.scale.downscale-setter",
            @"uikitmac.scale.downscale-getter",
            @"uikitmac.resize.edges",
            @"uikitmac.resize.proposed-size",
            @"appkit.mouse-monitor.selector",
            @"appkit.mouse-monitor.token",
            @"uikit.status-bar-frame",
            @"uikit.status-bar-manager-frame",
        ];
    });
    return identifiers;
}

static NSMutableDictionary<NSString *, IOSUsePlayHookEntry *> *
IOSUsePlayHookRegistryEntriesLocked(void) {
    if (IOSUsePlayHookEntries == nil) {
        IOSUsePlayHookEntries = [NSMutableDictionary dictionary];
    }
    return IOSUsePlayHookEntries;
}

static Class IOSUsePlayHookMethodOwner(
    Class targetClass,
    BOOL classMethod,
    SEL selector
) {
    for (Class candidate = targetClass;
         candidate != Nil;
         candidate = class_getSuperclass(candidate)) {
        Class methodClass = classMethod
            ? object_getClass(candidate)
            : candidate;
        unsigned int count = 0;
        Method *methods = class_copyMethodList(methodClass, &count);
        BOOL found = NO;
        for (unsigned int index = 0; index < count; index += 1) {
            if (method_getName(methods[index]) == selector) {
                found = YES;
                break;
            }
        }
        free(methods);
        if (found) {
            return candidate;
        }
    }
    return Nil;
}

static Class IOSUsePlayHookDispatchClass(
    Class targetClass,
    BOOL classMethod
) {
    return classMethod ? object_getClass(targetClass) : targetClass;
}

static BOOL IOSUsePlayHookTypesEqual(
    const char *left,
    const char *right
) {
    return left != NULL &&
        right != NULL &&
        strcmp(left, right) == 0;
}

static BOOL IOSUsePlayHookMethodsHaveEqualABI(
    Method target,
    Method replacement
) {
    if (target == NULL || replacement == NULL) {
        return NO;
    }
    unsigned int count = method_getNumberOfArguments(target);
    if (count != method_getNumberOfArguments(replacement)) {
        return NO;
    }
    char *targetReturn = method_copyReturnType(target);
    char *replacementReturn = method_copyReturnType(replacement);
    BOOL matches = IOSUsePlayHookTypesEqual(
        targetReturn,
        replacementReturn
    );
    free(targetReturn);
    free(replacementReturn);
    for (unsigned int index = 0; matches && index < count; index += 1) {
        char *targetArgument =
            method_copyArgumentType(target, index);
        char *replacementArgument =
            method_copyArgumentType(replacement, index);
        matches = IOSUsePlayHookTypesEqual(
            targetArgument,
            replacementArgument
        );
        free(targetArgument);
        free(replacementArgument);
    }
    return matches;
}

static BOOL IOSUsePlayHookMethodHasABI(
    Method method,
    const char *returnType,
    const char *const *argumentTypes,
    unsigned int explicitArgumentCount
) {
    if (method == NULL ||
        method_getNumberOfArguments(method) !=
            explicitArgumentCount + 2) {
        return NO;
    }
    char *observedReturn = method_copyReturnType(method);
    BOOL matches = IOSUsePlayHookTypesEqual(
        observedReturn,
        returnType
    );
    free(observedReturn);
    char *observedSelf = method_copyArgumentType(method, 0);
    char *observedCommand = method_copyArgumentType(method, 1);
    matches = matches &&
        IOSUsePlayHookTypesEqual(observedSelf, @encode(id)) &&
        IOSUsePlayHookTypesEqual(observedCommand, @encode(SEL));
    free(observedSelf);
    free(observedCommand);
    for (unsigned int index = 0;
         matches && index < explicitArgumentCount;
         index += 1) {
        char *observed =
            method_copyArgumentType(method, index + 2);
        matches = IOSUsePlayHookTypesEqual(
            observed,
            argumentTypes[index]
        );
        free(observed);
    }
    return matches;
}

static NSError *IOSUsePlayHookError(
    NSInteger code,
    NSString *description
) {
    return [NSError errorWithDomain:IOSUsePlayHookRegistryErrorDomain
                               code:code
                           userInfo:@{
        NSLocalizedDescriptionKey: description,
    }];
}

static IOSUsePlayHookEntry *IOSUsePlayHookMakeEntry(
    NSString *identifier,
    BOOL required,
    NSString *phase,
    Class targetClass,
    BOOL classMethod,
    SEL selector,
    const char *abi,
    BOOL requiresFirstUseBeforeReady
) {
    IOSUsePlayHookEntry *entry = [IOSUsePlayHookEntry new];
    entry.identifier = identifier;
    entry.kind = @"method";
    entry.required = required;
    entry.phase = phase;
    entry.target = targetClass == Nil
        ? @"unavailable"
        : NSStringFromClass(targetClass);
    entry.selector = selector == NULL
        ? @"unavailable"
        : NSStringFromSelector(selector);
    entry.abi = abi == NULL
        ? @"unavailable"
        : [NSString stringWithUTF8String:abi];
    entry.requiresFirstUseBeforeReady =
        requiresFirstUseBeforeReady;
    entry.targetClass = targetClass;
    entry.classMethod = classMethod;
    entry.targetSelector = selector;
    return entry;
}

static void IOSUsePlayHookStoreEntry(
    IOSUsePlayHookEntry *entry
) {
    os_unfair_lock_lock(&IOSUsePlayHookRegistryLock);
    NSMutableDictionary<NSString *, IOSUsePlayHookEntry *> *entries =
        IOSUsePlayHookRegistryEntriesLocked();
    IOSUsePlayHookEntry *existing = entries[entry.identifier];
    if (existing == nil) {
        entries[entry.identifier] = entry;
        os_unfair_lock_unlock(&IOSUsePlayHookRegistryLock);
        return;
    }
    BOOL sameContract =
        [existing.kind isEqualToString:entry.kind] &&
        existing.required == entry.required &&
        [existing.phase isEqualToString:entry.phase] &&
        [existing.target isEqualToString:entry.target] &&
        [existing.selector isEqualToString:entry.selector] &&
        [existing.abi isEqualToString:entry.abi] &&
        ((existing.owner == nil && entry.owner == nil) ||
         [existing.owner isEqualToString:entry.owner]) &&
        existing.requiresFirstUseBeforeReady ==
            entry.requiresFirstUseBeforeReady &&
        existing.targetClass == entry.targetClass &&
        existing.classMethod == entry.classMethod &&
        existing.targetSelector == entry.targetSelector;
    BOOL refreshable =
        sameContract &&
        ([entry.kind isEqualToString:@"method-preflight"] ||
         [entry.kind isEqualToString:@"state"]);
    if (!refreshable) {
        existing.identifierConflict = YES;
        existing.failure =
            @"duplicate hook identifier declaration";
        os_unfair_lock_unlock(&IOSUsePlayHookRegistryLock);
        return;
    }
    entry.invocationCount = existing.invocationCount;
    entry.firstReceiverClass = existing.firstReceiverClass;
    if ([entry.kind isEqualToString:@"method-preflight"]) {
        entry.identifierConflict = existing.identifierConflict;
        if (entry.installedIMP != existing.installedIMP) {
            existing.currentIMPMatchesInstalled = NO;
            if (existing.failure == nil) {
                existing.failure =
                    @"receiving IMP changed after preflight";
            }
            os_unfair_lock_unlock(
                &IOSUsePlayHookRegistryLock
            );
            return;
        }
        if (existing.failure != nil) {
            entry.failure = existing.failure;
            entry.currentIMPMatchesInstalled =
                existing.currentIMPMatchesInstalled;
        }
        entry.installedIMP = existing.installedIMP;
    } else if (existing.identifierConflict) {
        entry.identifierConflict = YES;
        entry.installed = NO;
        entry.currentIMPMatchesInstalled = NO;
        entry.failure = existing.failure ?:
            @"duplicate hook identifier declaration";
    }
    entries[entry.identifier] = entry;
    os_unfair_lock_unlock(&IOSUsePlayHookRegistryLock);
}

static BOOL IOSUsePlayHookRejectDuplicateInstall(
    NSString *identifier,
    NSError **error
) {
    os_unfair_lock_lock(&IOSUsePlayHookRegistryLock);
    IOSUsePlayHookEntry *existing =
        IOSUsePlayHookRegistryEntriesLocked()[identifier];
    if (existing != nil) {
        existing.identifierConflict = YES;
        existing.failure =
            @"duplicate hook identifier install";
    }
    os_unfair_lock_unlock(&IOSUsePlayHookRegistryLock);
    if (existing == nil) {
        return NO;
    }
    if (error != NULL) {
        *error = IOSUsePlayHookError(
            9,
            @"duplicate hook identifier install"
        );
    }
    return YES;
}

static BOOL IOSUsePlayHookFail(
    IOSUsePlayHookEntry *entry,
    NSInteger code,
    NSString *failure,
    NSError **error
) {
    entry.failure = failure;
    entry.installed = NO;
    entry.currentIMPMatchesInstalled = NO;
    IOSUsePlayHookStoreEntry(entry);
    if (error != NULL) {
        *error = IOSUsePlayHookError(code, failure);
    }
    return NO;
}

BOOL IOSUsePlayHookRegistryInstallMethodAlias(
    NSString *identifier,
    BOOL required,
    NSString *phase,
    Class targetClass,
    SEL targetSelector,
    Class replacementOwner,
    SEL replacementSelector,
    BOOL requiresDirectOwner,
    BOOL requiresFirstUseBeforeReady,
    IMP *originalOutput,
    NSError **error
) {
    if (originalOutput != NULL) {
        *originalOutput = NULL;
    }
    if (IOSUsePlayHookRejectDuplicateInstall(identifier, error)) {
        return NO;
    }
    Method target = targetClass == Nil || targetSelector == NULL
        ? NULL
        : class_getInstanceMethod(targetClass, targetSelector);
    Method replacement =
        replacementOwner == Nil || replacementSelector == NULL
            ? NULL
            : class_getInstanceMethod(
                replacementOwner,
                replacementSelector
            );
    IOSUsePlayHookEntry *entry = IOSUsePlayHookMakeEntry(
        identifier,
        required,
        phase,
        targetClass,
        NO,
        targetSelector,
        target == NULL ? NULL : method_getTypeEncoding(target),
        requiresFirstUseBeforeReady
    );
    Class owner = IOSUsePlayHookMethodOwner(
        targetClass,
        NO,
        targetSelector
    );
    entry.owner = owner == Nil ? nil : NSStringFromClass(owner);
    entry.kind = @"method-install";
    if (target == NULL || replacement == NULL) {
        return IOSUsePlayHookFail(
            entry,
            1,
            @"target or replacement method is unavailable",
            error
        );
    }
    if (requiresDirectOwner && owner != targetClass) {
        return IOSUsePlayHookFail(
            entry,
            2,
            @"target selector is not owned by the required class",
            error
        );
    }
    if (!IOSUsePlayHookMethodsHaveEqualABI(target, replacement)) {
        return IOSUsePlayHookFail(
            entry,
            3,
            @"target and replacement method ABIs differ",
            error
        );
    }
    IMP original = method_getImplementation(target);
    IMP installed = method_getImplementation(replacement);
    const char *types = method_getTypeEncoding(target);
    if (original == NULL || installed == NULL || types == NULL ||
        original == installed) {
        return IOSUsePlayHookFail(
            entry,
            4,
            @"original or replacement IMP is invalid",
            error
        );
    }
    unsigned int directCount = 0;
    Method *directMethods =
        class_copyMethodList(targetClass, &directCount);
    BOOL replacementAliasAlreadyDirect = NO;
    for (unsigned int index = 0; index < directCount; index += 1) {
        if (method_getName(directMethods[index]) ==
                replacementSelector) {
            replacementAliasAlreadyDirect = YES;
            break;
        }
    }
    free(directMethods);
    if (replacementAliasAlreadyDirect ||
        !class_addMethod(
            targetClass,
            replacementSelector,
            original,
            types
        )) {
        return IOSUsePlayHookFail(
            entry,
            5,
            @"original IMP alias already exists on target class",
            error
        );
    }
    if (owner == targetClass) {
        IMP replaced = method_setImplementation(target, installed);
        if (replaced != original) {
            return IOSUsePlayHookFail(
                entry,
                6,
                @"target method replacement returned an unexpected IMP",
                error
            );
        }
    } else if (!class_addMethod(
            targetClass,
            targetSelector,
            installed,
            types
        )) {
        return IOSUsePlayHookFail(
            entry,
            7,
            @"could not install an exact target-class override",
            error
        );
    }
    BOOL active =
        class_getMethodImplementation(
            targetClass,
            targetSelector
        ) == installed;
    entry.originalIMPRecorded = YES;
    entry.installedIMPRecorded = YES;
    entry.installedIMP = installed;
    entry.installed = active;
    entry.currentIMPMatchesInstalled = active;
    if (!active) {
        return IOSUsePlayHookFail(
            entry,
            8,
            @"target receiver does not dispatch to replacement IMP",
            error
        );
    }
    IOSUsePlayHookStoreEntry(entry);
    if (originalOutput != NULL) {
        *originalOutput = original;
    }
    return YES;
}

static BOOL IOSUsePlayHookRegistryRecordMethod(
    NSString *identifier,
    BOOL required,
    NSString *phase,
    Class targetClass,
    BOOL classMethod,
    SEL selector,
    const char *returnType,
    const char *const *argumentTypes,
    unsigned int explicitArgumentCount,
    BOOL requiresDirectOwner,
    BOOL requiresFirstUseBeforeReady,
    IMP replacement,
    IMP *original,
    BOOL replace,
    NSError **error
) {
    Method method = targetClass == Nil || selector == NULL
        ? NULL
        : classMethod
            ? class_getClassMethod(targetClass, selector)
            : class_getInstanceMethod(targetClass, selector);
    IOSUsePlayHookEntry *entry = IOSUsePlayHookMakeEntry(
        identifier,
        required,
        phase,
        targetClass,
        classMethod,
        selector,
        method == NULL ? NULL : method_getTypeEncoding(method),
        requiresFirstUseBeforeReady
    );
    entry.kind = replace
        ? @"method-install"
        : @"method-preflight";
    Class owner = IOSUsePlayHookMethodOwner(
        targetClass,
        classMethod,
        selector
    );
    entry.owner = owner == Nil ? nil : NSStringFromClass(owner);
    if (method == NULL) {
        return IOSUsePlayHookFail(
            entry,
            20,
            @"target method is unavailable",
            error
        );
    }
    if (requiresDirectOwner && owner != targetClass) {
        return IOSUsePlayHookFail(
            entry,
            21,
            @"target selector is not owned by the required class",
            error
        );
    }
    if ((explicitArgumentCount > 0 && argumentTypes == NULL) ||
        !IOSUsePlayHookMethodHasABI(
            method,
            returnType,
            argumentTypes,
            explicitArgumentCount
        )) {
        return IOSUsePlayHookFail(
            entry,
            22,
            @"target method ABI does not match the required contract",
            error
        );
    }
    Class dispatchClass = IOSUsePlayHookDispatchClass(
        targetClass,
        classMethod
    );
    IMP current = class_getMethodImplementation(
        dispatchClass,
        selector
    );
    if (current == NULL || (replace && replacement == NULL)) {
        return IOSUsePlayHookFail(
            entry,
            23,
            @"target or replacement IMP is unavailable",
            error
        );
    }
    if (original != NULL) {
        *original = current;
    }
    IMP expected = replace ? replacement : current;
    if (replace) {
        const char *types = method_getTypeEncoding(method);
        if (types == NULL) {
            return IOSUsePlayHookFail(
                entry,
                24,
                @"target method type encoding is unavailable",
                error
            );
        }
        if (owner == targetClass) {
            IMP replaced = method_setImplementation(
                method,
                replacement
            );
            if (replaced != current) {
                return IOSUsePlayHookFail(
                    entry,
                    25,
                    @"target method replacement returned unexpected IMP",
                    error
                );
            }
        } else if (!class_addMethod(
                dispatchClass,
                selector,
                replacement,
                types
            )) {
            return IOSUsePlayHookFail(
                entry,
                26,
                @"could not install exact dispatch-class override",
                error
            );
        }
    }
    BOOL active =
        class_getMethodImplementation(dispatchClass, selector) ==
            expected;
    entry.originalIMPRecorded = YES;
    entry.installedIMPRecorded = YES;
    entry.installedIMP = expected;
    entry.installed = active;
    entry.currentIMPMatchesInstalled = active;
    if (!active) {
        return IOSUsePlayHookFail(
            entry,
            27,
            @"target receiver does not dispatch to expected IMP",
            error
        );
    }
    IOSUsePlayHookStoreEntry(entry);
    return YES;
}

BOOL IOSUsePlayHookRegistryInstallFunction(
    NSString *identifier,
    BOOL required,
    NSString *phase,
    Class targetClass,
    BOOL classMethod,
    SEL selector,
    const char *returnType,
    const char *const *argumentTypes,
    unsigned int explicitArgumentCount,
    BOOL requiresDirectOwner,
    BOOL requiresFirstUseBeforeReady,
    IMP replacement,
    IMP *original,
    NSError **error
) {
    if (IOSUsePlayHookRejectDuplicateInstall(identifier, error)) {
        return NO;
    }
    return IOSUsePlayHookRegistryRecordMethod(
        identifier,
        required,
        phase,
        targetClass,
        classMethod,
        selector,
        returnType,
        argumentTypes,
        explicitArgumentCount,
        requiresDirectOwner,
        requiresFirstUseBeforeReady,
        replacement,
        original,
        YES,
        error
    );
}

BOOL IOSUsePlayHookRegistryObserveMethod(
    NSString *identifier,
    BOOL required,
    NSString *phase,
    Class targetClass,
    BOOL classMethod,
    SEL selector,
    const char *returnType,
    const char *const *argumentTypes,
    unsigned int explicitArgumentCount,
    BOOL requiresDirectOwner,
    BOOL requiresFirstUseBeforeReady,
    NSError **error
) {
    return IOSUsePlayHookRegistryRecordMethod(
        identifier,
        required,
        phase,
        targetClass,
        classMethod,
        selector,
        returnType,
        argumentTypes,
        explicitArgumentCount,
        requiresDirectOwner,
        requiresFirstUseBeforeReady,
        NULL,
        NULL,
        NO,
        error
    );
}

void IOSUsePlayHookRegistryRecordState(
    NSString *identifier,
    BOOL required,
    NSString *phase,
    NSString *target,
    NSString *selector,
    NSString *abi,
    BOOL requiresFirstUseBeforeReady,
    BOOL ready,
    NSString *failure
) {
    IOSUsePlayHookEntry *entry = [IOSUsePlayHookEntry new];
    entry.identifier = identifier;
    entry.kind = @"state";
    entry.required = required;
    entry.phase = phase;
    entry.target = target;
    entry.selector = selector;
    entry.abi = abi;
    entry.requiresFirstUseBeforeReady =
        requiresFirstUseBeforeReady;
    entry.installed = ready;
    entry.currentIMPMatchesInstalled = ready;
    entry.failure = ready ? nil : failure ?: @"required state is not ready";
    IOSUsePlayHookStoreEntry(entry);
}

void IOSUsePlayHookRegistryRecordFirstUse(
    NSString *identifier,
    Class receiverClass
) {
    os_unfair_lock_lock(&IOSUsePlayHookRegistryLock);
    IOSUsePlayHookEntry *entry =
        IOSUsePlayHookRegistryEntriesLocked()[identifier];
    if (entry != nil) {
        entry.invocationCount += 1;
        if (entry.firstReceiverClass == nil &&
            receiverClass != Nil) {
            entry.firstReceiverClass =
                NSStringFromClass(receiverClass);
        }
        if (entry.targetClass != Nil &&
            entry.targetSelector != NULL &&
            entry.installedIMP != NULL &&
            !entry.classMethod &&
            receiverClass != Nil) {
            IMP receiving = class_getMethodImplementation(
                receiverClass,
                entry.targetSelector
            );
            if (receiving != entry.installedIMP) {
                entry.currentIMPMatchesInstalled = NO;
                entry.failure =
                    @"first receiver bypasses installed IMP";
            }
        }
    }
    os_unfair_lock_unlock(&IOSUsePlayHookRegistryLock);
}

void IOSUsePlayHookRegistryRecordInvocation(
    NSString *identifier
) {
    // Interposed libSystem wrappers may run while the registry itself is
    // allocating Foundation storage. Never initialize storage or wait on the
    // registry lock from those low-level paths; dropping optional invocation
    // evidence is safer than recursive deadlock.
    if (!os_unfair_lock_trylock(&IOSUsePlayHookRegistryLock)) {
        return;
    }
    IOSUsePlayHookEntry *entry =
        IOSUsePlayHookEntries[identifier];
    if (entry != nil) {
        entry.invocationCount += 1;
    }
    os_unfair_lock_unlock(&IOSUsePlayHookRegistryLock);
}

void IOSUsePlayHookRegistryRecordPreMainInvocation(
    const char *identifier
) {
    if (identifier == NULL) {
        return;
    }
    size_t count =
        sizeof(IOSUsePlayPreMainInvocationCounters) /
        sizeof(IOSUsePlayPreMainInvocationCounters[0]);
    for (size_t index = 0; index < count; index += 1) {
        IOSUsePlayPreMainInvocationCounter *counter =
            &IOSUsePlayPreMainInvocationCounters[index];
        if (strcmp(counter->identifier, identifier) == 0) {
            atomic_fetch_add_explicit(
                &counter->invocationCount,
                1,
                memory_order_relaxed
            );
            return;
        }
    }
}

static BOOL IOSUsePlayHookRegistryPreMainInvocationCount(
    NSString *identifier,
    NSUInteger *invocationCount
) {
    const char *utf8 = identifier.UTF8String;
    if (utf8 == NULL) {
        return NO;
    }
    size_t count =
        sizeof(IOSUsePlayPreMainInvocationCounters) /
        sizeof(IOSUsePlayPreMainInvocationCounters[0]);
    for (size_t index = 0; index < count; index += 1) {
        IOSUsePlayPreMainInvocationCounter *counter =
            &IOSUsePlayPreMainInvocationCounters[index];
        if (strcmp(counter->identifier, utf8) == 0) {
            *invocationCount = (NSUInteger)atomic_load_explicit(
                &counter->invocationCount,
                memory_order_relaxed
            );
            return YES;
        }
    }
    return NO;
}

void IOSUsePlayHookRegistryDeclareObservedWrapper(
    NSString *identifier,
    NSString *phase,
    NSString *target,
    NSString *selector,
    NSString *abi
) {
    IOSUsePlayHookEntry *entry = [IOSUsePlayHookEntry new];
    entry.identifier = identifier;
    entry.kind = @"observed-wrapper";
    entry.required = NO;
    entry.phase = phase;
    entry.target = target;
    entry.selector = selector;
    entry.abi = abi;
    IOSUsePlayHookStoreEntry(entry);
}

static BOOL IOSUsePlayHookRefreshEntryLocked(
    IOSUsePlayHookEntry *entry
) {
    if ([entry.kind isEqualToString:@"observed-wrapper"]) {
        NSUInteger preMainInvocationCount = 0;
        if (IOSUsePlayHookRegistryPreMainInvocationCount(
                entry.identifier,
                &preMainInvocationCount
            )) {
            entry.invocationCount = preMainInvocationCount;
        }
        return entry.invocationCount > 0 &&
            entry.failure == nil;
    }
    if (entry.targetClass != Nil &&
        entry.targetSelector != NULL &&
        entry.installedIMP != NULL) {
        Class dispatchClass = IOSUsePlayHookDispatchClass(
            entry.targetClass,
            entry.classMethod
        );
        entry.currentIMPMatchesInstalled =
            class_getMethodImplementation(
                dispatchClass,
                entry.targetSelector
            ) == entry.installedIMP;
        if (!entry.currentIMPMatchesInstalled &&
            entry.failure == nil) {
            entry.failure =
                @"receiving IMP changed after install/preflight";
        }
    }
    return entry.installed &&
        entry.currentIMPMatchesInstalled &&
        entry.failure == nil &&
        (!entry.requiresFirstUseBeforeReady ||
         entry.invocationCount > 0);
}

BOOL IOSUsePlayHookRegistryRequiredReady(void) {
    os_unfair_lock_lock(&IOSUsePlayHookRegistryLock);
    NSMutableDictionary *entries =
        IOSUsePlayHookRegistryEntriesLocked();
    BOOL ready = YES;
    for (NSString *identifier in
         IOSUsePlayHookRegistryExpectedRequiredIdentifiers()) {
        IOSUsePlayHookEntry *entry = entries[identifier];
        if (entry == nil || !entry.required ||
            !IOSUsePlayHookRefreshEntryLocked(entry)) {
            ready = NO;
        }
    }
    os_unfair_lock_unlock(&IOSUsePlayHookRegistryLock);
    return ready;
}

BOOL IOSUsePlayHookRegistryEntryReady(NSString *identifier) {
    os_unfair_lock_lock(&IOSUsePlayHookRegistryLock);
    IOSUsePlayHookEntry *entry =
        IOSUsePlayHookRegistryEntriesLocked()[identifier];
    BOOL ready = entry != nil &&
        IOSUsePlayHookRefreshEntryLocked(entry);
    os_unfair_lock_unlock(&IOSUsePlayHookRegistryLock);
    return ready;
}

static NSDictionary<NSString *, id> *
IOSUsePlayHookEntryDiagnostics(IOSUsePlayHookEntry *entry) {
    BOOL ready = IOSUsePlayHookRefreshEntryLocked(entry);
    return @{
        @"identifier": entry.identifier,
        @"kind": entry.kind,
        @"phase": entry.phase,
        @"required": @(entry.required),
        @"target": entry.target,
        @"selector": entry.selector,
        @"abi": entry.abi,
        @"owner": entry.owner ?: NSNull.null,
        @"installed": @(entry.installed),
        @"originalIMPRecorded": @(entry.originalIMPRecorded),
        @"installedIMPRecorded": @(entry.installedIMPRecorded),
        @"currentIMPMatchesInstalled":
            @(entry.currentIMPMatchesInstalled),
        @"requiresFirstUseBeforeReady":
            @(entry.requiresFirstUseBeforeReady),
        @"invocationCount": @(entry.invocationCount),
        @"wrapperInvocationObserved": @(
            [entry.kind isEqualToString:@"observed-wrapper"] &&
            entry.invocationCount > 0
        ),
        @"firstReceiverClass":
            entry.firstReceiverClass ?: NSNull.null,
        @"failure": entry.failure ?: NSNull.null,
        @"identifierConflict": @(entry.identifierConflict),
        @"ready": @(ready),
    };
}

NSDictionary<NSString *, id> *
IOSUsePlayHookRegistryDiagnostics(void) {
    os_unfair_lock_lock(&IOSUsePlayHookRegistryLock);
    NSMutableDictionary *entries =
        IOSUsePlayHookRegistryEntriesLocked();
    NSMutableArray<NSDictionary<NSString *, id> *> *items =
        [NSMutableArray array];
    NSMutableSet<NSString *> *emitted = [NSMutableSet set];
    BOOL requiredReady = YES;
    for (NSString *identifier in
         IOSUsePlayHookRegistryExpectedRequiredIdentifiers()) {
        IOSUsePlayHookEntry *entry = entries[identifier];
        if (entry == nil) {
            requiredReady = NO;
            [items addObject:@{
                @"identifier": identifier,
                @"kind": @"missing-required",
                @"phase": @"undeclared",
                @"required": @YES,
                @"target": NSNull.null,
                @"selector": NSNull.null,
                @"abi": NSNull.null,
                @"owner": NSNull.null,
                @"installed": @NO,
                @"originalIMPRecorded": @NO,
                @"installedIMPRecorded": @NO,
                @"currentIMPMatchesInstalled": @NO,
                @"requiresFirstUseBeforeReady": @NO,
                @"invocationCount": @0,
                @"wrapperInvocationObserved": @NO,
                @"firstReceiverClass": NSNull.null,
                @"failure": @"expected required hook was not declared",
                @"identifierConflict": @NO,
                @"ready": @NO,
            }];
        } else {
            NSDictionary *diagnostics =
                IOSUsePlayHookEntryDiagnostics(entry);
            requiredReady =
                requiredReady && [diagnostics[@"ready"] boolValue];
            [items addObject:diagnostics];
        }
        [emitted addObject:identifier];
    }
    NSArray<NSString *> *optionalIdentifiers = [
        [entries.allKeys filteredArrayUsingPredicate:
            [NSPredicate predicateWithBlock:^BOOL(
                NSString *identifier,
                __unused NSDictionary *bindings
            ) {
                return ![emitted containsObject:identifier];
            }]]
        sortedArrayUsingSelector:@selector(compare:)
    ];
    for (NSString *identifier in optionalIdentifiers) {
        [items addObject:
            IOSUsePlayHookEntryDiagnostics(entries[identifier])];
    }
    os_unfair_lock_unlock(&IOSUsePlayHookRegistryLock);
    return @{
        @"schemaVersion": @1,
        @"requiredReady": @(requiredReady),
        @"entries": items,
    };
}

#if defined(IOS_USE_PLAY_HOOK_REGISTRY_TESTING)
void IOSUsePlayHookRegistryResetForTesting(void) {
    os_unfair_lock_lock(&IOSUsePlayHookRegistryLock);
    IOSUsePlayHookEntries = [NSMutableDictionary dictionary];
    IOSUsePlayHookExpectedRequiredIdentifiersForTesting = nil;
    size_t count =
        sizeof(IOSUsePlayPreMainInvocationCounters) /
        sizeof(IOSUsePlayPreMainInvocationCounters[0]);
    for (size_t index = 0; index < count; index += 1) {
        atomic_store_explicit(
            &IOSUsePlayPreMainInvocationCounters[index]
                .invocationCount,
            0,
            memory_order_relaxed
        );
    }
    os_unfair_lock_unlock(&IOSUsePlayHookRegistryLock);
}

void IOSUsePlayHookRegistrySetExpectedRequiredIdentifiersForTesting(
    NSArray<NSString *> *identifiers
) {
    os_unfair_lock_lock(&IOSUsePlayHookRegistryLock);
    IOSUsePlayHookExpectedRequiredIdentifiersForTesting =
        [identifiers copy];
    os_unfair_lock_unlock(&IOSUsePlayHookRegistryLock);
}
#endif
