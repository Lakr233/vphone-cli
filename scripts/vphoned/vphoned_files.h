/*
 * vphoned_files — Remote file operations over vsock.
 *
 * Handles file_list, file_get, file_put, file_mkdir, file_delete, file_rename.
 * file_get and file_put perform inline binary I/O on the socket.
 */

#pragma once
#import <Foundation/Foundation.h>

/// Handle a file command. Returns a response dict, or nil if the response
/// was already written inline (e.g. file_get with streaming data).
NSDictionary *vp_handle_file_command(int fd, NSDictionary *msg);
