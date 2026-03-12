#ifndef VPHONE_RESTORE_BRIDGE_H
#define VPHONE_RESTORE_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*vphone_restore_log_cb_t)(int level, const char* message, void* context);
typedef void (*vphone_restore_progress_cb_t)(int step, double progress, void* context);

struct vphone_restore_options {
	const char* ipsw_path;
	const char* cache_dir;
	const char* udid;
	uint64_t ecid;
	int flags;
	vphone_restore_log_cb_t log_cb;
	vphone_restore_progress_cb_t progress_cb;
	void* context;
};

enum {
	VPHONE_RESTORE_FLAG_SHSH_ONLY = 1 << 0,
	VPHONE_RESTORE_FLAG_ERASE = 1 << 1,
	VPHONE_RESTORE_FLAG_KEEP_PERS = 1 << 2,
	VPHONE_RESTORE_FLAG_DEBUG = 1 << 3
};

enum {
	VPHONE_IRECV_MODE_ANY = 0,
	VPHONE_IRECV_MODE_DFU = 1,
	VPHONE_IRECV_MODE_RECOVERY = 2
};

enum {
	VPHONE_IRECV_SEND_OPT_NONE = 0,
	VPHONE_IRECV_SEND_OPT_DFU_NOTIFY_FINISH = 1 << 0
};

int vphone_restore_run(const struct vphone_restore_options* options);
const char* vphone_irecv_error_string(int error);
int vphone_irecv_send_file(const char* path, uint64_t ecid, int has_ecid, int mode, uint32_t options);
int vphone_irecv_send_command(const char* command, uint64_t ecid, int has_ecid, int mode);
int vphone_irecv_wait_for_mode(uint64_t ecid, int has_ecid, int mode, int timeout_ms);

#ifdef __cplusplus
}
#endif

#endif
