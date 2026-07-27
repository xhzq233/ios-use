#include "IOSUsePlayRuntimeStdio.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static const char *const IOSUsePlayStdioEnabled =
    "IOS_USE_PLAY_STDIO_LOG";
static const char *const IOSUsePlayStdioPath =
    "IOS_USE_PLAY_STDIO_LOG_PATH";
static const char *const IOSUsePlayStdioDevice =
    "IOS_USE_PLAY_STDIO_LOG_DEVICE";
static const char *const IOSUsePlayStdioInode =
    "IOS_USE_PLAY_STDIO_LOG_INODE";

static IOSUsePlayRuntimeStdioState IOSUsePlayStdioState = {
    .status = IOSUsePlayRuntimeStdioDisabled,
};

#if !defined(IOS_USE_PLAY_RUNTIME_STDIO_STANDALONE)
extern void IOSUsePlayRuntimeInitializeAfterStdio(void);
#endif

static void IOSUsePlayStdioWriteAll(
    int descriptor,
    const char *bytes,
    size_t length
) {
    size_t offset = 0;
    while (offset < length) {
        ssize_t written = write(
            descriptor,
            bytes + offset,
            length - offset
        );
        if (written > 0) {
            offset += (size_t)written;
            continue;
        }
        if (written < 0 && errno == EINTR) {
            continue;
        }
        return;
    }
}

static void IOSUsePlayStdioRecordFailure(
    const char *stage,
    int errorNumber
) {
    IOSUsePlayStdioState.status = IOSUsePlayRuntimeStdioFailed;
    IOSUsePlayStdioState.errorNumber = errorNumber;
    (void)snprintf(
        IOSUsePlayStdioState.failureStage,
        sizeof(IOSUsePlayStdioState.failureStage),
        "%s",
        stage
    );
    char message[384];
    int count = snprintf(
        message,
        sizeof(message),
        "[ios-use-play] stdio capture failed: %s (errno %d)\n",
        stage,
        errorNumber
    );
    if (count > 0) {
        size_t length = (size_t)count;
        if (length >= sizeof(message)) {
            length = sizeof(message) - 1;
        }
        IOSUsePlayStdioWriteAll(
            STDERR_FILENO,
            message,
            length
        );
    }
}

static int IOSUsePlayStdioParseIdentity(
    const char *value,
    uint64_t *result
) {
    if (value == NULL || value[0] == '\0' || result == NULL) {
        return EINVAL;
    }
    for (const char *cursor = value; *cursor != '\0'; cursor++) {
        if (*cursor < '0' || *cursor > '9') {
            return EINVAL;
        }
    }
    errno = 0;
    char *end = NULL;
    unsigned long long parsed = strtoull(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0') {
        return errno == 0 ? EINVAL : errno;
    }
    *result = (uint64_t)parsed;
    return 0;
}

static int IOSUsePlayStdioDup2(
    int source,
    int destination
) {
    for (;;) {
        if (dup2(source, destination) >= 0) {
            return 0;
        }
        if (errno != EINTR) {
            return errno;
        }
    }
}

void IOSUsePlayRuntimeCopyStdioState(
    IOSUsePlayRuntimeStdioState *state
) {
    if (state != NULL) {
        *state = IOSUsePlayStdioState;
    }
}

static void IOSUsePlayRuntimeConfigureStdio(void) {
    const char *enabled = getenv(IOSUsePlayStdioEnabled);
    if (enabled == NULL || enabled[0] == '\0') {
        return;
    }
    if (strcmp(enabled, "1") != 0) {
        IOSUsePlayStdioRecordFailure(
            "invalid-enable-flag",
            EINVAL
        );
        return;
    }
    const char *path = getenv(IOSUsePlayStdioPath);
    if (path == NULL || path[0] != '/') {
        IOSUsePlayStdioRecordFailure(
            "missing-absolute-log-path",
            EINVAL
        );
        return;
    }
    size_t pathLength = strnlen(path, PATH_MAX);
    if (pathLength == 0 || pathLength >= PATH_MAX) {
        IOSUsePlayStdioRecordFailure(
            "invalid-log-path-length",
            ENAMETOOLONG
        );
        return;
    }
    memcpy(IOSUsePlayStdioState.path, path, pathLength + 1);
    int parseError = IOSUsePlayStdioParseIdentity(
        getenv(IOSUsePlayStdioDevice),
        &IOSUsePlayStdioState.device
    );
    if (parseError != 0) {
        IOSUsePlayStdioRecordFailure(
            "invalid-log-device-identity",
            parseError
        );
        return;
    }
    parseError = IOSUsePlayStdioParseIdentity(
        getenv(IOSUsePlayStdioInode),
        &IOSUsePlayStdioState.inode
    );
    if (parseError != 0 || IOSUsePlayStdioState.inode == 0) {
        IOSUsePlayStdioRecordFailure(
            "invalid-log-inode-identity",
            parseError == 0 ? EINVAL : parseError
        );
        return;
    }

    char parentPath[PATH_MAX];
    memcpy(parentPath, path, pathLength + 1);
    char *separator = strrchr(parentPath, '/');
    if (separator == NULL || separator == parentPath
        || separator[1] == '\0') {
        IOSUsePlayStdioRecordFailure(
            "invalid-log-path-shape",
            EINVAL
        );
        return;
    }
    *separator = '\0';
    const char *filename = separator + 1;
    int directory = openat(
        AT_FDCWD,
        parentPath,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    );
    if (directory < 0) {
        IOSUsePlayStdioRecordFailure(
            "open-log-directory",
            errno
        );
        return;
    }
    struct stat directoryStatus;
    if (fstat(directory, &directoryStatus) != 0) {
        int errorNumber = errno;
        close(directory);
        IOSUsePlayStdioRecordFailure(
            "stat-log-directory",
            errorNumber
        );
        return;
    }
    if ((directoryStatus.st_mode & S_IFMT) != S_IFDIR
        || directoryStatus.st_uid != geteuid()
        || (directoryStatus.st_mode & 07777) != 0700) {
        close(directory);
        IOSUsePlayStdioRecordFailure(
            "validate-log-directory",
            EPERM
        );
        return;
    }

    // PlayTools interposes open(2). Anchored openat(2) keeps this trust
    // boundary on the kernel primitive. O_NONBLOCK prevents a substituted
    // FIFO from blocking before fstat can reject it.
    int descriptor = openat(
        directory,
        filename,
        O_WRONLY | O_APPEND | O_NONBLOCK
            | O_NOFOLLOW | O_CLOEXEC
    );
    if (descriptor < 0) {
        int errorNumber = errno;
        close(directory);
        IOSUsePlayStdioRecordFailure(
            "open-exact-log-file",
            errorNumber
        );
        return;
    }
    struct stat status;
    struct stat namedStatus;
    if (fstat(descriptor, &status) != 0) {
        int errorNumber = errno;
        close(descriptor);
        close(directory);
        IOSUsePlayStdioRecordFailure(
            "stat-exact-log-file",
            errorNumber
        );
        return;
    }
    if (fstatat(
            directory,
            filename,
            &namedStatus,
            AT_SYMLINK_NOFOLLOW
        ) != 0) {
        int errorNumber = errno;
        close(descriptor);
        close(directory);
        IOSUsePlayStdioRecordFailure(
            "stat-named-log-file",
            errorNumber
        );
        return;
    }
    if (status.st_dev != namedStatus.st_dev
        || status.st_ino != namedStatus.st_ino
        || status.st_mode != namedStatus.st_mode
        || status.st_uid != namedStatus.st_uid
        || status.st_nlink != namedStatus.st_nlink
        || (status.st_mode & S_IFMT) != S_IFREG
        || status.st_uid != geteuid()
        || status.st_nlink != 1
        || (status.st_mode & 07777) != 0600
        || (uint64_t)status.st_dev
            != IOSUsePlayStdioState.device
        || (uint64_t)status.st_ino
            != IOSUsePlayStdioState.inode) {
        close(descriptor);
        close(directory);
        IOSUsePlayStdioRecordFailure(
            "validate-exact-log-file",
            EPERM
        );
        return;
    }
    int descriptorFlags = fcntl(descriptor, F_GETFL);
    if (descriptorFlags < 0
        || fcntl(
            descriptor,
            F_SETFL,
            descriptorFlags & ~O_NONBLOCK
        ) != 0) {
        int errorNumber = errno;
        close(descriptor);
        close(directory);
        IOSUsePlayStdioRecordFailure(
            "clear-log-nonblocking",
            errorNumber
        );
        return;
    }
    close(directory);

    (void)fflush(stdout);
    (void)fflush(stderr);
    int duplicateError = IOSUsePlayStdioDup2(
        descriptor,
        STDOUT_FILENO
    );
    if (duplicateError == 0) {
        duplicateError = IOSUsePlayStdioDup2(
            descriptor,
            STDERR_FILENO
        );
    }
    if (duplicateError != 0) {
        close(descriptor);
        IOSUsePlayStdioRecordFailure(
            "redirect-stdio",
            duplicateError
        );
        return;
    }
    if (descriptor > STDERR_FILENO) {
        close(descriptor);
    }
    (void)setvbuf(stdout, NULL, _IOLBF, 0);
    (void)setvbuf(stderr, NULL, _IONBF, 0);
    IOSUsePlayStdioState.status =
        IOSUsePlayRuntimeStdioRedirected;
    static const char ready[] =
        "[ios-use-play] stdio capture ready\n";
    IOSUsePlayStdioWriteAll(
        STDERR_FILENO,
        ready,
        sizeof(ready) - 1
    );
}

// Keep one explicit Runtime constructor so link order cannot place the
// Objective-C Runtime initializer ahead of stdio setup. Objective-C +load and
// dyld diagnostics necessarily precede every constructor and are intentionally
// outside this capture contract.
__attribute__((constructor))
static void IOSUsePlayRuntimeInitializeEntry(void) {
    IOSUsePlayRuntimeConfigureStdio();
#if !defined(IOS_USE_PLAY_RUNTIME_STDIO_STANDALONE)
    IOSUsePlayRuntimeInitializeAfterStdio();
#endif
}
