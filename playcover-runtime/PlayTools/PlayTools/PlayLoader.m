//
//  PlayLoader.m
//  PlayTools
//

#include <Foundation/Foundation.h>
#include <errno.h>
#include <pthread.h>
#include <sys/stat.h>
#include <sys/sysctl.h>

#import "PlayLoader.h"
#import "IOSUsePlayHookRegistry.h"
#import "IOSUsePlaySwiftBridge.h"
#import "IOSUsePlayDevice.h"
#import <Security/Security.h>
#import <sys/utsname.h>
#import "NSObject+Swizzle.h"
#import <dlfcn.h>

@import MachO;

// Get device model from playcover .plist
// With a null terminator
#define DEVICE_MODEL IOS_USE_PLAY_DEVICE_PRODUCT_TYPE
#define OEM_ID IOS_USE_PLAY_DEVICE_HARDWARE_TARGET
#define PLATFORM_IOS 2

// Define dyld_get_active_platform function for interpose
int dyld_get_active_platform(void);
int pt_dyld_get_active_platform(void) {
    IOSUsePlayHookRegistryRecordPreMainInvocation(
        "dyld.active-platform"
    );
    return PLATFORM_IOS;
}

// Change the machine output by uname to match expected output on iOS
static int pt_uname(struct utsname *uts) {
    IOSUsePlayHookRegistryRecordPreMainInvocation("dyld.uname");
    uname(uts);
    strncpy(uts->machine, DEVICE_MODEL, sizeof(uts->machine) - 1);
    uts->machine[sizeof(uts->machine) - 1] = '\0';
    return 0;
}


// Update output of sysctl for key values hw.machine, hw.product and hw.target to match iOS output
// This spoofs the device type to apps allowing us to report as any iOS device
static int pt_sysctl(int *name, u_int types, void *buf, size_t *size, void *arg0, size_t arg1) {
    IOSUsePlayHookRegistryRecordPreMainInvocation("dyld.sysctl");
    if (name[0] == CTL_HW && (name[1] == HW_MACHINE || name[0] == HW_PRODUCT)) {
        if (NULL == buf) {
            *size = strlen(DEVICE_MODEL) + 1;
        } else {
            if (*size > strlen(DEVICE_MODEL) + 1) {
                strcpy(buf, DEVICE_MODEL);
            } else {
                return ENOMEM;
            }
        }
        return 0;
    } else if (name[0] == CTL_HW && (name[1] == HW_TARGET)) {
        if (NULL == buf) {
            *size = strlen(OEM_ID) + 1;
        } else {
            if (*size > strlen(OEM_ID) + 1) {
                strcpy(buf, OEM_ID);
            } else {
                return ENOMEM;
            }
        }
        return 0;
    }

    return sysctl(name, types, buf, size, arg0, arg1);
}

static int pt_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    IOSUsePlayHookRegistryRecordPreMainInvocation(
        "dyld.sysctlbyname"
    );
    if ((strcmp(name, "hw.machine") == 0) || (strcmp(name, "hw.product") == 0) || (strcmp(name, "hw.model") == 0)) {
        if (oldp == NULL) {
            *oldlenp = strlen(DEVICE_MODEL) + 1;
            return 0;
        }
        else if (oldp != NULL) {
            if (*oldlenp < strlen(DEVICE_MODEL) + 1) {
                return ENOMEM;
            }
            strcpy((char *)oldp, DEVICE_MODEL);
            *oldlenp = strlen(DEVICE_MODEL) + 1;
            return 0;
        } else {
            int ret = sysctlbyname(name, oldp, oldlenp, newp, newlen);
            return ret;
        }
    } else if ((strcmp(name, "hw.target") == 0)) {
        if (oldp == NULL) {
            *oldlenp = strlen(OEM_ID) + 1;
            return 0;
        } else if (oldp != NULL) {
            if (*oldlenp < strlen(OEM_ID) + 1) {
                return ENOMEM;
            }
            strcpy((char *)oldp, OEM_ID);
            *oldlenp = strlen(OEM_ID) + 1;
            return 0;
        } else {
            int ret = sysctlbyname(name, oldp, oldlenp, newp, newlen);
            return ret;
        }
    } else {
        return sysctlbyname(name, oldp, oldlenp, newp, newlen);
    }
}

// Interpose the functions create the wrapper
DYLD_INTERPOSE(pt_dyld_get_active_platform, dyld_get_active_platform)
DYLD_INTERPOSE(pt_uname, uname)
DYLD_INTERPOSE(pt_sysctlbyname, sysctlbyname)
DYLD_INTERPOSE(pt_sysctl, sysctl)

// Interpose Apple Keychain functions (SecItemCopyMatching, SecItemAdd, SecItemUpdate, SecItemDelete)
// This allows us to intercept keychain requests and return our own data

// Use the implementations from PlayKeychain
static OSStatus pt_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    IOSUsePlayHookRegistryRecordInvocation(
        @"security.item-copy-matching"
    );
    OSStatus retval;
    if ([[PlaySettings shared] playChain]) {
        retval = [PlayKeychain copyMatching:(__bridge NSDictionary * _Nonnull)(query) result:result];
    } else {
        retval = SecItemCopyMatching(query, result);
    }
    if (result != NULL) {
        if ([[PlaySettings shared] playChainDebugging]) {
            [PlayKeychain debugLogger:[NSString stringWithFormat:@"SecItemCopyMatching: %@", query]];
            [PlayKeychain debugLogger:[NSString stringWithFormat:@"SecItemCopyMatching result: %@", *result]];
        }
    }
    return retval;
}

static OSStatus pt_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    IOSUsePlayHookRegistryRecordInvocation(
        @"security.item-add"
    );
    OSStatus retval;
    if ([[PlaySettings shared] playChain]) {
        retval = [PlayKeychain add:(__bridge NSDictionary * _Nonnull)(attributes) result:result];
    } else {
        retval = SecItemAdd(attributes, result);
    }
    if (result != NULL) {
        if ([[PlaySettings shared] playChainDebugging]) {
            [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecItemAdd: %@", attributes]];
            [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecItemAdd result: %@", *result]];
        }
    }
    return retval;
}

static OSStatus pt_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    IOSUsePlayHookRegistryRecordInvocation(
        @"security.item-update"
    );
    OSStatus retval;
    if ([[PlaySettings shared] playChain]) {
        retval = [PlayKeychain update:(__bridge NSDictionary * _Nonnull)(query) attributesToUpdate:(__bridge NSDictionary * _Nonnull)(attributesToUpdate)];
    } else {
        retval = SecItemUpdate(query, attributesToUpdate);
    }
    if (attributesToUpdate != NULL) {
        if ([[PlaySettings shared] playChainDebugging]) {
            [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecItemUpdate: %@", query]];
            [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecItemUpdate attributesToUpdate: %@", attributesToUpdate]];
        }
    }
    return retval;

}

static OSStatus pt_SecItemDelete(CFDictionaryRef query) {
    IOSUsePlayHookRegistryRecordInvocation(
        @"security.item-delete"
    );
    OSStatus retval;
    if ([[PlaySettings shared] playChain]) {
        retval = [PlayKeychain delete:(__bridge NSDictionary * _Nonnull)(query)];
    } else {
        retval = SecItemDelete(query);
    }
    if ([[PlaySettings shared] playChainDebugging]) {
        [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecItemDelete: %@", query]];
    }
    return retval;
}

static SecKeyRef pt_SecKeyCreateRandomKey(CFDictionaryRef parameters, CFErrorRef *error) {
    IOSUsePlayHookRegistryRecordInvocation(
        @"security.key-create-random"
    );
    SecKeyRef result;
    if ([[PlaySettings shared] playChain]) {
        result = [PlayKeychain keyCreateRandomKey:(__bridge NSDictionary * _Nonnull)(parameters) error:error];
    } else {
        result = SecKeyCreateRandomKey(parameters, (void *)error);
    }
    
        if ([[PlaySettings shared] playChainDebugging]) {
            [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecKeyCreateRandomKey: %@", parameters]];
            [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecKeyCreateRandomKey result: %@", result]];
        }
    
    return result;
}

// Deprecated, but some apps might still use it.
static OSStatus pt_SecKeyGeneratePair(CFDictionaryRef parameters, SecKeyRef *publicKey, SecKeyRef *privateKey) {
    IOSUsePlayHookRegistryRecordInvocation(
        @"security.key-generate-pair"
    );
    OSStatus retval;
    if ([[PlaySettings shared] playChain]) {
        retval = [PlayKeychain keyGeneratePair:(__bridge NSDictionary * _Nonnull)(parameters) publicKey:(void *)publicKey privateKey:(void *)privateKey];
    } else {
        retval = SecKeyGeneratePair(parameters, (void *)publicKey, (void *)privateKey);
    }
    
    if ([[PlaySettings shared] playChainDebugging]) {
        [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecKeyGeneratePair: %@", parameters]];
        [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecKeyGeneratePair public key result: %@", publicKey != NULL ? *publicKey : nil]];
        [PlayKeychain debugLogger: [NSString stringWithFormat:@"SecKeyGeneratePair private key result: %@", privateKey != NULL ? *privateKey : nil]];
    }
    
    return retval;
}

DYLD_INTERPOSE(pt_SecItemCopyMatching, SecItemCopyMatching)
DYLD_INTERPOSE(pt_SecItemAdd, SecItemAdd)
DYLD_INTERPOSE(pt_SecItemUpdate, SecItemUpdate)
DYLD_INTERPOSE(pt_SecItemDelete, SecItemDelete)
DYLD_INTERPOSE(pt_SecKeyCreateRandomKey, SecKeyCreateRandomKey)
DYLD_INTERPOSE(pt_SecKeyGeneratePair, SecKeyGeneratePair)

static uint8_t ue_status = 0;

static const char *const IOSUseCleanIOSDeniedLiteralPaths[] = {
    "/bin/bash",
    "/bin/sh",
    "/usr/bin/ssh",
    "/usr/sbin/sshd",
    "/usr/libexec/ssh-keysign",
    "/usr/libexec/sftp-server",
    "/etc/ssh/sshd_config",
    "/usr/sbin/frida-server",
    "/usr/bin/cycript",
    "/usr/local/bin/cycript",
    "/usr/lib/libcycript.dylib",
};

static const char *const IOSUseCleanIOSDeniedSubpaths[] = {
    "/Applications/Cydia.app",
    "/Library/MobileSubstrate",
    "/etc/apt",
    "/private/etc/apt",
    "/private/var/binpack",
    "/private/var/cache/apt",
    "/private/var/jb",
    "/private/var/lib/apt",
    "/private/var/lib/cydia",
    "/private/var/stash",
    "/var/binpack",
    "/var/cache/apt",
    "/var/jb",
    "/var/lib/apt",
    "/var/lib/cydia",
    "/var/stash",
};

static BOOL IOSUseCleanIOSPathHasPrefix(
    const char *path,
    const char *prefix
) {
    size_t length = strlen(prefix);
    return strncmp(path, prefix, length) == 0 &&
        (path[length] == '\0' || path[length] == '/');
}

static BOOL IOSUseCleanIOSPathIsDenied(const char *path) {
    if (path == NULL || path[0] != '/') {
        return NO;
    }
    size_t literalCount = sizeof(IOSUseCleanIOSDeniedLiteralPaths) /
        sizeof(IOSUseCleanIOSDeniedLiteralPaths[0]);
    for (size_t index = 0; index < literalCount; index += 1) {
        if (strcmp(path, IOSUseCleanIOSDeniedLiteralPaths[index]) == 0) {
            return YES;
        }
    }
    size_t subpathCount = sizeof(IOSUseCleanIOSDeniedSubpaths) /
        sizeof(IOSUseCleanIOSDeniedSubpaths[0]);
    for (size_t index = 0; index < subpathCount; index += 1) {
        if (IOSUseCleanIOSPathHasPrefix(
                path,
                IOSUseCleanIOSDeniedSubpaths[index]
            )) {
            return YES;
        }
    }
    return NO;
}

static int IOSUseCleanIOSRejectPath(const char *path) {
    if (!IOSUseCleanIOSPathIsDenied(path)) {
        return 0;
    }
    errno = ENOENT;
    return -1;
}

static char const* ue_fix_filename(char const* filename) {
    static char UE_PATTERN[1024] = "//Users/";
    getlogin_r(UE_PATTERN + 8, sizeof(UE_PATTERN) - 8);
    
    char const* p = filename;
    if (ue_status == 2) {
        char const* last_p = p;
        while ((p = strstr(p, UE_PATTERN))) {
            last_p = ++p;
        }
        
        return last_p;
    }

    return p;
}

static int pt_open(char const* restrict filename, int oflag, ... ) {
    filename = ue_fix_filename(filename);
    if (IOSUseCleanIOSRejectPath(filename) != 0) {
        return -1;
    }

    if (oflag == O_CREAT) {
        int mod;
        va_list ap;
        va_start(ap, oflag);
        mod = va_arg(ap, int);
        va_end(ap);

        return open(filename, O_CREAT, mod);
    }

    return open(filename, oflag);
}

static int pt_stat(char const* restrict path, struct stat* restrict buf) {
    path = ue_fix_filename(path);
    if (IOSUseCleanIOSRejectPath(path) != 0) {
        return -1;
    }
    return stat(path, buf);
}

static int pt_access(char const* path, int mode) {
    path = ue_fix_filename(path);
    if (IOSUseCleanIOSRejectPath(path) != 0) {
        return -1;
    }
    return access(path, mode);
}

static int pt_rename(char const* restrict old_name, char const* restrict new_name) {
    old_name = ue_fix_filename(old_name);
    new_name = ue_fix_filename(new_name);
    if (IOSUseCleanIOSRejectPath(old_name) != 0 ||
        IOSUseCleanIOSRejectPath(new_name) != 0) {
        return -1;
    }
    return rename(old_name, new_name);
}

static int pt_unlink(char const* path) {
    path = ue_fix_filename(path);
    if (IOSUseCleanIOSRejectPath(path) != 0) {
        return -1;
    }
    return unlink(path);
}

static NSMutableDictionary *thread_sleep_counters = nil;
static NSMutableDictionary *last_sleep_attempts = nil;
static dispatch_once_t thread_sleep_once;
static NSLock *thread_sleep_lock = nil;

static int pt_usleep(useconds_t time) {
    dispatch_once(&thread_sleep_once, ^{
        thread_sleep_counters = [NSMutableDictionary dictionary];
        last_sleep_attempts = [NSMutableDictionary dictionary];
        thread_sleep_lock = [[NSLock alloc] init];
        [thread_sleep_lock lock];
    });
    
    if ([[PlaySettings shared] blockSleepSpamming]) {
        int thread_id = pthread_mach_thread_np(pthread_self());
        NSNumber *threadKey = @(thread_id);
        
        int thread_sleep_counter = [thread_sleep_counters[threadKey] intValue];
        int last_sleep_attempt = [last_sleep_attempts[threadKey] intValue];
        
        if (time == 100000) {
            int timestamp = (int)[[NSDate date] timeIntervalSince1970];
            // If it sleeps too fast, increase counter
            if (timestamp - last_sleep_attempt < 2) {
                thread_sleep_counter++;
            } else {
                thread_sleep_counter = 1;
            }
            last_sleep_attempt = timestamp;
            thread_sleep_counters[threadKey] = @(thread_sleep_counter);
            last_sleep_attempts[threadKey] = @(last_sleep_attempt);
            
        }
        
        if (thread_sleep_counter > 100) {
            // Stop this thread from spamming usleep calls
            NSLog(@"[PC] Thread %i exceeded usleep limit. Seem sus, stopping this "
                  @"thread FOREVER",
                  thread_id);
            
            [thread_sleep_lock lock];
            [thread_sleep_lock unlock];
            
            return 0;
        }
    }
    
    return usleep(time);
}


DYLD_INTERPOSE(pt_open, open)
DYLD_INTERPOSE(pt_stat, stat)
DYLD_INTERPOSE(pt_access, access)
DYLD_INTERPOSE(pt_rename, rename)
DYLD_INTERPOSE(pt_unlink, unlink)
DYLD_INTERPOSE(pt_usleep, usleep)

@implementation PlayLoader

+ (void)load {
    IOSUsePlayHookRegistryDeclareObservedWrapper(
        @"dyld.active-platform",
        @"dyld-interpose",
        @"libSystem",
        @"dyld_get_active_platform",
        @"int(void)"
    );
    IOSUsePlayHookRegistryDeclareObservedWrapper(
        @"dyld.uname",
        @"dyld-interpose",
        @"libSystem",
        @"uname",
        @"int(struct utsname *)"
    );
    IOSUsePlayHookRegistryDeclareObservedWrapper(
        @"dyld.sysctl",
        @"dyld-interpose",
        @"libSystem",
        @"sysctl",
        @"int(int *, u_int, void *, size_t *, void *, size_t)"
    );
    IOSUsePlayHookRegistryDeclareObservedWrapper(
        @"dyld.sysctlbyname",
        @"dyld-interpose",
        @"libSystem",
        @"sysctlbyname",
        @"int(const char *, void *, size_t *, void *, size_t)"
    );
    IOSUsePlayHookRegistryDeclareObservedWrapper(
        @"security.item-copy-matching",
        @"dyld-interpose",
        @"Security.framework",
        @"SecItemCopyMatching",
        @"OSStatus(CFDictionaryRef, CFTypeRef *)"
    );
    IOSUsePlayHookRegistryDeclareObservedWrapper(
        @"security.item-add",
        @"dyld-interpose",
        @"Security.framework",
        @"SecItemAdd",
        @"OSStatus(CFDictionaryRef, CFTypeRef *)"
    );
    IOSUsePlayHookRegistryDeclareObservedWrapper(
        @"security.item-update",
        @"dyld-interpose",
        @"Security.framework",
        @"SecItemUpdate",
        @"OSStatus(CFDictionaryRef, CFDictionaryRef)"
    );
    IOSUsePlayHookRegistryDeclareObservedWrapper(
        @"security.item-delete",
        @"dyld-interpose",
        @"Security.framework",
        @"SecItemDelete",
        @"OSStatus(CFDictionaryRef)"
    );
    IOSUsePlayHookRegistryDeclareObservedWrapper(
        @"security.key-create-random",
        @"dyld-interpose",
        @"Security.framework",
        @"SecKeyCreateRandomKey",
        @"SecKeyRef(CFDictionaryRef, CFErrorRef *)"
    );
    IOSUsePlayHookRegistryDeclareObservedWrapper(
        @"security.key-generate-pair",
        @"dyld-interpose",
        @"Security.framework",
        @"SecKeyGeneratePair",
        @"OSStatus(CFDictionaryRef, SecKeyRef *, SecKeyRef *)"
    );
}

static void __attribute__((constructor)) initialize(void) {
    [PlayCover launch];
    
    if (ue_status == 0) {
        if (PlayInfo.isUnrealEngine) {
            ue_status = 2;
        }
    }
    
    if (ue_status == 2) {
        [PlayKeychain debugLogger: [NSString stringWithFormat:@"UnrealEngine Hooked"]];
    }

    if ([[PlaySettings shared] blockSleepSpamming]) {
        // Add an observer so we can unlock threads on app termination
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillTerminateNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            [thread_sleep_lock unlock];
        }];
    }
}

@end
