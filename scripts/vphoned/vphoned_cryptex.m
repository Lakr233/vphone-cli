/*
 * vphoned_cryptex — Cryptex install over vsock.
 *
 */

#import <Foundation/Foundation.h>
#import <spawn.h>
#import <sys/wait.h>

#import "vphoned_cryptex.h"
#import "vphoned_protocol.h"
#import "unarchive.h"

// We currently rely on the /usr/bin/cryptexctl executable (present in the cloudOS filesystem).
// In future, we can replace this dependency, by directly using the (Swift) CryptexKit framework.
BOOL vp_cryptex_available(void) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    return [fileManager fileExistsAtPath:@"/usr/bin/cryptexctl"];
}


extern char **environ;

typedef NS_ENUM(NSInteger, CryptexErrorCode) {
    CryptexErrorCodeStreamOpenFailure = 1,
    CryptexErrorCodeIOError,
    CryptexErrorCodePersonalizationFailed,
    CryptexErrorCodeNonZeroExit
};

static NSString * const CryptexErrorDomain = @"CryptexErrorDomain";

static NSError *CryptexMakeError(CryptexErrorCode code, NSString *description, NSDictionary * _Nullable userInfo)
{
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[NSLocalizedDescriptionKey] = description;
    if (userInfo.count > 0) {
        [info addEntriesFromDictionary:userInfo];
    }
    return [NSError errorWithDomain:CryptexErrorDomain code:code userInfo:info];
}

static BOOL RunExecutable(const char *executable, const char *const *arguments,
                          NSString * _Nullable *stdoutString) {
    
    int pipefd[2];
    if (pipe(pipefd) != 0) {
        return NO;
    }
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, pipefd[0]);
    posix_spawn_file_actions_addclose(&actions, pipefd[1]);
    
    pid_t pid;
    int status;

    int result = posix_spawn(&pid,
                             executable,
                             &actions,
                             NULL,
                             (char *const *)arguments,
                             environ);

    posix_spawn_file_actions_destroy(&actions);
    close(pipefd[1]);
    
    if (result != 0) {
        close(pipefd[0]);
        return NO;
    }
    
    NSMutableData *data = [NSMutableData data];
    char buffer[4096];
    ssize_t n;
    while ((n = read(pipefd[0], buffer, sizeof(buffer))) > 0) {
        [data appendBytes:buffer length:(NSUInteger)n];
    }
    close(pipefd[0]);

    if (stdoutString) {
        *stdoutString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }
    
    if (waitpid(pid, &status, 0) == -1) {
        return NO;
    }

    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        return NO;
    }

    return YES;
}

BOOL ExtractCryptex(NSString *archivePath, NSString *target, NSString * _Nullable *output)
{
    NSString *archiveError = nil;
    int ret = vp_extract_archive(archivePath, target, &archiveError);
    if (ret != 0) {
        *output = [@"Extraction issue" stringByAppendingString:archiveError];
        return NO;
    }
    return YES;
}

BOOL PersonalizeCryptex(NSString *uncompressedPath,
                        NSString *variant,
                        NSString * _Nullable * _Nullable personalizedPath,
                        NSString * _Nullable *output)
{
    NSString *outputPath = [uncompressedPath stringByAppendingString:@".signed"];
    BOOL ok = [[NSFileManager defaultManager] createDirectoryAtPath:outputPath withIntermediateDirectories:YES attributes:nil error:nil];
    
    NSArray<NSString *> *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:uncompressedPath error:nil];
    for (NSString *name in contents) {
        NSString *path = [uncompressedPath stringByAppendingPathComponent:name];

        const char *args[] = {
            "cryptexctl",
            "personalize",
            "--variant", [variant UTF8String],
            "--replace",
            "--host-identity",
            "--output-directory", [outputPath UTF8String],
            [path UTF8String],
            NULL
        };
        BOOL ok = RunExecutable("/usr/bin/cryptexctl", args, output);
        if (!ok) {
            return NO;
        }
        
        NSArray<NSString *> *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:outputPath error:nil];
        for (NSString *name in contents) {
            NSString *signedPath = [outputPath stringByAppendingPathComponent:name];
            *personalizedPath = signedPath;
            return YES;
        }
        *output = @"Signed Cryptex not found";
        return NO;
    }
    *output = @"No subdir";
    return NO;
}

BOOL InstallCryptex(NSString *cryptexPath, NSString *variant, NSString * _Nullable *output)
{
    const char *args[] = {
        "cryptexctl",
        "install",
        "--variant", [variant UTF8String],
        "--print-info",
        [cryptexPath UTF8String],
        NULL
    };

    return RunExecutable("/usr/bin/cryptexctl", args, output);
}

BOOL HandleCryptex(NSString *archivePath, NSString *variant, NSString * _Nullable *output)
{
    NSString *parentDir = [archivePath stringByDeletingLastPathComponent];
    NSString *fileName = [archivePath lastPathComponent];

    NSString *extractedDir =
        [parentDir stringByAppendingPathComponent:
            [fileName stringByAppendingString:@"-extracted"]];

    NSError *error = nil;
    BOOL ok = [[NSFileManager defaultManager] createDirectoryAtPath:extractedDir withIntermediateDirectories:YES attributes:nil error:&error];
    if (!ok) {
        *output = [@"Failed to create directory:" stringByAppendingString: [error localizedDescription]];
        return NO;
    }

    if (!ExtractCryptex(archivePath, extractedDir, output)) {
        return NO;
    }

    NSString *personalizedPath = nil;
    if (!PersonalizeCryptex(extractedDir, variant, &personalizedPath, output)) {
        return NO;
    }

    if (!InstallCryptex(personalizedPath, variant, output)) {
        return NO;
    }
    return YES;
}


NSDictionary *vp_handle_cryptex_command(NSDictionary *msg) {
    NSString *type = msg[@"t"];
    id reqId = msg[@"id"];
    NSMutableDictionary *r = vp_make_response(@"err", reqId);

    if ([type isEqualToString:@"cryptex_install"]) {
        NSString *archivePath = msg[@"path"];
        NSString *variant = msg[@"variant"];

        NSString *output = nil;
        BOOL success = HandleCryptex(archivePath, variant, &output);

        r[@"msg"] = output;
        r[@"ok"] = @(success);
        return r;
    } else if ([type isEqualToString:@"cryptex_list"]) {
        NSString *output = @"";
        const char *args[] = { "cryptexctl", "list", NULL };
        RunExecutable("/usr/bin/cryptexctl", args, &output);
        r[@"msg"] = output;
        r[@"ok"] = @(YES);
        return r;
    }

    r[@"msg"] = [NSString stringWithFormat:@"unknown cryptex command: %@", type];
    return r;
}
