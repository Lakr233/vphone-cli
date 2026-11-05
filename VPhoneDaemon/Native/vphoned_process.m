#import "Include/VphonedNative.h"
#include <mach/mach_time.h>
#include <sys/resource.h>
#include <sys/sysctl.h>

// libproc is not in the iOS SDK; this is its stable libsystem_kernel export.
extern int proc_pid_rusage(int pid, int flavor, rusage_info_t *buffer);

bool vp_process_usage(int pid, VPProcessUsage *usage) {
    memset(usage, 0, sizeof(*usage));
    usage->pid = pid;

    struct kinfo_proc info;
    size_t size = sizeof(info);
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0 || size == 0) return false;
    usage->ppid = info.kp_eproc.e_ppid;
    usage->uid = info.kp_eproc.e_ucred.cr_uid;
    usage->start_time = (double)info.kp_proc.p_starttime.tv_sec + info.kp_proc.p_starttime.tv_usec / 1e6;

    // Task statistics need the target to be inspectable; a failure here still
    // leaves the identity fields above valid.
    struct rusage_info_v4 rusage;
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&rusage) == 0) {
        static mach_timebase_info_data_t timebase;
        if (timebase.denom == 0) mach_timebase_info(&timebase);
        uint64_t ticks = rusage.ri_user_time + rusage.ri_system_time;
        usage->cpu_seconds = (double)ticks * timebase.numer / timebase.denom / 1e9;
        usage->footprint_bytes = rusage.ri_phys_footprint;
        usage->resident_bytes = rusage.ri_resident_size;
        usage->has_task_info = true;
    }
    return true;
}
