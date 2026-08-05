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

/// Redirect stdout/stderr from an already-open, host-owned descriptor.
/// Runtime never opens a path supplied by the host; path/device/inode are
/// diagnostics metadata and the descriptor's fstat identity is authoritative.
int IOSUsePlayRuntimeConfigureStdioFromDescriptor(
    int descriptor,
    const char *path,
    uint64_t expectedDevice,
    uint64_t expectedInode
);

#endif
