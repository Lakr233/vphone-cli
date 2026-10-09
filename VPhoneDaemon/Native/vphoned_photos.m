#import "Include/VphonedNative.h"
#import <Photos/Photos.h>
#include <crt_externs.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <spawn.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

// HTTP only stages files and reads receipts. PhotoKit runs in a bounded,
// separately executed mobile process; a stalled library never blocks RPC.
static NSString *imports = @"/var/mobile/Media/vphone-photo-imports";
static const char *workerFlag = "--photos-worker";
static dispatch_source_t scanTimer;
static NSLock *stagingLock;

static NSString *job_path(NSString *job) {
    return [imports stringByAppendingPathComponent:job];
}

static BOOL valid_job(NSString *job) {
    return job.length == 36 && [[NSUUID alloc] initWithUUIDString:job] != nil;
}

static BOOL supported(NSString *name) {
    return name.length && [name isEqualToString:name.lastPathComponent] &&
        ![name hasPrefix:@"."] && [name rangeOfString:@"\0"].location == NSNotFound &&
        [@[@"jpg", @"jpeg", @"png", @"heic", @"heif", @"gif", @"tif", @"tiff",
           @"bmp", @"mov", @"mp4", @"m4v"] containsObject:name.pathExtension.lowercaseString];
}

static NSDictionary *read_json(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static BOOL sync_path(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return NO;
    BOOL ok = fsync(fd) == 0;
    close(fd);
    return ok;
}

static BOOL write_json(NSDictionary *value, NSString *path) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    if (!data || ![data writeToFile:path options:NSDataWritingAtomic error:nil]) return NO;
    // NSData's atomic rename is only durable after the directory is synced.
    return sync_path(path) && sync_path(path.stringByDeletingLastPathComponent);
}

static BOOL mobile_directory(NSString *path) {
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) == 0 && !S_ISDIR(st.st_mode)) return NO;
    if (![NSFileManager.defaultManager createDirectoryAtPath:path
        withIntermediateDirectories:YES attributes:nil error:nil]) return NO;
    return chown(path.fileSystemRepresentation, 501, 501) == 0 &&
        chmod(path.fileSystemRepresentation, 0700) == 0;
}

static NSDictionary *status(NSString *job) {
    NSString *root = job_path(job);
    NSDictionary *metadata = read_json([root stringByAppendingPathComponent:@"job.json"]);
    if (!metadata) return @{@"ok": @NO, @"code": @"not_found", @"error": @"Unknown Photos import"};
    NSMutableDictionary *result = [metadata mutableCopy];
    NSDictionary *receipt = read_json([root stringByAppendingPathComponent:@"result.json"]);
    result[@"job"] = job;
    result[@"complete"] = @(receipt != nil);
    if (receipt) [result addEntriesFromDictionary:receipt];
    return result;
}

NSDictionary *vp_photos_status(NSString *job) {
    if (!valid_job(job)) return @{@"ok": @NO, @"code": @"invalid_request", @"error": @"job must be a UUID"};
    return status(job);
}

NSDictionary *vp_photos_import(NSString *job, NSString *source, NSString *name) {
    if (!valid_job(job) || !supported(name) || !source.isAbsolutePath ||
        [source rangeOfString:@"\0"].location != NSNotFound) {
        return @{@"ok": @NO, @"code": @"invalid_request",
            @"error": @"Use a UUID job, an absolute uploaded file path and a supported media filename"};
    }
    if (!stagingLock) return @{@"ok": @NO, @"code": @"unavailable", @"error": @"Photos imports are unavailable"};
    [stagingLock lock];
    @try {
        NSString *root = job_path(job);
        NSDictionary *previous = read_json([root stringByAppendingPathComponent:@"job.json"]);
        if (previous) {
            if (![previous[@"source"] isEqual:source] || ![previous[@"filename"] isEqual:name])
                return @{@"ok": @NO, @"code": @"conflict", @"error": @"job already belongs to another import"};
            return status(job);
        }
        // Bound pending disk and process work to eight media files (2 GiB).
        int pending = 0;
        for (NSString *entry in [NSFileManager.defaultManager contentsOfDirectoryAtPath:imports error:nil]) {
            if (valid_job(entry) && ![status(entry)[@"complete"] boolValue]) pending++;
        }
        if (pending >= 8) return @{@"ok": @NO, @"code": @"busy", @"error": @"Photos import queue is full"};
        struct stat st;
        if (lstat(source.fileSystemRepresentation, &st) || !S_ISREG(st.st_mode) ||
            st.st_size <= 0 || st.st_size > 256LL * 1024 * 1024) {
            return @{@"ok": @NO, @"code": @"invalid_media",
                @"error": @"Expected a regular media file from 1 byte to 256 MiB"};
        }
        // Publish the whole job atomically. A daemon restart never sees half
        // a manifest. Copy first: staging failure leaves the uploaded source.
        NSString *temporary = [imports stringByAppendingPathComponent:
            [NSString stringWithFormat:@".%@-%@", job, NSUUID.UUID.UUIDString]];
        NSString *media = [temporary stringByAppendingPathComponent:name];
        NSFileManager *fm = NSFileManager.defaultManager;
        NSError *error = nil;
        BOOL ok = mobile_directory(temporary) &&
            [fm copyItemAtPath:source toPath:media error:&error] &&
            chown(media.fileSystemRepresentation, 501, 501) == 0 &&
            chmod(media.fileSystemRepresentation, 0600) == 0 &&
            sync_path(media) &&
            write_json(@{@"filename": name, @"bytes": @(st.st_size), @"source": source},
                [temporary stringByAppendingPathComponent:@"job.json"]) &&
            chown([[temporary stringByAppendingPathComponent:@"job.json"] fileSystemRepresentation], 501, 501) == 0 &&
            rename(temporary.fileSystemRepresentation, root.fileSystemRepresentation) == 0 &&
            sync_path(imports);
        if (!ok) {
            [fm removeItemAtPath:temporary error:nil];
            return @{@"ok": @NO, @"code": @"staging_failed", @"error": error.localizedDescription ?: @"Cannot stage Photos import"};
        }
        // The staged media is retained on failure. The upload is temporary;
        // source_removed in the final receipt describes the staged media.
        [fm removeItemAtPath:source error:nil];
        return status(job);
    } @finally {
        [stagingLock unlock];
    }
}

static BOOL finish_import(NSString *root, NSDictionary *metadata, NSString *assetID) {
    NSString *receipt = [root stringByAppendingPathComponent:@"result.json"];
    NSString *path = [root stringByAppendingPathComponent:metadata[@"filename"]];
    NSMutableDictionary *result = [@{@"ok": @YES, @"imported": @YES,
        @"asset_id": assetID, @"source_removed": @NO} mutableCopy];
    // Success is durable before deleting the source or the journal.
    if (!write_json(result, receipt)) return NO;
    NSError *error = nil;
    BOOL removed = [NSFileManager.defaultManager removeItemAtPath:path error:&error] ||
        ![NSFileManager.defaultManager fileExistsAtPath:path];
    result[@"source_removed"] = @(removed);
    if (!removed) result[@"cleanup_error"] = error.localizedDescription ?: @"delete failed";
    if (!write_json(result, receipt)) return NO;
    [NSFileManager.defaultManager removeItemAtPath:[root stringByAppendingPathComponent:@"pending.json"] error:nil];
    return YES;
}

static int import_asset(NSString *root) {
    NSDictionary *metadata = read_json([root stringByAppendingPathComponent:@"job.json"]);
    NSString *name = metadata[@"filename"];
    if (!supported(name)) return 2;
    NSString *path = [root stringByAppendingPathComponent:name];
    NSString *receipt = [root stringByAppendingPathComponent:@"result.json"];
    NSString *journal = [root stringByAppendingPathComponent:@"pending.json"];
    NSDictionary *result = read_json(receipt);
    if ([result[@"ok"] boolValue]) return finish_import(root, metadata, result[@"asset_id"]) ? 0 : 1;
    if (result) return 1;
    NSString *failure;
    @try {
        PHPhotoLibrary *library = PHPhotoLibrary.sharedPhotoLibrary;
        NSString *priorID = read_json(journal)[@"asset_id"];
        if (priorID.length) {
            if ([PHAsset fetchAssetsWithLocalIdentifiers:@[priorID] options:nil].count)
                return finish_import(root, metadata, priorID) ? 0 : 1;
            // A missing asset does not prove a crashed transaction rolled back.
            // Keep its journal and source; never start a second transaction.
            failure = @"Previous Photos transaction is unresolved; inspect the library before retrying";
        } else {
            __block NSString *assetID = nil;
            NSError *error = nil;
            BOOL ok = [library performChangesAndWait:^{
                PHAssetCreationRequest *request = [PHAssetCreationRequest creationRequestForAsset];
                PHAssetResourceCreationOptions *options = [PHAssetResourceCreationOptions new];
                options.originalFilename = name;
                options.shouldMoveFile = NO;
                BOOL video = [@[@"mov", @"mp4", @"m4v"] containsObject:name.pathExtension.lowercaseString];
                [request addResourceWithType:video ? PHAssetResourceTypeVideo : PHAssetResourceTypePhoto
                    fileURL:[NSURL fileURLWithPath:path] options:options];
                assetID = request.placeholderForCreatedAsset.localIdentifier;
                if (!assetID.length || !write_json(@{@"asset_id": assetID}, journal))
                    [NSException raise:@"VPhonePhotoJournal" format:@"Cannot persist Photos transaction identifier"];
            } error:&error];
            if (ok && assetID.length) return finish_import(root, metadata, assetID) ? 0 : 1;
            failure = error.localizedDescription ?: @"Photos did not create an asset";
        }
    } @catch (NSException *exception) {
        // If PhotoKit committed before throwing, the supervisor will recover
        // through the journal once, without creating another asset.
        if (read_json(journal)) return 1;
        failure = [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason];
    }
    write_json(@{@"ok": @NO, @"imported": @NO, @"source_removed": @NO,
        @"code": @"import_failed", @"error": failure ?: @"Photos import failed"}, receipt);
    return 1;
}

int vp_photos_worker_main(void) {
    int argc = *_NSGetArgc();
    char **argv = *_NSGetArgv();
    if (argc < 2 || strcmp(argv[1], workerFlag) != 0) return -1;
    if (argc != 3) return 2;
    if (getuid() == 0) {
        gid_t group = 501;
        if (setgroups(1, &group) || setgid(501) || setuid(501)) return 3;
    }
    if (getuid() != 501) return 3;
    setenv("HOME", "/var/mobile", 1);
    setenv("CFFIXED_USER_HOME", "/var/mobile", 1);
    setenv("TMPDIR", "/var/mobile/Library/Caches", 1);
    @autoreleasepool {
        NSString *job = [NSString stringWithUTF8String:argv[2]];
        if (!valid_job(job)) return 2;
        // Also bound an orphan after the supervising HTTP worker dies.
        alarm(150);
        return import_asset(job_path(job));
    }
}

static void run_worker(NSString *job, BOOL recovery) {
    char executable[PATH_MAX];
    uint32_t length = sizeof(executable);
    if (_NSGetExecutablePath(executable, &length)) return;
    char *arguments[] = {executable, (char *)workerFlag, (char *)job.UTF8String, NULL};
    pid_t pid;
    int error = posix_spawn(&pid, executable, NULL, NULL, arguments, *_NSGetEnviron());
    BOOL finished = NO;
    int childStatus = 0;
    if (!error) {
        for (int i = 0; i < 300; i++) {
            pid_t result = waitpid(pid, &childStatus, WNOHANG);
            if (result == pid) { finished = YES; break; }
            if (result < 0 && errno != EINTR) break;
            usleep(500000);
        }
        if (!finished) {
            kill(pid, SIGKILL);
            while (waitpid(pid, &childStatus, 0) < 0 && errno == EINTR) {}
        }
    }
    NSString *root = job_path(job);
    NSString *receipt = [root stringByAppendingPathComponent:@"result.json"];
    if (read_json(receipt)) return;
    if (recovery && read_json([root stringByAppendingPathComponent:@"pending.json"])) {
        run_worker(job, NO);
        return;
    }
    NSString *reason = error ? [NSString stringWithUTF8String:strerror(error)] :
        (finished ? @"Photos worker exited without a receipt" : @"Photos worker timed out; source retained");
    write_json(@{@"ok": @NO, @"imported": @NO, @"source_removed": @NO,
        @"code": @"worker_failed", @"error": reason}, receipt);
}

void vp_photos_start(void) {
    if (!mobile_directory(imports)) return;
    stagingLock = [NSLock new];
    dispatch_queue_t queue = dispatch_queue_create("vphoned.photos", DISPATCH_QUEUE_SERIAL);
    scanTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(scanTimer, DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC, NSEC_PER_SEC / 4);
    dispatch_source_set_event_handler(scanTimer, ^{
        @autoreleasepool {
            // Inherit this lock into the child. It survives an HTTP worker
            // restart until the old PhotoKit child exits; another daemon
            // cannot race recovery against a still-committing transaction.
            NSString *lockPath = [imports stringByAppendingPathComponent:@".lock"];
            int lockFD = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDWR | O_NOFOLLOW, 0600);
            if (lockFD < 0) return;
            if (flock(lockFD, LOCK_EX | LOCK_NB) == 0) {
                for (NSString *job in [NSFileManager.defaultManager contentsOfDirectoryAtPath:imports error:nil]) {
                    if (!valid_job(job)) continue;
                    NSDictionary *info = status(job);
                    if (![info[@"complete"] boolValue] ||
                        ([info[@"ok"] boolValue] && ![info[@"source_removed"] boolValue])) run_worker(job, YES);
                }
            }
            close(lockFD);
        }
    });
    dispatch_resume(scanTimer);
}
