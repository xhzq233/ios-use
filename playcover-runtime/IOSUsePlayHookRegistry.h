#import <Foundation/Foundation.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

/// Required hook identifiers are fixed by the non-configurable Mac Runtime.
/// A missing declaration is itself a readiness failure.
FOUNDATION_EXPORT NSArray<NSString *> *
IOSUsePlayHookRegistryExpectedRequiredIdentifiers(void);

/// Installs an Objective-C replacement method while preserving the original
/// implementation under `replacementSelector` on the exact target class.
/// Inherited target methods are allowed unless `requiresDirectOwner` is true;
/// neither the observed superclass nor the replacement owner is mutated.
FOUNDATION_EXPORT BOOL IOSUsePlayHookRegistryInstallMethodAlias(
    NSString *identifier,
    BOOL required,
    NSString *phase,
    Class _Nullable targetClass,
    SEL targetSelector,
    Class _Nullable replacementOwner,
    SEL replacementSelector,
    BOOL requiresDirectOwner,
    BOOL requiresFirstUseBeforeReady,
    IMP _Nullable * _Nullable original,
    NSError * _Nullable * _Nullable error
);

/// Installs a C/Objective-C IMP after validating an explicit ABI. Argument
/// types include only arguments after `self` and `_cmd`.
FOUNDATION_EXPORT BOOL IOSUsePlayHookRegistryInstallFunction(
    NSString *identifier,
    BOOL required,
    NSString *phase,
    Class _Nullable targetClass,
    BOOL classMethod,
    SEL selector,
    const char *returnType,
    const char * _Nonnull const * _Nullable argumentTypes,
    unsigned int explicitArgumentCount,
    BOOL requiresDirectOwner,
    BOOL requiresFirstUseBeforeReady,
    IMP replacement,
    IMP _Nullable * _Nullable original,
    NSError * _Nullable * _Nullable error
);

/// Preflights a method which is consumed but not replaced. Readiness also
/// verifies that its receiving IMP has not changed since preflight.
FOUNDATION_EXPORT BOOL IOSUsePlayHookRegistryObserveMethod(
    NSString *identifier,
    BOOL required,
    NSString *phase,
    Class _Nullable targetClass,
    BOOL classMethod,
    SEL selector,
    const char *returnType,
    const char * _Nonnull const * _Nullable argumentTypes,
    unsigned int explicitArgumentCount,
    BOOL requiresDirectOwner,
    BOOL requiresFirstUseBeforeReady,
    NSError * _Nullable * _Nullable error
);

/// Records a required non-method state such as a CFRunLoop source or installed
/// event-monitor token.
FOUNDATION_EXPORT void IOSUsePlayHookRegistryRecordState(
    NSString *identifier,
    BOOL required,
    NSString *phase,
    NSString *target,
    NSString *selector,
    NSString *abi,
    BOOL requiresFirstUseBeforeReady,
    BOOL ready,
    NSString * _Nullable failure
);

/// Records the first real receiver invocation of an installed/observed method.
FOUNDATION_EXPORT void IOSUsePlayHookRegistryRecordFirstUse(
    NSString *identifier,
    Class _Nullable receiverClass
);

/// Records a real wrapper/state invocation. This does not claim that another
/// image was bound to the wrapper; it proves only that this function ran.
FOUNDATION_EXPORT void IOSUsePlayHookRegistryRecordInvocation(
    NSString *identifier
);

/// Records an invocation from a low-level interposed wrapper which may run
/// before Objective-C messaging is safe. The identifier must be one of the
/// fixed pre-main wrapper identifiers owned by the Runtime.
FOUNDATION_EXPORT void IOSUsePlayHookRegistryRecordPreMainInvocation(
    const char *identifier
);

/// Records an optional observed wrapper such as a DYLD interpose function.
FOUNDATION_EXPORT void IOSUsePlayHookRegistryDeclareObservedWrapper(
    NSString *identifier,
    NSString *phase,
    NSString *target,
    NSString *selector,
    NSString *abi
);

/// Returns false for a missing expected identifier, failed install/preflight,
/// receiving-IMP collision, or a missing pre-ready first use.
FOUNDATION_EXPORT BOOL IOSUsePlayHookRegistryRequiredReady(void);

/// Refreshes and returns one declared entry's correctness state.
FOUNDATION_EXPORT BOOL IOSUsePlayHookRegistryEntryReady(
    NSString *identifier
);

/// Returns correctness evidence only. No latency or performance fields are
/// exposed.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *
IOSUsePlayHookRegistryDiagnostics(void);

/// Distinguishes a permanent required-hook failure from the normal interval
/// before every required declaration and first eligible invocation exists.
/// A missing declaration becomes permanent only after configuration failed.
FOUNDATION_EXPORT BOOL IOSUsePlayHookRegistryHasRequiredFailure(
    NSDictionary<NSString *, id> *diagnostics,
    BOOL configurationFailed
);

#if defined(IOS_USE_PLAY_HOOK_REGISTRY_TESTING)
FOUNDATION_EXPORT void IOSUsePlayHookRegistryResetForTesting(void);
FOUNDATION_EXPORT void
IOSUsePlayHookRegistrySetExpectedRequiredIdentifiersForTesting(
    NSArray<NSString *> *identifiers
);
#endif

NS_ASSUME_NONNULL_END
