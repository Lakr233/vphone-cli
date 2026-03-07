#import "unarchive.h"

#include <archive.h>
#include <archive_entry.h>

static int copy_data(struct archive *ar, struct archive *aw) {
    const void *buff;
    size_t size;
    la_int64_t offset;

    for (;;) {
        int r = archive_read_data_block(ar, &buff, &size, &offset);
        if (r == ARCHIVE_EOF) return ARCHIVE_OK;
        if (r < ARCHIVE_OK) return r;
        r = archive_write_data_block(aw, buff, size, offset);
        if (r < ARCHIVE_OK) {
            fprintf(stderr, "%s\n", archive_error_string(aw));
            return r;
        }
    }
}

int vp_extract_archive(NSString *archivePath, NSString *extractionPath, NSString **errorOutput) {
    int flags = ARCHIVE_EXTRACT_TIME
              | ARCHIVE_EXTRACT_PERM
              | ARCHIVE_EXTRACT_SECURE_NODOTDOT;

    // Resolve symlinks in extractionPath (e.g. /tmp -> /private/tmp on iOS)
    // so ARCHIVE_EXTRACT_SECURE_SYMLINKS doesn't reject trusted system symlinks.
    NSString *resolvedPath = [extractionPath stringByResolvingSymlinksInPath];
    NSLog(@"vphoned: extract %@ -> %@ (resolved: %@)", archivePath, extractionPath, resolvedPath);

    struct archive *a = archive_read_new();
    archive_read_support_format_all(a);
    archive_read_support_filter_all(a);

    struct archive *ext = archive_write_disk_new();
    archive_write_disk_set_options(ext, flags);
    archive_write_disk_set_standard_lookup(ext);

    int ret = 0;
    if (archive_read_open_filename(a, archivePath.fileSystemRepresentation, 10240) != ARCHIVE_OK) {
        NSString *err = [NSString stringWithFormat:@"archive_read_open failed: %s", archive_error_string(a)];
        NSLog(@"vphoned: %@", err);
        if (errorOutput) *errorOutput = err;
        ret = 1;
        goto cleanup;
    }

    for (;;) {
        struct archive_entry *entry;
        int r = archive_read_next_header(a, &entry);
        if (r == ARCHIVE_EOF) break;
        if (r < ARCHIVE_OK)
            NSLog(@"vphoned: archive_read_next_header: %s", archive_error_string(a));
        if (r < ARCHIVE_WARN) {
            if (errorOutput) *errorOutput = [NSString stringWithFormat:@"archive_read_next_header failed: %s", archive_error_string(a)];
            ret = 1; goto cleanup;
        }

        const char *entryPath = archive_entry_pathname(entry);
        if (!entryPath) { ret = 1; goto cleanup; }
        NSString *currentFile = [NSString stringWithUTF8String:entryPath];
        if (!currentFile) { ret = 1; goto cleanup; }
        NSString *fullOutputPath = [resolvedPath stringByAppendingPathComponent:currentFile];
        archive_entry_set_pathname(entry, fullOutputPath.fileSystemRepresentation);

        r = archive_write_header(ext, entry);
        if (r < ARCHIVE_OK)
            NSLog(@"vphoned: archive_write_header(%@): %s (r=%d)", currentFile, archive_error_string(ext), r);
        if (r < ARCHIVE_WARN) {
            if (errorOutput) *errorOutput = [NSString stringWithFormat:@"archive_write_header failed for %@: %s", currentFile, archive_error_string(ext)];
            ret = 1; goto cleanup;
        }
        if (archive_entry_size(entry) > 0) {
            r = copy_data(a, ext);
            if (r < ARCHIVE_OK)
                NSLog(@"vphoned: copy_data(%@): %s (r=%d)", currentFile, archive_error_string(ext), r);
            if (r < ARCHIVE_WARN) {
                if (errorOutput) *errorOutput = [NSString stringWithFormat:@"copy_data failed for %@: %s", currentFile, archive_error_string(ext)];
                ret = 1; goto cleanup;
            }
        }

        r = archive_write_finish_entry(ext);
        if (r < ARCHIVE_OK)
            NSLog(@"vphoned: archive_write_finish_entry(%@): %s (r=%d)", currentFile, archive_error_string(ext), r);
        if (r < ARCHIVE_WARN) {
            if (errorOutput) *errorOutput = [NSString stringWithFormat:@"archive_write_finish_entry failed for %@: %s", currentFile, archive_error_string(ext)];
            ret = 1; goto cleanup;
        }
    }

cleanup:
    archive_read_close(a);
    archive_read_free(a);
    archive_write_close(ext);
    archive_write_free(ext);
    return ret;
}
