#include "IOSUsePlayRuntimeStdio.h"

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int WriteAll(
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
        return 1;
    }
    return 0;
}

int main(void) {
    const char *enabled = getenv("IOS_USE_PLAY_STDIO_LOG");
#if defined(IOS_USE_PLAY_RUNTIME_STDIO_STANDALONE)
    if (enabled != NULL && strcmp(enabled, "1") == 0) {
        const char *path = getenv("IOS_USE_PLAY_STDIO_LOG_PATH");
        const char *deviceText = getenv("IOS_USE_PLAY_STDIO_LOG_DEVICE");
        const char *inodeText = getenv("IOS_USE_PLAY_STDIO_LOG_INODE");
        char *deviceEnd = NULL;
        char *inodeEnd = NULL;
        errno = 0;
        unsigned long long device = deviceText == NULL
            ? 0
            : strtoull(deviceText, &deviceEnd, 10);
        unsigned long long inode = inodeText == NULL
            ? 0
            : strtoull(inodeText, &inodeEnd, 10);
        int descriptor = path == NULL
            ? -1
            : open(path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC);
        if (deviceText == NULL || deviceEnd == deviceText ||
            *deviceEnd != '\0' || inodeText == NULL ||
            inodeEnd == inodeText || *inodeEnd != '\0' || errno != 0) {
            if (descriptor >= 0) {
                close(descriptor);
            }
            descriptor = -1;
        }
        (void)IOSUsePlayRuntimeConfigureStdioFromDescriptor(
            descriptor,
            path,
            (uint64_t)device,
            (uint64_t)inode
        );
    }
#endif
    IOSUsePlayRuntimeStdioState state;
    IOSUsePlayRuntimeCopyStdioState(&state);
    if (state.status == IOSUsePlayRuntimeStdioFailed) {
        return 78;
    }
    if (enabled != NULL && enabled[0] != '\0'
        && state.status != IOSUsePlayRuntimeStdioRedirected) {
        return 79;
    }
    if ((enabled == NULL || enabled[0] == '\0')
        && state.status != IOSUsePlayRuntimeStdioDisabled) {
        return 80;
    }
    const char *token = getenv("IOS_USE_PLAY_STDIO_TEST_TOKEN");
    if (token == NULL || token[0] == '\0') {
        token = "default";
    }
    const char stdoutPrefix[] = "fixture-stdout:";
    const char stderrPrefix[] = "fixture-stderr:";
    const char newline[] = "\n";
    return WriteAll(
        STDOUT_FILENO,
        stdoutPrefix,
        sizeof(stdoutPrefix) - 1
    ) || WriteAll(STDOUT_FILENO, token, strlen(token))
        || WriteAll(STDOUT_FILENO, newline, 1)
        || WriteAll(
            STDERR_FILENO,
            stderrPrefix,
            sizeof(stderrPrefix) - 1
        )
        || WriteAll(STDERR_FILENO, token, strlen(token))
        || WriteAll(STDERR_FILENO, newline, 1);
}
