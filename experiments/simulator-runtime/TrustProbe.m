// Real runtime trust evaluation against a throwaway CA, with negative controls.
#import <Foundation/Foundation.h>
#import <Security/Security.h>

static BOOL evaluate(SecCertificateRef leaf, SecCertificateRef root, NSString *host,
                     NSDate *date, BOOL anchored, BOOL expected, OSStatus expectedError) {
    SecPolicyRef policy = SecPolicyCreateSSL(true, (__bridge CFStringRef)host);
    SecTrustRef trust = NULL;
    OSStatus status = SecTrustCreateWithCertificates((__bridge CFArrayRef)@[(__bridge id)leaf, (__bridge id)root], policy, &trust);
    CFRelease(policy);
    if (status) return NO;
    if (anchored) {
        status = SecTrustSetAnchorCertificates(trust, (__bridge CFArrayRef)@[(__bridge id)root]);
        if (!status) status = SecTrustSetAnchorCertificatesOnly(trust, true);
    }
    if (!status) status = SecTrustSetVerifyDate(trust, (__bridge CFDateRef)date);
    if (!status) status = SecTrustSetNetworkFetchAllowed(trust, false);
    CFErrorRef error = NULL;
    BOOL valid = !status && SecTrustEvaluateWithError(trust, &error);
    CFIndex code = error ? CFErrorGetCode(error) : status;
    printf("[trust] anchored=%d host=%s date=%s valid=%d error=%ld\n", anchored,
           host.UTF8String, date.description.UTF8String, valid, (long)code);
    BOOL passed = !status && valid == expected && (expected || (error && code == expectedError));
    if (error) CFRelease(error);
    CFRelease(trust);
    return passed;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3) return 2;
        NSData *rootData = [NSData dataWithContentsOfFile:@(argv[1])];
        NSData *leafData = [NSData dataWithContentsOfFile:@(argv[2])];
        if (!rootData || !leafData) return 50;
        SecCertificateRef root = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)rootData);
        SecCertificateRef leaf = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)leafData);
        if (!root || !leaf) return 50;
        NSDate *now = [NSDate date];
        BOOL passed = evaluate(leaf, root, @"runtime-probe.invalid", now, YES, YES, 0);
        passed &= evaluate(leaf, root, @"wrong-host.invalid", now, YES, NO, errSecHostNameMismatch);
        passed &= evaluate(leaf, root, @"runtime-probe.invalid", [now dateByAddingTimeInterval:7*86400],
                           YES, NO, errSecCertificateExpired);
        passed &= evaluate(leaf, root, @"runtime-probe.invalid", now, NO, NO, errSecNotTrusted);
        CFRelease(leaf);
        CFRelease(root);
        return passed ? 0 : 51;
    }
}
