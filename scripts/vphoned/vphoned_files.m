#import "vphoned_files.h"
#import "vphoned_protocol.h"
#include <sys/stat.h>
#include <unistd.h>

NSDictionary *vp_handle_file_command(int fd, NSDictionary *msg) {
    NSString *type = msg[@"t"];
    id reqId = msg[@"id"];

    // -- file_list: list directory contents --
    if ([type isEqualToString:@"file_list"]) {
        NSString *path = msg[@"path"];
        if (!path) {
            NSMutableDictionary *r = vp_make_response(@"err", reqId);
            r[@"msg"] = @"missing path";
            return r;
        }

        NSFileManager *fm = [NSFileManager defaultManager];
        NSError *err = nil;
        NSArray *contents = [fm contentsOfDirectoryAtPath:path error:&err];
        if (!contents) {
            NSMutableDictionary *r = vp_make_response(@"err", reqId);
            r[@"msg"] = err.localizedDescription ?: @"list failed";
            return r;
        }

        NSMutableArray *entries = [NSMutableArray arrayWithCapacity:contents.count];
        for (NSString *name in contents) {
            NSString *full = [path stringByAppendingPathComponent:name];
            NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
            if (!attrs) continue;

            NSString *fileType = attrs[NSFileType];
            NSString *typeStr = @"file";
            if ([fileType isEqualToString:NSFileTypeDirectory]) typeStr = @"dir";
            else if ([fileType isEqualToString:NSFileTypeSymbolicLink]) typeStr = @"link";

            NSNumber *size = attrs[NSFileSize] ?: @0;
            NSDate *mtime = attrs[NSFileModificationDate];
            NSNumber *posixPerms = attrs[NSFilePosixPermissions];

            [entries addObject:@{
                @"name": name,
                @"type": typeStr,
                @"size": size,
                @"perm": [NSString stringWithFormat:@"%lo", [posixPerms unsignedLongValue]],
                @"mtime": @(mtime ? [mtime timeIntervalSince1970] : 0),
            }];
        }

        NSMutableDictionary *r = vp_make_response(@"ok", reqId);
        r[@"entries"] = entries;
        return r;
    }

    // -- file_get: download file from guest to host --
    if ([type isEqualToString:@"file_get"]) {
        NSString *path = msg[@"path"];
        if (!path) {
            NSMutableDictionary *r = vp_make_response(@"err", reqId);
            r[@"msg"] = @"missing path";
            return r;
        }

        int fileFd = open([path fileSystemRepresentation], O_RDONLY);
        if (fileFd < 0) {
            NSMutableDictionary *r = vp_make_response(@"err", reqId);
            r[@"msg"] = [NSString stringWithFormat:@"open failed: %s", strerror(errno)];
            return r;
        }

        struct stat st;
        if (fstat(fileFd, &st) != 0) {
            close(fileFd);
            NSMutableDictionary *r = vp_make_response(@"err", reqId);
            r[@"msg"] = [NSString stringWithFormat:@"stat failed: %s", strerror(errno)];
            return r;
        }
        if (!S_ISREG(st.st_mode)) {
            close(fileFd);
            NSMutableDictionary *r = vp_make_response(@"err", reqId);
            r[@"msg"] = @"not a regular file";
            return r;
        }

        // Send header with file size
        NSMutableDictionary *header = vp_make_response(@"file_data", reqId);
        header[@"size"] = @((unsigned long long)st.st_size);
        if (!vp_write_message(fd, header)) {
            close(fileFd);
            return nil;
        }

        // Stream file data in chunks
        uint8_t buf[32768];
        ssize_t n;
        while ((n = read(fileFd, buf, sizeof(buf))) > 0) {
            if (!vp_write_fully(fd, buf, (size_t)n)) {
                NSLog(@"vphoned: file_get write failed for %@", path);
                close(fileFd);
                return nil;
            }
        }
        close(fileFd);
        return nil;  // Response already written inline
    }

    // -- file_put: upload file from host to guest --
    if ([type isEqualToString:@"file_put"]) {
        NSString *path = msg[@"path"];
        NSUInteger size = [msg[@"size"] unsignedIntegerValue];
        NSString *perm = msg[@"perm"];

        if (!path) {
            // Must still drain the raw bytes to keep protocol in sync
            if (size > 0) vp_drain(fd, size);
            NSMutableDictionary *r = vp_make_response(@"err", reqId);
            r[@"msg"] = @"missing path";
            return r;
        }

        // Create parent directories if needed
        NSString *parent = [path stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:parent
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];

        // Write to temp file, then rename (atomic)
        char tmp_path[PATH_MAX];
        snprintf(tmp_path, sizeof(tmp_path), "%s.XXXXXX", [path fileSystemRepresentation]);
        int tmp_fd = mkstemp(tmp_path);
        if (tmp_fd < 0) {
            vp_drain(fd, size);
            NSMutableDictionary *r = vp_make_response(@"err", reqId);
            r[@"msg"] = [NSString stringWithFormat:@"mkstemp failed: %s", strerror(errno)];
            return r;
        }

        uint8_t buf[32768];
        NSUInteger remaining = size;
        BOOL ok = YES;
        while (remaining > 0) {
            size_t chunk = remaining < sizeof(buf) ? remaining : sizeof(buf);
            if (!vp_read_fully(fd, buf, chunk)) { ok = NO; break; }
            if (write(tmp_fd, buf, chunk) != (ssize_t)chunk) { ok = NO; break; }
            remaining -= chunk;
        }
        close(tmp_fd);

        if (!ok) {
            unlink(tmp_path);
            NSMutableDictionary *r = vp_make_response(@"err", reqId);
            r[@"msg"] = @"file transfer failed";
            return r;
        }

        // Set permissions
        if (perm) {
            unsigned long mode = strtoul([perm UTF8String], NULL, 8);
            chmod(tmp_path, (mode_t)mode);
        } else {
            chmod(tmp_path, 0644);
        }

        if (rename(tmp_path, [path fileSystemRepresentation]) != 0) {
            unlink(tmp_path);
            NSMutableDictionary *r = vp_make_response(@"err", reqId);
            r[@"msg"] = [NSString stringWithFormat:@"rename failed: %s", strerror(errno)];
            return r;
        }

        NSLog(@"vphoned: file_put %@ (%lu bytes)", path, (unsigned long)size);
        return vp_make_response(@"ok", reqId);
    }

    // -- file_mkdir --
    if ([type isEqualToString:@"file_mkdir"]) {
        NSString *path = msg[@"path"];
        if (!path) {
            NSMutableDictionary *r = vp_make_response(@"err", reqId);
            r[@"msg"] = @"missing path";
            return r;
        }
        NSError *err = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtPath:path
                                       withIntermediateDirectories:YES
                                                        attributes:nil
                                                             error:&err]) {
            NSMutableDictionary *r = vp_make_response(@"err", reqId);
            r[@"msg"] = err.localizedDescription ?: @"mkdir failed";
            return r;
        }
        return vp_make_response(@"ok", reqId);
    }

    // -- file_delete --
    if ([type isEqualToString:@"file_delete"]) {
        NSString *path = msg[@"path"];
        if (!path) {
            NSMutableDictionary *r = vp_make_response(@"err", reqId);
            r[@"msg"] = @"missing path";
            return r;
        }
        NSError *err = nil;
        if (![[NSFileManager defaultManager] removeItemAtPath:path error:&err]) {
            NSMutableDictionary *r = vp_make_response(@"err", reqId);
            r[@"msg"] = err.localizedDescription ?: @"delete failed";
            return r;
        }
        return vp_make_response(@"ok", reqId);
    }

    // -- file_rename --
    if ([type isEqualToString:@"file_rename"]) {
        NSString *from = msg[@"from"];
        NSString *to = msg[@"to"];
        if (!from || !to) {
            NSMutableDictionary *r = vp_make_response(@"err", reqId);
            r[@"msg"] = @"missing from/to";
            return r;
        }
        NSError *err = nil;
        if (![[NSFileManager defaultManager] moveItemAtPath:from toPath:to error:&err]) {
            NSMutableDictionary *r = vp_make_response(@"err", reqId);
            r[@"msg"] = err.localizedDescription ?: @"rename failed";
            return r;
        }
        return vp_make_response(@"ok", reqId);
    }

    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = [NSString stringWithFormat:@"unknown file command: %@", type];
    return r;
}
