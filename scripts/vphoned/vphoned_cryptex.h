/*
 * vphoned_cryptex — Cryptex install over vsock.
 *
 */

#pragma once
#import <Foundation/Foundation.h>

BOOL vp_cryptex_available(void);

/// Handle a cryptex command. Returns a response dict, or nil if the response
/// was already written inline (e.g. file_get with streaming data).
NSDictionary *vp_handle_cryptex_command(NSDictionary *msg);
