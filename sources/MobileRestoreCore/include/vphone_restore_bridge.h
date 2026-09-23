/*
 * vphone_restore_bridge.h
 *
 * The one public header of MobileRestoreCore, and the only thing in this
 * target's include/ directory. Everything else here — idevicerestore's own
 * sources, config.h and the libzip stub — is private to the target, so a
 * Swift caller sees this file and nothing else.
 *
 * This is what stands in for upstream's main(): src/idevicerestore.c is
 * compiled with IDEVICERESTORE_NOMAIN, so its argv parsing, usage text and
 * signal handling are gone, and vphone_restore_run() below sets up the same
 * client object from a struct instead of from a command line.
 *
 * One restore at a time. idevicerestore keeps its mode, its log level and its
 * quit flag in process globals, so a second concurrent call would fight the
 * first over them; vphone_restore_run() refuses with
 * VPHONE_RESTORE_E_BUSY rather than letting that happen.
 */

#ifndef VPHONE_RESTORE_BRIDGE_H
#define VPHONE_RESTORE_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* --- Logging ----------------------------------------------------------- */

/*
 * The level on a log line, matching idevicerestore's own `enum loglevel`
 * one for one. Lower is more severe.
 */
typedef enum {
    VPHONE_RESTORE_LOG_ERROR = 0,
    VPHONE_RESTORE_LOG_WARNING = 1,
    VPHONE_RESTORE_LOG_NOTICE = 2,
    VPHONE_RESTORE_LOG_INFO = 3,
    VPHONE_RESTORE_LOG_VERBOSE = 4,
    VPHONE_RESTORE_LOG_DEBUG = 5
} vphone_restore_log_level_t;

/*
 * Called for every line idevicerestore produces, with the trailing newline
 * left on. `message` is owned by the bridge and is only valid for the
 * duration of the call, so copy anything you keep.
 *
 * It is called from whichever thread produced the line, and idevicerestore
 * does its transfers on worker threads, so an implementation has to be safe
 * to call concurrently.
 */
typedef void (*vphone_restore_log_cb_t)(int level, const char *message, void *context);

/* --- Progress ---------------------------------------------------------- */

/*
 * `step` is one of the values below; `step_progress` runs 0.0 to 1.0 within
 * that step. Same threading rules as the log callback.
 */
typedef void (*vphone_restore_progress_cb_t)(int step, double step_progress, void *context);

/* idevicerestore.h's RESTORE_STEP_* enum, repeated so a caller need not see it. */
#define VPHONE_RESTORE_STEP_DETECT 0
#define VPHONE_RESTORE_STEP_PREPARE 1
#define VPHONE_RESTORE_STEP_UPLOAD_FS 2
#define VPHONE_RESTORE_STEP_VERIFY_FS 3
#define VPHONE_RESTORE_STEP_FLASH_FW 4
#define VPHONE_RESTORE_STEP_FLASH_BB 5
#define VPHONE_RESTORE_STEP_FUD 6
#define VPHONE_RESTORE_STEP_UPLOAD_IMG 7

/* A short label for a step, or "unknown" for a value not listed above. */
const char *vphone_restore_step_name(int step);

/* --- Result codes ------------------------------------------------------ */

/*
 * 0 is success. A negative value from idevicerestore_start() is passed
 * straight through, and those are small negatives (-1, -2, …), so the
 * bridge's own failures sit far below them where they cannot be confused.
 */
#define VPHONE_RESTORE_OK 0
#define VPHONE_RESTORE_E_INVALID_ARG (-1001)
#define VPHONE_RESTORE_E_NO_RESTORE_DIR (-1002)
#define VPHONE_RESTORE_E_TICKET (-1003)
#define VPHONE_RESTORE_E_OUT_OF_MEMORY (-1004)
#define VPHONE_RESTORE_E_BUSY (-1005)

/* A one-line explanation of a bridge result code. Never NULL. */
const char *vphone_restore_error_string(int code);

/* --- Running a restore ------------------------------------------------- */

struct vphone_restore_options {
    /*
     * The extracted iPhone*_Restore directory. Required, and it really does
     * have to be a directory: this build has no libzip, so a .ipsw file is
     * rejected here rather than failing later. See zip.h.
     */
    const char *restore_dir;

    /* Where personalized components and the .shsh from shsh_only are cached.
     * NULL means idevicerestore's default, which is the current directory. */
    const char *cache_dir;

    /* Target a specific device by UDID. NULL to target by ECID alone.
     * Only devices in normal mode have a UDID idevicerestore can match. */
    const char *udid;

    /* Target a specific device by ECID. 0 means "the only one attached". */
    uint64_t ecid;

    /* true  -> erase install, upstream's -e  (pymobiledevice3's Behavior.Erase)
     * false -> update in place               (Behavior.Update) */
    bool erase;

    /*
     * NULL fetches a ticket from Apple over the network.
     *
     * Non-NULL is an offline restore from a saved TSS response, and the file
     * must be the WHOLE response plist — the thing `shsh_only` writes, or
     * what pymobiledevice3's fetch_tss_record() dumps — not a bare AP
     * ticket. A full response carries a signature per component; a bare
     * ApImg4Ticket does not, and personalizing with one produces components
     * the device rejects. This is deliberately NOT upstream's -T/--ticket,
     * which takes the bare ticket; see vphone_restore_bridge.c.
     */
    const char *ticket_path;

    /* Fetch the TSS record, save it under cache_dir/shsh/, and stop without
     * touching the device. Upstream's -t/--shsh. */
    bool shsh_only;

    /* Also write each personalized component to a file, for debugging.
     * Upstream's -k/--keep-pers. */
    bool keep_pers;

    /* 0 is normal output. 1 or more turns on idevicerestore's debug logging,
     * which is what raises the log callback's level ceiling to DEBUG. */
    int debug_level;

    /* NULL discards the output / the progress notifications. */
    vphone_restore_log_cb_t log_cb;
    vphone_restore_progress_cb_t progress_cb;

    /* Passed back to both callbacks untouched. */
    void *context;
};

/*
 * Runs one restore to completion, blocking the calling thread for its whole
 * duration — minutes, and it drives USB and the network throughout, so it
 * does not belong on the main thread of a GUI.
 *
 * Returns VPHONE_RESTORE_OK, one of the VPHONE_RESTORE_E_* codes above, or a
 * negative idevicerestore result.
 */
int vphone_restore_run(const struct vphone_restore_options *options);

#ifdef __cplusplus
}
#endif

#endif /* VPHONE_RESTORE_BRIDGE_H */
