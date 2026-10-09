#pragma once
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>
#import <mach/mach.h>

enum { IOSUseWebBridgeMessageID = 420 };

// Private inherited broker channel; no named service or listening socket.
void IOSUseSendWebMessage(mach_port_t destination, NSDictionary *payload,
                         mach_port_t replyPort, IOSurfaceRef surface);
// Consumes the received message. Caller owns the returned port and surface.
NSDictionary *IOSUseDecodeWebMessage(mach_msg_header_t *message,
                                    mach_port_t *replyPort, IOSurfaceRef *surface);
