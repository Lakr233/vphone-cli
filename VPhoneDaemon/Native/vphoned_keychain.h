/*
 * vphoned_keychain — Remote keychain enumeration over vsock.
 *
 * Handles keychain_list: queries SecItemCopyMatching for all keychain
 * classes and returns attributes as JSON.
 */

#pragma once
#import <Foundation/Foundation.h>

/// Handle a keychain command. Returns a response dict.
NSDictionary *vp_handle_keychain_command(NSDictionary *msg);
