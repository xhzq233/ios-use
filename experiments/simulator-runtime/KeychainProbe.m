// Synthetic items only, served by the runtime's isolated securityd.
#import <Foundation/Foundation.h>
#import <Security/Security.h>

static BOOL statusIs(const char *operation, OSStatus actual, OSStatus expected) {
    fprintf(stderr, "[keychain-probe] %s status=%d expected=%d\n", operation, (int)actual, (int)expected);
    return actual == expected;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 2) return 2;
        NSDictionary *query = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService: @"io.iosuse.synthetic-keychain-probe",
            (__bridge id)kSecAttrAccount: @"synthetic-account"};
        NSData *initial = [@"generated test value" dataUsingEncoding:NSUTF8StringEncoding];
        NSData *updated = [@"updated test value" dataUsingEncoding:NSUTF8StringEncoding];
        NSMutableDictionary *read = [query mutableCopy];
        read[(__bridge id)kSecReturnData] = @YES;
        CFTypeRef value = NULL;
        if (!strcmp(argv[1], "other")) {
            if (!statusIs("other identity lookup", SecItemCopyMatching((__bridge CFDictionaryRef)read, &value), errSecItemNotFound)) return 89;
            read[(__bridge id)kSecAttrAccessGroup] = @"IOSUSETEST.io.iosuse.runtime-keychain-probe";
            return statusIs("unauthorized access group", SecItemCopyMatching((__bridge CFDictionaryRef)read, &value), errSecMissingEntitlement) ? 0 : 90;
        }
        NSData *keyTag = [@"io.iosuse.synthetic-key" dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *keyQuery = @{(__bridge id)kSecClass: (__bridge id)kSecClassKey,
            (__bridge id)kSecAttrApplicationTag: keyTag,
            (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeECSECPrimeRandom};
        if (!strcmp(argv[1], "write")) {
            if (!statusIs("initial lookup", SecItemCopyMatching((__bridge CFDictionaryRef)read, &value), errSecItemNotFound)) return 81;
            NSMutableDictionary *add = [query mutableCopy];
            add[(__bridge id)kSecValueData] = initial;
            add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
            if (!statusIs("add", SecItemAdd((__bridge CFDictionaryRef)add, NULL), errSecSuccess)) return 82;
            if (!statusIs("duplicate", SecItemAdd((__bridge CFDictionaryRef)add, NULL), errSecDuplicateItem)) return 83;
            NSDictionary *attributes = @{(__bridge id)kSecValueData: updated};
            if (!statusIs("update", SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)attributes), errSecSuccess)) return 84;
            CFErrorRef error = NULL;
            NSDictionary *keyAttributes = @{(__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeECSECPrimeRandom,
                (__bridge id)kSecAttrKeySizeInBits: @256,
                (__bridge id)kSecPrivateKeyAttrs: @{(__bridge id)kSecAttrIsPermanent: @YES,
                    (__bridge id)kSecAttrApplicationTag: keyTag}};
            SecKeyRef key = SecKeyCreateRandomKey((__bridge CFDictionaryRef)keyAttributes, &error);
            fprintf(stderr, "[keychain-probe] persistent EC key=%d error=%ld\n", key != NULL, error ? (long)CFErrorGetCode(error) : 0);
            if (error) CFRelease(error);
            if (!key) return 91;
            CFRelease(key);
        } else if (strcmp(argv[1], "read-delete")) return 2;
        if (!statusIs("read", SecItemCopyMatching((__bridge CFDictionaryRef)read, &value), errSecSuccess)) return 85;
        BOOL equal = CFGetTypeID(value) == CFDataGetTypeID() && [(__bridge NSData *)value isEqualToData:updated];
        CFRelease(value); value = NULL;
        fprintf(stderr, "[keychain-probe] updated bytes equal=%d\n", equal);
        if (!equal) return 86;
        if (!strcmp(argv[1], "read-delete")) {
            NSMutableDictionary *keyRead = [keyQuery mutableCopy];
            keyRead[(__bridge id)kSecReturnRef] = @YES;
            CFTypeRef key = NULL;
            if (!statusIs("persisted EC key lookup", SecItemCopyMatching((__bridge CFDictionaryRef)keyRead, &key), errSecSuccess)) return 92;
            SecKeyRef publicKey = SecKeyCopyPublicKey((SecKeyRef)key);
            CFErrorRef error = NULL;
            CFDataRef signature = SecKeyCreateSignature((SecKeyRef)key, kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
                (__bridge CFDataRef)initial, &error);
            BOOL valid = signature && publicKey && SecKeyVerifySignature(publicKey, kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
                (__bridge CFDataRef)initial, signature, NULL);
            BOOL rejectsChangedMessage = signature && publicKey && !SecKeyVerifySignature(publicKey, kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
                (__bridge CFDataRef)updated, signature, NULL);
            fprintf(stderr, "[keychain-probe] persisted signature valid=%d rejectsChangedMessage=%d error=%ld\n",
                valid, rejectsChangedMessage, error ? (long)CFErrorGetCode(error) : 0);
            if (signature) CFRelease(signature);
            if (error) CFRelease(error);
            if (publicKey) CFRelease(publicKey);
            CFRelease(key);
            if (!valid || !rejectsChangedMessage) return 93;
            if (!statusIs("EC key delete", SecItemDelete((__bridge CFDictionaryRef)keyQuery), errSecSuccess)) return 94;
            if (!statusIs("delete", SecItemDelete((__bridge CFDictionaryRef)query), errSecSuccess)) return 87;
            if (!statusIs("deleted lookup", SecItemCopyMatching((__bridge CFDictionaryRef)read, &value), errSecItemNotFound)) return 88;
        }
        return 0;
    }
}
