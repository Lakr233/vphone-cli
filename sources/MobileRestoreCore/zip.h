/*
 * zip.h
 *
 * A stub for libzip. NOT an upstream file, and not libzip's header — it
 * declares only the twenty-two entry points upstream actually calls, with
 * libzip's own signatures, so that src/ipsw.c and src/restore.c compile and
 * link unchanged. vphone_zip_stub.c is the matching implementation, and it
 * fails every call with a message instead of doing anything.
 *
 * WHY THERE IS NO REAL LIBZIP HERE
 * --------------------------------
 * libzip is the one PKG_CHECK_MODULES dependency in configure.ac with no
 * counterpart in this package: libirecovery is MobileRecoveryCore, libplist,
 * libimobiledevice, its glue, libusbmuxd and libtatsu come from the
 * AppleMobileDeviceLibrary xcframeworks, and zlib and libcurl are in
 * /usr/lib. Linking Homebrew's libzip would put an absolute /opt/homebrew
 * path in the dependency closure, which is exactly what `scripts/check_aux.sh`
 * gate 1 exists to reject.
 *
 * WHAT IS LOST
 * ------------
 * Two things, and only two:
 *
 *  1. Reading an IPSW straight out of the .ipsw zip. src/ipsw.c takes one of
 *     two paths per call, chosen once in ipsw_open(): a directory sets
 *     archive->zip = 0 and every read goes through stdio, and a file goes
 *     through libzip. This project always hands idevicerestore an
 *     already-extracted `iPhone*_Restore` directory — vphone_restore_run()
 *     refuses anything else before idevicerestore ever sees it — so the zip
 *     arm is unreachable by construction.
 *
 *  2. Baseband firmware signing. restore_sign_bbfw() in src/restore.c opens
 *     the .bbfw (which is itself a zip), stitches the signature blobs into
 *     the .mbn/.fls members and writes it back. A virtual iPhone has no
 *     baseband, so the restore never reaches that function. On real hardware
 *     with a baseband it would, and it would fail loudly here rather than
 *     flashing something unsigned — which is the right failure.
 *
 * Both paths therefore end at zip_open() returning NULL after logging what
 * happened and why, which upstream already handles as an ordinary error.
 * Nothing below returns a plausible-looking success value.
 */

#ifndef VPHONE_MOBILERESTORECORE_ZIP_H
#define VPHONE_MOBILERESTORECORE_ZIP_H

#include <stdint.h>
#include <time.h>

#ifdef __cplusplus
extern "C" {
#endif

/* libzip's fixed-width aliases, as <zip.h> spells them. */
typedef int8_t zip_int8_t;
typedef uint8_t zip_uint8_t;
typedef int16_t zip_int16_t;
typedef uint16_t zip_uint16_t;
typedef int32_t zip_int32_t;
typedef uint32_t zip_uint32_t;
typedef int64_t zip_int64_t;
typedef uint64_t zip_uint64_t;

typedef zip_uint32_t zip_flags_t;

/*
 * Opaque in libzip too. src/ipsw.h stores `struct zip*` and `struct zip_file*`
 * in struct ipsw_file_handle without ever dereferencing them, so incomplete
 * types are all upstream needs.
 */
struct zip;
struct zip_file;
struct zip_source;

typedef struct zip zip_t;
typedef struct zip_file zip_file_t;
typedef struct zip_source zip_source_t;

/*
 * libzip's layout, field for field. Upstream reads .name, .size and
 * .comp_method; the rest are here so the struct a caller allocates on the
 * stack is the shape libzip documents.
 */
struct zip_stat {
    zip_uint64_t valid;             /* which fields have valid values */
    const char *name;               /* name of the file */
    zip_uint64_t index;             /* index within archive */
    zip_uint64_t size;              /* size of file (uncompressed) */
    zip_uint64_t comp_size;         /* size of file (compressed) */
    time_t mtime;                   /* modification time */
    zip_uint32_t crc;               /* crc of file data */
    zip_uint16_t comp_method;       /* compression method used */
    zip_uint16_t encryption_method; /* encryption method used */
    zip_uint32_t flags;             /* reserved for future use */
};

typedef struct zip_stat zip_stat_t;

/* Compression method: stored, i.e. not compressed. Used by ipsw_file_open. */
#define ZIP_CM_STORE 0

/* zip_file_add flag: replace an entry of the same name. */
#define ZIP_FL_OVERWRITE 8192u

/* Operating system of the external attributes. Used by ipsw_extract_to_memory. */
#define ZIP_OPSYS_UNIX 0x03u

/* --- The calls src/ipsw.c and src/restore.c make. ---------------------- */

zip_t *zip_open(const char *path, int flags, int *errorp);
int zip_close(zip_t *archive);
int zip_unchange_all(zip_t *archive);
const char *zip_strerror(zip_t *archive);

zip_int64_t zip_name_locate(zip_t *archive, const char *fname, zip_flags_t flags);
zip_int64_t zip_get_num_entries(zip_t *archive, zip_flags_t flags);
const char *zip_get_name(zip_t *archive, zip_uint64_t index, zip_flags_t flags);
int zip_delete(zip_t *archive, zip_uint64_t index);

void zip_stat_init(zip_stat_t *st);
int zip_stat(zip_t *archive, const char *fname, zip_flags_t flags, zip_stat_t *st);
int zip_stat_index(zip_t *archive, zip_uint64_t index, zip_flags_t flags, zip_stat_t *st);
int zip_file_get_external_attributes(zip_t *archive, zip_uint64_t index,
                                     zip_flags_t flags, zip_uint8_t *opsys,
                                     zip_uint32_t *attributes);

zip_file_t *zip_fopen_index(zip_t *archive, zip_uint64_t index, zip_flags_t flags);
int zip_fclose(zip_file_t *file);
zip_int64_t zip_fread(zip_file_t *file, void *buf, zip_uint64_t nbytes);
zip_int8_t zip_fseek(zip_file_t *file, zip_int64_t offset, int whence);
zip_int64_t zip_ftell(zip_file_t *file);
void zip_file_error_get(zip_file_t *file, int *zep, int *sep);

zip_source_t *zip_source_buffer(zip_t *archive, const void *data, zip_uint64_t len, int freep);
void zip_source_free(zip_source_t *source);
int zip_file_replace(zip_t *archive, zip_uint64_t index, zip_source_t *source, zip_flags_t flags);
zip_int64_t zip_file_add(zip_t *archive, const char *name, zip_source_t *source, zip_flags_t flags);

#ifdef __cplusplus
}
#endif

#endif /* VPHONE_MOBILERESTORECORE_ZIP_H */
