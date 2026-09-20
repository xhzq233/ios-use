// Real UIKit editing semantics exercised by native AppKit keyboard events.
#import <UIKit/UIKit.h>

@interface KeyboardProbeDelegate : UIResponder <UIApplicationDelegate, UITextViewDelegate, UITextFieldDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) UITextView *textView;
@property(nonatomic, strong) UITextField *field;
@property(nonatomic) unsigned textChanges, fieldChanges, rejectedChanges;
@property(nonatomic) BOOL firstPhasePassed;
@end

@implementation KeyboardProbeDelegate
- (void)finishTextPhase {
    // Includes native character/backspace/return events, committed Unicode,
    // two trailing spaces, and deletion of one entire family emoji cluster.
    self.firstPhasePassed = self.textView.isFirstResponder && self.textChanges == 8
        && [self.textView.text isEqualToString:@"x\n中文 "]
        && NSEqualRanges(self.textView.selectedRange, NSMakeRange(5, 0));
    fprintf(stderr, "[keyboard-probe] text changes=%u selection=%lu,%lu passed=%d\n", self.textChanges,
        (unsigned long)self.textView.selectedRange.location, (unsigned long)self.textView.selectedRange.length,
        self.firstPhasePassed);
    if (!self.firstPhasePassed || ![self.field becomeFirstResponder]) exit(71);
}
- (void)textViewDidChange:(UITextView *)view {
    if (++self.textChanges == 8) {
        // Check after UIKit finishes the edit, then switch focus before the
        // host's second batch. App launch time is independent of the host clock.
        dispatch_async(dispatch_get_main_queue(), ^{ [self finishTextPhase]; });
    }
}
- (void)fieldChanged:(UITextField *)field { ++self.fieldChanges; }
- (BOOL)textField:(UITextField *)field shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)text {
    fprintf(stderr, "[keyboard-probe] delegate edit length=%lu first=%u\n", (unsigned long)text.length,
        text.length ? [text characterAtIndex:0] : 0);
    if ([text isEqualToString:@"!"]) { ++self.rejectedChanges; return NO; }
    return YES;
}
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = UIColor.systemBlueColor;
    self.window.rootViewController = controller;
    self.textView = [[UITextView alloc] initWithFrame:CGRectMake(20, 100, 360, 150)];
    self.textView.font = [UIFont systemFontOfSize:28];
    self.textView.delegate = self;
    [controller.view addSubview:self.textView];
    self.field = [[UITextField alloc] initWithFrame:CGRectMake(20, 300, 360, 50)];
    self.field.backgroundColor = UIColor.whiteColor;
    self.field.delegate = self;
    [self.field addTarget:self action:@selector(fieldChanged:) forControlEvents:UIControlEventEditingChanged];
    [controller.view addSubview:self.field];
    [self.window makeKeyAndVisible];
    if (![self.textView becomeFirstResponder]) exit(71);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        BOOL passed = self.firstPhasePassed && self.field.isFirstResponder
            && !self.textView.isFirstResponder && self.fieldChanges == 1 && self.rejectedChanges == 1
            && [self.field.text isEqualToString:@"q"] && [self.textView.text isEqualToString:@"x\n中文 "];
        fprintf(stderr, "[keyboard-probe] field focus=%d old focus=%d changes=%u rejected=%u length=%lu passed=%d\n",
            self.field.isFirstResponder, self.textView.isFirstResponder, self.fieldChanges, self.rejectedChanges,
            (unsigned long)self.field.text.length, passed);
        exit(passed ? 0 : 72);
    });
    return YES;
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(KeyboardProbeDelegate.class));
    }
}
