#include "vphone_restore_bridge.h"

#include <curl/curl.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "common.h"
#include "idevicerestore.h"
#include "log.h"

struct vphone_restore_runtime {
	vphone_restore_log_cb_t log_cb;
	vphone_restore_progress_cb_t progress_cb;
	void* context;
};

static struct vphone_restore_runtime* vphone_restore_active_runtime = NULL;

static void vphone_restore_logger(enum loglevel level, const char* fmt, va_list ap)
{
	if (!vphone_restore_active_runtime || !vphone_restore_active_runtime->log_cb) {
		return;
	}

	char buffer[4096];
	vsnprintf(buffer, sizeof(buffer), fmt, ap);
	vphone_restore_active_runtime->log_cb((int)level, buffer, vphone_restore_active_runtime->context);
}

static void vphone_restore_progress(int step, double progress, void* userdata)
{
	struct vphone_restore_runtime* runtime = (struct vphone_restore_runtime*)userdata;
	if (!runtime || !runtime->progress_cb) {
		return;
	}
	runtime->progress_cb(step, progress, runtime->context);
}

int vphone_restore_run(const struct vphone_restore_options* options)
{
	if (!options || !options->ipsw_path || !options->ipsw_path[0]) {
		return -1;
	}

	struct idevicerestore_client_t* client = idevicerestore_client_new();
	if (!client) {
		return -1;
	}

	struct vphone_restore_runtime runtime = {
		.log_cb = options->log_cb,
		.progress_cb = options->progress_cb,
		.context = options->context,
	};
	vphone_restore_active_runtime = &runtime;

	logger_set_logfile("NONE");
	logger_set_print_func(vphone_restore_logger);

	if (options->flags & VPHONE_RESTORE_FLAG_DEBUG) {
		client->flags |= FLAG_DEBUG;
		client->debug_level = 1;
		log_level = LL_DEBUG;
	}
	if (options->flags & VPHONE_RESTORE_FLAG_SHSH_ONLY) {
		client->flags |= FLAG_SHSHONLY;
	}
	if (options->flags & VPHONE_RESTORE_FLAG_ERASE) {
		client->flags |= FLAG_ERASE;
	}
	if (options->flags & VPHONE_RESTORE_FLAG_KEEP_PERS) {
		client->flags |= FLAG_KEEP_PERS;
	}

	idevicerestore_set_ipsw(client, options->ipsw_path);
	if (options->cache_dir && options->cache_dir[0]) {
		idevicerestore_set_cache_path(client, options->cache_dir);
	}
	if (options->udid && options->udid[0]) {
		idevicerestore_set_udid(client, options->udid);
	}
	if (options->ecid != 0) {
		idevicerestore_set_ecid(client, options->ecid);
	}
	idevicerestore_set_progress_callback(client, vphone_restore_progress, &runtime);

	curl_global_init(CURL_GLOBAL_ALL);
	int result = idevicerestore_start(client);
	curl_global_cleanup();

	idevicerestore_client_free(client);
	logger_set_print_func(NULL);
	vphone_restore_active_runtime = NULL;
	return result;
}
