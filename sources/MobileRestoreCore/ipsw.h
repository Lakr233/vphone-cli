/*
 * ipsw.h
 * Definitions for IPSW utilities
 *
 * Copyright (c) 2012-2019 Nikias Bassen. All Rights Reserved.
 * Copyright (c) 2010 Martin Szulecki. All Rights Reserved.
 * Copyright (c) 2010 Joshua Hill. All Rights Reserved.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
 */

#ifndef IDEVICERESTORE_IPSW_H
#define IDEVICERESTORE_IPSW_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>
#include <plist/plist.h>
#include <sys/stat.h>

struct ipsw_archive {
	int zip;
	char *path;
};
typedef struct ipsw_archive* ipsw_archive_t;

ipsw_archive_t ipsw_open(const char* ipsw);
void ipsw_close(ipsw_archive_t ipsw);

int ipsw_print_info(const char* ipsw);

typedef int (*ipsw_list_cb)(void *ctx, ipsw_archive_t ipsw, const char *name, struct stat *stat);
typedef int (*ipsw_send_cb)(void *ctx, const void *data, size_t size, size_t done, size_t total_size);

struct ipsw_file_handle {
	FILE* file;
	struct zip* zip;
	struct zip_file* zfile;
	uint64_t size;
	int seekable;
};
typedef struct ipsw_file_handle* ipsw_file_handle_t;

ipsw_file_handle_t ipsw_file_open(ipsw_archive_t, const char* path);
void ipsw_file_close(ipsw_file_handle_t handle);

uint64_t ipsw_file_size(ipsw_file_handle_t handle);
int64_t ipsw_file_read(ipsw_file_handle_t handle, void* buffer, size_t size);
int ipsw_file_seek(ipsw_file_handle_t handle, int64_t offset, int whence);
int64_t ipsw_file_tell(ipsw_file_handle_t handle);

int ipsw_is_directory(const char* ipsw);

int ipsw_file_exists(ipsw_archive_t ipsw, const char* infile);
int ipsw_get_file_size(ipsw_archive_t ipsw, const char* infile, uint64_t* size);
int ipsw_extract_to_file(ipsw_archive_t ipsw, const char* infile, const char* outfile);
int ipsw_extract_to_file_with_progress(ipsw_archive_t ipsw, const char* infile, const char* outfile, int print_progress);
int ipsw_extract_to_memory(ipsw_archive_t ipsw, const char* infile, void** pbuffer, size_t* psize);
int ipsw_extract_send(ipsw_archive_t ipsw, const char* infile, int blocksize, ipsw_send_cb send_callback, void* ctx);
int ipsw_extract_build_manifest(ipsw_archive_t ipsw, plist_t* buildmanifest, int *tss_enabled);
int ipsw_extract_restore_plist(ipsw_archive_t ipsw, plist_t* restore_plist);
int ipsw_list_contents(ipsw_archive_t ipsw, ipsw_list_cb cb, void *ctx);

int ipsw_get_signed_firmwares(const char* product, plist_t* firmwares);
int ipsw_download_fw(const char *fwurl, unsigned char* isha1, const char* todir, char** ipswfile);

int ipsw_get_latest_fw(plist_t version_data, const char* product, char** fwurl, unsigned char* sha1buf);
int ipsw_download_latest_fw(plist_t version_data, const char* product, const char* todir, char** ipswfile);

void ipsw_cancel(void);

#ifdef __cplusplus
}
#endif

#endif
