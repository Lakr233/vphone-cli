#pragma once
#include <stdbool.h>
#include <stdint.h>
#ifdef __OBJC__
#import <Foundation/Foundation.h>
#endif

/// Sign all executable code in an extracted app. Returns a malloc-owned error or NULL.
char *vp_sign_app_for_install(const char *appPath, const char *certificatePath);
void vp_native_bootstrap_cached_binary(void);
void vp_native_confirm_cached_binary(void);
/// 0 = launchd proxy, 1 = --io worker, -1 = invalid arguments.
int vp_native_process_mode(void);
int vp_native_run_proxy(void);
int vp_native_watch_proxy(void);
void vp_vcam_start(void);

typedef struct {
    int32_t pid;
    int32_t ppid;
    uint32_t uid;
    double start_time;
    double cpu_seconds;
    uint64_t footprint_bytes;
    uint64_t resident_bytes;
    bool has_task_info;
} VPProcessUsage;

/// Identity and resource usage for one process. Returns false when the process is gone.
bool vp_process_usage(int pid, VPProcessUsage *usage);
