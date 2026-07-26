#import <Foundation/Foundation.h>

static void IOSUseInputTestFail(NSString *message) {
    fprintf(
        stderr,
        "InputContractTests: %s\n",
        message.UTF8String
    );
    exit(1);
}

static void IOSUseInputTestRequire(
    BOOL condition,
    NSString *message
) {
    if (!condition) {
        IOSUseInputTestFail(message);
    }
}

static NSString *IOSUseInputTestFunctionBody(
    NSString *source,
    NSString *functionName
) {
    NSRange nameRange = [source rangeOfString:functionName];
    IOSUseInputTestRequire(
        nameRange.location != NSNotFound,
        [NSString stringWithFormat:
            @"missing function %@", functionName]
    );
    NSRange opening = [source
        rangeOfString:@"{"
              options:0
                range:NSMakeRange(
                    NSMaxRange(nameRange),
                    source.length - NSMaxRange(nameRange)
                )];
    IOSUseInputTestRequire(
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
            IOSUseInputTestRequire(
                depth > 0,
                [NSString stringWithFormat:
                    @"unbalanced body for %@", functionName]
            );
            depth -= 1;
            if (depth == 0) {
                return [source substringWithRange:NSMakeRange(
                    opening.location,
                    index - opening.location + 1
                )];
            }
        }
    }
    IOSUseInputTestFail(
        [NSString stringWithFormat:
            @"unterminated body for %@", functionName]
    );
    return @"";
}

static NSUInteger IOSUseInputTestPosition(
    NSString *source,
    NSString *needle
) {
    return [source rangeOfString:needle].location;
}

static void IOSUseInputTestRequireContains(
    NSString *source,
    NSString *needle,
    NSString *message
) {
    IOSUseInputTestRequire(
        IOSUseInputTestPosition(source, needle) != NSNotFound,
        message
    );
}

static NSRange IOSUseInputTestSuffixRange(
    NSString *value,
    NSInteger requestedDeleteCount,
    NSInteger *appliedDeleteCount
) {
    NSUInteger start = value.length;
    NSInteger applied = 0;
    while (applied < requestedDeleteCount && start > 0) {
        NSRange composedRange =
            [value rangeOfComposedCharacterSequenceAtIndex:start - 1];
        start = composedRange.location;
        applied += 1;
    }
    if (appliedDeleteCount != NULL) {
        *appliedDeleteCount = applied;
    }
    return NSMakeRange(start, value.length - start);
}

static NSString *IOSUseInputTestReplaceSuffix(
    NSString *value,
    NSInteger requestedDeleteCount,
    NSString *content,
    NSInteger *appliedDeleteCount
) {
    NSRange replacement = IOSUseInputTestSuffixRange(
        value,
        requestedDeleteCount,
        appliedDeleteCount
    );
    return [[value substringToIndex:replacement.location]
        stringByAppendingString:content];
}

static void IOSUseInputTestGraphemeReplacement(void) {
    NSInteger applied = -1;
    NSString *family = @"prefix👨‍👩‍👧‍👦";
    IOSUseInputTestRequire(
        [[IOSUseInputTestReplaceSuffix(
            family,
            1,
            @"U",
            &applied
        ) copy] isEqualToString:@"prefixU"],
        @"one delete must replace one extended family grapheme"
    );
    IOSUseInputTestRequire(
        applied == 1,
        @"family grapheme delete count must be one"
    );

    NSString *combining = @"Ame\u0301";
    IOSUseInputTestRequire(
        [[IOSUseInputTestReplaceSuffix(
            combining,
            1,
            @"!",
            &applied
        ) copy] isEqualToString:@"Am!"],
        @"one delete must replace a base-plus-combining-mark grapheme"
    );
    IOSUseInputTestRequire(
        [[IOSUseInputTestReplaceSuffix(
            @"ab",
            99,
            @"Z",
            &applied
        ) copy] isEqualToString:@"Z"],
        @"oversized delete must replace the complete value"
    );
    IOSUseInputTestRequire(
        applied == 2,
        @"applied delete count must report available graphemes"
    );
    IOSUseInputTestRequire(
        [[IOSUseInputTestReplaceSuffix(
            @"  keep  ",
            0,
            @" tail ",
            &applied
        ) copy] isEqualToString:@"  keep   tail "],
        @"append must preserve leading and trailing whitespace exactly"
    );
}

static void IOSUseInputTestSourceContract(NSString *source) {
    NSString *input = IOSUseInputTestFunctionBody(
        source,
        @"IOSUseAutomationInput("
    );
    NSString *unsupported = IOSUseInputTestFunctionBody(
        source,
        @"IOSUseAutomationUnsupportedInputError("
    );
    NSString *exactValue = IOSUseInputTestFunctionBody(
        source,
        @"IOSUseAutomationExactTextValue("
    );
    NSString *suffixRange = IOSUseInputTestFunctionBody(
        source,
        @"IOSUseAutomationSuffixRange("
    );
    NSString *selection = IOSUseInputTestFunctionBody(
        source,
        @"IOSUseAutomationSelectTextRange("
    );
    NSString *documentMatch = IOSUseInputTestFunctionBody(
        source,
        @"IOSUseAutomationTextDocumentMatchesValue("
    );

    IOSUseInputTestRequireContains(
        unsupported,
        @"@\"input_unsupported\"",
        @"unsupported input must have a stable error code"
    );
    IOSUseInputTestRequireContains(
        unsupported,
        @"details[@\"unsupportedReason\"]",
        @"unsupported input must expose a stable reason field"
    );
    IOSUseInputTestRequireContains(
        unsupported,
        @"details[@\"responderClass\"]",
        @"unsupported input must identify the responder class"
    );
    for (NSString *reason in @[
        @"@\"secure_text\"",
        @"@\"marked_text\"",
        @"@\"custom_text_input\"",
        @"@\"custom_key_input\"",
        @"@\"disabled_text_input\"",
        @"@\"inconsistent_text_document\"",
        @"@\"unverifiable_selection\"",
    ]) {
        IOSUseInputTestRequireContains(
            input,
            reason,
            [NSString stringWithFormat:
                @"missing unsupported reason %@", reason]
        );
    }

    NSUInteger firstMutation = IOSUseInputTestPosition(
        input,
        @"insertText:content"
    );
    IOSUseInputTestRequire(
        firstMutation != NSNotFound,
        @"input must have a text mutation"
    );
    for (NSString *preflight in @[
        @"target != nil && expectedResponder == nil",
        @"the input target did not become the live UIKeyInput first responder",
        @"![firstResponder isKindOfClass:UITextField.class]",
        @"((UITextField *)firstResponder).secureTextEntry",
        @"textInput.markedTextRange != nil",
        @"IOSUseAutomationTextDocumentMatchesValue(",
        @"IOSUseAutomationSelectTextRange(",
        @"IOSUseAutomationCurrentFirstResponder() != firstResponder",
    ]) {
        NSUInteger position = IOSUseInputTestPosition(
            input,
            preflight
        );
        IOSUseInputTestRequire(
            position != NSNotFound && position < firstMutation,
            [NSString stringWithFormat:
                @"preflight must precede mutation: %@", preflight]
        );
    }

    IOSUseInputTestRequire(
        IOSUseInputTestPosition(
            input,
            @"IOSUseAutomationString("
        ) == NSNotFound,
        @"input must not use the DOM string helper that trims values"
    );
    IOSUseInputTestRequire(
        IOSUseInputTestPosition(
            exactValue,
            @"stringByTrimmingCharactersInSet"
        ) == NSNotFound,
        @"exact input values must never be trimmed"
    );
    IOSUseInputTestRequireContains(
        exactValue,
        @"((UITextField *)responder).text ?: @\"\"",
        @"UITextField must use its exact text property"
    );
    IOSUseInputTestRequireContains(
        exactValue,
        @"((UITextView *)responder).text ?: @\"\"",
        @"UITextView must use its exact text property"
    );
    IOSUseInputTestRequireContains(
        documentMatch,
        @"[documentValue isEqualToString:value]",
        @"UITextInput document and control value must match exactly"
    );
    IOSUseInputTestRequireContains(
        suffixRange,
        @"rangeOfComposedCharacterSequenceAtIndex",
        @"delete count must operate on composed character sequences"
    );
    IOSUseInputTestRequireContains(
        selection,
        @"actualLocation ==",
        @"replacement selection location must be verified"
    );
    IOSUseInputTestRequireContains(
        selection,
        @"actualLength ==",
        @"replacement selection length must be verified"
    );
    IOSUseInputTestRequireContains(
        input,
        @"[afterValue isEqualToString:expectedValue]",
        @"actual text must be compared with the exact expected value"
    );
    IOSUseInputTestRequireContains(
        input,
        @"@\"exactValueVerified\": @YES",
        @"success must explicitly report exact value verification"
    );
    IOSUseInputTestRequireContains(
        input,
        @"@\"beforeValue\": beforeValue",
        @"success must report the untrimmed value before input"
    );
    IOSUseInputTestRequireContains(
        input,
        @"@\"value\": afterValue",
        @"success must report the untrimmed verified value"
    );
    IOSUseInputTestRequireContains(
        input,
        @"IOSUsePlayRuntimeWebAccessibilityActionFocusInput",
        @"Web target input must use the fixed accessibility focus bridge"
    );
    IOSUseInputTestRequireContains(
        input,
        @"IOSUseAutomationIsSupportedWebInputResponder(\n"
         "                    expectedResponder",
        @"Web native focus must require the exact WKContentView responder"
    );
    IOSUseInputTestRequireContains(
        input,
        @"WKContentView.becomeFirstResponder-after-validated-web-focus",
        @"Web focus evidence must distinguish validated HTML focus from "
         "native WKContentView responder activation"
    );
    IOSUseInputTestRequireContains(
        input,
        @"webTarget ? candidate.serialized : nil",
        @"Web input state must stay bound to the freshly selected proxy"
    );
    IOSUseInputTestRequireContains(
        input,
        @"@\"backend\": supportedWebInput",
        @"input evidence must identify its concrete mutation backend"
    );
    IOSUseInputTestRequireContains(
        input,
        @"@\"WKContentView.deleteBackward\"",
        @"Web deletion evidence must identify exact WKContentView delivery"
    );
    IOSUseInputTestRequireContains(
        input,
        @"@\"WKContentView.insertText\"",
        @"Web insertion evidence must identify exact WKContentView delivery"
    );
    IOSUseInputTestRequireContains(
        input,
        @"[webState[@\"tag\"] isEqualToString:@\"textarea\"]",
        @"Web textarea Return must verify its exact newline value"
    );
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        IOSUseInputTestRequire(
            argc == 2,
            @"usage: InputContractTests <RuntimeAutomation.m>"
        );
        NSError *error = nil;
        NSString *sourcePath = [NSString
            stringWithUTF8String:argv[1]];
        NSString *source = [NSString
            stringWithContentsOfFile:sourcePath
                            encoding:NSUTF8StringEncoding
                               error:&error];
        IOSUseInputTestRequire(
            source != nil,
            [NSString stringWithFormat:
                @"could not read source: %@",
                error.localizedDescription ?: @"unknown error"]
        );
        IOSUseInputTestSourceContract(source);
        IOSUseInputTestGraphemeReplacement();
        printf("InputContractTests: passed\n");
    }
    return 0;
}
