/*
 * deviceinterfaced.c
 * Control deviceinterfaced while accessing restore devices on macOS
 *
 * Copyright (c) 2026 libimobiledevice contributors. All Rights Reserved.
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

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#include <libimobiledevice-glue/thread.h>

#include "deviceinterfaced.h"
#include "log.h"

#define DEVICEINTERFACED_LABEL "com.apple.deviceinterfaced"
#define DEVICEINTERFACED_TARGET "system/" DEVICEINTERFACED_LABEL
#define DEVICEINTERFACED_PLIST "/Library/Apple/System/Library/PrivateFrameworks/DeviceInterface.framework/Support/com.apple.deviceinterfaced.plist"
#define SUDO_PATH "/usr/bin/sudo"
#define LAUNCHCTL_PATH "/bin/launchctl"
#define SUDO_PROMPT "[sudo] password to manage " DEVICEINTERFACED_LABEL ": "
/* "sudo" "-p" prompt "--" "/bin/launchctl" + subcommand args (max observed: 3) + NULL */
#define LAUNCHCTL_ARGV_MAX 10

extern char **environ;

enum deviceinterfaced_control_state {
	DEVICEINTERFACED_INACTIVE,
	DEVICEINTERFACED_BOOTED_OUT,
	DEVICEINTERFACED_KILLING,
	DEVICEINTERFACED_NEEDS_KICKSTART
};

static int cleanup_registered = 0;
static enum deviceinterfaced_control_state control_state = DEVICEINTERFACED_INACTIVE;
static atomic_bool stop_killer;
static THREAD_T killer_thread = THREAD_T_NULL;

/*
 * Runs "launchctl <args...>". Read-only queries (e.g. "print") never need
 * elevated privileges and are run directly. State-changing subcommands
 * ("bootout", "bootstrap", "kickstart", "kill") act on a system-domain
 * LaunchDaemon and require root, so they are wrapped with "sudo" instead of
 * requiring the whole idevicerestore process to run as root. sudo prompts
 * for the password on the controlling terminal (/dev/tty) directly, so
 * redirecting stdout/stderr below does not hide the prompt; it is only
 * suppressed here to keep launchctl's own (uninteresting) output quiet.
 * Any sudo diagnostic (e.g. "a password is required") is left visible on
 * stderr for privileged calls so the user can see why it failed.
 */
static int launchctl_run(char *const args[], int privileged)
{
	posix_spawn_file_actions_t actions;
	char *argv[LAUNCHCTL_ARGV_MAX];
	const char *program;
	pid_t pid;
	pid_t waited;
	int error;
	int status;
	int argc = 0;
	int i;

	if (privileged) {
		argv[argc++] = SUDO_PATH;
		argv[argc++] = "-p";
		argv[argc++] = SUDO_PROMPT;
		argv[argc++] = "--";
		argv[argc++] = LAUNCHCTL_PATH;
		program = SUDO_PATH;
	} else {
		argv[argc++] = LAUNCHCTL_PATH;
		program = LAUNCHCTL_PATH;
	}
	for (i = 0; args[i] != NULL; i++) {
		if (argc >= LAUNCHCTL_ARGV_MAX - 1) {
			return -ENAMETOOLONG;
		}
		argv[argc++] = args[i];
	}
	argv[argc] = NULL;

	error = posix_spawn_file_actions_init(&actions);
	if (error != 0) {
		return -error;
	}
	error = posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
	if (error == 0 && !privileged) {
		error = posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
	}
	if (error != 0) {
		posix_spawn_file_actions_destroy(&actions);
		return -error;
	}

	error = posix_spawn(&pid, program, &actions, NULL, argv, environ);
	posix_spawn_file_actions_destroy(&actions);
	if (error != 0) {
		return -error;
	}

	do {
		waited = waitpid(pid, &status, 0);
	} while (waited < 0 && errno == EINTR);
	if (waited < 0) {
		return -errno;
	}

	if (!WIFEXITED(status)) {
		return -EIO;
	}
	return WEXITSTATUS(status);
}

static void log_launchctl_failure(const char *operation, int status)
{
	if (status < 0) {
		logger(LL_ERROR, "Could not %s " DEVICEINTERFACED_LABEL ": %s.\n", operation, strerror(-status));
	} else {
		logger(LL_ERROR, "Could not %s " DEVICEINTERFACED_LABEL ": launchctl exited with status %d.\n", operation, status);
	}
}

static int service_is_loaded(int *loaded)
{
	char *const argv[] = {
		"print", DEVICEINTERFACED_TARGET, NULL
	};
	int status = launchctl_run(argv, 0);

	if (status < 0) {
		return status;
	}
	*loaded = (status == 0);
	return 0;
}

static int wait_for_service_to_unload(void)
{
	int i;
	int loaded;

	for (i = 0; i < 100; i++) {
		int status = service_is_loaded(&loaded);
		if (status < 0) {
			return status;
		}
		if (!loaded) {
			return 0;
		}
		usleep(50000);
	}
	return -ETIMEDOUT;
}

static void *kill_service(void *data)
{
	char *const argv[] = {
		"kill", "SIGKILL", DEVICEINTERFACED_TARGET, NULL
	};

	(void)data;
	while (!atomic_load_explicit(&stop_killer, memory_order_relaxed)) {
		launchctl_run(argv, 1);
		usleep(100000);
	}
	return NULL;
}

void deviceinterfaced_control_stop(void)
{
	int status;

	if (control_state == DEVICEINTERFACED_KILLING) {
		atomic_store_explicit(&stop_killer, 1, memory_order_relaxed);
		status = thread_join(killer_thread);
		if (status != 0) {
			logger(LL_ERROR, "Could not stop " DEVICEINTERFACED_LABEL " termination loop: %s.\n", strerror(status));
			return;
		}
		killer_thread = THREAD_T_NULL;
		control_state = DEVICEINTERFACED_NEEDS_KICKSTART;
	}

	if (control_state == DEVICEINTERFACED_BOOTED_OUT) {
		char *const bootstrap_argv[] = {
			"bootstrap", "system", DEVICEINTERFACED_PLIST, NULL
		};
		status = launchctl_run(bootstrap_argv, 1);
		if (status != 0) {
			log_launchctl_failure("bootstrap", status);
			logger(LL_ERROR, "Run 'sudo launchctl bootstrap system " DEVICEINTERFACED_PLIST "' to load it.\n");
			return;
		}
		control_state = DEVICEINTERFACED_NEEDS_KICKSTART;
	}

	if (control_state == DEVICEINTERFACED_NEEDS_KICKSTART) {
		char *const kickstart_argv[] = {
			"kickstart", DEVICEINTERFACED_TARGET, NULL
		};
		status = launchctl_run(kickstart_argv, 1);
		if (status != 0) {
			log_launchctl_failure("kickstart", status);
			logger(LL_ERROR, "Run 'sudo launchctl kickstart " DEVICEINTERFACED_TARGET "' to start it.\n");
			return;
		}
		control_state = DEVICEINTERFACED_INACTIVE;
		logger(LL_INFO, "Restored " DEVICEINTERFACED_LABEL ".\n");
	}
}

int deviceinterfaced_control_start(void)
{
	char *const bootout_argv[] = {
		"bootout", DEVICEINTERFACED_TARGET, NULL
	};
	int loaded;
	int status;

	if (control_state != DEVICEINTERFACED_INACTIVE) {
		return 0;
	}

	if (!cleanup_registered) {
		if (atexit(deviceinterfaced_control_stop) != 0) {
			logger(LL_ERROR, "Could not register " DEVICEINTERFACED_LABEL " cleanup.\n");
			return -1;
		}
		cleanup_registered = 1;
	}

	status = service_is_loaded(&loaded);
	if (status < 0) {
		log_launchctl_failure("query", status);
		return -1;
	}
	if (!loaded) {
		logger(LL_INFO, DEVICEINTERFACED_LABEL " is not loaded.\n");
		return 0;
	}

	status = launchctl_run(bootout_argv, 1);
	if (status == 0) {
		control_state = DEVICEINTERFACED_BOOTED_OUT;
		status = wait_for_service_to_unload();
		if (status < 0) {
			if (status == -ETIMEDOUT) {
				logger(LL_ERROR, "Timed out waiting for " DEVICEINTERFACED_LABEL " to stop.\n");
			} else {
				log_launchctl_failure("query", status);
			}
			return -1;
		}
		logger(LL_INFO, "Booted out " DEVICEINTERFACED_LABEL " for the duration of the restore.\n");
		return 0;
	}
	if (status < 0) {
		log_launchctl_failure("boot out", status);
		return -1;
	}

	logger(LL_WARNING, "Could not boot out " DEVICEINTERFACED_LABEL " (launchctl exit status %d); terminating it while the restore runs.\n", status);
	atomic_store_explicit(&stop_killer, 0, memory_order_relaxed);
	status = thread_new(&killer_thread, kill_service, NULL);
	if (status != 0) {
		logger(LL_ERROR, "Could not start " DEVICEINTERFACED_LABEL " termination loop: %s.\n", strerror(status));
		return -1;
	}
	control_state = DEVICEINTERFACED_KILLING;
	return 0;
}
