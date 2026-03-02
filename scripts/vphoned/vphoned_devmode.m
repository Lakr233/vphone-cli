#import "vphoned_devmode.h"
#include <dlfcn.h>

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

static BOOL gXPCLoaded = NO;

BOOL vp_devmode_load(void) {
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
    gXPCLoaded = YES;
    return YES;
}

BOOL vp_devmode_available(void) {
    return gXPCLoaded;
}

// MARK: - AMFI XPC

typedef enum {
    kAMFIActionArm     = 0,  // arm developer mode (prompts on next reboot)
    kAMFIActionDisable = 1,  // disable developer mode immediately
    kAMFIActionStatus  = 2,  // query: {success, status, armed}
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

BOOL vp_devmode_status(void) {
    NSDictionary *reply = amfi_send(kAMFIActionStatus);
    if (!reply) return NO;
    NSNumber *success = reply[@"success"];
    if (!success || ![success boolValue]) return NO;
    NSNumber *status = reply[@"status"];
    return [status boolValue];
}

BOOL vp_devmode_arm(BOOL *alreadyEnabled) {
    BOOL enabled = vp_devmode_status();
    if (alreadyEnabled) *alreadyEnabled = enabled;
    if (enabled) return YES;

    NSDictionary *reply = amfi_send(kAMFIActionArm);
    if (!reply) return NO;
    NSNumber *success = reply[@"success"];
    return success && [success boolValue];
}
