#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "IOSUsePlayRuntimeDOM.h"
#import "IOSUsePlayInteractionView.h"
#import "IOSUsePlayRuntimeViewTree.h"

UIView * _Nullable IOSUsePlayRuntimeDOMResolveTargetView(
    NSString *target,
    NSDictionary<NSString *, id> **commandError
) {
    (void)target;
    (void)commandError;
    return nil;
}

static BOOL IOSUseViewTreeRequire(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "[view-tree-contract] %s\n", message.UTF8String);
    }
    return condition;
}

static NSDictionary<NSString *, id> *IOSUseViewTreeFirstSubview(
    NSDictionary<NSString *, id> *node
) {
    NSArray<NSDictionary<NSString *, id> *> *subviews = node[@"subviews"];
    return subviews.firstObject;
}

int main(void) {
    @autoreleasepool {
        BOOL passed = YES;

        // Model Catalyst's tab label beneath a disabled visual-effect wrapper.
        UIView *container = [UIView new];
        UIButton *control = [UIButton buttonWithType:UIButtonTypeSystem];
        UIView *decoration = [UIView new];
        UIView *content = [UIView new];
        UILabel *controlLabel = [UILabel new];
        decoration.userInteractionEnabled = NO;
        [container addSubview:control];
        [control addSubview:decoration];
        [decoration addSubview:content];
        [content addSubview:controlLabel];
        passed &= IOSUseViewTreeRequire(
            IOSUsePlayNormalizedInteractionView(controlLabel) == control,
            @"decorated label did not resolve to its owning control"
        );
        control.enabled = NO;
        passed &= IOSUseViewTreeRequire(
            IOSUsePlayNormalizedInteractionView(controlLabel) == nil,
            @"disabled control became actionable through its label"
        );
        control.enabled = YES;
        container.userInteractionEnabled = NO;
        passed &= IOSUseViewTreeRequire(
            IOSUsePlayNormalizedInteractionView(controlLabel) == nil,
            @"disabled ancestor above the control was ignored"
        );
        container.userInteractionEnabled = YES;
        decoration.hidden = YES;
        passed &= IOSUseViewTreeRequire(
            IOSUsePlayNormalizedInteractionView(controlLabel) == nil,
            @"hidden decoration exposed its label"
        );
        decoration.hidden = NO;
        [container addSubview:decoration];
        passed &= IOSUseViewTreeRequire(
            IOSUsePlayNormalizedInteractionView(controlLabel) == nil,
            @"disabled generic container acquired an interaction owner"
        );
        decoration.userInteractionEnabled = YES;
        passed &= IOSUseViewTreeRequire(
            IOSUsePlayNormalizedInteractionView(controlLabel) == content,
            @"ordinary label interaction owner changed"
        );

        UIView *root = [[UIView alloc] initWithFrame:
            CGRectMake(0, 0, 430, 932)];
        root.accessibilityIdentifier = @"fixture-root";

        UIStackView *stack = [[UIStackView alloc] initWithFrame:
            CGRectMake(20, 40, 300, 100)];
        stack.axis = UILayoutConstraintAxisHorizontal;
        stack.spacing = 12;
        [root addSubview:stack];

        UILabel *label = [[UILabel alloc] initWithFrame:
            CGRectMake(0, 0, 120, 40)];
        label.text = @"Fixture title";
        label.font = [UIFont systemFontOfSize:19];
        label.numberOfLines = 2;
        [stack addArrangedSubview:label];

        NSDictionary<NSString *, id> *snapshot =
            IOSUsePlayRuntimeViewTreeSnapshotForTesting(@[root], 3);
        NSArray<NSDictionary<NSString *, id> *> *roots = snapshot[@"roots"];
        NSDictionary<NSString *, id> *rootNode = roots.firstObject;
        NSDictionary<NSString *, id> *stackNode =
            IOSUseViewTreeFirstSubview(rootNode);
        NSDictionary<NSString *, id> *labelNode =
            IOSUseViewTreeFirstSubview(stackNode);

        passed &= IOSUseViewTreeRequire(
            [snapshot[@"nodeCount"] integerValue] == 3 &&
                ![snapshot[@"truncated"] boolValue] &&
                roots.count == 1,
            @"snapshot summary changed"
        );
        passed &= IOSUseViewTreeRequire(
            [rootNode[@"class"] isEqual:@"UIView"] &&
                [rootNode[@"accessibilityIdentifier"]
                    isEqual:@"fixture-root"] &&
                [rootNode[@"frame"][@"width"] doubleValue] == 430,
            @"root identity or geometry changed"
        );
        passed &= IOSUseViewTreeRequire(
            [stackNode[@"class"] isEqual:@"UIStackView"] &&
                [stackNode[@"properties"][@"axis"]
                    isEqual:@"horizontal"] &&
                [stackNode[@"properties"][@"alignment"]
                    isEqual:@"fill"] &&
                [stackNode[@"properties"][@"distribution"]
                    isEqual:@"fill"] &&
                [stackNode[@"properties"][@"spacing"] doubleValue] == 12 &&
                [stackNode[@"properties"][@"arrangedSubviewCount"]
                    integerValue] == 1,
            @"stack-view properties changed"
        );
        passed &= IOSUseViewTreeRequire(
            [labelNode[@"class"] isEqual:@"UILabel"] &&
                [labelNode[@"properties"][@"text"]
                    isEqual:@"Fixture title"] &&
                [labelNode[@"properties"][@"fontSize"] doubleValue] == 19,
            @"label properties changed"
        );

        NSError *jsonError = nil;
        NSData *json = [NSJSONSerialization dataWithJSONObject:snapshot
                                                       options:0
                                                         error:&jsonError];
        NSString *jsonText = json == nil
            ? nil
            : [[NSString alloc] initWithData:json
                                    encoding:NSUTF8StringEncoding];
        passed &= IOSUseViewTreeRequire(
            jsonError == nil &&
                [jsonText rangeOfString:@"address"].location == NSNotFound,
            @"snapshot serialized a process address"
        );

        NSDictionary<NSString *, id> *shallow =
            IOSUsePlayRuntimeViewTreeSnapshotForTesting(@[root], 1);
        NSDictionary<NSString *, id> *shallowStack =
            IOSUseViewTreeFirstSubview([shallow[@"roots"] firstObject]);
        passed &= IOSUseViewTreeRequire(
            [shallow[@"truncated"] boolValue] &&
                [shallow[@"nodeCount"] integerValue] == 2 &&
                [shallowStack[@"subviews"] count] == 0,
            @"depth bound did not truncate descendants"
        );

        NSDictionary<NSString *, id> *commandError = nil;
        NSDictionary<NSString *, id> *invalid =
            IOSUsePlayRuntimeViewTreeCommand(
                @{@"target": NSNull.null, @"depth": @21},
                &commandError
            );
        passed &= IOSUseViewTreeRequire(
            invalid == nil &&
                [commandError[@"code"] isEqual:@"invalid_arguments"],
            @"invalid depth did not fail closed"
        );

        if (!passed) {
            return 1;
        }
        fprintf(stderr, "[view-tree-contract] PASS\n");
        return 0;
    }
}
