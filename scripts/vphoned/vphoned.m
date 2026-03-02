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
 *   hid     — inject HID events (Home, Power, Lock, Unlock) via IOKit
 *   devmode — enable developer mode via AMFI XPC
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
#include <objc/runtime.h>
#include <objc/message.h>
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

// MARK: - Developer Mode (AMFI XPC)
//
// Talks to com.apple.amfi.xpc to query / arm developer mode.
// Reference: TrollStore RootHelper/devmode.m
// Requires entitlement: com.apple.private.amfi.developer-mode-control

// XPC functions resolved via dlsym to avoid iOS SDK availability
// guards (xpc_connection_create_mach_service is marked unavailable
// on iOS but works at runtime with the right entitlements).

typedef void *xpc_conn_t;  // opaque, avoids typedef conflict with SDK
typedef void *xpc_obj_t;

static xpc_conn_t (*pXpcCreateMach)(const char *, dispatch_queue_t, uint64_t);
static void (*pXpcSetHandler)(xpc_conn_t, void (^)(xpc_obj_t));
static void (*pXpcResume)(xpc_conn_t);
static void (*pXpcCancel)(xpc_conn_t);
static xpc_obj_t (*pXpcSendSync)(xpc_conn_t, xpc_obj_t);
static xpc_obj_t (*pXpcDictGet)(xpc_obj_t, const char *);
static xpc_obj_t (*pCFToXPC)(CFTypeRef);
static CFTypeRef (*pXPCToCF)(xpc_obj_t);

static BOOL load_xpc(void) {
    void *libxpc = dlopen("/usr/lib/system/libxpc.dylib", RTLD_NOW);
    if (!libxpc) { NSLog(@"vphoned: dlopen libxpc failed"); return NO; }

    void *libcf = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_NOW);
    if (!libcf) { NSLog(@"vphoned: dlopen CoreFoundation failed"); return NO; }

    pXpcCreateMach = dlsym(libxpc, "xpc_connection_create_mach_service");
    pXpcSetHandler = dlsym(libxpc, "xpc_connection_set_event_handler");
    pXpcResume     = dlsym(libxpc, "xpc_connection_resume");
    pXpcCancel     = dlsym(libxpc, "xpc_connection_cancel");
    pXpcSendSync   = dlsym(libxpc, "xpc_connection_send_message_with_reply_sync");
    pXpcDictGet    = dlsym(libxpc, "xpc_dictionary_get_value");
    pCFToXPC       = dlsym(libcf, "_CFXPCCreateXPCMessageWithCFObject");
    pXPCToCF       = dlsym(libcf, "_CFXPCCreateCFObjectFromXPCMessage");

    if (!pXpcCreateMach || !pXpcSetHandler || !pXpcResume || !pXpcCancel ||
        !pXpcSendSync || !pXpcDictGet || !pCFToXPC || !pXPCToCF) {
        NSLog(@"vphoned: missing XPC/CF symbols");
        return NO;
    }

    NSLog(@"vphoned: XPC loaded");
    return YES;
}

typedef enum {
    kAMFIActionArm    = 0,  // arm developer mode (prompts on next reboot)
    kAMFIActionDisable = 1, // disable developer mode immediately
    kAMFIActionStatus = 2,  // query: {success, status, armed}
} AMFIXPCAction;

static NSDictionary *amfi_send(AMFIXPCAction action) {
    xpc_conn_t conn = pXpcCreateMach("com.apple.amfi.xpc", NULL, 0);
    if (!conn) {
        NSLog(@"vphoned: amfi xpc connection failed");
        return nil;
    }
    pXpcSetHandler(conn, ^(xpc_obj_t event) {});
    pXpcResume(conn);

    xpc_obj_t msg = pCFToXPC((__bridge CFDictionaryRef)@{@"action": @(action)});
    xpc_obj_t reply = pXpcSendSync(conn, msg);
    pXpcCancel(conn);
    if (!reply) {
        NSLog(@"vphoned: amfi xpc no reply");
        return nil;
    }

    xpc_obj_t cfReply = pXpcDictGet(reply, "cfreply");
    if (!cfReply) {
        NSLog(@"vphoned: amfi xpc no cfreply");
        return nil;
    }

    NSDictionary *dict = (__bridge_transfer NSDictionary *)pXPCToCF(cfReply);
    NSLog(@"vphoned: amfi reply: %@", dict);
    return dict;
}

static BOOL devmode_status(void) {
    NSDictionary *reply = amfi_send(kAMFIActionStatus);
    if (!reply) return NO;
    NSNumber *success = reply[@"success"];
    if (!success || ![success boolValue]) return NO;
    NSNumber *status = reply[@"status"];
    return [status boolValue];
}

static BOOL devmode_arm(BOOL *alreadyEnabled) {
    BOOL enabled = devmode_status();
    if (alreadyEnabled) *alreadyEnabled = enabled;
    if (enabled) return YES;

    NSDictionary *reply = amfi_send(kAMFIActionArm);
    if (!reply) return NO;
    NSNumber *success = reply[@"success"];
    return success && [success boolValue];
}

// MARK: - CoreLocation Simulation

static id gSimManager = nil;
static SEL gSetLocationSel = NULL;
static SEL gClearLocationsSel = NULL;
static SEL gFlushSel = NULL;
static SEL gStartSimSel = NULL;
static BOOL gLocationLoaded = NO;

static BOOL load_corelocation(void) {
    void *h = dlopen("/System/Library/Frameworks/CoreLocation.framework/CoreLocation", RTLD_NOW);
    if (!h) { NSLog(@"vphoned: dlopen CoreLocation failed"); return NO; }

    Class cls = NSClassFromString(@"CLSimulationManager");
    if (!cls) { NSLog(@"vphoned: CLSimulationManager not found"); return NO; }

    gSimManager = [[cls alloc] init];
    if (!gSimManager) { NSLog(@"vphoned: CLSimulationManager alloc/init failed"); return NO; }

    // Probe available selectors for setting location
    SEL candidates[] = {
        NSSelectorFromString(@"setSimulatedLocation:"),
        NSSelectorFromString(@"appendSimulatedLocation:"),
        NSSelectorFromString(@"setLocation:"),
    };
    for (int i = 0; i < 3; i++) {
        if ([gSimManager respondsToSelector:candidates[i]]) {
            gSetLocationSel = candidates[i];
            break;
        }
    }
    if (!gSetLocationSel) {
        NSLog(@"vphoned: no set-location selector found, dumping methods:");
        unsigned int count = 0;
        Method *methods = class_copyMethodList([gSimManager class], &count);
        for (unsigned int i = 0; i < count; i++) {
            NSLog(@"  %s", sel_getName(method_getName(methods[i])));
        }
        free(methods);
        return NO;
    }

    // Probe clear selector
    SEL clearCandidates[] = {
        NSSelectorFromString(@"clearSimulatedLocations"),
        NSSelectorFromString(@"stopLocationSimulation"),
    };
    for (int i = 0; i < 2; i++) {
        if ([gSimManager respondsToSelector:clearCandidates[i]]) {
            gClearLocationsSel = clearCandidates[i];
            break;
        }
    }

    // Probe flush selector
    SEL flushCandidates[] = {
        NSSelectorFromString(@"flush"),
        NSSelectorFromString(@"flushSimulatedLocations"),
    };
    for (int i = 0; i < 2; i++) {
        if ([gSimManager respondsToSelector:flushCandidates[i]]) {
            gFlushSel = flushCandidates[i];
            break;
        }
    }

    // Probe startLocationSimulation selector
    SEL startCandidates[] = {
        NSSelectorFromString(@"startLocationSimulation"),
        NSSelectorFromString(@"startSimulation"),
    };
    for (int i = 0; i < 2; i++) {
        if ([gSimManager respondsToSelector:startCandidates[i]]) {
            gStartSimSel = startCandidates[i];
            break;
        }
    }

    // Start simulation session if available
    if (gStartSimSel) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [gSimManager performSelector:gStartSimSel];
#pragma clang diagnostic pop
    }

    NSLog(@"vphoned: CoreLocation simulation loaded (set=%s, clear=%s, flush=%s, start=%s)",
          sel_getName(gSetLocationSel),
          gClearLocationsSel ? sel_getName(gClearLocationsSel) : "(none)",
          gFlushSel ? sel_getName(gFlushSel) : "(none)",
          gStartSimSel ? sel_getName(gStartSimSel) : "(none)");
    gLocationLoaded = YES;
    return YES;
}

static void simulate_location(double lat, double lon, double alt,
                              double hacc, double vacc,
                              double speed, double course) {
    if (!gLocationLoaded || !gSimManager || !gSetLocationSel) return;

    @try {
        // CLLocationCoordinate2D is {double latitude, double longitude}
        typedef struct { double latitude; double longitude; } CLCoord2D;
        CLCoord2D coord = {lat, lon};

        // Use full CLLocation init including speed and course
        Class locClass = NSClassFromString(@"CLLocation");
        id locInst = [locClass alloc];
        SEL initSel = NSSelectorFromString(
            @"initWithCoordinate:altitude:horizontalAccuracy:verticalAccuracy:course:speed:timestamp:");
        if (![locInst respondsToSelector:initSel]) {
            // Fallback to simpler init
            initSel = NSSelectorFromString(
                @"initWithCoordinate:altitude:horizontalAccuracy:verticalAccuracy:timestamp:");
            typedef id (*InitFunc5)(id, SEL, CLCoord2D, double, double, double, id);
            id location = ((InitFunc5)objc_msgSend)(locInst, initSel, coord, alt, hacc, vacc, [NSDate date]);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [gSimManager performSelector:gSetLocationSel withObject:location];
            if (gFlushSel) [gSimManager performSelector:gFlushSel];
#pragma clang diagnostic pop

            NSLog(@"vphoned: simulate_location lat=%.6f lon=%.6f (fallback init) sel=%s%s",
                  lat, lon, sel_getName(gSetLocationSel),
                  gFlushSel ? " (flushed)" : "");
            return;
        }

        typedef id (*InitFunc7)(id, SEL, CLCoord2D, double, double, double, double, double, id);
        id location = ((InitFunc7)objc_msgSend)(locInst, initSel, coord, alt, hacc, vacc, course, speed, [NSDate date]);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [gSimManager performSelector:gSetLocationSel withObject:location];
        if (gFlushSel) {
            [gSimManager performSelector:gFlushSel];
        }
#pragma clang diagnostic pop

        NSLog(@"vphoned: simulate_location lat=%.6f lon=%.6f alt=%.1f spd=%.1f crs=%.1f sel=%s%s",
              lat, lon, alt, speed, course, sel_getName(gSetLocationSel),
              gFlushSel ? " (flushed)" : "");
    } @catch (NSException *e) {
        NSLog(@"vphoned: simulate_location exception: %@", e);
    }
}

static void clear_simulated_location(void) {
    if (!gLocationLoaded || !gSimManager) return;
    @try {
        if (gClearLocationsSel) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [gSimManager performSelector:gClearLocationsSel];
#pragma clang diagnostic pop
            NSLog(@"vphoned: cleared simulated location");
        }
    } @catch (NSException *e) {
        NSLog(@"vphoned: clear_simulated_location exception: %@", e);
    }
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

static BOOL write_fully(int fd, const void *buf, size_t count) {
    size_t offset = 0;
    while (offset < count) {
        ssize_t n = write(fd, (const uint8_t *)buf + offset, count - offset);
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

// MARK: - File Operations
//
// Handle file_list, file_get, file_put, file_mkdir, file_delete, file_rename.
// file_get and file_put perform inline binary I/O on the socket, so they
// need the fd directly (can't use the simple return-dict pattern).

/// Handle a file command. Returns a response dict, or nil if the response
/// was already written inline (file_get with streaming data).
static NSDictionary *handle_file_command(int fd, NSDictionary *msg) {
    NSString *type = msg[@"t"];
    id reqId = msg[@"id"];

    // -- file_list: list directory contents --
    if ([type isEqualToString:@"file_list"]) {
        NSString *path = msg[@"path"];
        if (!path) {
            NSMutableDictionary *r = make_response(@"err", reqId);
            r[@"msg"] = @"missing path";
            return r;
        }

        NSFileManager *fm = [NSFileManager defaultManager];
        NSError *err = nil;
        NSArray *contents = [fm contentsOfDirectoryAtPath:path error:&err];
        if (!contents) {
            NSMutableDictionary *r = make_response(@"err", reqId);
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

        NSMutableDictionary *r = make_response(@"ok", reqId);
        r[@"entries"] = entries;
        return r;
    }

    // -- file_get: download file from guest to host --
    if ([type isEqualToString:@"file_get"]) {
        NSString *path = msg[@"path"];
        if (!path) {
            NSMutableDictionary *r = make_response(@"err", reqId);
            r[@"msg"] = @"missing path";
            return r;
        }

        struct stat st;
        if (stat([path fileSystemRepresentation], &st) != 0) {
            NSMutableDictionary *r = make_response(@"err", reqId);
            r[@"msg"] = [NSString stringWithFormat:@"stat failed: %s", strerror(errno)];
            return r;
        }
        if (!S_ISREG(st.st_mode)) {
            NSMutableDictionary *r = make_response(@"err", reqId);
            r[@"msg"] = @"not a regular file";
            return r;
        }

        int fileFd = open([path fileSystemRepresentation], O_RDONLY);
        if (fileFd < 0) {
            NSMutableDictionary *r = make_response(@"err", reqId);
            r[@"msg"] = [NSString stringWithFormat:@"open failed: %s", strerror(errno)];
            return r;
        }

        // Send header with file size
        NSMutableDictionary *header = make_response(@"file_data", reqId);
        header[@"size"] = @((unsigned long long)st.st_size);
        if (!write_message(fd, header)) {
            close(fileFd);
            return nil;
        }

        // Stream file data in chunks
        uint8_t buf[32768];
        ssize_t n;
        while ((n = read(fileFd, buf, sizeof(buf))) > 0) {
            if (!write_fully(fd, buf, (size_t)n)) {
                NSLog(@"vphoned: file_get write failed for %@", path);
                close(fileFd);
                return nil;
            }
        }
        close(fileFd);
        return nil; // Response already written inline
    }

    // -- file_put: upload file from host to guest --
    if ([type isEqualToString:@"file_put"]) {
        NSString *path = msg[@"path"];
        NSUInteger size = [msg[@"size"] unsignedIntegerValue];
        NSString *perm = msg[@"perm"];

        if (!path) {
            // Must still drain the raw bytes to keep protocol in sync
            if (size > 0) {
                uint8_t drain[32768];
                NSUInteger remaining = size;
                while (remaining > 0) {
                    size_t chunk = remaining < sizeof(drain) ? remaining : sizeof(drain);
                    if (!read_fully(fd, drain, chunk)) break;
                    remaining -= chunk;
                }
            }
            NSMutableDictionary *r = make_response(@"err", reqId);
            r[@"msg"] = @"missing path";
            return r;
        }

        // Create parent directories if needed
        NSString *parent = [path stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:parent
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];

        // Write to temp file, then rename (atomic, same pattern as receive_update)
        char tmp_path[PATH_MAX];
        snprintf(tmp_path, sizeof(tmp_path), "%s.XXXXXX", [path fileSystemRepresentation]);
        int tmp_fd = mkstemp(tmp_path);
        if (tmp_fd < 0) {
            // Drain bytes
            uint8_t drain[32768];
            NSUInteger remaining = size;
            while (remaining > 0) {
                size_t chunk = remaining < sizeof(drain) ? remaining : sizeof(drain);
                if (!read_fully(fd, drain, chunk)) break;
                remaining -= chunk;
            }
            NSMutableDictionary *r = make_response(@"err", reqId);
            r[@"msg"] = [NSString stringWithFormat:@"mkstemp failed: %s", strerror(errno)];
            return r;
        }

        uint8_t buf[32768];
        NSUInteger remaining = size;
        BOOL ok = YES;
        while (remaining > 0) {
            size_t chunk = remaining < sizeof(buf) ? remaining : sizeof(buf);
            if (!read_fully(fd, buf, chunk)) { ok = NO; break; }
            if (write(tmp_fd, buf, chunk) != (ssize_t)chunk) { ok = NO; break; }
            remaining -= chunk;
        }
        close(tmp_fd);

        if (!ok) {
            unlink(tmp_path);
            NSMutableDictionary *r = make_response(@"err", reqId);
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
            NSMutableDictionary *r = make_response(@"err", reqId);
            r[@"msg"] = [NSString stringWithFormat:@"rename failed: %s", strerror(errno)];
            return r;
        }

        NSLog(@"vphoned: file_put %@ (%lu bytes)", path, (unsigned long)size);
        return make_response(@"ok", reqId);
    }

    // -- file_mkdir --
    if ([type isEqualToString:@"file_mkdir"]) {
        NSString *path = msg[@"path"];
        if (!path) {
            NSMutableDictionary *r = make_response(@"err", reqId);
            r[@"msg"] = @"missing path";
            return r;
        }
        NSError *err = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtPath:path
                                       withIntermediateDirectories:YES
                                                        attributes:nil
                                                             error:&err]) {
            NSMutableDictionary *r = make_response(@"err", reqId);
            r[@"msg"] = err.localizedDescription ?: @"mkdir failed";
            return r;
        }
        return make_response(@"ok", reqId);
    }

    // -- file_delete --
    if ([type isEqualToString:@"file_delete"]) {
        NSString *path = msg[@"path"];
        if (!path) {
            NSMutableDictionary *r = make_response(@"err", reqId);
            r[@"msg"] = @"missing path";
            return r;
        }
        NSError *err = nil;
        if (![[NSFileManager defaultManager] removeItemAtPath:path error:&err]) {
            NSMutableDictionary *r = make_response(@"err", reqId);
            r[@"msg"] = err.localizedDescription ?: @"delete failed";
            return r;
        }
        return make_response(@"ok", reqId);
    }

    // -- file_rename --
    if ([type isEqualToString:@"file_rename"]) {
        NSString *from = msg[@"from"];
        NSString *to = msg[@"to"];
        if (!from || !to) {
            NSMutableDictionary *r = make_response(@"err", reqId);
            r[@"msg"] = @"missing from/to";
            return r;
        }
        NSError *err = nil;
        if (![[NSFileManager defaultManager] moveItemAtPath:from toPath:to error:&err]) {
            NSMutableDictionary *r = make_response(@"err", reqId);
            r[@"msg"] = err.localizedDescription ?: @"rename failed";
            return r;
        }
        return make_response(@"ok", reqId);
    }

    NSMutableDictionary *r = make_response(@"err", reqId);
    r[@"msg"] = [NSString stringWithFormat:@"unknown file command: %@", type];
    return r;
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
            // Single down or up event (for modifier combos)
            IOHIDEventRef ev = pKeyboard(kCFAllocatorDefault, mach_absolute_time(),
                                         page, usage, [downVal boolValue] ? 1 : 0, 0);
            if (ev) { send_hid_event(ev); CFRelease(ev); }
        } else {
            // Full press (down + 100ms + up)
            press(page, usage);
        }
        return make_response(@"ok", reqId);
    }

    if ([type isEqualToString:@"devmode"]) {
        if (!pXpcCreateMach) {
            NSMutableDictionary *r = make_response(@"err", reqId);
            r[@"msg"] = @"XPC not available";
            return r;
        }
        NSString *action = msg[@"action"];
        if ([action isEqualToString:@"status"]) {
            BOOL enabled = devmode_status();
            NSMutableDictionary *r = make_response(@"ok", reqId);
            r[@"enabled"] = @(enabled);
            return r;
        }
        if ([action isEqualToString:@"enable"]) {
            BOOL alreadyEnabled = NO;
            BOOL ok = devmode_arm(&alreadyEnabled);
            NSMutableDictionary *r = make_response(ok ? @"ok" : @"err", reqId);
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
        NSMutableDictionary *r = make_response(@"err", reqId);
        r[@"msg"] = [NSString stringWithFormat:@"unknown devmode action: %@", action];
        return r;
    }

    if ([type isEqualToString:@"ping"]) {
        return make_response(@"pong", reqId);
    }

    if ([type isEqualToString:@"location"]) {
        double lat   = [msg[@"lat"] doubleValue];
        double lon   = [msg[@"lon"] doubleValue];
        double alt   = [msg[@"alt"] doubleValue];
        double hacc  = [msg[@"hacc"] doubleValue];
        double vacc  = [msg[@"vacc"] doubleValue];
        double speed = [msg[@"speed"] doubleValue];
        double course = [msg[@"course"] doubleValue];
        simulate_location(lat, lon, alt, hacc, vacc, speed, course);
        return make_response(@"ok", reqId);
    }

    if ([type isEqualToString:@"location_stop"]) {
        clear_simulated_location();
        return make_response(@"ok", reqId);
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
            @"caps": gLocationLoaded ? @[@"hid", @"devmode", @"file", @"location"] : @[@"hid", @"devmode", @"file"],
        } mutableCopy];
        if (needUpdate) helloResp[@"need_update"] = @YES;

        if (!write_message(fd, helloResp)) { close(fd); return NO; }
        NSLog(@"vphoned: client connected (v%d)%s",
              PROTOCOL_VERSION, needUpdate ? " [update pending]" : "");

        NSDictionary *msg;
        while ((msg = read_message(fd)) != nil) {
            @autoreleasepool {
                NSString *t = msg[@"t"];
                NSLog(@"vphoned: recv cmd: %@", t);

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

                // File operations (need fd for inline binary transfer)
                if ([t hasPrefix:@"file_"]) {
                    NSDictionary *resp = handle_file_command(fd, msg);
                    if (resp && !write_message(fd, resp)) break;
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
        if (!load_xpc()) NSLog(@"vphoned: XPC unavailable, devmode disabled");
        load_corelocation();

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
