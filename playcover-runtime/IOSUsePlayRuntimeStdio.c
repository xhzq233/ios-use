#include "IOSUsePlayRuntimeStdio.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#if !defined(IOS_USE_PLAY_RUNTIME_STDIO_STANDALONE)
static const char *const IOSUsePlayStdioEnabled =
    "IOS_USE_PLAY_STDIO_LOG";
#endif
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

int IOSUsePlayRuntimeConfigureStdioFromDescriptor(
    int descriptor,
    const char *path,
    uint64_t expectedDevice,
    uint64_t expectedInode
) {
    if (descriptor < 0) {
        IOSUsePlayStdioRecordFailure("missing-log-descriptor", EBADF);
        return EBADF;
    }
    struct stat status;
    if (fstat(descriptor, &status) != 0) {
        int errorNumber = errno;
        close(descriptor);
        IOSUsePlayStdioRecordFailure("stat-log-descriptor", errorNumber);
        return errorNumber;
    }
    int descriptorFlags = fcntl(descriptor, F_GETFL);
    int accessMode = descriptorFlags < 0
        ? O_RDONLY
        : descriptorFlags & O_ACCMODE;
    if ((status.st_mode & S_IFMT) != S_IFREG
        || status.st_uid != geteuid()
        || status.st_nlink != 1
        || (status.st_mode & 07777) != 0600
        || descriptorFlags < 0
        || accessMode == O_RDONLY
        || expectedDevice == 0
        || expectedInode == 0
        || (uint64_t)status.st_dev != expectedDevice
        || (uint64_t)status.st_ino != expectedInode) {
        close(descriptor);
        IOSUsePlayStdioRecordFailure(
            "validate-log-descriptor",
            EPERM
        );
        return EPERM;
    }
    if (path == NULL || path[0] != '/') {
        close(descriptor);
        IOSUsePlayStdioRecordFailure("invalid-log-path-metadata", EINVAL);
        return EINVAL;
    }
    size_t pathLength = strnlen(path, PATH_MAX);
    if (pathLength == 0 || pathLength >= PATH_MAX) {
        close(descriptor);
        IOSUsePlayStdioRecordFailure(
            "invalid-log-path-length",
            ENAMETOOLONG
        );
        return ENAMETOOLONG;
    }
    memcpy(IOSUsePlayStdioState.path, path, pathLength + 1);
    IOSUsePlayStdioState.device = (uint64_t)status.st_dev;
    IOSUsePlayStdioState.inode = (uint64_t)status.st_ino;
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
        return duplicateError;
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
    return 0;
}

// Keep one explicit Runtime constructor so link order cannot place the
// Objective-C Runtime initializer ahead of stdio setup. Objective-C +load and
// dyld diagnostics necessarily precede every constructor and are intentionally
// outside this capture contract.
__attribute__((constructor))
static void IOSUsePlayRuntimeInitializeEntry(void) {
#if !defined(IOS_USE_PLAY_RUNTIME_STDIO_STANDALONE)
    extern void IOSUsePlayRuntimeStartSocket(void);
    extern int IOSUsePlayRuntimeBootstrapStdio(void);
    IOSUsePlayRuntimeStartSocket();
    if (getenv(IOSUsePlayStdioEnabled) != NULL) {
        (void)IOSUsePlayRuntimeBootstrapStdio();
    }
    IOSUsePlayRuntimeInitializeAfterStdio();
#endif
}
