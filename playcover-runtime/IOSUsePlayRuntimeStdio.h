#ifndef IOS_USE_PLAY_RUNTIME_STDIO_H
#define IOS_USE_PLAY_RUNTIME_STDIO_H

#include <limits.h>
#include <stdint.h>

typedef enum {
    IOSUsePlayRuntimeStdioDisabled = 0,
    IOSUsePlayRuntimeStdioRedirected = 1,
    IOSUsePlayRuntimeStdioFailed = 2,
} IOSUsePlayRuntimeStdioStatus;

typedef struct {
    IOSUsePlayRuntimeStdioStatus status;
    int errorNumber;
    uint64_t device;
    uint64_t inode;
    char path[PATH_MAX];
    char failureStage[96];
} IOSUsePlayRuntimeStdioState;

void IOSUsePlayRuntimeCopyStdioState(
    IOSUsePlayRuntimeStdioState *state
);

#endif
