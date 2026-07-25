#import "IOSUsePlayRuntimeSocket.h"

#import <UIKit/UIKit.h>
#import <arpa/inet.h>
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <objc/message.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <sys/un.h>
#import <unistd.h>

static const NSUInteger IOSUseMaximumFrameSize = 64 * 1024;
static const NSTimeInterval IOSUseSocketTimeoutSeconds = 5.0;
static const NSTimeInterval IOSUseMainThreadSnapshotTimeoutSeconds = 0.2;

static NSDictionary<NSString *, id> *IOSUseRuntimeProfile;
static NSDictionary<NSString *, id> *IOSUseRuntimeBootstrap;
static NSString *IOSUseRuntimeInstanceID;
static NSString *IOSUseRuntimeSocketStatus = @"not-started";
static NSString *IOSUseRuntimeSocketFailureStage;
static NSNumber *IOSUseRuntimeSocketFailureErrno;
static os_unfair_lock IOSUseRuntimeStateLock = OS_UNFAIR_LOCK_INIT;
static atomic_bool IOSUseMainSnapshotInFlight = false;

typedef id (*IOSUseSocketSendID)(id, SEL);
typedef BOOL (*IOSUseSocketSendBool)(id, SEL);
typedef NSInteger (*IOSUseSocketSendInteger)(id, SEL);
typedef CGFloat (*IOSUseSocketSendFloat)(id, SEL);
typedef CGSize (*IOSUseSocketSendSize)(id, SEL);
typedef CGRect (*IOSUseSocketSendRect)(id, SEL);
typedef CGRect (*IOSUseSocketSendRectArgument)(id, SEL, CGRect);

static BOOL IOSUseIsNonemptyString(id value) {
    return [value isKindOfClass:NSString.class] &&
        ((NSString *)value).length > 0;
}

static BOOL IOSUseIsSchemaVersionOne(id value) {
    if (![value isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
        return NO;
    }
    NSNumber *number = value;
    return number.longLongValue == 1 && number.doubleValue == 1.0;
}

static BOOL IOSUseIsSchemaVersionTwo(id value) {
    if (![value isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
        return NO;
    }
    NSNumber *number = value;
    return number.longLongValue == 2 && number.doubleValue == 2.0;
}

static void IOSUseRecordSocketStartupFailure(
    NSString *stage,
    NSInteger errorCode
) {
    os_unfair_lock_lock(&IOSUseRuntimeStateLock);
    IOSUseRuntimeSocketStatus = @"failed";
    IOSUseRuntimeSocketFailureStage = [stage copy];
    IOSUseRuntimeSocketFailureErrno = @(errorCode);
    os_unfair_lock_unlock(&IOSUseRuntimeStateLock);
    NSLog(
        @"[ios-use-play] runtime socket startup failed stage=%@ errno=%ld (%s)",
        stage,
        (long)errorCode,
        strerror((int)errorCode)
    );
}

static void IOSUseLogPOSIXError(NSString *operation, NSString *path) {
    int savedErrno = errno;
    IOSUseRecordSocketStartupFailure(operation, savedErrno);
    NSLog(
        @"[ios-use-play] runtime socket failure path=%@",
        path
    );
}

static void IOSUseRecordSocketValidationFailure(NSString *stage) {
    IOSUseRecordSocketStartupFailure(stage, EINVAL);
}

static void IOSUseRecordSocketPermissionFailure(NSString *stage) {
    IOSUseRecordSocketStartupFailure(stage, EPERM);
}

static void IOSUseLogBootstrapReadFailure(NSError *error) {
    NSInteger errorCode = error == nil ? EIO : error.code;
    IOSUseRecordSocketStartupFailure(@"bootstrap-read", errorCode);
    NSLog(
        @"[ios-use-play] runtime bootstrap read failed: %@",
        error.localizedDescription ?: @"empty file"
    );
}

static void IOSUseLogBootstrapValidationFailure(NSString *stage) {
    IOSUseRecordSocketValidationFailure(stage);
    NSLog(
        @"[ios-use-play] runtime bootstrap validation failed stage=%@",
        stage
    );
}

static NSData *IOSUseReadPrivateRegularFile(NSString *path, NSError **error) {
    const char *filePath = path.fileSystemRepresentation;
    struct stat pathStatus;
    if (lstat(filePath, &pathStatus) != 0) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        }
        return nil;
    }
    if (S_ISLNK(pathStatus.st_mode) ||
        !S_ISREG(pathStatus.st_mode) ||
        pathStatus.st_uid != geteuid() ||
        (pathStatus.st_mode & 0777) != 0600) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:EPERM
                                     userInfo:nil];
        }
        return nil;
    }
    int fileDescriptor = open(filePath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fileDescriptor < 0) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        }
        return nil;
    }
    struct stat openedStatus;
    if (fstat(fileDescriptor, &openedStatus) != 0 ||
        !S_ISREG(openedStatus.st_mode) ||
        openedStatus.st_uid != geteuid() ||
        (openedStatus.st_mode & 0777) != 0600 ||
        openedStatus.st_dev != pathStatus.st_dev ||
        openedStatus.st_ino != pathStatus.st_ino) {
        close(fileDescriptor);
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:EPERM
                                     userInfo:nil];
        }
        return nil;
    }

    NSMutableData *data = [NSMutableData data];
    uint8_t buffer[4096];
    for (;;) {
        ssize_t count = read(fileDescriptor, buffer, sizeof(buffer));
        if (count == 0) {
            break;
        }
        if (count < 0) {
            int savedErrno = errno;
            close(fileDescriptor);
            if (error != NULL) {
                *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                             code:savedErrno
                                         userInfo:nil];
            }
            return nil;
        }
        if (data.length + (NSUInteger)count > IOSUseMaximumFrameSize) {
            close(fileDescriptor);
            if (error != NULL) {
                *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                             code:NSFileReadTooLargeError
                                         userInfo:nil];
            }
            return nil;
        }
        [data appendBytes:buffer length:(NSUInteger)count];
    }
    close(fileDescriptor);
    return data;
}

static NSDictionary<NSString *, id> *IOSUseLoadBootstrap(
    NSDictionary<NSString *, id> *profile
) {
    NSString *bootstrapPath = profile[@"runtimeBootstrapPath"];
    NSString *profileSocketPath = profile[@"runtimeSocketPath"];
    NSString *profileHash = profile[@"profileHash"];
    NSString *preparedGenerationID = profile[@"preparedGenerationID"];
    if (!IOSUseIsSchemaVersionTwo(profile[@"schemaVersion"]) ||
        !IOSUseIsSchemaVersionOne(profile[@"deviceProfileSchemaVersion"]) ||
        ![profile[@"backend"] isEqualToString:@"playcover-headless"] ||
        !IOSUseIsNonemptyString(bootstrapPath) ||
        !IOSUseIsNonemptyString(profileSocketPath) ||
        !IOSUseIsNonemptyString(profileHash) ||
        !IOSUseIsNonemptyString(preparedGenerationID)) {
        IOSUseRecordSocketValidationFailure(@"profile");
        NSLog(@"[ios-use-play] signed runtime profile is missing socket identity");
        return nil;
    }

    NSError *error = nil;
    NSData *data = IOSUseReadPrivateRegularFile(bootstrapPath, &error);
    if (data.length == 0) {
        IOSUseLogBootstrapReadFailure(error);
        return nil;
    }
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![object isKindOfClass:NSDictionary.class]) {
        IOSUseLogBootstrapValidationFailure(@"bootstrap-json");
        NSLog(
            @"[ios-use-play] runtime bootstrap JSON is invalid: %@",
            error.localizedDescription ?: @"top-level value is not an object"
        );
        return nil;
    }
    NSDictionary<NSString *, id> *bootstrap = object;
    NSSet<NSString *> *expectedKeys = [NSSet setWithArray:@[
        @"schemaVersion",
        @"launchNonce",
        @"runtimeSocketPath",
        @"profileHash",
        @"bundleIdentifier",
        @"preparedGenerationID",
    ]];
    if (bootstrap.count != expectedKeys.count ||
        ![[NSSet setWithArray:bootstrap.allKeys] isEqualToSet:expectedKeys] ||
        !IOSUseIsSchemaVersionOne(bootstrap[@"schemaVersion"])) {
        IOSUseLogBootstrapValidationFailure(@"bootstrap-schema");
        NSLog(@"[ios-use-play] runtime bootstrap does not match schema version 1");
        return nil;
    }
    for (NSString *key in @[
        @"launchNonce",
        @"runtimeSocketPath",
        @"profileHash",
        @"bundleIdentifier",
        @"preparedGenerationID",
    ]) {
        if (!IOSUseIsNonemptyString(bootstrap[key])) {
            IOSUseLogBootstrapValidationFailure(@"bootstrap-field");
            NSLog(@"[ios-use-play] runtime bootstrap field %@ is invalid", key);
            return nil;
        }
    }

    NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier ?: @"";
    if (![bootstrap[@"runtimeSocketPath"] isEqualToString:profileSocketPath] ||
        ![bootstrap[@"profileHash"] isEqualToString:profileHash] ||
        ![bootstrap[@"preparedGenerationID"] isEqualToString:preparedGenerationID] ||
        ![bootstrap[@"bundleIdentifier"] isEqualToString:bundleIdentifier]) {
        IOSUseLogBootstrapValidationFailure(@"bootstrap-identity");
        NSLog(@"[ios-use-play] runtime bootstrap identity does not match signed app");
        return nil;
    }
    return bootstrap;
}

static BOOL IOSUsePrepareSocketDirectory(
    NSString *socketPath,
    struct stat *verifiedStatus
) {
    if (![socketPath isAbsolutePath] ||
        [socketPath rangeOfString:@"\0"].location != NSNotFound) {
        IOSUseRecordSocketValidationFailure(@"socket-path");
        NSLog(@"[ios-use-play] runtime socket path must be absolute");
        return NO;
    }
    NSString *directory = socketPath.stringByDeletingLastPathComponent;
    if (directory.length == 0 || [directory isEqualToString:socketPath]) {
        IOSUseRecordSocketValidationFailure(@"socket-directory");
        NSLog(@"[ios-use-play] runtime socket directory is invalid");
        return NO;
    }

    const char *directoryPath = directory.fileSystemRepresentation;
    struct stat status;
    if (lstat(directoryPath, &status) != 0) {
        if (errno != ENOENT) {
            IOSUseLogPOSIXError(@"lstat directory", directory);
            return NO;
        }
        if (mkdir(directoryPath, 0700) != 0) {
            IOSUseLogPOSIXError(@"create directory", directory);
            return NO;
        }
        if (lstat(directoryPath, &status) != 0) {
            IOSUseLogPOSIXError(@"verify directory", directory);
            return NO;
        }
    }
    if (S_ISLNK(status.st_mode) ||
        !S_ISDIR(status.st_mode) ||
        status.st_uid != geteuid()) {
        IOSUseRecordSocketPermissionFailure(@"directory-ownership");
        NSLog(@"[ios-use-play] runtime socket directory is not private and owned");
        return NO;
    }
    struct stat originalStatus = status;
    if ((status.st_mode & 0777) != 0700 &&
        chmod(directoryPath, 0700) != 0) {
        IOSUseLogPOSIXError(@"secure directory", directory);
        return NO;
    }
    if (lstat(directoryPath, &status) != 0) {
        IOSUseLogPOSIXError(@"secure directory", directory);
        return NO;
    }
    if (S_ISLNK(status.st_mode) ||
        !S_ISDIR(status.st_mode) ||
        status.st_uid != geteuid() ||
        (status.st_mode & 0777) != 0700 ||
        status.st_dev != originalStatus.st_dev ||
        status.st_ino != originalStatus.st_ino) {
        IOSUseRecordSocketPermissionFailure(@"directory-changed");
        return NO;
    }
    if (verifiedStatus != NULL) {
        *verifiedStatus = status;
    }
    return YES;
}

static BOOL IOSUseSocketDirectoryMatches(
    NSString *socketPath,
    const struct stat *expected
) {
    NSString *directory = socketPath.stringByDeletingLastPathComponent;
    struct stat current;
    if (expected == NULL ||
        lstat(directory.fileSystemRepresentation, &current) != 0) {
        return NO;
    }
    return !S_ISLNK(current.st_mode) &&
        S_ISDIR(current.st_mode) &&
        current.st_uid == geteuid() &&
        (current.st_mode & 0777) == 0700 &&
        current.st_dev == expected->st_dev &&
        current.st_ino == expected->st_ino;
}

static BOOL IOSUseRequireAbsentSocketPath(NSString *socketPath) {
    const char *filePath = socketPath.fileSystemRepresentation;
    struct stat status;
    if (lstat(filePath, &status) != 0) {
        if (errno == ENOENT) {
            return YES;
        }
        IOSUseLogPOSIXError(@"lstat path", socketPath);
        return NO;
    }
    NSLog(
        @"[ios-use-play] refusing existing %@ runtime socket path",
        S_ISLNK(status.st_mode)
            ? @"symlink"
            : (S_ISSOCK(status.st_mode) ? @"socket" : @"non-socket")
    );
    IOSUseRecordSocketStartupFailure(@"socket-path-present", EEXIST);
    return NO;
}

static BOOL IOSUseConfigureSocket(
    int fileDescriptor,
    BOOL includeReadWriteTimeouts
) {
    int enabled = 1;
    if (setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            (socklen_t)sizeof(enabled)
        ) != 0) {
        return NO;
    }
    if (includeReadWriteTimeouts) {
        struct timeval timeout = {
            .tv_sec = (time_t)IOSUseSocketTimeoutSeconds,
            .tv_usec = 0,
        };
        if (setsockopt(
                fileDescriptor,
                SOL_SOCKET,
                SO_RCVTIMEO,
                &timeout,
                (socklen_t)sizeof(timeout)
            ) != 0 ||
            setsockopt(
                fileDescriptor,
                SOL_SOCKET,
                SO_SNDTIMEO,
                &timeout,
                (socklen_t)sizeof(timeout)
            ) != 0) {
            return NO;
        }
    }
    (void)fcntl(fileDescriptor, F_SETFD, FD_CLOEXEC);
    return YES;
}

static BOOL IOSUseReadExactly(int fileDescriptor, void *buffer, size_t length) {
    uint8_t *cursor = buffer;
    size_t remaining = length;
    while (remaining > 0) {
        ssize_t count = recv(fileDescriptor, cursor, remaining, 0);
        if (count == 0) {
            return NO;
        }
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            return NO;
        }
        cursor += (size_t)count;
        remaining -= (size_t)count;
    }
    return YES;
}

static BOOL IOSUseWriteExactly(
    int fileDescriptor,
    const void *buffer,
    size_t length
) {
    const uint8_t *cursor = buffer;
    size_t remaining = length;
    while (remaining > 0) {
        ssize_t count = send(fileDescriptor, cursor, remaining, 0);
        if (count <= 0) {
            if (count < 0 && errno == EINTR) {
                continue;
            }
            return NO;
        }
        cursor += (size_t)count;
        remaining -= (size_t)count;
    }
    return YES;
}

static NSDictionary<NSString *, NSNumber *> *IOSUseRectJSON(CGRect rect) {
    return @{
        @"x": @(rect.origin.x),
        @"y": @(rect.origin.y),
        @"width": @(rect.size.width),
        @"height": @(rect.size.height),
    };
}

static NSDictionary<NSString *, NSNumber *> *IOSUseSizeJSON(CGSize size) {
    return @{
        @"width": @(size.width),
        @"height": @(size.height),
    };
}

static NSDictionary<NSString *, NSNumber *> *IOSUseInsetsJSON(
    UIEdgeInsets insets
) {
    return @{
        @"top": @(insets.top),
        @"left": @(insets.left),
        @"bottom": @(insets.bottom),
        @"right": @(insets.right),
    };
}

static UIWindow *IOSUseKeyUIKitWindow(void) {
    UIApplication *application = UIApplication.sharedApplication;
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) {
                return window;
            }
        }
    }
    return nil;
}

static id IOSUseSelectedAppKitWindow(NSString **selection) {
    static void *appKitHandle;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        appKitHandle = dlopen(
            "/System/Library/Frameworks/AppKit.framework/AppKit",
            RTLD_NOW | RTLD_LOCAL
        );
        if (appKitHandle == NULL) {
            NSLog(@"[ios-use-play] AppKit observation unavailable: %s", dlerror());
        }
    });
    Class applicationClass = NSClassFromString(@"NSApplication");
    if (applicationClass == Nil) {
        return nil;
    }
    UIWindow *keyUIKitWindow = IOSUseKeyUIKitWindow();
    SEL nsWindowSelector = NSSelectorFromString(@"nsWindow");
    if ([keyUIKitWindow respondsToSelector:nsWindowSelector]) {
        id bridgedWindow = ((IOSUseSocketSendID)objc_msgSend)(
            keyUIKitWindow,
            nsWindowSelector
        );
        if (bridgedWindow != nil) {
            if (selection != NULL) {
                *selection = @"key-uiwindow-bridge";
            }
            return bridgedWindow;
        }
    }

    id application = ((IOSUseSocketSendID)objc_msgSend)(
        (id)applicationClass,
        NSSelectorFromString(@"sharedApplication")
    );
    SEL windowsSelector = NSSelectorFromString(@"windows");
    SEL uiWindowsSelector = NSSelectorFromString(@"uiWindows");
    if (keyUIKitWindow != nil &&
        application != nil &&
        [application respondsToSelector:windowsSelector]) {
        id candidateWindows = ((IOSUseSocketSendID)objc_msgSend)(
            application,
            windowsSelector
        );
        if ([candidateWindows isKindOfClass:NSArray.class]) {
            for (id candidateWindow in (NSArray *)candidateWindows) {
                if (![candidateWindow respondsToSelector:uiWindowsSelector]) {
                    continue;
                }
                id uiWindows = ((IOSUseSocketSendID)objc_msgSend)(
                    candidateWindow,
                    uiWindowsSelector
                );
                if ([uiWindows isKindOfClass:NSArray.class] &&
                    [(NSArray *)uiWindows containsObject:keyUIKitWindow]) {
                    if (selection != NULL) {
                        *selection = @"appkit-uiwindows-owner";
                    }
                    return candidateWindow;
                }
            }
        }
    }
    SEL keyWindowSelector = NSSelectorFromString(@"keyWindow");
    if (application != nil &&
        [application respondsToSelector:keyWindowSelector]) {
        id keyWindow = ((IOSUseSocketSendID)objc_msgSend)(
            application,
            keyWindowSelector
        );
        if (keyWindow != nil && selection != NULL) {
            *selection = @"appkit-key-window";
        }
        return keyWindow;
    }
    return nil;
}

static NSDictionary<NSString *, id> *IOSUseAppKitObservation(void) {
    NSString *selection = @"none";
    id selectedWindow = IOSUseSelectedAppKitWindow(&selection);
    if (selectedWindow == nil) {
        return @{
            @"available": @NO,
            @"selectedBy": selection,
        };
    }

    SEL keySelector = NSSelectorFromString(@"isKeyWindow");
    SEL windowNumberSelector = NSSelectorFromString(@"windowNumber");
    SEL frameSelector = NSSelectorFromString(@"frame");
    SEL contentLayoutRectSelector = NSSelectorFromString(@"contentLayoutRect");
    SEL backingScaleFactorSelector = NSSelectorFromString(@"backingScaleFactor");
    SEL contentViewSelector = NSSelectorFromString(@"contentView");
    SEL sharingTypeSelector = NSSelectorFromString(@"sharingType");
    SEL contentMinSizeSelector = NSSelectorFromString(@"contentMinSize");
    SEL contentMaxSizeSelector = NSSelectorFromString(@"contentMaxSize");
    SEL contentAspectRatioSelector =
        NSSelectorFromString(@"contentAspectRatio");
    BOOL keyWindow = [selectedWindow respondsToSelector:keySelector] &&
        ((IOSUseSocketSendBool)objc_msgSend)(selectedWindow, keySelector);
    NSInteger windowNumber = [selectedWindow respondsToSelector:windowNumberSelector]
        ? ((IOSUseSocketSendInteger)objc_msgSend)(
            selectedWindow,
            windowNumberSelector
        )
        : -1;
    CGRect frame = [selectedWindow respondsToSelector:frameSelector]
        ? ((IOSUseSocketSendRect)objc_msgSend)(selectedWindow, frameSelector)
        : CGRectZero;
    CGRect contentLayoutRect =
        [selectedWindow respondsToSelector:contentLayoutRectSelector]
            ? ((IOSUseSocketSendRect)objc_msgSend)(
                selectedWindow,
                contentLayoutRectSelector
            )
            : CGRectZero;
    CGFloat backingScaleFactor =
        [selectedWindow respondsToSelector:backingScaleFactorSelector]
            ? ((IOSUseSocketSendFloat)objc_msgSend)(
                selectedWindow,
                backingScaleFactorSelector
            )
            : 0;
    NSInteger sharingType =
        [selectedWindow respondsToSelector:sharingTypeSelector]
            ? ((IOSUseSocketSendInteger)objc_msgSend)(
                selectedWindow,
                sharingTypeSelector
            )
            : -1;
    CGSize contentMinSize =
        [selectedWindow respondsToSelector:contentMinSizeSelector]
            ? ((IOSUseSocketSendSize)objc_msgSend)(
                selectedWindow,
                contentMinSizeSelector
            )
            : CGSizeZero;
    CGSize contentMaxSize =
        [selectedWindow respondsToSelector:contentMaxSizeSelector]
            ? ((IOSUseSocketSendSize)objc_msgSend)(
                selectedWindow,
                contentMaxSizeSelector
            )
            : CGSizeZero;
    CGSize contentAspectRatio =
        [selectedWindow respondsToSelector:contentAspectRatioSelector]
            ? ((IOSUseSocketSendSize)objc_msgSend)(
                selectedWindow,
                contentAspectRatioSelector
            )
            : CGSizeZero;
    id contentView = [selectedWindow respondsToSelector:contentViewSelector]
        ? ((IOSUseSocketSendID)objc_msgSend)(
            selectedWindow,
            contentViewSelector
        )
        : nil;
    CGRect contentViewBounds = CGRectZero;
    CGRect backingContentRect = CGRectZero;
    SEL boundsSelector = NSSelectorFromString(@"bounds");
    if (contentView != nil &&
        [contentView respondsToSelector:boundsSelector]) {
        contentViewBounds = ((IOSUseSocketSendRect)objc_msgSend)(
            contentView,
            boundsSelector
        );
        SEL backingSelector = NSSelectorFromString(@"convertRectToBacking:");
        if ([contentView respondsToSelector:backingSelector]) {
            backingContentRect = ((IOSUseSocketSendRectArgument)objc_msgSend)(
                contentView,
                backingSelector,
                contentViewBounds
            );
        }
    }
    CGFloat requestedWidth =
        [IOSUseRuntimeProfile[@"logicalWidth"] doubleValue];
    CGFloat requestedHeight =
        [IOSUseRuntimeProfile[@"logicalHeight"] doubleValue];
    BOOL positive =
        contentViewBounds.size.width > 0 &&
        contentViewBounds.size.height > 0 &&
        contentLayoutRect.size.width > 0 &&
        contentLayoutRect.size.height > 0;
    CGFloat widthTolerance = fmax(
        1.0,
        fmax(
            contentViewBounds.size.width,
            contentLayoutRect.size.width
        ) * 0.01
    );
    CGFloat heightTolerance = fmax(
        1.0,
        fmax(
            contentViewBounds.size.height,
            contentLayoutRect.size.height
        ) * 0.01
    );
    BOOL contentMatchesLayout =
        fabs(
            contentViewBounds.size.width -
            contentLayoutRect.size.width
        ) <= widthTolerance &&
        fabs(
            contentViewBounds.size.height -
            contentLayoutRect.size.height
        ) <= heightTolerance;
    CGFloat presentationScaleX =
        requestedWidth > 0
            ? contentViewBounds.size.width / requestedWidth
            : 0;
    CGFloat presentationScaleY =
        requestedHeight > 0
            ? contentViewBounds.size.height / requestedHeight
            : 0;
    CGFloat scaleTolerance =
        fmax(presentationScaleX, presentationScaleY) * 0.01;
    BOOL uniform =
        positive &&
        contentMatchesLayout &&
        presentationScaleX > 0 &&
        presentationScaleY > 0 &&
        presentationScaleX <= 1.0 &&
        presentationScaleY <= 1.0 &&
        fabs(presentationScaleX - presentationScaleY) <= scaleTolerance;
    BOOL appKitExactProfile =
        fabs(contentViewBounds.size.width - requestedWidth) < 0.01 &&
        fabs(contentViewBounds.size.height - requestedHeight) < 0.01 &&
        fabs(contentLayoutRect.size.width - requestedWidth) < 0.01 &&
        fabs(contentLayoutRect.size.height - requestedHeight) < 0.01;
    return @{
        @"available": @YES,
        @"selectedBy": selection,
        @"keyWindow": @(keyWindow),
        @"windowNumber": @(windowNumber),
        @"frame": IOSUseRectJSON(frame),
        @"contentLayoutRect": IOSUseRectJSON(contentLayoutRect),
        @"contentView": @{
            @"available": @(contentView != nil),
            @"bounds": IOSUseRectJSON(contentViewBounds),
        },
        @"contentViewBounds": IOSUseRectJSON(contentViewBounds),
        @"backingContentRect": IOSUseRectJSON(backingContentRect),
        @"backingScaleFactor": @(backingScaleFactor),
        @"sharingType": @(sharingType),
        @"contentMinSize": IOSUseSizeJSON(contentMinSize),
        @"contentMaxSize": IOSUseSizeJSON(contentMaxSize),
        @"contentAspectRatio": IOSUseSizeJSON(contentAspectRatio),
        @"presentationScaleX": @(presentationScaleX),
        @"presentationScaleY": @(presentationScaleY),
        @"presentationContentLayoutMatch": @(contentMatchesLayout),
        @"uniform": @(uniform),
        @"appKitExactProfile": @(appKitExactProfile),
    };
}

static BOOL IOSUseSizeMatches(
    CGSize size,
    CGFloat expectedWidth,
    CGFloat expectedHeight
) {
    return fabs(size.width - expectedWidth) < 0.01 &&
        fabs(size.height - expectedHeight) < 0.01;
}

static CGSize IOSUseSizeFromJSON(id object) {
    if (![object isKindOfClass:NSDictionary.class]) {
        return CGSizeZero;
    }
    NSDictionary *dictionary = object;
    return CGSizeMake(
        [dictionary[@"width"] doubleValue],
        [dictionary[@"height"] doubleValue]
    );
}

static CALayer *IOSUseFirstMetalLayer(CALayer *rootLayer) {
    Class metalLayerClass = NSClassFromString(@"CAMetalLayer");
    if (rootLayer == nil || metalLayerClass == Nil) {
        return nil;
    }
    NSMutableArray<CALayer *> *pending = [NSMutableArray arrayWithObject:rootLayer];
    NSUInteger inspected = 0;
    while (pending.count > 0 && inspected < 512) {
        CALayer *layer = pending.firstObject;
        [pending removeObjectAtIndex:0];
        inspected += 1;
        if ([layer isKindOfClass:metalLayerClass]) {
            return layer;
        }
        NSArray<CALayer *> *sublayers = layer.sublayers;
        if (sublayers.count > 0) {
            [pending addObjectsFromArray:sublayers];
        }
    }
    return nil;
}

static NSDictionary<NSString *, id> *IOSUseMetalLayerObservation(
    CALayer *rootLayer,
    CGSize *drawableSize
) {
    CALayer *metalLayer = IOSUseFirstMetalLayer(rootLayer);
    if (metalLayer == nil) {
        if (drawableSize != NULL) {
            *drawableSize = CGSizeZero;
        }
        return @{@"available": @NO};
    }
    SEL drawableSizeSelector = NSSelectorFromString(@"drawableSize");
    CGSize observedDrawableSize =
        [metalLayer respondsToSelector:drawableSizeSelector]
            ? ((IOSUseSocketSendSize)objc_msgSend)(
                metalLayer,
                drawableSizeSelector
            )
            : CGSizeZero;
    if (drawableSize != NULL) {
        *drawableSize = observedDrawableSize;
    }
    return @{
        @"available": @YES,
        @"class": NSStringFromClass(metalLayer.class),
        @"bounds": IOSUseRectJSON(metalLayer.bounds),
        @"frame": IOSUseRectJSON(metalLayer.frame),
        @"contentsScale": @(metalLayer.contentsScale),
        @"drawableSize": IOSUseSizeJSON(observedDrawableSize),
    };
}

static NSDictionary<NSString *, id> *IOSUseSceneSizeRestrictionsObservation(
    UIWindowScene *scene,
    CGSize requested,
    BOOL *ready
) {
    if (ready != NULL) {
        *ready = NO;
    }
    SEL restrictionsSelector = NSSelectorFromString(@"sizeRestrictions");
    if (scene == nil || ![scene respondsToSelector:restrictionsSelector]) {
        return @{@"available": @NO};
    }
    id restrictions = ((IOSUseSocketSendID)objc_msgSend)(
        scene,
        restrictionsSelector
    );
    SEL minimumSelector = NSSelectorFromString(@"minimumSize");
    SEL maximumSelector = NSSelectorFromString(@"maximumSize");
    if (restrictions == nil ||
        ![restrictions respondsToSelector:minimumSelector] ||
        ![restrictions respondsToSelector:maximumSelector]) {
        return @{@"available": @NO};
    }
    CGSize minimumSize = ((IOSUseSocketSendSize)objc_msgSend)(
        restrictions,
        minimumSelector
    );
    CGSize maximumSize = ((IOSUseSocketSendSize)objc_msgSend)(
        restrictions,
        maximumSelector
    );
    BOOL restrictionsReady =
        IOSUseSizeMatches(minimumSize, requested.width, requested.height) &&
        IOSUseSizeMatches(maximumSize, requested.width, requested.height);
    if (ready != NULL) {
        *ready = restrictionsReady;
    }
    return @{
        @"available": @YES,
        @"minimumSize": IOSUseSizeJSON(minimumSize),
        @"maximumSize": IOSUseSizeJSON(maximumSize),
        @"fixed": @(restrictionsReady),
    };
}

static NSDictionary<NSString *, id> *IOSUseObservedUIKit(
    NSDictionary<NSString *, id> *appKit,
    NSString **stage,
    CGSize *windowSize
) {
    UIScreen *screen = UIScreen.mainScreen;
    UIWindow *window = IOSUseKeyUIKitWindow();
    UIWindowScene *windowScene = window.windowScene;
    UIViewController *rootController = window.rootViewController;
    UIView *rootView = rootController.isViewLoaded ? rootController.view : nil;
    CALayer *layer = rootView.layer;

    CGFloat requestedWidth = [IOSUseRuntimeProfile[@"logicalWidth"] doubleValue];
    CGFloat requestedHeight = [IOSUseRuntimeProfile[@"logicalHeight"] doubleValue];
    CGFloat nativeWidth = [IOSUseRuntimeProfile[@"nativeWidth"] doubleValue];
    CGFloat nativeHeight = [IOSUseRuntimeProfile[@"nativeHeight"] doubleValue];
    CGSize requested = CGSizeMake(requestedWidth, requestedHeight);

    CGSize appKitContentSize = IOSUseSizeFromJSON(appKit[@"contentViewBounds"]);
    CGSize effectiveWindowSize = appKitContentSize;
    if (effectiveWindowSize.width <= 0 || effectiveWindowSize.height <= 0) {
        effectiveWindowSize = window.bounds.size;
    }

    BOOL screenReady =
        IOSUseSizeMatches(screen.bounds.size, requestedWidth, requestedHeight) &&
        IOSUseSizeMatches(
            screen.nativeBounds.size,
            nativeWidth,
            nativeHeight
        );
    BOOL windowReady = window != nil &&
        IOSUseSizeMatches(window.bounds.size, requestedWidth, requestedHeight);
    BOOL rootReady = rootView != nil &&
        IOSUseSizeMatches(rootView.bounds.size, requestedWidth, requestedHeight);
    BOOL restrictionsReady = NO;
    NSDictionary *restrictionsObservation =
        IOSUseSceneSizeRestrictionsObservation(
            windowScene,
            requested,
            &restrictionsReady
        );
    CGRect fixedCoordinateBounds =
        windowScene.screen.fixedCoordinateSpace.bounds;
    BOOL sceneReady = windowScene != nil &&
        IOSUseSizeMatches(
            windowScene.coordinateSpace.bounds.size,
            requestedWidth,
            requestedHeight
        ) &&
        IOSUseSizeMatches(
            fixedCoordinateBounds.size,
            requestedWidth,
            requestedHeight
        ) &&
        windowScene.interfaceOrientation == UIInterfaceOrientationPortrait &&
        restrictionsReady;

    BOOL appKitReady =
        [appKit[@"available"] boolValue] &&
        [appKit[@"uniform"] boolValue] &&
        [appKit[@"sharingType"] integerValue] == 1;
    BOOL configured =
        screenReady &&
        sceneReady &&
        windowReady &&
        rootReady &&
        appKitReady;
    if (stage != NULL) {
        *stage = configured ? @"window-configured" : @"runtime-loaded";
    }
    if (windowSize != NULL) {
        *windowSize = effectiveWindowSize;
    }

    NSDictionary *screenObservation = @{
        @"bounds": IOSUseRectJSON(screen.bounds),
        @"nativeBounds": IOSUseRectJSON(screen.nativeBounds),
        @"scale": @(screen.scale),
        @"nativeScale": @(screen.nativeScale),
    };
    NSDictionary *windowObservation = window == nil ? @{@"available": @NO} : @{
        @"available": @YES,
        @"bounds": IOSUseRectJSON(window.bounds),
        @"frame": IOSUseRectJSON(window.frame),
        @"safeAreaInsets": IOSUseInsetsJSON(window.safeAreaInsets),
        @"safeAreaLayoutFrame": IOSUseRectJSON(
            window.safeAreaLayoutGuide.layoutFrame
        ),
        @"hidden": @(window.hidden),
        @"keyWindow": @(window.isKeyWindow),
    };
    NSDictionary *sceneObservation = windowScene == nil ? @{@"available": @NO} : @{
        @"available": @YES,
        @"coordinateSpaceBounds": IOSUseRectJSON(windowScene.coordinateSpace.bounds),
        @"fixedCoordinateSpaceBounds": IOSUseRectJSON(fixedCoordinateBounds),
        @"screenBounds": IOSUseRectJSON(windowScene.screen.bounds),
        @"interfaceOrientation": @(windowScene.interfaceOrientation),
        @"deviceOrientation": @(UIDevice.currentDevice.orientation),
        @"activationState": @(windowScene.activationState),
        @"sizeRestrictions": restrictionsObservation,
    };
    NSDictionary *rootViewObservation = rootView == nil ? @{@"available": @NO} : @{
        @"available": @YES,
        @"bounds": IOSUseRectJSON(rootView.bounds),
        @"frame": IOSUseRectJSON(rootView.frame),
        @"safeAreaInsets": IOSUseInsetsJSON(rootView.safeAreaInsets),
        @"safeAreaLayoutFrame": IOSUseRectJSON(
            rootView.safeAreaLayoutGuide.layoutFrame
        ),
    };
    NSDictionary *layerObservation = layer == nil ? @{@"available": @NO} : @{
        @"available": @YES,
        @"bounds": IOSUseRectJSON(layer.bounds),
        @"frame": IOSUseRectJSON(layer.frame),
        @"contentsScale": @(layer.contentsScale),
    };
    CGSize metalDrawableSize = CGSizeZero;
    NSDictionary *metalLayerObservation = IOSUseMetalLayerObservation(
        layer,
        &metalDrawableSize
    );
    CGSize appKitBackingSize = IOSUseSizeFromJSON(appKit[@"backingContentRect"]);
    if (appKitBackingSize.width <= 0 || appKitBackingSize.height <= 0) {
        CGFloat backingScale = [appKit[@"backingScaleFactor"] doubleValue];
        appKitBackingSize = CGSizeMake(
            appKitContentSize.width * backingScale,
            appKitContentSize.height * backingScale
        );
    }
    BOOL appKitBackingAvailable =
        appKitBackingSize.width > 0 && appKitBackingSize.height > 0;
    BOOL metalDrawableAvailable =
        metalDrawableSize.width > 0 && metalDrawableSize.height > 0;
    BOOL backingMismatch =
        (appKitBackingAvailable &&
         !IOSUseSizeMatches(appKitBackingSize, nativeWidth, nativeHeight)) ||
        (metalDrawableAvailable &&
         !IOSUseSizeMatches(metalDrawableSize, nativeWidth, nativeHeight));
    BOOL leftTopCropLikely =
        [appKit[@"available"] boolValue] &&
        ![appKit[@"uniform"] boolValue];
    NSDictionary *readiness = @{
        @"screen": @(screenReady),
        @"scene": @(sceneReady),
        @"sceneSizeRestrictions": @(restrictionsReady),
        @"window": @(windowReady),
        @"rootView": @(rootReady),
        @"appKit": @(appKitReady),
        @"configured": @(configured),
    };
    return @{
        @"hooks": IOSUsePlayRuntimeHookDiagnostics(),
        @"screen": screenObservation,
        @"window": windowObservation,
        @"scene": sceneObservation,
        @"rootView": rootViewObservation,
        @"layer": layerObservation,
        @"metalLayer": metalLayerObservation,
        @"appKit": appKit,
        @"readiness": readiness,
        @"expectedNativeSize": IOSUseSizeJSON(
            CGSizeMake(nativeWidth, nativeHeight)
        ),
        @"appKitBackingSize": IOSUseSizeJSON(appKitBackingSize),
        @"backingMismatch": @(backingMismatch),
        @"leftTopCropLikely": @(leftTopCropLikely),
    };
}

static NSDictionary<NSString *, id> *IOSUseSnapshot(BOOL includeObserved) {
    __block NSDictionary<NSString *, id> *snapshot;
    void (^collect)(void) = ^{
        NSDictionary *appKit = IOSUseAppKitObservation();
        NSString *stage = nil;
        CGSize windowSize = CGSizeZero;
        NSDictionary *observed = IOSUseObservedUIKit(
            appKit,
            &stage,
            &windowSize
        );
        UIScreen *screen = UIScreen.mainScreen;
        CGRect logical = screen.bounds;
        CGRect native = screen.nativeBounds;
        NSMutableDictionary<NSString *, id> *payload = [@{
            @"protocolVersion": @1,
            @"pid": @(NSProcessInfo.processInfo.processIdentifier),
            @"bundleIdentifier": NSBundle.mainBundle.bundleIdentifier ?: @"",
            @"profileHash": IOSUseRuntimeProfile[@"profileHash"],
            @"launchNonce": IOSUseRuntimeBootstrap[@"launchNonce"],
            @"runtimeInstanceID": IOSUseRuntimeInstanceID,
            @"preparedGenerationID": IOSUseRuntimeProfile[@"preparedGenerationID"],
            @"runtimeSocketPath": IOSUseRuntimeProfile[@"runtimeSocketPath"],
            @"capabilities": @[@"hello", @"ping", @"diagnostics"],
            @"logicalWidth": @(logical.size.width),
            @"logicalHeight": @(logical.size.height),
            @"nativeWidth": @(native.size.width),
            @"nativeHeight": @(native.size.height),
            @"scale": @(screen.scale),
            @"windowWidth": @(windowSize.width),
            @"windowHeight": @(windowSize.height),
            @"stage": stage,
        } mutableCopy];
        if (includeObserved) {
            payload[@"observed"] = observed;
        }
        snapshot = payload;
    };
    if (NSThread.isMainThread) {
        collect();
    } else {
        bool expected = false;
        if (!atomic_compare_exchange_strong(
                &IOSUseMainSnapshotInFlight,
                &expected,
                true
            )) {
            NSLog(@"[ios-use-play] runtime snapshot already in flight");
            return nil;
        }
        dispatch_semaphore_t completion = dispatch_semaphore_create(0);
        CFAbsoluteTime expiresAt =
            CFAbsoluteTimeGetCurrent()
            + IOSUseMainThreadSnapshotTimeoutSeconds;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (CFAbsoluteTimeGetCurrent() <= expiresAt) {
                collect();
            }
            atomic_store(&IOSUseMainSnapshotInFlight, false);
            dispatch_semaphore_signal(completion);
        });
        dispatch_time_t deadline = dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)(
                IOSUseMainThreadSnapshotTimeoutSeconds * NSEC_PER_SEC
            )
        );
        if (dispatch_semaphore_wait(completion, deadline) != 0) {
            NSLog(@"[ios-use-play] runtime snapshot main-thread timeout");
            return nil;
        }
    }
    return snapshot;
}

static NSDictionary<NSString *, id> *IOSUsePingSnapshot(void) {
    if (IOSUseRuntimeProfile == nil ||
        IOSUseRuntimeBootstrap == nil ||
        IOSUseRuntimeInstanceID.length == 0) {
        return nil;
    }
    return @{
        @"protocolVersion": @1,
        @"pid": @(NSProcessInfo.processInfo.processIdentifier),
        @"bundleIdentifier": NSBundle.mainBundle.bundleIdentifier ?: @"",
        @"profileHash": IOSUseRuntimeProfile[@"profileHash"],
        @"launchNonce": IOSUseRuntimeBootstrap[@"launchNonce"],
        @"runtimeInstanceID": IOSUseRuntimeInstanceID,
        @"preparedGenerationID": IOSUseRuntimeProfile[@"preparedGenerationID"],
        @"runtimeSocketPath": IOSUseRuntimeProfile[@"runtimeSocketPath"],
        @"capabilities": @[@"hello", @"ping", @"diagnostics"],
        @"logicalWidth": IOSUseRuntimeProfile[@"logicalWidth"],
        @"logicalHeight": IOSUseRuntimeProfile[@"logicalHeight"],
        @"nativeWidth": IOSUseRuntimeProfile[@"nativeWidth"],
        @"nativeHeight": IOSUseRuntimeProfile[@"nativeHeight"],
        @"scale": IOSUseRuntimeProfile[@"scale"],
        @"windowWidth": NSNull.null,
        @"windowHeight": NSNull.null,
        @"stage": @"runtime-listening",
    };
}

static NSDictionary<NSString *, id> *IOSUseErrorResponse(
    NSString *requestID,
    NSString *code,
    NSString *message
) {
    return @{
        @"schemaVersion": @1,
        @"requestId": requestID ?: @"",
        @"ok": @NO,
        @"error": @{
            @"code": code,
            @"message": message,
        },
    };
}

static NSDictionary<NSString *, id> *IOSUseHandleRequest(id object) {
    if (![object isKindOfClass:NSDictionary.class]) {
        return IOSUseErrorResponse(
            @"",
            @"invalid_request",
            @"request must be a JSON object"
        );
    }
    NSDictionary<NSString *, id> *request = object;
    NSString *requestID = IOSUseIsNonemptyString(request[@"requestId"])
        ? request[@"requestId"]
        : @"";
    NSSet<NSString *> *expectedKeys = [NSSet setWithArray:@[
        @"schemaVersion",
        @"requestId",
        @"command",
        @"launchNonce",
    ]];
    if (request.count != expectedKeys.count ||
        ![[NSSet setWithArray:request.allKeys] isEqualToSet:expectedKeys] ||
        !IOSUseIsSchemaVersionOne(request[@"schemaVersion"]) ||
        requestID.length == 0 ||
        !IOSUseIsNonemptyString(request[@"command"]) ||
        !IOSUseIsNonemptyString(request[@"launchNonce"])) {
        return IOSUseErrorResponse(
            requestID,
            @"invalid_request",
            @"request does not match schema version 1"
        );
    }
    if (![request[@"launchNonce"] isEqualToString:IOSUseRuntimeBootstrap[@"launchNonce"]]) {
        return IOSUseErrorResponse(
            requestID,
            @"unauthorized",
            @"launch nonce does not match this runtime"
        );
    }

    NSString *command = request[@"command"];
    NSDictionary<NSString *, id> *payload;
    if ([command isEqualToString:@"hello"]) {
        payload = IOSUseSnapshot(NO);
    } else if ([command isEqualToString:@"ping"]) {
        payload = IOSUsePingSnapshot();
    } else if ([command isEqualToString:@"diagnostics"]) {
        payload = IOSUseSnapshot(YES);
    } else {
        return IOSUseErrorResponse(
            requestID,
            @"unsupported_command",
            @"supported commands are hello, ping, and diagnostics"
        );
    }
    if (payload == nil) {
        return IOSUseErrorResponse(
            requestID,
            @"main_thread_timeout",
            @"UIKit diagnostics did not complete before the runtime deadline"
        );
    }
    return @{
        @"schemaVersion": @1,
        @"requestId": requestID,
        @"ok": @YES,
        @"payload": payload,
    };
}

static void IOSUseServeConnection(int connection) {
    if (!IOSUseConfigureSocket(connection, YES)) {
        return;
    }
    uid_t peerUser = (uid_t)-1;
    gid_t peerGroup = (gid_t)-1;
    if (getpeereid(connection, &peerUser, &peerGroup) != 0 ||
        peerUser != geteuid()) {
        NSLog(@"[ios-use-play] rejected runtime socket peer");
        return;
    }

    uint32_t networkLength = 0;
    if (!IOSUseReadExactly(connection, &networkLength, sizeof(networkLength))) {
        return;
    }
    uint32_t frameLength = ntohl(networkLength);
    if (frameLength == 0 || frameLength > IOSUseMaximumFrameSize) {
        NSDictionary *response = IOSUseErrorResponse(
            @"",
            @"invalid_frame",
            @"frame length must be between 1 and 65536 bytes"
        );
        NSError *error = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:response
                                                       options:0
                                                         error:&error];
        if (data != nil) {
            uint32_t responseLength = htonl((uint32_t)data.length);
            (void)IOSUseWriteExactly(
                connection,
                &responseLength,
                sizeof(responseLength)
            );
            (void)IOSUseWriteExactly(connection, data.bytes, data.length);
        }
        return;
    }

    NSMutableData *frame = [NSMutableData dataWithLength:frameLength];
    if (!IOSUseReadExactly(connection, frame.mutableBytes, frameLength)) {
        return;
    }
    NSError *error = nil;
    NSString *utf8 = [[NSString alloc] initWithData:frame
                                           encoding:NSUTF8StringEncoding];
    id object = nil;
    if (utf8 != nil) {
        object = [NSJSONSerialization JSONObjectWithData:frame
                                                 options:0
                                                   error:&error];
    }
    NSDictionary *response = object == nil
        ? IOSUseErrorResponse(
            @"",
            @"invalid_json",
            utf8 == nil
                ? @"frame is not valid UTF-8"
                : @"frame is not valid JSON"
        )
        : IOSUseHandleRequest(object);
    NSData *responseData = [NSJSONSerialization dataWithJSONObject:response
                                                            options:0
                                                              error:&error];
    if (responseData == nil || responseData.length > IOSUseMaximumFrameSize) {
        return;
    }
    uint32_t responseLength = htonl((uint32_t)responseData.length);
    if (!IOSUseWriteExactly(connection, &responseLength, sizeof(responseLength))) {
        return;
    }
    (void)IOSUseWriteExactly(connection, responseData.bytes, responseData.length);
}

static int IOSUseCreateListener(NSString *socketPath) {
    struct stat directoryStatus;
    if (!IOSUsePrepareSocketDirectory(socketPath, &directoryStatus) ||
        !IOSUseRequireAbsentSocketPath(socketPath)) {
        return -1;
    }
    NSData *pathData = [socketPath dataUsingEncoding:NSUTF8StringEncoding];
    if (pathData.length == 0 ||
        pathData.length >= sizeof(((struct sockaddr_un *)0)->sun_path)) {
        IOSUseRecordSocketStartupFailure(@"socket-path-length", ENAMETOOLONG);
        NSLog(@"[ios-use-play] runtime socket path is too long");
        return -1;
    }

    int listener = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listener < 0) {
        IOSUseLogPOSIXError(@"create", socketPath);
        return -1;
    }
    if (!IOSUseConfigureSocket(listener, NO)) {
        IOSUseLogPOSIXError(@"configure", socketPath);
        close(listener);
        return -1;
    }

    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    address.sun_len = (uint8_t)sizeof(address);
    memcpy(address.sun_path, pathData.bytes, pathData.length);
    address.sun_path[pathData.length] = '\0';
    if (bind(listener, (const struct sockaddr *)&address, sizeof(address)) != 0) {
        IOSUseLogPOSIXError(@"bind", socketPath);
        close(listener);
        return -1;
    }
    if (!IOSUseSocketDirectoryMatches(socketPath, &directoryStatus)) {
        IOSUseRecordSocketPermissionFailure(@"directory-changed-after-bind");
        close(listener);
        return -1;
    }

    const char *filePath = socketPath.fileSystemRepresentation;
    struct stat status;
    if (chmod(filePath, 0600) != 0 ||
        lstat(filePath, &status) != 0 ||
        S_ISLNK(status.st_mode) ||
        !S_ISSOCK(status.st_mode) ||
        status.st_uid != geteuid() ||
        (status.st_mode & 0777) != 0600) {
        IOSUseLogPOSIXError(@"secure", socketPath);
        close(listener);
        unlink(filePath);
        return -1;
    }
    if (listen(listener, 8) != 0) {
        IOSUseLogPOSIXError(@"listen", socketPath);
        close(listener);
        unlink(filePath);
        return -1;
    }
    return listener;
}

void IOSUsePlayRuntimeStartSocket(NSDictionary<NSString *, id> *profile) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        os_unfair_lock_lock(&IOSUseRuntimeStateLock);
        IOSUseRuntimeSocketStatus = @"starting";
        IOSUseRuntimeSocketFailureStage = nil;
        IOSUseRuntimeSocketFailureErrno = nil;
        os_unfair_lock_unlock(&IOSUseRuntimeStateLock);
        NSLog(@"[ios-use-play] runtime socket startup begin");
        NSDictionary<NSString *, id> *bootstrap = IOSUseLoadBootstrap(profile);
        if (bootstrap == nil) {
            return;
        }
        NSString *socketPath = bootstrap[@"runtimeSocketPath"];
        os_unfair_lock_lock(&IOSUseRuntimeStateLock);
        IOSUseRuntimeProfile = [profile copy];
        IOSUseRuntimeBootstrap = [bootstrap copy];
        IOSUseRuntimeInstanceID = NSUUID.UUID.UUIDString;
        os_unfair_lock_unlock(&IOSUseRuntimeStateLock);
        int listener = IOSUseCreateListener(socketPath);
        if (listener < 0) {
            return;
        }
        os_unfair_lock_lock(&IOSUseRuntimeStateLock);
        IOSUseRuntimeSocketStatus = @"listening";
        IOSUseRuntimeSocketFailureStage = nil;
        IOSUseRuntimeSocketFailureErrno = nil;
        os_unfair_lock_unlock(&IOSUseRuntimeStateLock);
        dispatch_queue_t queue = dispatch_queue_create(
            "io.ios-use.play-runtime.socket",
            DISPATCH_QUEUE_SERIAL
        );
        dispatch_async(queue, ^{
            NSLog(@"[ios-use-play] runtime socket listening at %@", socketPath);
            for (;;) {
                @autoreleasepool {
                    int connection = accept(listener, NULL, NULL);
                    if (connection < 0) {
                        int savedErrno = errno;
                        if (savedErrno == EINTR) {
                            continue;
                        }
                        IOSUseRecordSocketStartupFailure(
                            @"accept",
                            savedErrno
                        );
                        if (savedErrno == EMFILE ||
                            savedErrno == ENFILE ||
                            savedErrno == ENOBUFS ||
                            savedErrno == ENOMEM) {
                            usleep(250000);
                            continue;
                        }
                        close(listener);
                        return;
                    }
                    os_unfair_lock_lock(&IOSUseRuntimeStateLock);
                    IOSUseRuntimeSocketStatus = @"listening";
                    IOSUseRuntimeSocketFailureStage = nil;
                    IOSUseRuntimeSocketFailureErrno = nil;
                    os_unfair_lock_unlock(&IOSUseRuntimeStateLock);
                    IOSUseServeConnection(connection);
                    close(connection);
                }
            }
        });
    });
}

NSDictionary<NSString *, id> *IOSUsePlayRuntimeSocketIdentity(void) {
    os_unfair_lock_lock(&IOSUseRuntimeStateLock);
    NSString *socketStatus = [IOSUseRuntimeSocketStatus copy];
    NSString *failureStage = [IOSUseRuntimeSocketFailureStage copy];
    NSNumber *failureErrno = IOSUseRuntimeSocketFailureErrno;
    NSDictionary<NSString *, id> *profile = IOSUseRuntimeProfile;
    NSDictionary<NSString *, id> *bootstrap = IOSUseRuntimeBootstrap;
    NSString *runtimeInstanceID = [IOSUseRuntimeInstanceID copy];
    os_unfair_lock_unlock(&IOSUseRuntimeStateLock);
    NSMutableDictionary<NSString *, id> *identity = [@{
        @"runtimeSocketStatus": socketStatus ?: @"unknown",
    } mutableCopy];
    if (failureStage.length > 0) {
        identity[@"runtimeSocketErrorStage"] = failureStage;
    }
    if (failureErrno != nil) {
        identity[@"runtimeSocketErrno"] = failureErrno;
    }
    if (bootstrap == nil || runtimeInstanceID.length == 0) {
        return identity;
    }
    [identity addEntriesFromDictionary:@{
        @"launchNonce": bootstrap[@"launchNonce"],
        @"preparedGenerationID": profile[@"preparedGenerationID"],
        @"runtimeInstanceID": runtimeInstanceID,
        @"runtimeSocketPath": profile[@"runtimeSocketPath"],
    }];
    return identity;
}
