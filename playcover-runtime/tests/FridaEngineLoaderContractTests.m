#import <Foundation/Foundation.h>

#import <stdint.h>

typedef void *(*IOSUseFridaSymbolLookupFunction)(
    void *handle,
    const char *name
);

extern NSDictionary<NSString *, id> * _Nullable
IOSUsePlayRuntimeFridaTestResolveEngineABI(
    void *handle,
    IOSUseFridaSymbolLookupFunction lookup
);

static NSSet<NSString *> *IOSUseAvailableSymbols;

static void *IOSUseTestLookup(void *handle, const char *name) {
    (void)handle;
    NSString *symbol = [NSString stringWithUTF8String:name];
    return [IOSUseAvailableSymbols containsObject:symbol]
        ? (void *)(uintptr_t)1
        : NULL;
}

static void IOSUseRequire(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FridaEngineLoaderContractTests failed: %@", message);
        abort();
    }
}

int main(void) {
    @autoreleasepool {
        NSArray<NSString *> *requiredSymbols = @[
            @"IOSUseFridaEngineCreate",
            @"IOSUseFridaEngineReset",
            @"IOSUseFridaEngineSetEventCallback",
            @"IOSUseFridaEngineClearEventCallback",
            @"IOSUseFridaEngineEvaluate",
        ];

        IOSUseAvailableSymbols = [NSSet setWithArray:requiredSymbols];
        NSDictionary<NSString *, id> *error =
            IOSUsePlayRuntimeFridaTestResolveEngineABI(
                (void *)(uintptr_t)1,
                IOSUseTestLookup
            );
        IOSUseRequire(error == nil, @"the complete ABI must resolve");

        for (NSString *missingSymbol in requiredSymbols) {
            NSMutableSet<NSString *> *available =
                [NSMutableSet setWithArray:requiredSymbols];
            [available removeObject:missingSymbol];
            IOSUseAvailableSymbols = available;
            error = IOSUsePlayRuntimeFridaTestResolveEngineABI(
                (void *)(uintptr_t)1,
                IOSUseTestLookup
            );
            IOSUseRequire(
                [error[@"code"] isEqualToString:
                    @"frida_engine_abi_mismatch"],
                @"a missing symbol must be an ABI mismatch"
            );
            IOSUseRequire(
                [error[@"message"] containsString:missingSymbol],
                [NSString stringWithFormat:
                    @"the error must identify %@",
                    missingSymbol]
            );
        }

        NSLog(@"FridaEngineLoaderContractTests passed");
    }
    return 0;
}
