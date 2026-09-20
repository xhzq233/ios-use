// Linked only into the keyboard probe's native broker, never a supplied app run.
#import <AppKit/AppKit.h>

static NSWindow *probeWindow(void) {
    NSWindow *window = NSApp.mainWindow ?: NSApp.windows.firstObject;
    if (!window) { fprintf(stderr, "[keyboard-probe] native window not ready\n"); exit(70); }
    return window;
}

static void key(NSString *text, unsigned short code, NSEventModifierFlags modifiers) {
    NSWindow *window = probeWindow();
    NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:modifiers
        timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil
        characters:text charactersIgnoringModifiers:text isARepeat:NO keyCode:code];
    [window sendEvent:event];
}

__attribute__((constructor)) static void exerciseKeyboard(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        key(@"x", 7, 0);
        key(@"y", 16, 0);
        key(@"\x7f", 51, 0);
        key(@"\r", 36, 0);
        // A committed text callback, not a claim that IME composition is hosted.
        [probeWindow().firstResponder insertText:@"中文 👨‍👩‍👧‍👦  "];
        key(@"\x7f", 51, 0);
        key(@"\x7f", 51, 0);
        key(@"\x7f", 51, 0);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 16 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        key(@"q", 12, 0);
        key(@"!", 18, NSEventModifierFlagShift);
    });
}
