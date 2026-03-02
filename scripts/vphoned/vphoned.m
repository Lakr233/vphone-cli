/*
 * vphoned — VM guest agent for vphone-cli.
 *
 * Runs inside the iOS VM as a LaunchDaemon. Communicates with the host
 * over vsock using length-prefixed JSON (vphone-control protocol).
 *
 * Auto-update: on each handshake the host sends its binary hash. If it
 * differs from our own, the host pushes a signed replacement. We write
 * it to CACHE_PATH and exit — launchd restarts us, and the bootstrap
 * code in main() exec's the cached binary.
 *
 * Build:
 *   make vphoned
 */

#import <Foundation/Foundation.h>
#include <CommonCrypto/CommonDigest.h>
#include <mach-o/dyld.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#import "vphoned_protocol.h"
#import "vphoned_hid.h"
#import "vphoned_devmode.h"
#import "vphoned_location.h"
#import "vphoned_files.h"

#ifndef AF_VSOCK
#define AF_VSOCK 40
#endif

#define VMADDR_CID_ANY   0xFFFFFFFF
#define VPHONED_PORT     1337

#define INSTALL_PATH "/usr/bin/vphoned"
#define CACHE_PATH   "/var/root/Library/Caches/vphoned"
#define CACHE_DIR    "/var/root/Library/Caches"

struct sockaddr_vm {
    __uint8_t    svm_len;
    sa_family_t  svm_family;
    __uint16_t   svm_reserved1;
    __uint32_t   svm_port;
    __uint32_t   svm_cid;
};

// MARK: - Self-hash

static NSString *sha256_of_file(const char *path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return nil;

    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);

    uint8_t buf[32768];
    ssize_t n;
    while ((n = read(fd, buf, sizeof(buf))) > 0)
        CC_SHA256_Update(&ctx, buf, (CC_LONG)n);
    close(fd);

    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);

    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++)
        [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

static const char *self_executable_path(void) {
    static char path[4096];
    uint32_t size = sizeof(path);
    if (_NSGetExecutablePath(path, &size) != 0) return NULL;
    return path;
}

// MARK: - Auto-update

/// Receive raw binary from host, write to CACHE_PATH, chmod +x.
static BOOL receive_update(int fd, NSUInteger size) {
    mkdir(CACHE_DIR, 0755);

    char tmp_path[] = CACHE_DIR "/vphoned.XXXXXX";
    int tmp_fd = mkstemp(tmp_path);
    if (tmp_fd < 0) {
        NSLog(@"vphoned: mkstemp failed: %s", strerror(errno));
        return NO;
    }

    uint8_t buf[32768];
    NSUInteger remaining = size;
    while (remaining > 0) {
        size_t chunk = remaining < sizeof(buf) ? remaining : sizeof(buf);
        if (!vp_read_fully(fd, buf, chunk)) {
            NSLog(@"vphoned: update read failed at %lu/%lu",
                  (unsigned long)(size - remaining), (unsigned long)size);
            close(tmp_fd);
            unlink(tmp_path);
            return NO;
        }
        if (write(tmp_fd, buf, chunk) != (ssize_t)chunk) {
            NSLog(@"vphoned: update write failed: %s", strerror(errno));
            close(tmp_fd);
            unlink(tmp_path);
            return NO;
        }
        remaining -= chunk;
    }
    close(tmp_fd);
    chmod(tmp_path, 0755);

    if (rename(tmp_path, CACHE_PATH) != 0) {
        NSLog(@"vphoned: rename to cache failed: %s", strerror(errno));
        unlink(tmp_path);
        return NO;
    }

    NSLog(@"vphoned: update written to %s (%lu bytes)", CACHE_PATH, (unsigned long)size);
    return YES;
}

// MARK: - Command Dispatch

static NSDictionary *handle_command(NSDictionary *msg) {
    NSString *type = msg[@"t"];
    id reqId = msg[@"id"];

    if ([type isEqualToString:@"hid"]) {
        uint32_t page  = [msg[@"page"] unsignedIntValue];
        uint32_t usage = [msg[@"usage"] unsignedIntValue];
        NSNumber *downVal = msg[@"down"];
        if (downVal != nil) {
            vp_hid_key(page, usage, [downVal boolValue]);
        } else {
            vp_hid_press(page, usage);
        }
        return vp_make_response(@"ok", reqId);
    }

    if ([type isEqualToString:@"devmode"]) {
        if (!vp_devmode_available()) {
            NSMutableDictionary *r = vp_make_response(@"err", reqId);
            r[@"msg"] = @"XPC not available";
            return r;
        }
        NSString *action = msg[@"action"];
        if ([action isEqualToString:@"status"]) {
            BOOL enabled = vp_devmode_status();
            NSMutableDictionary *r = vp_make_response(@"ok", reqId);
            r[@"enabled"] = @(enabled);
            return r;
        }
        if ([action isEqualToString:@"enable"]) {
            BOOL alreadyEnabled = NO;
            BOOL ok = vp_devmode_arm(&alreadyEnabled);
            NSMutableDictionary *r = vp_make_response(ok ? @"ok" : @"err", reqId);
            if (ok) {
                r[@"already_enabled"] = @(alreadyEnabled);
                r[@"msg"] = alreadyEnabled
                    ? @"developer mode already enabled"
                    : @"developer mode armed, reboot to activate";
            } else {
                r[@"msg"] = @"failed to arm developer mode";
            }
            return r;
        }
        NSMutableDictionary *r = vp_make_response(@"err", reqId);
        r[@"msg"] = [NSString stringWithFormat:@"unknown devmode action: %@", action];
        return r;
    }

    if ([type isEqualToString:@"ping"]) {
        return vp_make_response(@"pong", reqId);
    }

    if ([type isEqualToString:@"location"]) {
        double lat   = [msg[@"lat"] doubleValue];
        double lon   = [msg[@"lon"] doubleValue];
        double alt   = [msg[@"alt"] doubleValue];
        double hacc  = [msg[@"hacc"] doubleValue];
        double vacc  = [msg[@"vacc"] doubleValue];
        double speed = [msg[@"speed"] doubleValue];
        double course = [msg[@"course"] doubleValue];
        vp_location_simulate(lat, lon, alt, hacc, vacc, speed, course);
        return vp_make_response(@"ok", reqId);
    }

    if ([type isEqualToString:@"location_stop"]) {
        vp_location_clear();
        return vp_make_response(@"ok", reqId);
    }

    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = [NSString stringWithFormat:@"unknown type: %@", type];
    return r;
}

// MARK: - Client Session

/// Returns YES if daemon should exit for restart (after update).
static BOOL handle_client(int fd) {
    BOOL should_restart = NO;
    @autoreleasepool {
        NSDictionary *hello = vp_read_message(fd);
        if (!hello) { close(fd); return NO; }

        NSInteger version = [hello[@"v"] integerValue];
        NSString *type = hello[@"t"];

        if (![type isEqualToString:@"hello"]) {
            NSLog(@"vphoned: expected hello, got %@", type);
            close(fd);
            return NO;
        }

        if (version != PROTOCOL_VERSION) {
            NSLog(@"vphoned: version mismatch (client v%ld, daemon v%d)",
                  (long)version, PROTOCOL_VERSION);
            vp_write_message(fd, @{@"v": @PROTOCOL_VERSION, @"t": @"err",
                                   @"msg": @"version mismatch"});
            close(fd);
            return NO;
        }

        // Hash comparison for auto-update
        NSString *hostHash = hello[@"bin_hash"];
        BOOL needUpdate = NO;
        if (hostHash.length > 0) {
            const char *selfPath = self_executable_path();
            NSString *selfHash = selfPath ? sha256_of_file(selfPath) : nil;
            if (selfHash && ![selfHash isEqualToString:hostHash]) {
                NSLog(@"vphoned: hash mismatch (self=%@ host=%@)", selfHash, hostHash);
                needUpdate = YES;
            } else if (selfHash) {
                NSLog(@"vphoned: hash OK");
            }
        }

        // Build capabilities list
        NSMutableArray *caps = [NSMutableArray arrayWithObjects:@"hid", @"devmode", @"file", nil];
        if (vp_location_available()) [caps addObject:@"location"];

        NSMutableDictionary *helloResp = [@{
            @"v": @PROTOCOL_VERSION,
            @"t": @"hello",
            @"name": @"vphoned",
            @"caps": caps,
        } mutableCopy];
        if (needUpdate) helloResp[@"need_update"] = @YES;

        if (!vp_write_message(fd, helloResp)) { close(fd); return NO; }
        NSLog(@"vphoned: client connected (v%d)%s",
              PROTOCOL_VERSION, needUpdate ? " [update pending]" : "");

        NSDictionary *msg;
        while ((msg = vp_read_message(fd)) != nil) {
            @autoreleasepool {
                NSString *t = msg[@"t"];
                NSLog(@"vphoned: recv cmd: %@", t);

                if ([t isEqualToString:@"update"]) {
                    NSUInteger size = [msg[@"size"] unsignedIntegerValue];
                    id reqId = msg[@"id"];
                    NSLog(@"vphoned: receiving update (%lu bytes)", (unsigned long)size);
                    if (size > 0 && size < 10 * 1024 * 1024 && receive_update(fd, size)) {
                        NSMutableDictionary *r = vp_make_response(@"ok", reqId);
                        r[@"msg"] = @"updated, restarting";
                        vp_write_message(fd, r);
                        should_restart = YES;
                        break;
                    } else {
                        NSMutableDictionary *r = vp_make_response(@"err", reqId);
                        r[@"msg"] = @"update failed";
                        vp_write_message(fd, r);
                    }
                    continue;
                }

                // File operations (need fd for inline binary transfer)
                if ([t hasPrefix:@"file_"]) {
                    NSDictionary *resp = vp_handle_file_command(fd, msg);
                    if (resp && !vp_write_message(fd, resp)) break;
                    continue;
                }

                NSDictionary *resp = handle_command(msg);
                if (resp && !vp_write_message(fd, resp)) break;
            }
        }

        NSLog(@"vphoned: client disconnected%s", should_restart ? " (restarting for update)" : "");
        close(fd);
    }
    return should_restart;
}

// MARK: - Main

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // Bootstrap: if running from install path and a cached update exists, exec it
        const char *selfPath = self_executable_path();
        if (selfPath && strcmp(selfPath, INSTALL_PATH) == 0 && access(CACHE_PATH, X_OK) == 0) {
            NSLog(@"vphoned: found cached binary at %s, exec'ing", CACHE_PATH);
            execv(CACHE_PATH, argv);
            NSLog(@"vphoned: execv failed: %s — continuing with installed binary", strerror(errno));
            unlink(CACHE_PATH);
        }

        NSLog(@"vphoned: starting (pid=%d, path=%s)", getpid(), selfPath ?: "?");

        if (!vp_hid_load()) return 1;
        if (!vp_devmode_load()) NSLog(@"vphoned: XPC unavailable, devmode disabled");
        vp_location_load();

        int sock = socket(AF_VSOCK, SOCK_STREAM, 0);
        if (sock < 0) { perror("vphoned: socket(AF_VSOCK)"); return 1; }

        int one = 1;
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

        struct sockaddr_vm addr = {
            .svm_len    = sizeof(struct sockaddr_vm),
            .svm_family = AF_VSOCK,
            .svm_port   = VPHONED_PORT,
            .svm_cid    = VMADDR_CID_ANY,
        };

        if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
            perror("vphoned: bind"); close(sock); return 1;
        }
        if (listen(sock, 2) < 0) {
            perror("vphoned: listen"); close(sock); return 1;
        }

        NSLog(@"vphoned: listening on vsock port %d", VPHONED_PORT);

        for (;;) {
            int client = accept(sock, NULL, NULL);
            if (client < 0) { perror("vphoned: accept"); sleep(1); continue; }
            if (handle_client(client)) {
                NSLog(@"vphoned: exiting for update restart");
                close(sock);
                return 0;
            }
        }
    }
}
