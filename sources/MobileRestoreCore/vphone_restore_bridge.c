/*
 * vphone_restore_bridge.c
 *
 * What stands in for upstream's main(). NOT an upstream file.
 *
 * src/idevicerestore.c is compiled with IDEVICERESTORE_NOMAIN, so everything
 * below its `#ifndef IDEVICERESTORE_NOMAIN` guard — argv parsing, the usage
 * text, the SIGINT handler and main() itself — is gone, and this file builds
 * the same struct idevicerestore_client_t from a struct instead. Read
 * vphone_restore_bridge.h for the caller's side of the contract.
 *
 * Three things here are worth reading before changing anything:
 *
 *   1. The offline ticket. Upstream's -T/--ticket is NOT what this bridge's
 *      `ticket_path` does, and it cannot be — see "THE OFFLINE TICKET" below.
 *   2. The log plumbing. idevicerestore writes to two places, a levelled
 *      logger() and plain printf(), and both have to end up at one callback.
 *   3. Process-global state. idevicerestore keeps the log level, the debug
 *      flag and the quit flag in globals, so only one restore can run at a
 *      time and vphone_restore_run() enforces that.
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include <curl/curl.h>
#include <plist/plist.h>
#include <zlib.h>

#include "common.h"
#include "idevicerestore.h"
#include "log.h"

#include "vphone_restore_bridge.h"

/*
 * log.c defines this next to `log_level`, which log.h does declare. It is the
 * ceiling on what reaches logger_set_print_func()'s callback: anything above
 * it goes only to the stderr copy, which this bridge turns off. Upstream's
 * main() never moves it because its own callback writes to a terminal that
 * also gets the stderr copy. Here the callback is all there is, so debug
 * output would be dropped silently unless the ceiling comes up with
 * `log_level`.
 */
extern enum loglevel print_level;

/* --- Shared state ------------------------------------------------------ */

/*
 * One restore at a time, and every global below is covered by g_lock at the
 * moments it is installed and torn down. The callbacks themselves are read
 * without the lock, from whichever worker thread is logging — they are set
 * before idevicerestore_start() and cleared after it returns, so there is no
 * window in which a thread inside the restore sees them change.
 */
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_running = 0;

static vphone_restore_log_cb_t g_log_cb = NULL;
static vphone_restore_progress_cb_t g_progress_cb = NULL;
static void *g_context = NULL;

/* The saved TSS response for an offline restore, or NULL. See below. */
static plist_t g_offline_tss = NULL;

/*
 * Set for as long as this thread is inside one of the caller's callbacks. The
 * stdout capture below uses it to break the loop a callback that prints would
 * otherwise close: callback -> printf -> captured stdout -> callback.
 */
static __thread int g_in_callback = 0;

static void vphone_emit(int level, const char *message)
{
    vphone_restore_log_cb_t cb = g_log_cb;
    if (!cb || !message) {
        return;
    }
    g_in_callback++;
    cb(level, message, g_context);
    g_in_callback--;
}

/* --- THE OFFLINE TICKET ------------------------------------------------ */

/*
 * `ticket_path` is NOT upstream's -T/--ticket, and this is the one place in
 * this target where an upstream file is patched rather than copied. Both
 * halves of that deserve the explanation.
 *
 * What -T does, in this exact snapshot of src/idevicerestore.c:
 *
 *   - line 1966-1974, in main()'s getopt loop: read_file(optarg, …) into
 *     client->root_ticket / client->root_ticket_len. Raw bytes, no parsing.
 *   - line 1281-1292, in idevicerestore_start(): if the device is already in
 *     restore mode, wrap those bytes in a PLIST_DATA node, build a BRAND NEW
 *     one-key dict, and assign it to client->tss:
 *
 *         client->tss = plist_new_dict();
 *         plist_dict_set_item(client->tss, "ApImg4Ticket", ap_ticket);
 *
 * So -T's client->tss holds the AP ticket and nothing else. A real TSS
 * response is a dict with an entry PER COMPONENT — iBEC, iBoot, SEP, the
 * kernelcache and the rest — each carrying that component's Blob/signature,
 * and personalize_component() looks its component up in client->tss by name.
 * With -T there is nothing to look up, so every component personalizes
 * without its signature and the device rejects it. -T is for the narrow case
 * where a device is already in restore mode and only the AP ticket is still
 * needed; it is not an offline restore.
 *
 * The backend this replaces, pymobiledevice3, passed the whole response
 * plist: `Restore(ipsw, device, tss=tss, …)` where tss came straight from
 * `fetch_tss_record()`. That is what scripts/pymobiledevice3_bridge.py's
 * --tss option carried, and it is what `make restore_offline` feeds from the
 * .shsh file that `make restore_get_shsh` wrote. So the bridge has to install
 * the full response as client->tss, not a bare ticket.
 *
 * There is no seam in upstream for that. client->tss is written in exactly
 * four places: the -T block above, and three calls to get_tss_response()
 * (idevicerestore.c:1294 and :1513, dfu.c:520), each of which passes
 * &client->tss. Pre-setting the field does not survive, because
 * get_tss_response() starts with `*tss = NULL;` (idevicerestore.c:2353), and
 * its own local-.shsh cache is reachable only when build_major <= 8 or
 * FLAG_CUSTOM is set — neither is true for a modern iPhone. Interposing the
 * symbol is not possible either: it is a plain static-library symbol that the
 * calling translation units resolve directly.
 *
 * So get_tss_response() carries a four-line hook at its top, marked `vphone:`
 * in idevicerestore.c, that calls the function below and returns early if it
 * fills the response. That is the ONLY edit to upstream code in this target.
 *
 * The hook fires for the main request only. All three call sites pass
 * &client->tss, and the one request that must still go to Apple — the
 * recovery-OS root ticket at idevicerestore.c:1316 — passes
 * &client->tss_recoveryos_root_ticket instead, so comparing the out-parameter
 * against &client->tss separates them exactly.
 */
int vphone_offline_tss_lookup(struct idevicerestore_client_t *client,
                              plist_t build_identity, plist_t *tss);

int vphone_offline_tss_lookup(struct idevicerestore_client_t *client,
                              plist_t build_identity, plist_t *tss)
{
    (void)build_identity;

    if (!g_offline_tss || !client || !tss || tss != &client->tss) {
        return 0;
    }

    plist_t copy = plist_copy(g_offline_tss);
    if (!copy) {
        logger(LL_ERROR, "Out of memory copying the saved TSS response\n");
        return 0;
    }

    *tss = copy;
    logger(LL_INFO, "Using the saved TSS response; not contacting Apple\n");
    return 1;
}

/*
 * Loads the file `path` into a plist.
 *
 * Two shapes have to work, because two different tools write these files:
 * idevicerestore's own -t/--shsh writes a gzipped binary plist (see the
 * gzopen/gzwrite in idevicerestore.c's FLAG_SHSHONLY block), while
 * pymobiledevice3 dumped a plain XML plist. plist_from_memory() detects
 * binary, XML and JSON on its own, so the only thing to handle here is the
 * gzip wrapper.
 */
static int vphone_load_tss_file(const char *path, plist_t *out)
{
    unsigned char *raw = NULL;
    size_t raw_len = 0;
    plist_t parsed = NULL;

    *out = NULL;

    if (read_file(path, (void **)&raw, &raw_len) != 0 || !raw || raw_len < 8) {
        logger(LL_ERROR, "Could not read the ticket at '%s'\n", path);
        free(raw);
        return -1;
    }

    if (raw[0] == 0x1f && raw[1] == 0x8b) {
        /* gzip. What `-t/--shsh` and this bridge's shsh_only write. */
        free(raw);
        raw = NULL;
        raw_len = 0;

        gzFile zf = gzopen(path, "rb");
        if (!zf) {
            logger(LL_ERROR, "Could not open the gzipped ticket at '%s'\n", path);
            return -1;
        }
        size_t cap = 65536;
        unsigned char *buf = (unsigned char *)malloc(cap);
        size_t len = 0;
        int failed = (buf == NULL);
        while (!failed) {
            int n = gzread(zf, buf + len, (unsigned int)(cap - len));
            if (n < 0) {
                logger(LL_ERROR, "Could not decompress the ticket at '%s'\n", path);
                failed = 1;
                break;
            }
            len += (size_t)n;
            if (len < cap) {
                break; /* short read means end of stream */
            }
            cap *= 2;
            unsigned char *bigger = (unsigned char *)realloc(buf, cap);
            if (!bigger) {
                failed = 1;
                break;
            }
            buf = bigger;
        }
        gzclose(zf);
        if (failed) {
            free(buf);
            return -1;
        }
        raw = buf;
        raw_len = len;
    }

    if (raw_len == 0 || raw_len > UINT32_MAX) {
        logger(LL_ERROR, "The ticket at '%s' is empty or implausibly large\n", path);
        free(raw);
        return -1;
    }

    plist_from_memory((const char *)raw, (uint32_t)raw_len, &parsed, NULL);
    free(raw);

    if (!parsed) {
        logger(LL_ERROR, "The ticket at '%s' is not a property list\n", path);
        return -1;
    }
    if (plist_get_node_type(parsed) != PLIST_DICT) {
        logger(LL_ERROR, "The ticket at '%s' is not a TSS response dictionary\n", path);
        plist_free(parsed);
        return -1;
    }
    if (!plist_dict_get_item(parsed, "ApImg4Ticket")) {
        /*
         * Not fatal — a pre-Image4 device's response has no ApImg4Ticket —
         * but on anything modern its absence means the wrong file was passed,
         * most likely a bare AP ticket rather than the whole response.
         */
        logger(LL_WARNING,
               "The ticket at '%s' has no ApImg4Ticket entry; if this is a bare "
               "AP ticket rather than a full TSS response, the restore will fail\n",
               path);
    }

    *out = parsed;
    return 0;
}

/* --- Log plumbing ------------------------------------------------------ */

/*
 * idevicerestore's levelled channel. logger() hands this the message with the
 * timestamp and level label already stripped, plus the level itself, which is
 * exactly the shape vphone_restore_log_cb_t wants.
 *
 * logger() holds its own mutex across this call, so the formatting below is
 * already serialised; the stack buffer is per-call regardless.
 */
static void vphone_log_print(enum loglevel level, const char *fmt, va_list ap)
{
    char stack_buf[2048];
    va_list copy;
    int needed;

    if (!g_log_cb) {
        return;
    }

    va_copy(copy, ap);
    needed = vsnprintf(stack_buf, sizeof(stack_buf), fmt, copy);
    va_end(copy);

    if (needed < 0) {
        return;
    }
    if ((size_t)needed < sizeof(stack_buf)) {
        vphone_emit((int)level, stack_buf);
        return;
    }

    char *heap_buf = (char *)malloc((size_t)needed + 1);
    if (!heap_buf) {
        stack_buf[sizeof(stack_buf) - 1] = '\0';
        vphone_emit((int)level, stack_buf);
        return;
    }
    vsnprintf(heap_buf, (size_t)needed + 1, fmt, ap);
    vphone_emit((int)level, heap_buf);
    free(heap_buf);
}

/*
 * idevicerestore's OTHER channel: plain printf(3). common.c prints the banner
 * box, the ASCII progress bars and the interactive prompts straight to
 * stdout, and logger_dump_plist() writes a whole plist to a FILE* too. None
 * of that goes through logger(), so none of it would reach the callback.
 *
 * funopen(3) is the answer: a FILE* backed by the function below, installed
 * as `stdout` for the duration of the run. On Darwin `stdout` is a macro for
 * the assignable global __stdoutp, so the swap is a plain assignment and the
 * original is put back before vphone_restore_run() returns.
 *
 * That swap is process-wide while it lasts. It is a deliberate trade — the
 * alternative is idevicerestore printing onto a terminal the caller may not
 * have — and it is the other half of why only one restore may run at a time.
 * A host that prints from another thread during a restore will see those
 * lines arrive at its own log callback instead of on stdout.
 *
 * With one exception, and it is not optional: a log callback that itself
 * prints to stdout — which is the obvious thing for a callback to do — would
 * otherwise feed its own output straight back into itself and recurse until
 * the stack runs out. g_in_callback marks that case and the write goes to the
 * real stdout instead, so printing from either callback works and lands where
 * the caller expects.
 *
 * stdio takes the FILE's lock around each call, so the line buffer below is
 * only ever touched by one thread at a time.
 */
static char g_line_buf[4096];
static size_t g_line_len = 0;
static FILE *g_real_stdout = NULL;

static void vphone_flush_line(void)
{
    if (g_line_len == 0) {
        return;
    }
    g_line_buf[g_line_len] = '\0';
    vphone_emit((int)LL_INFO, g_line_buf);
    g_line_len = 0;
}

static int vphone_stdout_write(void *cookie, const char *data, int len)
{
    (void)cookie;

    /* The caller's own callback is printing. Let it through untouched. */
    if (g_in_callback) {
        if (g_real_stdout) {
            fwrite(data, 1, (size_t)len, g_real_stdout);
            fflush(g_real_stdout);
        }
        return len;
    }

    for (int i = 0; i < len; i++) {
        char c = data[i];
        /*
         * '\r' as well as '\n': a progress bar redraws itself with a carriage
         * return and no newline, and a callback wants one message per redraw
         * rather than one enormous line at the end.
         */
        if (c == '\n' || c == '\r') {
            vphone_flush_line();
            continue;
        }
        if (g_line_len + 1 >= sizeof(g_line_buf)) {
            vphone_flush_line();
        }
        g_line_buf[g_line_len++] = c;
    }
    return len;
}

static int vphone_stdout_close(void *cookie)
{
    (void)cookie;
    vphone_flush_line();
    return 0;
}

/* --- Progress and the other UI hooks ----------------------------------- */

static void vphone_progress_cb(int step, double step_progress, void *userdata)
{
    (void)userdata;
    vphone_restore_progress_cb_t cb = g_progress_cb;
    if (!cb) {
        return;
    }
    /* Same guard as vphone_emit: a progress callback that prints must not
       have its own output captured and turned back into log lines. */
    g_in_callback++;
    cb(step, step_progress, g_context);
    g_in_callback--;
}

/*
 * common.c's second progress channel, for sub-tasks inside a step (the
 * filesystem upload, each firmware component). Left to itself it draws ASCII
 * bars; forwarded here it becomes one verbose line per task per update, which
 * set_progress_granularity() below keeps down to roughly twenty per task.
 */
static void vphone_update_progress(struct progress_info_entry **list, int count)
{
    char line[256];

    if (!g_log_cb || !list) {
        return;
    }
    for (int i = 0; i < count; i++) {
        struct progress_info_entry *entry = list[i];
        if (!entry || !entry->label) {
            continue;
        }
        snprintf(line, sizeof(line), "%s: %5.1f%%\n", entry->label, entry->progress * 100.0);
        vphone_emit((int)LL_VERBOSE, line);
    }
}

static void vphone_show_banner(const char *text)
{
    if (text) {
        vphone_emit((int)LL_NOTICE, text);
    }
}

static void vphone_hide_banner(void)
{
}

/*
 * There is nobody at a terminal. prompt_user() is only reached under
 * FLAG_INTERACTIVE, which this bridge never sets, but installing a prompt
 * function closes the door properly: without one, common.c falls through to
 * get_user_input() and blocks on stdin forever. A negative result is the one
 * that makes idevicerestore set FLAG_QUIT and stop, which is the right answer
 * when the question is "shall I destroy all data on this device".
 */
static int vphone_prompt(const char *title, const char *text)
{
    char line[1024];
    snprintf(line, sizeof(line), "%s: %s", title ? title : "prompt", text ? text : "");
    vphone_emit((int)LL_WARNING, line);
    vphone_emit((int)LL_ERROR,
                "Cannot answer that question without a user; stopping.\n");
    return -1;
}

/* --- Small public helpers ---------------------------------------------- */

const char *vphone_restore_step_name(int step)
{
    switch (step) {
    case VPHONE_RESTORE_STEP_DETECT: return "detect";
    case VPHONE_RESTORE_STEP_PREPARE: return "prepare";
    case VPHONE_RESTORE_STEP_UPLOAD_FS: return "upload filesystem";
    case VPHONE_RESTORE_STEP_VERIFY_FS: return "verify filesystem";
    case VPHONE_RESTORE_STEP_FLASH_FW: return "flash firmware";
    case VPHONE_RESTORE_STEP_FLASH_BB: return "flash baseband";
    case VPHONE_RESTORE_STEP_FUD: return "flash FUD";
    case VPHONE_RESTORE_STEP_UPLOAD_IMG: return "upload image";
    default: return "unknown";
    }
}

const char *vphone_restore_error_string(int code)
{
    switch (code) {
    case VPHONE_RESTORE_OK:
        return "the restore finished";
    case VPHONE_RESTORE_E_INVALID_ARG:
        return "no options were given";
    case VPHONE_RESTORE_E_NO_RESTORE_DIR:
        return "restore_dir must name an extracted iPhone*_Restore directory";
    case VPHONE_RESTORE_E_TICKET:
        return "the ticket file could not be read as a TSS response";
    case VPHONE_RESTORE_E_OUT_OF_MEMORY:
        return "out of memory";
    case VPHONE_RESTORE_E_BUSY:
        return "another restore is already running in this process";
    default:
        return "idevicerestore stopped; see the log for what happened";
    }
}

/* --- Running a restore ------------------------------------------------- */

/*
 * The part of upstream's main() that builds a client and starts it. Called
 * once the log plumbing is up and the arguments have been checked.
 */
static int vphone_drive_idevicerestore(const struct vphone_restore_options *options)
{
    struct idevicerestore_client_t *client = NULL;
    int result;
    int flags = 0;

    client = idevicerestore_client_new();
    if (!client) {
        return VPHONE_RESTORE_E_OUT_OF_MEMORY;
    }

    /*
     * The flag set upstream's getopt loop would have built. FLAG_INTERACTIVE
     * is pointedly absent: main() turns it on when stdin and stdout are both
     * a tty, and here neither is anything of the sort.
     */
    if (options->erase) {
        flags |= FLAG_ERASE;
    }
    if (options->shsh_only) {
        flags |= FLAG_SHSHONLY;
    }
    if (options->keep_pers) {
        flags |= FLAG_KEEP_PERS;
    }
    if (options->debug_level > 0) {
        flags |= FLAG_DEBUG;
    }
    idevicerestore_set_flags(client, flags);
    client->debug_level = options->debug_level;

    idevicerestore_set_ecid(client, options->ecid);
    if (options->udid) {
        idevicerestore_set_udid(client, options->udid);
    }
    if (options->cache_dir) {
        idevicerestore_set_cache_path(client, options->cache_dir);
    }

    /*
     * Always ours, never the caller's directly: idevicerestore_progress()
     * draws an ASCII bar when the client has no callback at all, and that is
     * output nobody asked for. vphone_progress_cb forwards to the caller's if
     * there is one and swallows it otherwise.
     */
    idevicerestore_set_progress_callback(client, vphone_progress_cb, NULL);

    logger(LL_INFO, "%s %s (libirecovery %s)\n", PACKAGE_NAME, PACKAGE_VERSION, irecv_version());

    /*
     * ipsw_open() reports its own reason and returns NULL, and
     * idevicerestore_set_ipsw() swallows that, so the field is what says
     * whether it worked.
     */
    idevicerestore_set_ipsw(client, options->restore_dir);
    if (!client->ipsw) {
        logger(LL_ERROR, "Could not open the restore directory '%s'\n", options->restore_dir);
        idevicerestore_client_free(client);
        return VPHONE_RESTORE_E_NO_RESTORE_DIR;
    }

    curl_global_init(CURL_GLOBAL_ALL);

    client->flags |= FLAG_IN_PROGRESS;
    result = idevicerestore_start(client);
    client->flags &= ~FLAG_IN_PROGRESS;

    idevicerestore_client_free(client);
    curl_global_cleanup();

    return result;
}

int vphone_restore_run(const struct vphone_restore_options *options)
{
    FILE *fake_stdout = NULL;
    FILE *saved_stdout = NULL;
    enum loglevel saved_log_level;
    enum loglevel saved_print_level;
    struct stat st;
    int result;

    /* The only failure that cannot be reported: there is no callback to
       report it to. */
    if (!options) {
        return VPHONE_RESTORE_E_INVALID_ARG;
    }

    pthread_mutex_lock(&g_lock);
    if (g_running) {
        pthread_mutex_unlock(&g_lock);
        return VPHONE_RESTORE_E_BUSY;
    }
    g_running = 1;
    g_log_cb = options->log_cb;
    g_progress_cb = options->progress_cb;
    g_context = options->context;
    pthread_mutex_unlock(&g_lock);

    /* Levels first, so the ticket load below is already being reported. */
    saved_log_level = log_level;
    saved_print_level = print_level;
    log_level = (options->debug_level > 0) ? LL_DEBUG : LL_INFO;
    print_level = log_level;

    logger_set_print_func(vphone_log_print);
    /*
     * "NONE" only clears log.c's stderr_enabled; it opens no file. Upstream's
     * main() would otherwise create a restore_<ecid>_<timestamp>.log in the
     * working directory and freopen(3) the process's stderr onto it, which is
     * not a library's business. With the stderr copy off, logger() hands each
     * line to vphone_log_print and nowhere else.
     */
    logger_set_logfile("NONE");

    set_banner_funcs(vphone_show_banner, vphone_hide_banner);
    set_prompt_func(vphone_prompt);
    set_update_progress_func(vphone_update_progress);
    set_progress_granularity(0.05);

    g_line_len = 0;
    fake_stdout = funopen(NULL, NULL, vphone_stdout_write, NULL, vphone_stdout_close);
    if (fake_stdout) {
        setvbuf(fake_stdout, NULL, _IOLBF, 0);
        saved_stdout = stdout;
        g_real_stdout = saved_stdout;
        stdout = fake_stdout;
    }

    /*
     * Everything below here is reported through the callback, which is why
     * the argument checks wait until the log plumbing is up.
     *
     * restore_dir has to be a directory, not a .ipsw: src/ipsw.c would take
     * its libzip arm for a regular file, and this build has no libzip (see
     * zip.h). Saying so here, where the message can name the real problem, is
     * better than letting zip_open() report it four layers down.
     */
    if (!options->restore_dir || options->restore_dir[0] == '\0') {
        logger(LL_ERROR, "No restore directory was given\n");
        result = VPHONE_RESTORE_E_NO_RESTORE_DIR;
        goto done;
    }
    if (stat(options->restore_dir, &st) != 0) {
        logger(LL_ERROR, "Cannot use '%s' as a restore directory: %s\n",
               options->restore_dir, strerror(errno));
        result = VPHONE_RESTORE_E_NO_RESTORE_DIR;
        goto done;
    }
    if (!S_ISDIR(st.st_mode)) {
        logger(LL_ERROR,
               "'%s' is not a directory; this build restores from an extracted "
               "iPhone*_Restore directory, not from a .ipsw archive\n",
               options->restore_dir);
        result = VPHONE_RESTORE_E_NO_RESTORE_DIR;
        goto done;
    }

    if (options->ticket_path && options->ticket_path[0] != '\0') {
        if (vphone_load_tss_file(options->ticket_path, &g_offline_tss) != 0) {
            result = VPHONE_RESTORE_E_TICKET;
            goto done;
        }
        logger(LL_INFO, "Restoring offline with the TSS response at '%s'\n",
               options->ticket_path);
    }

    result = vphone_drive_idevicerestore(options);

done:
    if (g_offline_tss) {
        plist_free(g_offline_tss);
        g_offline_tss = NULL;
    }

    if (fake_stdout) {
        fflush(fake_stdout);
        stdout = saved_stdout;
        fclose(fake_stdout); /* flushes the last partial line through close */
        g_real_stdout = NULL;
    }

    set_update_progress_func(NULL);
    set_prompt_func(NULL);
    set_banner_funcs(NULL, NULL);
    logger_set_print_func(NULL);

    log_level = saved_log_level;
    print_level = saved_print_level;

    pthread_mutex_lock(&g_lock);
    g_log_cb = NULL;
    g_progress_cb = NULL;
    g_context = NULL;
    g_running = 0;
    pthread_mutex_unlock(&g_lock);

    return result;
}
