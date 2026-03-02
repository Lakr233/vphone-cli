/*
 * vphoned_protocol — Length-prefixed JSON framing over vsock.
 *
 * Each message: [uint32 big-endian length][UTF-8 JSON payload]
 */

#pragma once
#import <Foundation/Foundation.h>

#define PROTOCOL_VERSION 1

BOOL vp_read_fully(int fd, void *buf, size_t count);
BOOL vp_write_fully(int fd, const void *buf, size_t count);

/// Discard exactly `size` bytes from fd. Used to keep protocol in sync on error paths.
void vp_drain(int fd, size_t size);

NSDictionary *vp_read_message(int fd);
BOOL vp_write_message(int fd, NSDictionary *dict);

/// Build a response dict with protocol version, type, and optional request ID echo.
NSMutableDictionary *vp_make_response(NSString *type, id reqId);
