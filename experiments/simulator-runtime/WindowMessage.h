#pragma once
#include <mach/mach.h>

// Only the inherited, private broker port carries these experimental messages.
enum { IOSUseWindowFrame = 400, IOSUseWindowPointer = 401, IOSUseWindowRelease = 402,
       IOSUseWindowText = 403 };
typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t surface;
    mach_msg_port_descriptor_t input;
    uint32_t surfaceID;
} IOSUseWindowFrameMessage;

typedef struct {
    mach_msg_header_t header;
    uint32_t surfaceID;
} IOSUseWindowReleaseMessage;

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
