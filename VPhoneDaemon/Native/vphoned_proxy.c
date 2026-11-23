#include "vphoned_session.h"

#include <crt_externs.h>
#include <errno.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

static volatile sig_atomic_t stopping = 0;
static const char *pending_update = "/var/root/Library/Caches/vphoned.api-v2.pending";

static void request_stop(int signal_number) {
    stopping = signal_number;
}

static int worker_fd(void) {
    int argc = *_NSGetArgc();
    char **argv = *_NSGetArgv();
    if (argc != 3 || strcmp(argv[1], "--io") != 0) return -1;
    char *end = NULL;
    long value = strtol(argv[2], &end, 10);
    if (!end || *end != '\0' || value < 3 || value > INT_MAX) return -1;
    return (int)value;
}

int vp_native_process_mode(void) {
    int argc = *_NSGetArgc();
    if (argc == 1) return 0;
    if (vp_session_arguments_present()) return 2;
    return worker_fd() >= 0 ? 1 : -1;
}

static void *watch_proxy(void *context) {
    int fd = (int)(intptr_t)context;
    char byte;
    while (read(fd, &byte, 1) < 0 && errno == EINTR) {}
    // Only the proxy owns the write end. Its death must not leave an
    // unaccounted worker holding the VSOCK ports open. Say so: jetsam kills
    // the proxy without a word, and this line is the only trace it leaves.
    static const char line[] = "vphoned: the proxy is gone; worker exiting\n";
    (void)write(STDERR_FILENO, line, sizeof(line) - 1);
    _exit(0);
}

// MARK: - Jetsam band

// Private in XNU's kern_memorystatus.h; vphoned holds
// com.apple.private.memorystatus.
extern int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t size);

enum { VPMemorystatusSetPriorityProperties = 2 };

typedef struct {
    int32_t priority;
    uint64_t user_data;
} vp_memorystatus_priority_properties;

// JETSAM_PRIORITY_DEFAULT: the band the kernel gives a process launchd does
// not manage, which is where the worker runs.
static const int32_t worker_jetsam_band = 180;

static void move_to_worker_jetsam_band(void) {
    // launchd starts the proxy as a daemon it has no jetsam entry for, in
    // band 40, which jetsam empties long before it reaches the foreground app
    // (100). The worker exits with the proxy, so a guest short of memory lost
    // its API every time: a 2 GiB iPadOS 27.0.1 guest started a new worker
    // 30 times in one day and, after the last kill, none at all.
    vp_memorystatus_priority_properties properties = {.priority = worker_jetsam_band, .user_data = 0};
    if (memorystatus_control(VPMemorystatusSetPriorityProperties, getpid(), 0, &properties,
                             sizeof(properties)) != 0) {
        fprintf(stderr, "vphoned proxy: could not move to jetsam band %d: %s\n", worker_jetsam_band,
                strerror(errno));
    }
}

int vp_native_watch_proxy(void) {
    int fd = worker_fd();
    if (fd < 0) return -1;
    pthread_attr_t attributes;
    if (pthread_attr_init(&attributes) != 0) return -1;
    int result = pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
    if (result == 0) result = pthread_attr_setstacksize(&attributes, 64 * 1024);
    pthread_t thread;
    if (result == 0) result = pthread_create(&thread, &attributes, watch_proxy, (void *)(intptr_t)fd);
    pthread_attr_destroy(&attributes);
    return result == 0 ? 0 : -1;
}

static void pause_before_retry(void) {
    // A fixed delay, however often the worker fails: during boot the worker
    // can exit several times, and a growing backoff kept the API down for
    // tens of seconds after the guest was otherwise ready.
    struct timespec remaining = {.tv_sec = 1, .tv_nsec = 0};
    while (!stopping && nanosleep(&remaining, &remaining) < 0 && errno == EINTR) {}
}

static void stop_worker(pid_t pid, int write_fd) {
    close(write_fd);
    kill(pid, SIGTERM);
    for (int tries = 0; tries < 30; tries++) {
        pid_t waited = waitpid(pid, NULL, WNOHANG);
        if (waited == pid || (waited < 0 && errno == ECHILD)) return;
        struct timespec delay = {.tv_sec = 0, .tv_nsec = 100000000};
        nanosleep(&delay, NULL);
    }
    kill(pid, SIGKILL);
    while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
}

int vp_native_run_proxy(void) {
    char executable[4096];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) != 0) return 1;
    move_to_worker_jetsam_band();

    struct sigaction action = {.sa_handler = request_stop};
    sigemptyset(&action.sa_mask);
    sigaction(SIGTERM, &action, NULL);
    sigaction(SIGINT, &action, NULL);

    while (!stopping) {
        int pipe_fds[2];
        if (pipe(pipe_fds) != 0) return 1;
        posix_spawn_file_actions_t file_actions;
        int error = vp_spawn_file_actions_init(&file_actions);
        if (error != 0) {
            close(pipe_fds[0]);
            close(pipe_fds[1]);
            return 1;
        }
        error = vp_spawn_file_actions_addclose(&file_actions, pipe_fds[1]);
        if (error != 0) {
            vp_spawn_file_actions_destroy(&file_actions);
            close(pipe_fds[0]);
            close(pipe_fds[1]);
            return 1;
        }

        char fd_argument[24];
        snprintf(fd_argument, sizeof(fd_argument), "%d", pipe_fds[0]);
        char *arguments[] = {executable, "--io", fd_argument, NULL};
        pid_t child = -1;
        error = vp_spawn(&child, executable, &file_actions, NULL, arguments, environ);
        vp_spawn_file_actions_destroy(&file_actions);
        close(pipe_fds[0]);
        if (error != 0) {
            fprintf(stderr, "vphoned proxy: posix_spawn failed: %s\n", strerror(error));
            close(pipe_fds[1]);
            pause_before_retry();
        } else {
            if (stopping) {
                stop_worker(child, pipe_fds[1]);
                break;
            }
            int status = 0;
            pid_t waited;
            do {
                waited = waitpid(child, &status, 0);
            } while (waited < 0 && errno == EINTR && !stopping);
            if (stopping) {
                if (waited == child) close(pipe_fds[1]);
                else stop_worker(child, pipe_fds[1]);
                break;
            }
            close(pipe_fds[1]);
            if (waited == child && WIFEXITED(status) && WEXITSTATUS(status) == 0) {
                // agent.apply_update exits the worker after installing the
                // cached binary. launchd restarts us into that new image.
                return 0;
            }
            if (access(pending_update, F_OK) == 0) {
                // A cached worker failed before binding. The next launchd
                // start falls back to the bundled binary.
                return 1;
            }
            if (waited != child) {
                fprintf(stderr, "vphoned proxy: waitpid %d failed: %s; retrying\n", child, strerror(errno));
            } else if (WIFSIGNALED(status)) {
                fprintf(stderr, "vphoned proxy: worker %d killed by signal %d; retrying\n", child, WTERMSIG(status));
            } else {
                fprintf(stderr, "vphoned proxy: worker %d exited with status %d; retrying\n", child, WEXITSTATUS(status));
            }
            pause_before_retry();
        }
    }
    return 0;
}
