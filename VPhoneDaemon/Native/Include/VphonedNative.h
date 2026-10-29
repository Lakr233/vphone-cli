#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <spawn.h>
#include <sys/types.h>
#ifdef __OBJC__
#import <Foundation/Foundation.h>
#endif

// MARK: - Spawning

// tvOS has posix_spawn and execv, and libSystem exports them there as on iOS,
// but the AppleTVOS SDK declares them unavailable. vphoned is built for both
// from one source, so it calls the same libSystem symbols under these names.
int vp_spawn(pid_t * _Nullable pid, const char * _Nonnull path,
    const posix_spawn_file_actions_t _Nullable * _Nullable actions,
    const posix_spawnattr_t _Nullable * _Nullable attributes,
    char * _Nullable const argv[_Nonnull], char * _Nullable const envp[_Nullable]) __asm__("_posix_spawn");
int vp_spawn_file_actions_init(posix_spawn_file_actions_t _Nullable * _Nonnull actions)
    __asm__("_posix_spawn_file_actions_init");
int vp_spawn_file_actions_destroy(posix_spawn_file_actions_t _Nullable * _Nonnull actions)
    __asm__("_posix_spawn_file_actions_destroy");
int vp_spawn_file_actions_addclose(posix_spawn_file_actions_t _Nullable * _Nonnull actions, int descriptor)
    __asm__("_posix_spawn_file_actions_addclose");
int vp_spawn_file_actions_adddup2(posix_spawn_file_actions_t _Nullable * _Nonnull actions, int descriptor, int target)
    __asm__("_posix_spawn_file_actions_adddup2");
int vp_spawn_file_actions_addopen(posix_spawn_file_actions_t _Nullable * _Nonnull actions, int descriptor,
    const char * _Nonnull path, int flags, mode_t mode) __asm__("_posix_spawn_file_actions_addopen");
int vp_spawnattr_init(posix_spawnattr_t _Nullable * _Nonnull attributes) __asm__("_posix_spawnattr_init");
int vp_spawnattr_destroy(posix_spawnattr_t _Nullable * _Nonnull attributes) __asm__("_posix_spawnattr_destroy");
int vp_spawnattr_setflags(posix_spawnattr_t _Nullable * _Nonnull attributes, short flags)
    __asm__("_posix_spawnattr_setflags");
int vp_execv(const char * _Nonnull path, char * _Nullable const argv[_Nonnull]) __asm__("_execv");

// Keep legacy bridge pointers explicitly unspecified: their Swift import stays
// unchanged while sharing this header with APIs that declare nonnull pointers.
// Do not assume nonnull for error strings or optional output parameters.

/// Sign all executable code in an extracted app. Returns a malloc-owned error or NULL.
char * _Null_unspecified vp_sign_app_for_install(const char * _Null_unspecified appPath, const char * _Null_unspecified certificatePath);
void vp_native_bootstrap_cached_binary(void);
void vp_native_confirm_cached_binary(void);
/// 0 = launchd proxy, 1 = --io worker, 2 = --session, -1 = invalid arguments.
int vp_native_process_mode(void);
int vp_native_run_proxy(void);
int vp_native_watch_proxy(void);

// MARK: - Scripting Sessions

/// Lead a process group of the session's own, and take its terminal, when it
/// has one, as the controlling terminal. A `--session` process calls this
/// before anything else runs: the worker ends a session by its group.
void vp_session_detach(void);

/// Replace this `--session exec <program>` process with the program, on the
/// session's terminal. Returns only when that fails, with the exit status.
int vp_session_exec(void);

/// Run one program and collect what it writes, for a script's `proc.run`.
/// `input` may be NULL. Both outputs are malloc-owned and always set on
/// success. Returns 0, or an errno value; `*status` is the wait status.
int vp_spawn_collect(const char * _Nonnull path, const char * _Nullable const * _Nonnull argv,
                     const char * _Nullable input, int * _Nonnull status,
                     char * _Nullable * _Nonnull output, char * _Nullable * _Nonnull errors);

/// Start a session process on a pseudo-terminal, as a session leader with the
/// terminal as its controlling one, so job control and ^C work. `program` is
/// NULL for the built-in REPL or an absolute path to run instead. Returns the
/// master descriptor and sets `*pid`, or -1 with errno set.
int vp_session_open(const char * _Nullable program, int columns, int rows, pid_t * _Nonnull pid);

/// Tell a session's terminal its new size and signal the foreground group.
void vp_session_resize(int master, int columns, int rows);

/// Close a session: hang the terminal up, SIGKILL what is left after `grace`
/// seconds, and reap it. Returns the wait status, or -1.
int vp_session_close(int master, pid_t pid, double grace);

/// Evaluate `source` in a one-shot session process, which ends with it.
/// Returns the malloc-owned JSON object the session printed, or NULL with
/// `*status` holding the wait status; `timeout` seconds kills it first.
char * _Nullable vp_session_evaluate(const char * _Nonnull source, double timeout, int * _Nonnull status);
void vp_vcam_start(void);
/// Publish the HomePod MiniDisplay HID device when firmware has its geometry.
/// The device and its callback queue live for the worker process lifetime.
void vp_homepod_display_start(void);
bool vp_homepod_display_is_configured(void);
/// Latest guest-written MiniDisplay frame and geometry, malloc-owned JSON.
char * _Null_unspecified vp_homepod_display_copy_json(void);
/// SoundBoardServices debug controls, available only on HomePod firmware.
bool vp_homepod_debug_available(void);
/// Validated operation result or error, returned as malloc-owned JSON.
char * _Null_unspecified vp_homepod_debug_copy_json(const char * _Null_unspecified operation, const char * _Null_unspecified arguments_json);

/// Load the IOKit digitizer symbols used for multi-finger injection. Idempotent,
/// safe to call more than once; returns false (injection then stays a no-op)
/// on bases that do not expose the private symbols.
bool vp_hid_load(void);
/// A keyboard/consumer hold transition, including KeyboardLongPress on release.
bool vp_hid_keyboard_hold(uint16_t page, uint16_t usage, bool down);

/// Inject one two-finger digitizer event, the shape a trackpad pinch needs.
/// Phase is 0 = down, 1 = move, 3 = up; coordinates are normalized 0..1 with
/// the origin at the top-left. Neither icli's `input.touch` nor its
/// `touchSequence` can carry two fingers at once, which is why this exists.
void vp_hid_touch2(int phase, double x1, double y1, double x2, double y2);

/// Inject one finger that started at a screen edge, with the digitizer edge
/// flags UIKit's screen-edge gestures (home, Control Center) require. `edge` is
/// the host's `_VZTouch` swipeAim code: 1 top, 2 bottom, 4 right, 8 left.
/// Phase and coordinates as for vp_hid_touch2.
void vp_hid_touch_edge(int phase, double x, double y, int edge);

/// Turn the display on without pressing a button. False when
/// SpringBoardServices has no SBSUndimScreen.
bool vp_screen_undim(void);
/// Call `touched` on a private queue when a finger lands on the screen while
/// SpringBoard has it blanked, at most every half second: the tap a phone's
/// touch controller reports as a wake gesture.
void vp_tap_to_wake_start(void (* _Nonnull touched)(void));
bool vp_device_pose_set(int deviceOrientation, int hingeState, int tabletopPose);

/// Ask launchd to shut the guest down and halt. Returns 0 once the request is
/// accepted, otherwise an errno value. Needs root.
int vp_system_halt(void);

/// Whether timed sets the clock itself (Settings' Set Automatically): 1 on,
/// 0 off, -1 when CoreTime does not offer it, -2 when timed did not answer.
int vp_clock_automatic(void);

/// Turn timed's automatic time on or off, as Set Automatically does for the
/// clock. timed sends no reply, so the caller reads it back. 0 once sent, -1
/// when CoreTime does not offer it, -2 when timed did not take it within 3
/// seconds. Needs com.apple.timed.
int vp_clock_set_automatic(bool enabled);

/// Offer timed `unixTime`, good to `uncertainty` seconds, as an NTP result.
/// timed weighs it against what it has and sets the clock itself; nothing is
/// returned, so the caller reads the clock. 0 once sent, -1 when CoreTime has
/// no TMSetSourceTime, -2 when timed did not take it within 3 seconds. Needs
/// com.apple.timed and NTP in com.apple.timed.sources.
int vp_clock_offer(double unixTime, double uncertainty);

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
bool vp_process_usage(int pid, VPProcessUsage * _Null_unspecified usage);

/// Make `serial` the USB serial string the host sees, re-enumerating only when
/// it changes or `force` is set (`*changed`). Returns a malloc-owned error or NULL.
char * _Null_unspecified vp_usb_set_serial(const char * _Null_unspecified serial, bool force, bool * _Null_unspecified changed);

/// The guest's own USB serial, built from `/chosen` `chip-id` and
/// `unique-chip-id`. malloc-owned, or NULL when the device tree lacks either.
char * _Null_unspecified vp_usb_own_serial(void);

/// The names of the APFS snapshots of the volume mounted at `mount`, in
/// `*names` (free with `vp_apfs_snapshot_names_free`). Returns 0 or an errno value.
int vp_apfs_snapshot_list(const char * _Null_unspecified mount, char * _Null_unspecified * _Null_unspecified * _Null_unspecified names, int * _Null_unspecified count);
void vp_apfs_snapshot_names_free(char * _Null_unspecified * _Null_unspecified names, int count);

/// Append the names in one `fs_snapshot_list` batch of `entries` entries
/// (`ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME`) to `*names`, skipping names
/// already there and malformed entries; `*added` counts the new ones.
/// Returns 0 or ENOMEM.
int vp_apfs_snapshot_parse(const char * _Null_unspecified buffer, size_t size, int entries, char * _Null_unspecified * _Null_unspecified * _Null_unspecified names, int * _Null_unspecified count, int * _Null_unspecified added);

/// Delete the snapshot `name` of the volume mounted at `mount`. Returns 0 or
/// an errno value. Needs root and com.apple.private.vfs.snapshot.
int vp_apfs_snapshot_delete(const char * _Null_unspecified mount, const char * _Null_unspecified name);

/// Register the Apple app bundle at `app_path`, inside the bundle container
/// `container_path`, with LaunchServices as a deletable system app. Returns a
/// malloc-owned error or NULL, with the registration call that worked in
/// `*method` (malloc-owned).
char * _Null_unspecified vp_ls_register_system_app(const char * _Null_unspecified app_path, const char * _Null_unspecified container_path, char * _Null_unspecified * _Null_unspecified method);
char * _Null_unspecified vp_ls_system_app_state(const char * _Null_unspecified bundle_id);
char * _Null_unspecified vp_ls_unregister_system_app(const char * _Null_unspecified bundle_id, const char * _Null_unspecified app_path);

#ifdef __OBJC__
/// Read-only HID service geometry and report descriptors; no event is sent.
NSDictionary<NSString *, id> * _Nonnull vp_hid_input_devices(void);
/// The configured radians/second and the injected HID provider's heartbeat.
NSDictionary * _Null_unspecified vp_gyro_get(void);
BOOL vp_gyro_set(double x, double y, double z, bool enabled);
/// The backboardd HID gravity provider used by display.rotation.
NSDictionary * _Nonnull vp_accelerometer_get(void);
BOOL vp_accelerometer_set_orientation(NSString * _Nonnull spec);
/// The virtual hinge HID provider behind display.posture: the fold angle
/// (degrees, closed 0) and whether the provider in backboardd is enumerated
/// and current.
NSDictionary * _Nonnull vp_hinge_get(void);
/// Every display-ish IOService object the guest published, with its small
/// properties: what the display stack bound, for the foldable display work.
NSArray * _Nonnull vp_display_probe(void);
/// Read-only CoreAnimation display modes and capability surface.
NSDictionary<NSString *, id> * _Nonnull vp_display_modes(void);
NSDictionary<NSString *, id> * _Nonnull vp_external_display_status(void);
NSDictionary<NSString *, id> * _Nonnull vp_external_display_diagnostics(void);
NSDictionary<NSString *, id> * _Nonnull vp_external_display_configure(BOOL enabled, NSInteger width, NSInteger height);
NSData * _Nullable vp_external_display_frame(NSString * _Nullable * _Nullable error);
NSDictionary<NSString *, id> * _Nonnull vp_device_pose_get(void);
BOOL vp_hinge_set(double angleDegrees);
/// Sweep the hinge to `targetDegrees` the way Apple's Duo tooling does: over
/// a profiled transition (0 continuous fold, 1 fade-in-out), `durationMs` < 0
/// the per-direction default (opening faster than closing), 0 an instant
/// swap. Returns false on an out-of-range request.
BOOL vp_hinge_sweep(double targetDegrees, double durationMs, int profile);
NSDictionary * _Null_unspecified vp_attitude_get(void);
BOOL vp_attitude_set(double roll, double pitch, double yaw, bool enabled);

/// Snapshot-local nested accessibility tree, using actual private iOS child links.
NSDictionary * _Null_unspecified vp_ax_hierarchy(int pid, int maxElements, int maxDepth, int timeoutMS);

/// `interface`'s IPv4 settings in configd's network preferences: `method`
/// (dhcp or manual), `address`, `subnet_mask`, `router`, `dns`, and `managed`
/// when vphoned wrote them. Nil with `*error` set when there is no such service.
NSDictionary * _Null_unspecified vp_network_ipv4_get(NSString * _Null_unspecified interface, NSString * _Null_unspecified * _Null_unspecified error);

/// Set `interface` to `params` (`method` dhcp, or manual with `address`,
/// `subnet_mask`, `router` and `dns`), commit and apply. DHCP only undoes a
/// manual setting vphoned made. Returns the result of `vp_network_ipv4_get`
/// plus `changed`.
NSDictionary * _Null_unspecified vp_network_ipv4_set(NSString * _Null_unspecified interface, NSDictionary * _Null_unspecified params, NSString * _Null_unspecified * _Null_unspecified error);

/// The guest's mDNS name (`local_host_name`, null when unset) and whether
/// vphoned set it (`managed`).
NSDictionary * _Null_unspecified vp_network_hostname_get(NSString * _Null_unspecified * _Null_unspecified error);

/// Set the mDNS name, or with nil put back the one vphoned replaced. Only a
/// name vphoned set is ever undone. Returns the get result plus `changed`.
NSDictionary * _Null_unspecified vp_network_hostname_set(NSString * _Null_unspecified name, NSString * _Null_unspecified * _Null_unspecified error);

/// Apply the preferences as they are, changing nothing: every process
/// watching them, configd's preferences monitor first, reads them again and
/// publishes what it derives from them.
BOOL vp_preferences_apply(NSString * _Null_unspecified * _Null_unspecified error);
#endif
