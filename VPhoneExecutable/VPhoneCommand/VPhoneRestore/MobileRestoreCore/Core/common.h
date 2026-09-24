/*
 * common.h
 * Misc functions used in idevicerestore
 *
 * Copyright (c) 2012-2019 Nikias Bassen. All Rights Reserved.
 * Copyright (c) 2012 Martin Szulecki. All Rights Reserved.
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

#ifndef IDEVICERESTORE_COMMON_H
#define IDEVICERESTORE_COMMON_H

#ifdef __cplusplus
extern "C" {
#endif

#ifdef HAVE_CONFIG_H
#include <config.h>
#endif

#include <inttypes.h>
#include <unistd.h>

#include <plist/plist.h>
#include <libirecovery.h>
#include <libimobiledevice-glue/thread.h>

#include "idevicerestore.h"
#include "log.h"

#define _MODE_UNKNOWN         0
#define _MODE_WTF             1
#define _MODE_DFU             2
#define _MODE_RECOVERY        3
#define _MODE_RESTORE         4
#define _MODE_NORMAL          5
#define _MODE_PORTDFU         6

#define MODE_UNKNOWN  &idevicerestore_modes[_MODE_UNKNOWN]
#define MODE_WTF      &idevicerestore_modes[_MODE_WTF]
#define MODE_DFU      &idevicerestore_modes[_MODE_DFU]
#define MODE_RECOVERY &idevicerestore_modes[_MODE_RECOVERY]
#define MODE_RESTORE  &idevicerestore_modes[_MODE_RESTORE]
#define MODE_NORMAL   &idevicerestore_modes[_MODE_NORMAL]
#define MODE_PORTDFU  &idevicerestore_modes[_MODE_PORTDFU]

#define FLAG_QUIT            1

#define CPFM_FLAG_SECURITY_MODE 1 << 0
#define CPFM_FLAG_PRODUCTION_MODE 1 << 1

#define IBOOT_FLAG_IMAGE4_AWARE  1 << 2
#define IBOOT_FLAG_EFFECTIVE_SECURITY_MODE 1 << 3
#define IBOOT_FLAG_EFFECTIVE_PRODUCTION_MODE 1 << 4

#define USER_AGENT_STRING "InetURL/1.0"

struct dfu_client_t;
struct normal_client_t;
struct restore_client_t;
struct recovery_client_t;
struct ipsw_archive;

typedef struct ipsw_archive* ipsw_archive_t;

struct idevicerestore_mode_t {
	int index;
	const char* string;
};

struct idevicerestore_client_t {
	int flags;
	int debug_level;
	plist_t tss;
	plist_t tss_localpolicy;
	plist_t tss_recoveryos_root_ticket;
	char* tss_url;
	plist_t version_data;
	uint64_t ecid;
	unsigned char* nonce;
	int nonce_size;
	int image4supported;
	plist_t build_manifest;
	plist_t firmware_preflight_info;
	plist_t preflight_info;
	plist_t parameters;
	char* udid;
	char* srnm;
	ipsw_archive_t ipsw;
	struct dfu_client_t* dfu;
	struct restore_client_t* restore;
	struct recovery_client_t* recovery;
	irecv_device_t device;
	struct idevicerestore_mode_t* mode;
	char* version;
	char* build;
	char* device_version;
	char* device_build;
	int build_major;
	char* restore_boot_args;
	char* cache_dir;
	unsigned char* root_ticket;
	int root_ticket_len;
	idevicerestore_progress_cb_t progress_cb;
	void* progress_cb_data;
	irecv_device_event_context_t irecv_e_ctx;
	void* idevice_e_ctx;
	mutex_t device_event_mutex;
	cond_t device_event_cond;
	int ignore_device_add_events;
	plist_t macos_variant;
	plist_t recovery_variant;
	char* restore_variant;
	char* filesystem;
	int delete_fs;
	int async_err;
};

extern int global_quit_flag;

extern struct idevicerestore_mode_t idevicerestore_modes[];

extern int idevicerestore_debug;

void set_banner_funcs(void (*showfunc)(const char*), void (*hidefunc)(void));
void show_banner(const char* text);
void hide_banner();

struct progress_info_entry {
	uint32_t tag;
	char* label;
	double progress;
	int lastprog;
};
void set_update_progress_func(void (*func)(struct progress_info_entry** list, int count));
void set_progress_granularity(double granularity);
uint32_t progress_get_next_tag(void);
void progress_reset_tag(void);
void register_progress(uint32_t tag, const char* label);
void set_progress(uint32_t tag, double progress);
void finalize_progress(uint32_t tag);
void print_progress_bar(const char* prefix, double progress);

struct tuple {
	int idx;
	int len;
	int plen;
};

int process_text_lines(const char* text, int maxwidth, struct tuple** lines_out, int* maxlen_out);

void set_prompt_func(int (*func)(const char* title, const char* text));
int prompt_user(const char* title, const char* message);

int read_file(const char* filename, void** data, size_t* size);
int write_file(const char* filename, const void* data, size_t size);

char *generate_guid(void);

#ifdef WIN32
#include <windows.h>
#include <unistd.h>
#define __mkdir(path, mode) mkdir(path)
#ifndef sleep
#define sleep(x) Sleep(x*1000)
#endif
#define __usleep(x) Sleep(x/1000)
#else
#include <sys/stat.h>
#define __mkdir(path, mode) mkdir(path, mode)
#define __usleep(x) usleep(x)
#endif

#ifndef S_IFLNK
#define S_IFLNK 0120000
#endif
#ifndef S_ISLNK
#define S_ISLNK(m) (((m) & S_IFMT) == S_IFLNK)
#endif

int mkdir_with_parents(const char *dir, int mode);

char *get_temp_filename(const char *prefix);

void idevicerestore_progress(struct idevicerestore_client_t* client, int step, double progress);

#ifndef HAVE_STRSEP
char* strsep(char** strp, const char* delim);
#endif

#ifndef HAVE_REALPATH
char* realpath(const char *filename, char *resolved_name);
#endif

void get_user_input(char *buf, int maxlen, int secure);

const char* path_get_basename(const char* path);

#ifdef __cplusplus
}
#endif

#endif
