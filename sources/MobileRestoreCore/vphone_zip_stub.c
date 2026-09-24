/*
 * vphone_zip_stub.c
 *
 * The implementation behind zip.h. NOT an upstream file.
 *
 * Read zip.h first — it says why libzip is not linked and which two upstream
 * code paths this removes. In short: this package always hands idevicerestore
 * an already-extracted `iPhone*_Restore` directory, src/ipsw.c picks its
 * stdio arm for a directory in ipsw_open() and never touches libzip again,
 * and the only other caller is baseband firmware signing on a device that
 * has no baseband.
 *
 * The contract here is: fail, say why, and never return something a caller
 * could mistake for success. zip_open() is the single door into libzip from
 * upstream — every other entry point below needs a zip_t or a zip_file_t that
 * only zip_open() and zip_fopen_index() can hand out — so zip_open() carries
 * the real explanation and the rest report that they were reached at all,
 * which would mean a bug in this file rather than a missing feature.
 *
 * Everything logs through upstream's logger(), so these lines arrive at the
 * host's vphone_restore_log_cb_t alongside the rest of the restore output
 * rather than on some stream nobody is reading.
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include <string.h>

#include "log.h"
#include "zip.h"

#define VPHONE_ZIP_REASON                                                      \
    "this build has no libzip: it restores from an extracted "                 \
    "iPhone*_Restore directory, not from a .ipsw or .bbfw archive"

/*
 * The one call upstream can legitimately make. Returning NULL is an error
 * libzip itself can return and that both ipsw.c and restore.c already handle,
 * so the restore stops here with a message rather than further in with junk.
 *
 * ZIP_ER_OPNOTSUPP is 21 in libzip's error table; it is what the `int*` out
 * parameter gets so the "zip_open: %s: %d" line upstream prints next carries a
 * number that means something to anyone who looks it up.
 */
zip_t *zip_open(const char *path, int flags, int *errorp)
{
    (void)flags;
    if (errorp) {
        *errorp = 21; /* ZIP_ER_OPNOTSUPP */
    }
    logger(
        LL_ERROR,
        "Cannot open '%s' as a zip archive: %s.\n",
        path ? path : "(null)",
        VPHONE_ZIP_REASON
    );
    return NULL;
}

/*
 * Unreachable. Each of these needs a handle that only zip_open() above (or
 * zip_fopen_index(), which needs one of those) could have produced, and it
 * never produces one. Reaching any of them means this file is out of step
 * with the upstream sources beside it, so they say so plainly and then return
 * the value that makes the caller take its error path.
 */
static void vphone_zip_unreachable(const char *fn)
{
    logger(
        LL_ERROR,
        "internal error: %s() was called on a zip handle that cannot "
        "exist (%s)\n",
        fn,
        VPHONE_ZIP_REASON
    );
}

int zip_close(zip_t *archive)
{
    (void)archive;
    vphone_zip_unreachable("zip_close");
    return -1;
}

int zip_unchange_all(zip_t *archive)
{
    (void)archive;
    vphone_zip_unreachable("zip_unchange_all");
    return -1;
}

const char *zip_strerror(zip_t *archive)
{
    (void)archive;
    return VPHONE_ZIP_REASON;
}

zip_int64_t zip_name_locate(zip_t *archive, const char *fname, zip_flags_t flags)
{
    (void)archive;
    (void)fname;
    (void)flags;
    vphone_zip_unreachable("zip_name_locate");
    return -1;
}

zip_int64_t zip_get_num_entries(zip_t *archive, zip_flags_t flags)
{
    (void)archive;
    (void)flags;
    vphone_zip_unreachable("zip_get_num_entries");
    return -1;
}

const char *zip_get_name(zip_t *archive, zip_uint64_t index, zip_flags_t flags)
{
    (void)archive;
    (void)index;
    (void)flags;
    vphone_zip_unreachable("zip_get_name");
    return NULL;
}

int zip_delete(zip_t *archive, zip_uint64_t index)
{
    (void)archive;
    (void)index;
    vphone_zip_unreachable("zip_delete");
    return -1;
}

/*
 * The one exception to "unreachable": upstream calls zip_stat_init() on a
 * stack struct before it has a handle, so this one does run. libzip's own
 * zip_stat_init() only clears the struct, and doing the same here keeps
 * `stat.name` from being an uninitialised pointer that a later error message
 * would print.
 */
void zip_stat_init(zip_stat_t *st)
{
    if (st) {
        memset(st, 0, sizeof(*st));
    }
}

int zip_stat(zip_t *archive, const char *fname, zip_flags_t flags, zip_stat_t *st)
{
    (void)archive;
    (void)fname;
    (void)flags;
    (void)st;
    vphone_zip_unreachable("zip_stat");
    return -1;
}

int zip_stat_index(zip_t *archive, zip_uint64_t index, zip_flags_t flags, zip_stat_t *st)
{
    (void)archive;
    (void)index;
    (void)flags;
    (void)st;
    vphone_zip_unreachable("zip_stat_index");
    return -1;
}

int zip_file_get_external_attributes(
    zip_t *archive,
    zip_uint64_t index,
    zip_flags_t flags,
    zip_uint8_t *opsys,
    zip_uint32_t *attributes
)
{
    (void)archive;
    (void)index;
    (void)flags;
    (void)opsys;
    (void)attributes;
    vphone_zip_unreachable("zip_file_get_external_attributes");
    return -1;
}

zip_file_t *zip_fopen_index(zip_t *archive, zip_uint64_t index, zip_flags_t flags)
{
    (void)archive;
    (void)index;
    (void)flags;
    vphone_zip_unreachable("zip_fopen_index");
    return NULL;
}

int zip_fclose(zip_file_t *file)
{
    (void)file;
    vphone_zip_unreachable("zip_fclose");
    return -1;
}

zip_int64_t zip_fread(zip_file_t *file, void *buf, zip_uint64_t nbytes)
{
    (void)file;
    (void)buf;
    (void)nbytes;
    vphone_zip_unreachable("zip_fread");
    return -1;
}

zip_int8_t zip_fseek(zip_file_t *file, zip_int64_t offset, int whence)
{
    (void)file;
    (void)offset;
    (void)whence;
    vphone_zip_unreachable("zip_fseek");
    return -1;
}

zip_int64_t zip_ftell(zip_file_t *file)
{
    (void)file;
    vphone_zip_unreachable("zip_ftell");
    return -1;
}

void zip_file_error_get(zip_file_t *file, int *zep, int *sep)
{
    (void)file;
    if (zep) {
        *zep = 21; /* ZIP_ER_OPNOTSUPP */
    }
    if (sep) {
        *sep = 0;
    }
}

zip_source_t *zip_source_buffer(zip_t *archive, const void *data, zip_uint64_t len, int freep)
{
    (void)archive;
    (void)data;
    (void)len;
    (void)freep;
    vphone_zip_unreachable("zip_source_buffer");
    return NULL;
}

void zip_source_free(zip_source_t *source)
{
    (void)source;
    vphone_zip_unreachable("zip_source_free");
}

int zip_file_replace(zip_t *archive, zip_uint64_t index, zip_source_t *source, zip_flags_t flags)
{
    (void)archive;
    (void)index;
    (void)source;
    (void)flags;
    vphone_zip_unreachable("zip_file_replace");
    return -1;
}

zip_int64_t zip_file_add(zip_t *archive, const char *name, zip_source_t *source, zip_flags_t flags)
{
    (void)archive;
    (void)name;
    (void)source;
    (void)flags;
    vphone_zip_unreachable("zip_file_add");
    return -1;
}
