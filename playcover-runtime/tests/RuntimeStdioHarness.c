#include "IOSUsePlayRuntimeStdio.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
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
    IOSUsePlayRuntimeStdioState state;
    IOSUsePlayRuntimeCopyStdioState(&state);
    if (state.status == IOSUsePlayRuntimeStdioFailed) {
        return 78;
    }
    const char *enabled = getenv("IOS_USE_PLAY_STDIO_LOG");
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
