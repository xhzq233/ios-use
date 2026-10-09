// Keyboard UI stays in the runtime app; native text uses the existing input port.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static BOOL usesRemoteKeyboard(id self, SEL selector) { return NO; }

__attribute__((constructor)) static void useLocalKeyboard(void) {
    // A failed remote KeyboardManagement connection makes UIKit resign the real
    // text responder. Select UIKit's own in-process keyboard implementation.
    Method enabled = class_getClassMethod(NSClassFromString(@"_UIRemoteKeyboards"), @selector(enabled));
    method_setImplementation(enabled, (IMP)usesRemoteKeyboard);
}

extern bool originalCapability(CFStringRef) __asm__("_MGGetBoolAnswer");
static bool capability(CFStringRef key) {
    // No speech/Assistant service is hosted. Advertising dictation here causes
    // repeated availability callbacks to consume the app's main queue.
    if (CFEqual(key, CFSTR("dictation"))) return false;
    return originalCapability(key);
}

__attribute__((used, section("__DATA,__interpose"))) static const struct {
    const void *replacement, *original;
} replacements[] = {{(void *)capability, (void *)originalCapability}};
