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
 * Capabilities:
 *   hid — inject HID events (Home, Power, Lock, Unlock) via IOKit
 *
 * Protocol:
 *   Each message: [uint32 big-endian length][UTF-8 JSON payload]
 *   Every JSON object carries "v" (protocol version), "t" (type),
 *   and optionally "id" (request ID, echoed in responses).
 *
 * Build:
 *   xcrun -sdk iphoneos clang -arch arm64 -Os -fobjc-arc \
 *       -o vphoned vphoned.m -framework Foundation
 */

#import <Foundation/Foundation.h>
#include <CommonCrypto/CommonDigest.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <mach-o/dyld.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef AF_VSOCK
#define AF_VSOCK 40
#endif

#define VMADDR_CID_ANY   0xFFFFFFFF
#define VPHONED_PORT     1337
#define PROTOCOL_VERSION 1

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

// MARK: - IOKit (matches TrollVNC's STHIDEventGenerator)

typedef void *IOHIDEventSystemClientRef;
typedef void *IOHIDEventRef;

static IOHIDEventSystemClientRef (*pCreate)(CFAllocatorRef);
static IOHIDEventRef (*pKeyboard)(CFAllocatorRef, uint64_t,
                                  uint32_t, uint32_t, int, int);
static void (*pSetSender)(IOHIDEventRef, uint64_t);
static void (*pDispatch)(IOHIDEventSystemClientRef, IOHIDEventRef);

static IOHIDEventSystemClientRef gClient;
static dispatch_queue_t gHIDQueue;

static BOOL load_iokit(void) {
    void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!h) { NSLog(@"vphoned: dlopen IOKit failed"); return NO; }

    pCreate    = dlsym(h, "IOHIDEventSystemClientCreate");
    pKeyboard  = dlsym(h, "IOHIDEventCreateKeyboardEvent");
    pSetSender = dlsym(h, "IOHIDEventSetSenderID");
    pDispatch  = dlsym(h, "IOHIDEventSystemClientDispatchEvent");

    if (!pCreate || !pKeyboard || !pSetSender || !pDispatch) {
        NSLog(@"vphoned: missing IOKit symbols");
        return NO;
    }

    gClient = pCreate(kCFAllocatorDefault);
    if (!gClient) { NSLog(@"vphoned: IOHIDEventSystemClientCreate returned NULL"); return NO; }

    dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
    gHIDQueue = dispatch_queue_create("com.vphone.vphoned.hid", attr);

    NSLog(@"vphoned: IOKit loaded");
    return YES;
}

static void send_hid_event(IOHIDEventRef event) {
    IOHIDEventRef strong = (IOHIDEventRef)CFRetain(event);
    dispatch_async(gHIDQueue, ^{
        pSetSender(strong, 0x8000000817319372);
        pDispatch(gClient, strong);
        CFRelease(strong);
    });
}

static void press(uint32_t page, uint32_t usage) {
    IOHIDEventRef down = pKeyboard(kCFAllocatorDefault, mach_absolute_time(),
                                   page, usage, 1, 0);
    if (!down) return;
    send_hid_event(down);
    CFRelease(down);

    usleep(100000);

    IOHIDEventRef up = pKeyboard(kCFAllocatorDefault, mach_absolute_time(),
                                 page, usage, 0, 0);
    if (!up) return;
    send_hid_event(up);
    CFRelease(up);
}

// MARK: - Protocol Framing

static BOOL read_fully(int fd, void *buf, size_t count) {
    size_t offset = 0;
    while (offset < count) {
        ssize_t n = read(fd, (uint8_t *)buf + offset, count - offset);
        if (n <= 0) return NO;
        offset += n;
    }
    return YES;
}

static NSDictionary *read_message(int fd) {
    uint32_t header = 0;
    if (!read_fully(fd, &header, 4)) return nil;
    uint32_t length = ntohl(header);
    if (length == 0 || length > 4 * 1024 * 1024) return nil;

    NSMutableData *payload = [NSMutableData dataWithLength:length];
    if (!read_fully(fd, payload.mutableBytes, length)) return nil;

    NSError *err = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:payload options:0 error:&err];
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    return obj;
}

static BOOL write_message(int fd, NSDictionary *dict) {
    NSError *err = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:dict options:0 error:&err];
    if (!json) return NO;

    uint32_t header = htonl((uint32_t)json.length);
    if (write(fd, &header, 4) != 4) return NO;
    if (write(fd, json.bytes, json.length) != (ssize_t)json.length) return NO;
    return YES;
}

// MARK: - Response Helper

/// Build a response dict with protocol version, type, and optional request ID echo.
static NSMutableDictionary *make_response(NSString *type, id reqId) {
    NSMutableDictionary *r = [@{@"v": @PROTOCOL_VERSION, @"t": type} mutableCopy];
    if (reqId) r[@"id"] = reqId;
    return r;
}

// MARK: - Command Dispatch

static NSDictionary *handle_command(NSDictionary *msg) {
    NSString *type = msg[@"t"];
    id reqId = msg[@"id"];

    if ([type isEqualToString:@"hid"]) {
        uint32_t page  = [msg[@"page"] unsignedIntValue];
        uint32_t usage = [msg[@"usage"] unsignedIntValue];
        press(page, usage);
        return make_response(@"ok", reqId);
    }

    if ([type isEqualToString:@"ping"]) {
        return make_response(@"pong", reqId);
    }

    NSMutableDictionary *r = make_response(@"err", reqId);
    r[@"msg"] = [NSString stringWithFormat:@"unknown type: %@", type];
    return r;
}

// MARK: - Auto-update

/// Receive raw binary from host, write to CACHE_PATH, chmod +x.
/// Returns YES on success.
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
        if (!read_fully(fd, buf, chunk)) {
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

// MARK: - Client Session

/// Returns YES if daemon should exit for restart (after update).
static BOOL handle_client(int fd) {
    BOOL should_restart = NO;
    @autoreleasepool {
        NSDictionary *hello = read_message(fd);
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
            write_message(fd, @{@"v": @PROTOCOL_VERSION, @"t": @"err",
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

        NSMutableDictionary *helloResp = [@{
            @"v": @PROTOCOL_VERSION,
            @"t": @"hello",
            @"name": @"vphoned",
            @"caps": @[@"hid"],
        } mutableCopy];
        if (needUpdate) helloResp[@"need_update"] = @YES;

        if (!write_message(fd, helloResp)) { close(fd); return NO; }
        NSLog(@"vphoned: client connected (v%d)%s",
              PROTOCOL_VERSION, needUpdate ? " [update pending]" : "");

        NSDictionary *msg;
        while ((msg = read_message(fd)) != nil) {
            @autoreleasepool {
                NSString *t = msg[@"t"];

                if ([t isEqualToString:@"update"]) {
                    NSUInteger size = [msg[@"size"] unsignedIntegerValue];
                    id reqId = msg[@"id"];
                    NSLog(@"vphoned: receiving update (%lu bytes)", (unsigned long)size);
                    if (size > 0 && size < 10 * 1024 * 1024 && receive_update(fd, size)) {
                        NSMutableDictionary *r = make_response(@"ok", reqId);
                        r[@"msg"] = @"updated, restarting";
                        write_message(fd, r);
                        should_restart = YES;
                        break;
                    } else {
                        NSMutableDictionary *r = make_response(@"err", reqId);
                        r[@"msg"] = @"update failed";
                        write_message(fd, r);
                    }
                    continue;
                }

                NSDictionary *resp = handle_command(msg);
                if (resp && !write_message(fd, resp)) break;
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

        if (!load_iokit()) return 1;

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
