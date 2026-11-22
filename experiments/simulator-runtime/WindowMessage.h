#pragma once
#include <mach/mach.h>

// Only the inherited, private broker port carries these experimental messages.
enum { IOSUseWindowFrame = 400, IOSUseWindowPointer = 401, IOSUseWindowRelease = 402,
       IOSUseWindowText = 403, IOSUseWindowSceneState = 404,
       IOSUseWindowSceneClose = 405, IOSUseWindowSceneClosed = 406 };
typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t surface;
    mach_msg_port_descriptor_t release; // Frame ownership, independent of input.
    mach_msg_port_descriptor_t input;   // MACH_PORT_NULL when input is disabled.
    uint32_t surfaceID;
    uint32_t sceneID; // The stable presentation context for this Scene.
} IOSUseWindowFrameMessage;

typedef struct {
    mach_msg_header_t header;
    uint32_t surfaceID;
} IOSUseWindowReleaseMessage;

typedef struct {
    mach_msg_header_t header;
    uint32_t foreground;
} IOSUseWindowSceneStateMessage;

// SceneClose is a header-only request on that Scene's presentation port.
typedef struct {
    mach_msg_header_t header;
    uint32_t sceneID;
} IOSUseWindowSceneClosedMessage;

typedef struct {
    mach_msg_header_t header;
    double x, y;
    uint32_t phase; // UITouchPhase: began=0, moved=1, ended=3, cancelled=4
} IOSUseWindowPointerMessage;

enum { IOSUseTextInsert = 0, IOSUseTextDeleteBackward = 1 };
typedef struct {
    mach_msg_header_t header;
    uint32_t operation;
    uint32_t length;
    char utf8[4096];
} IOSUseWindowTextMessage;
