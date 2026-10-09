#import <Foundation/Foundation.h>
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

// Run the production staging, journal, recovery and supervisor against a fake
// PhotoKit library. No call in this executable opens the host's photo library.
static NSString *testRoot;
static NSString *mode(void) {
    return @(getenv("VP_PHOTOS_TEST_MODE") ?: "success");
}
static NSString *libraryPath(NSString *name) {
    return [testRoot stringByAppendingPathComponent:name];
}

@interface TestPlaceholder : NSObject
@property NSString *localIdentifier;
@end
@implementation TestPlaceholder
@end

@interface TestResourceOptions : NSObject
@property NSString *originalFilename;
@property BOOL shouldMoveFile;
@end
@implementation TestResourceOptions
@end

@interface TestAssetRequest : NSObject
@property TestPlaceholder *placeholderForCreatedAsset;
+ (instancetype)creationRequestForAsset;
- (void)addResourceWithType:(PHAssetResourceType)type fileURL:(NSURL *)url options:(TestResourceOptions *)options;
@end
@implementation TestAssetRequest
+ (instancetype)creationRequestForAsset {
    TestAssetRequest *request = [self new];
    request.placeholderForCreatedAsset = [TestPlaceholder new];
    request.placeholderForCreatedAsset.localIdentifier = @"test-asset/001";
    return request;
}
- (void)addResourceWithType:(PHAssetResourceType)type fileURL:(NSURL *)url options:(TestResourceOptions *)options {
    NSCAssert(!options.shouldMoveFile, @"PhotoKit must not consume the source before a receipt");
    NSCAssert([NSFileManager.defaultManager fileExistsAtPath:url.path], @"staged media exists");
    [@{@"type": @(type), @"filename": options.originalFilename}
        writeToFile:libraryPath(@".resource") atomically:YES];
}
@end

@interface TestAsset : NSObject
+ (NSArray *)fetchAssetsWithLocalIdentifiers:(NSArray *)identifiers options:(id)options;
@end
@implementation TestAsset
+ (NSArray *)fetchAssetsWithLocalIdentifiers:(NSArray *)identifiers options:(id)options {
    return [NSFileManager.defaultManager fileExistsAtPath:libraryPath(@".asset")] ? identifiers : @[];
}
@end

@interface TestPhotoLibrary : NSObject
+ (instancetype)sharedPhotoLibrary;
- (BOOL)performChangesAndWait:(void (^)(void))changes error:(NSError **)error;
@end
@implementation TestPhotoLibrary
+ (instancetype)sharedPhotoLibrary { return [self new]; }
- (BOOL)performChangesAndWait:(void (^)(void))changes error:(NSError **)error {
    NSString *counter = libraryPath(@".transactions");
    NSInteger count = [[NSString stringWithContentsOfFile:counter encoding:NSUTF8StringEncoding error:nil] integerValue];
    [[@(count + 1) stringValue] writeToFile:counter atomically:YES encoding:NSUTF8StringEncoding error:nil];
    if ([mode() isEqual:@"hang-before"]) for (;;) pause();
    changes();
    if ([mode() isEqual:@"failure"]) {
        *error = [NSError errorWithDomain:@"TestPhotos" code:1 userInfo:@{NSLocalizedDescriptionKey: @"injected failure"}];
        return NO;
    }
    [NSData.data writeToFile:libraryPath(@".asset") atomically:YES];
    if ([mode() isEqual:@"crash-after"]) _exit(41);
    if ([mode() isEqual:@"hang-after"]) for (;;) pause();
    if ([mode() isEqual:@"throw-after"]) [NSException raise:@"TestCommit" format:@"committed, reply lost"];
    return YES;
}
@end

static int test_chown(const char *path, uid_t uid, gid_t gid) {
    NSCAssert(uid == 501 && gid == 501, @"only mobile ownership");
    return 0;
}
static uid_t test_getuid(void) { return 501; }
static unsigned test_alarm(unsigned seconds) {
    NSCAssert(seconds == 150, @"production orphan timeout");
    return alarm(2);
}
static int test_usleep(useconds_t microseconds) { return usleep(MIN(microseconds, 5000)); }
static int test_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions,
    const posix_spawnattr_t *attributes, char *const argv[], char *const env[]) {
    if ([mode() isEqual:@"spawn-failure"]) return EAGAIN;
    return posix_spawn(pid, path, actions, attributes, argv, env);
}
#define PHPhotoLibrary TestPhotoLibrary
#define PHAsset TestAsset
#define PHAssetCreationRequest TestAssetRequest
#define PHAssetResourceCreationOptions TestResourceOptions
#define chown test_chown
#define getuid test_getuid
#define alarm test_alarm
#define usleep test_usleep
#define posix_spawn test_spawn
#include "../Native/vphoned_photos.m"
#undef posix_spawn
#undef usleep
#undef alarm
#undef getuid
#undef chown

static int assertions;
static void check(BOOL value, NSString *description) {
    assertions++;
    if (!value) {
        fprintf(stderr, "FAIL: %s\n", description.UTF8String);
        exit(1);
    }
}
static NSString *fresh(NSString *behavior) {
    [NSFileManager.defaultManager removeItemAtPath:testRoot error:nil];
    check(mobile_directory(testRoot), @"temporary root");
    setenv("VP_PHOTOS_TEST_MODE", behavior.UTF8String, 1);
    return NSUUID.UUID.UUIDString;
}
static NSString *upload(void) {
    NSString *path = libraryPath(@".upload");
    check([@"123" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil], @"create upload");
    return path;
}
static NSDictionary *stage(NSString *job, NSString *name) {
    NSDictionary *result = vp_photos_import(job, upload(), name);
    check(!result[@"code"] && ![result[@"complete"] boolValue], @"accepted pending job");
    check(![NSFileManager.defaultManager fileExistsAtPath:libraryPath(@".upload")], @"upload consumed only after staging");
    return result;
}
static NSInteger transactions(void) {
    return [[NSString stringWithContentsOfFile:libraryPath(@".transactions") encoding:NSUTF8StringEncoding error:nil] integerValue];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *root = getenv("VP_PHOTOS_TEST_ROOT");
        if (!root) return 2;
        testRoot = @(root);
        imports = testRoot;
        if (argc == 2 && strcmp(argv[1], "--hold-lock") == 0) {
            for (;;) pause();
        }
        int worker = vp_photos_worker_main();
        if (worker >= 0) return worker;
        stagingLock = [NSLock new];

        for (NSString *name in @[@"photo.JPG", @"movie.mp4"]) {
            NSString *job = fresh(@"success");
            NSDictionary *pending = stage(job, name);
            run_worker(job, YES);
            NSDictionary *result = vp_photos_status(job);
            check([result[@"ok"] boolValue] && [result[@"complete"] boolValue], @"completed success");
            check([result[@"imported"] boolValue] && [result[@"source_removed"] boolValue], @"asset created and source removed");
            check([result[@"filename"] isEqual:name] && [result[@"bytes"] isEqual:pending[@"bytes"]], @"receipt metadata");
            check([result[@"asset_id"] isEqual:@"test-asset/001"], @"asset ID");
            NSDictionary *resource = [NSDictionary dictionaryWithContentsOfFile:libraryPath(@".resource")];
            check([resource[@"type"] integerValue] == ([name hasSuffix:@"mp4"] ? PHAssetResourceTypeVideo : PHAssetResourceTypePhoto), @"image/video resource");
            check([vp_photos_import(job, libraryPath(@".upload"), name) isEqual:result], @"idempotent receipt replay");
            run_worker(job, YES);
            check(transactions() == 1, @"success replay must not create duplicate");
            check([vp_photos_import(job, libraryPath(@".other"), name)[@"code"] isEqual:@"conflict"], @"conflicting path refused");
            check([vp_photos_import(job, libraryPath(@".upload"), @"other.png")[@"code"] isEqual:@"conflict"], @"conflicting name refused");
        }

        for (NSString *behavior in @[@"crash-after", @"throw-after", @"hang-after"]) {
            NSString *job = fresh(behavior);
            stage(job, @"photo.png");
            run_worker(job, YES);
            NSDictionary *result = vp_photos_status(job);
            check([result[@"ok"] boolValue] && [result[@"source_removed"] boolValue], @"recover committed asset after crash/exception/timeout");
            check(transactions() == 1, @"recovery fetches original asset; never submits again");
        }

        for (NSString *behavior in @[@"failure", @"hang-before", @"spawn-failure"]) {
            NSString *job = fresh(behavior);
            stage(job, @"photo.png");
            run_worker(job, YES);
            NSDictionary *result = vp_photos_status(job);
            check([result[@"complete"] boolValue] && ![result[@"ok"] boolValue], @"terminal failure receipt");
            check(![result[@"source_removed"] boolValue], @"failed source retained");
            check([NSFileManager.defaultManager fileExistsAtPath:[job_path(job) stringByAppendingPathComponent:@"photo.png"]], @"retained file exists");
            check([result[@"code"] isEqual:([behavior isEqual:@"failure"] ? @"import_failed" : @"worker_failed")], @"failure classification");
        }

        NSString *job = fresh(@"success");
        stage(job, @"photo.png");
        NSString *journal = [job_path(job) stringByAppendingPathComponent:@"pending.json"];
        check(write_json(@{@"asset_id": @"unresolved"}, journal), @"persist unresolved journal");
        run_worker(job, YES);
        check(![vp_photos_status(job)[@"ok"] boolValue] && transactions() == 0, @"unresolved journal cannot start new transaction");
        check([NSFileManager.defaultManager fileExistsAtPath:journal], @"unresolved journal retained");

        job = fresh(@"success");
        stage(job, @"photo.png");
        check(write_json(@{@"ok": @YES, @"imported": @YES, @"asset_id": @"committed", @"source_removed": @NO},
            [job_path(job) stringByAppendingPathComponent:@"result.json"]), @"persist before cleanup");
        run_worker(job, YES);
        check([vp_photos_status(job)[@"source_removed"] boolValue] && transactions() == 0, @"recover interrupted source cleanup");

        job = fresh(@"success");
        NSString *source = upload();
        check([vp_photos_import(@"no-uuid", source, @"a.png")[@"code"] isEqual:@"invalid_request"], @"invalid job");
        check([vp_photos_status(@"no-uuid")[@"code"] isEqual:@"invalid_request"], @"invalid status job");
        check([vp_photos_status(job)[@"code"] isEqual:@"not_found"], @"unknown job");
        for (NSString *name in @[@"../a.png", @".a.png", @"a.txt", @"folder/a.png", @""]) {
            check([vp_photos_import(job, source, name)[@"code"] isEqual:@"invalid_request"], @"invalid name");
        }
        check([vp_photos_import(job, @"relative", @"a.png")[@"code"] isEqual:@"invalid_request"], @"relative source");
        NSString *link = libraryPath(@".symlink");
        check(symlink(source.fileSystemRepresentation, link.fileSystemRepresentation) == 0, @"symlink fixture");
        check([vp_photos_import(job, link, @"a.png")[@"code"] isEqual:@"invalid_media"], @"symlink refused");
        check([vp_photos_import(job, testRoot, @"a.png")[@"code"] isEqual:@"invalid_media"], @"directory refused");
        int fd = open(source.fileSystemRepresentation, O_WRONLY | O_TRUNC);
        check(fd >= 0, @"size fixture");
        check([vp_photos_import(job, source, @"a.png")[@"code"] isEqual:@"invalid_media"], @"empty file refused");
        check(ftruncate(fd, 256LL * 1024 * 1024 + 1) == 0, @"oversize fixture");
        check([vp_photos_import(job, source, @"a.png")[@"code"] isEqual:@"invalid_media"], @"oversized file refused");
        close(fd);

        fresh(@"success");
        for (int i = 0; i < 8; i++) stage(NSUUID.UUID.UUIDString, @"photo.png");
        source = upload();
        check([vp_photos_import(NSUUID.UUID.UUIDString, source, @"photo.png")[@"code"] isEqual:@"busy"], @"bounded queue");
        check([NSFileManager.defaultManager fileExistsAtPath:source], @"busy preserves upload");

        job = fresh(@"success");
        source = upload();
        check([NSData.data writeToFile:job_path(job) atomically:YES], @"block publication");
        check([vp_photos_import(job, source, @"photo.png")[@"code"] isEqual:@"staging_failed"], @"atomic publication failure");
        check([NSFileManager.defaultManager fileExistsAtPath:source], @"staging failure preserves upload");
        check([NSFileManager.defaultManager contentsOfDirectoryAtPath:testRoot error:nil].count == 2, @"staging failure removes partial directory");

        // The old daemon can exit while its worker still owns the inherited
        // lock. A new daemon must not overlap an in-flight PhotoKit commit.
        fresh(@"success");
        NSString *lockPath = libraryPath(@".lock");
        int lockFD = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDWR, 0600);
        check(lockFD >= 0 && flock(lockFD, LOCK_EX | LOCK_NB) == 0, @"acquire supervisor lock");
        char *args[] = {argv[0], "--hold-lock", NULL};
        pid_t child;
        check(posix_spawn(&child, argv[0], NULL, NULL, args, *_NSGetEnviron()) == 0, @"spawn inheriting worker");
        close(lockFD);
        int nextFD = open(lockPath.fileSystemRepresentation, O_RDWR);
        check(nextFD >= 0 && flock(nextFD, LOCK_EX | LOCK_NB) != 0, @"orphan worker excludes new supervisor");
        kill(child, SIGKILL);
        int childStatus;
        waitpid(child, &childStatus, 0);
        check(flock(nextFD, LOCK_EX | LOCK_NB) == 0, @"worker exit releases inherited lock");
        close(nextFD);

        printf("Photos import: %d assertions passed (real files/processes, fake PhotoKit).\n", assertions);
        [NSFileManager.defaultManager removeItemAtPath:testRoot error:nil];
        return 0;
    }
}
