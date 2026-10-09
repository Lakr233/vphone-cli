#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __OBJC__
#import <Foundation/Foundation.h>
#endif

/// Sign all executable code in an extracted app. Returns a malloc-owned error or NULL.
char *vp_sign_app_for_install(const char *appPath, const char *certificatePath);
void vp_native_bootstrap_cached_binary(void);
void vp_native_confirm_cached_binary(void);
/// Returns -1 outside worker mode. Call before normal daemon bootstrap.
int vp_photos_worker_main(void);
void vp_photos_start(void);
/// 0 = launchd proxy, 1 = --io worker, -1 = invalid arguments.
int vp_native_process_mode(void);
int vp_native_run_proxy(void);
int vp_native_watch_proxy(void);
void vp_vcam_start(void);

/// Load the IOKit digitizer symbols used for multi-finger injection. Idempotent,
/// safe to call more than once; returns false (injection then stays a no-op)
/// on bases that do not expose the private symbols.
bool vp_hid_load(void);

/// Inject one two-finger digitizer event, the shape a trackpad pinch needs.
/// Phase is 0 = down, 1 = move, 3 = up; coordinates are normalized 0..1 with
/// the origin at the top-left. Neither icli's `input.touch` nor its
/// `touchSequence` can carry two fingers at once, which is why this exists.
void vp_hid_touch2(int phase, double x1, double y1, double x2, double y2);

/// Turn the display on without pressing a button. False when
/// SpringBoardServices has no SBSUndimScreen.
bool vp_screen_undim(void);

/// Ask launchd to shut the guest down and halt. Returns 0 once the request is
/// accepted, otherwise an errno value. Needs root.
int vp_system_halt(void);

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

/// Make `serial` the USB serial string the host sees, re-enumerating only when
/// it changes or `force` is set (`*changed`). Returns a malloc-owned error or NULL.
char *vp_usb_set_serial(const char *serial, bool force, bool *changed);

/// The guest's own USB serial, built from `/chosen` `chip-id` and
/// `unique-chip-id`. malloc-owned, or NULL when the device tree lacks either.
char *vp_usb_own_serial(void);

/// The names of the APFS snapshots of the volume mounted at `mount`, in
/// `*names` (free with `vp_apfs_snapshot_names_free`). Returns 0 or an errno value.
int vp_apfs_snapshot_list(const char *mount, char ***names, int *count);
void vp_apfs_snapshot_names_free(char **names, int count);

/// Append the names in one `fs_snapshot_list` batch of `entries` entries
/// (`ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME`) to `*names`, skipping names
/// already there and malformed entries; `*added` counts the new ones.
/// Returns 0 or ENOMEM.
int vp_apfs_snapshot_parse(const char *buffer, size_t size, int entries, char ***names, int *count, int *added);

/// Delete the snapshot `name` of the volume mounted at `mount`. Returns 0 or
/// an errno value. Needs root and com.apple.private.vfs.snapshot.
int vp_apfs_snapshot_delete(const char *mount, const char *name);

/// Register the Apple app bundle at `app_path`, inside the bundle container
/// `container_path`, with LaunchServices as a deletable system app. Returns a
/// malloc-owned error or NULL, with the registration call that worked in
/// `*method` (malloc-owned).
char *vp_ls_register_system_app(const char *app_path, const char *container_path, char **method);

#ifdef __OBJC__
/// Start an idempotent import of an uploaded image/video, or read its receipt.
NSDictionary *vp_photos_import(NSString *job, NSString *source, NSString *name);
NSDictionary *vp_photos_status(NSString *job);

/// The configured radians/second and the injected HID provider's heartbeat.
NSDictionary *vp_gyro_get(void);
BOOL vp_gyro_set(double x, double y, double z, bool enabled);
NSDictionary *vp_attitude_get(void);
BOOL vp_attitude_set(double roll, double pitch, double yaw, bool enabled);

/// Snapshot-local nested accessibility tree, using actual private iOS child links.
NSDictionary *vp_ax_hierarchy(int pid, int maxElements, int maxDepth, int timeoutMS);

/// `interface`'s IPv4 settings in configd's network preferences: `method`
/// (dhcp or manual), `address`, `subnet_mask`, `router`, `dns`, and `managed`
/// when vphoned wrote them. Nil with `*error` set when there is no such service.
NSDictionary *vp_network_ipv4_get(NSString *interface, NSString **error);

/// Set `interface` to `params` (`method` dhcp, or manual with `address`,
/// `subnet_mask`, `router` and `dns`), commit and apply. DHCP only undoes a
/// manual setting vphoned made. Returns the result of `vp_network_ipv4_get`
/// plus `changed`.
NSDictionary *vp_network_ipv4_set(NSString *interface, NSDictionary *params, NSString **error);

/// The guest's mDNS name (`local_host_name`, null when unset) and whether
/// vphoned set it (`managed`).
NSDictionary *vp_network_hostname_get(NSString **error);

/// Set the mDNS name, or with nil put back the one vphoned replaced. Only a
/// name vphoned set is ever undone. Returns the get result plus `changed`.
NSDictionary *vp_network_hostname_set(NSString *name, NSString **error);

/// Apply the preferences as they are, changing nothing: every process
/// watching them, configd's preferences monitor first, reads them again and
/// publishes what it derives from them.
BOOL vp_preferences_apply(NSString **error);
#endif
