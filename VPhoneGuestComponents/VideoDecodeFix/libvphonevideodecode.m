// Process-private PV video compatibility. No application/SDK hooks, codec
// replacement, dropped output, synthetic ACK or change to Apple's reply clerk.
// See Research/Guest/hevc_paravirtual_decoder_stall.md for the measured cycle.

#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#include "VPVideoDecodeFlow.h"
#include "VPVideoDecodeMetadata.h"
#include "MISFixDetour.h"

#include <dlfcn.h>
#include <fcntl.h>
#include <mach-o/loader.h>
#include <os/lock.h>
#include <os/log.h>
#include <ptrauth.h>
#include <stdatomic.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static const char *const metadataPath = "/usr/lib/vphone-video-decoder";
static const char *const frameworkPath = "/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox";
static VPVideoDecodeMetadata metadata;
static uintptr_t entries[VPVideoEntryCount];
static _Atomic bool enabled;

static uint64_t now(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static uintptr_t code(const void *pointer) {
    return (uintptr_t)ptrauth_strip((void *)pointer, ptrauth_key_function_pointer);
}
static void *callable(uintptr_t address) {
    return ptrauth_sign_unauthenticated((void *)address, ptrauth_key_function_pointer, 0);
}
static void note(NSString *message) {
    os_log(OS_LOG_DEFAULT, "vphone video decoder: %{public}@", message);
}

@interface VPVideoDecoderState : NSObject {
@public
    VPVideoDecodeFlow flow;
    bool flowReady;
    _Atomic uint64_t routedBuffers;
    _Atomic uint64_t outputCallbacks;
    _Atomic uint64_t ownerMismatches;
    _Atomic uint64_t pausedReplyWaits;
}
@property(nonatomic, readonly) NSData *uuid;
@property(nonatomic, readonly) dispatch_queue_t bufferQueue;
- (instancetype)initWithUUID:(NSData *)uuid;
@end

@implementation VPVideoDecoderState
- (instancetype)initWithUUID:(NSData *)uuid {
    if (!(self = [super init])) return nil;
    if (!VPVideoDecodeFlowInit(&flow)) return nil;
    flowReady = true;
    _uuid = [uuid copy];
    _bufferQueue = dispatch_queue_create("org.vphone.video-decoder.buffers", DISPATCH_QUEUE_SERIAL);
    return self;
}
- (void)dealloc {
    if (!flowReady) return;
    note([NSString stringWithFormat:@"retired buffers=%llu callbacks=%llu paused_waits=%llu owner_mismatches=%llu",
          (unsigned long long)atomic_load(&routedBuffers),
          (unsigned long long)atomic_load(&outputCallbacks),
          (unsigned long long)atomic_load(&pausedReplyWaits),
          (unsigned long long)atomic_load(&ownerMismatches)]);
    VPVideoDecodeFlowDestroy(&flow);
}
@end

static NSMutableDictionary<NSData *, VPVideoDecoderState *> *states;
static os_unfair_lock statesLock = OS_UNFAIR_LOCK_INIT;

static VPVideoDecoderState *findState(const uint8_t uuid[16]) {
    NSData *key = [NSData dataWithBytes:uuid length:16];
    os_unfair_lock_lock(&statesLock);
    VPVideoDecoderState *state = states[key];
    os_unfair_lock_unlock(&statesLock);
    return state;
}

typedef void (^VPMessageHandler)(CMBlockBufferRef, CFTypeRef);
typedef OSStatus (*VPMessageInfo)(CMBlockBufferRef, uint32_t *, uint32_t *, uint8_t *);
typedef OSStatus (*VPInstallHandler)(const uint8_t *, VPMessageHandler, CFTypeRef);
typedef void (*VPRemoveHandler)(const uint8_t *);
typedef OSStatus (*VPCreateSession)(CFAllocatorRef, CMVideoFormatDescriptionRef, CFDictionaryRef,
    CFDictionaryRef, const VTDecompressionOutputCallbackRecord *, uintptr_t, VTDecompressionSessionRef *);
typedef OSStatus (*VPInvalidateDecoder)(CFTypeRef);
typedef OSStatus (*VPSendSync)(CMBlockBufferRef, CMTime, CMBlockBufferRef *);

static VPMessageInfo messageInfo;
static VPInstallHandler originalInstall;
static VPRemoveHandler originalRemove;
static VPCreateSession originalCreate;
static VPInvalidateDecoder originalInvalidate;
static VPSendSync originalSendSync;
static VTDecompressionOutputCallback originalOutput;
static void (*originalDispatchAsync)(dispatch_queue_t, dispatch_block_t);
static long (*originalSemaphoreWait)(dispatch_semaphore_t, dispatch_time_t);
static CFTypeRef (*copyWeakObject)(CFTypeRef);
static void *(*decoderBase)(CFTypeRef);
static void *(*derivedStorage)(void *);

// Borrowed only while the enclosing native stack frame owns a strong state and
// decoder reference. Save/restore supports unrelated nested native work.
typedef struct {
    __unsafe_unretained VPVideoDecoderState *state;
    os_unfair_lock_t lock;
} VPOutputScope;
typedef struct {
    __unsafe_unretained VPVideoDecoderState *state;
    uint64_t budget;
} VPReplyScope;
static _Thread_local VPOutputScope *outputScope;
static _Thread_local VPReplyScope *replyScope;

static bool isMessage(CMBlockBufferRef message, uint32_t wanted, uint8_t uuid[16]) {
    uint32_t type = 0, flags = 0;
    return message && messageInfo(message, &type, &flags, uuid) == noErr && type == wanted;
}

static void handleOutput(VPVideoDecoderState *state, VPMessageHandler handler,
                         CMBlockBufferRef message, CFTypeRef weak) {
    CFTypeRef decoder = weak ? copyWeakObject(weak) : NULL;
    if (!decoder) { handler(message, weak); return; }
    uint8_t *storage = derivedStorage(decoderBase(decoder));
    bool matches = storage && !memcmp(storage + metadata.uuidOffset, state.uuid.bytes, 16);
    bool admitted = matches && VPVideoDecodeBeginOutput(&state->flow);
    // Once teardown starts, keep Apple's original lock across any new output.
    // Invalidate clears the session pointers under that same lock, so those
    // handlers need no borrowed-lock lease and must not wait behind dinv.
    VPOutputScope scope = {state, storage ? (os_unfair_lock_t)(storage + metadata.lockOffset) : NULL};
    VPOutputScope *previous = outputScope;
    outputScope = admitted ? &scope : NULL;
    handler(message, weak);
    outputScope = previous;
    if (admitted) VPVideoDecodeEndOutput(&state->flow);
    // A final release can call RemoveHandler; do it after leaving the gate.
    CFRelease(decoder);
}

static OSStatus installHandler(const uint8_t *uuid, VPMessageHandler handler, CFTypeRef weak) {
    // The Blocks ABI's invoke field is public. Captured-field offsets below
    // are private and separately discovered/verified in the host metadata.
    const void *invoke = NULL;
    if (handler) memcpy(&invoke, (const uint8_t *)(__bridge const void *)handler + 16, sizeof(invoke));
    if (!atomic_load(&enabled) || !uuid || code(invoke) != entries[VPVideoDecoderHandler])
        return originalInstall(uuid, handler, weak);
    @autoreleasepool {
        NSData *key = [NSData dataWithBytes:uuid length:16];
        VPVideoDecoderState *state = [[VPVideoDecoderState alloc] initWithUUID:key];
        if (!state) return originalInstall(uuid, handler, weak);
        os_unfair_lock_lock(&statesLock);
        bool inserted = states[key] == nil;
        if (inserted) states[key] = state;
        os_unfair_lock_unlock(&statesLock);
        if (!inserted) return originalInstall(uuid, handler, weak);

        VPMessageHandler wrapped = ^(CMBlockBufferRef message, CFTypeRef holder) {
            @autoreleasepool {
                VPOutputScope *previous = outputScope;
                outputScope = NULL;
                uint8_t messageUUID[16];
                if (isMessage(message, 0x44656d74, messageUUID) && // Demt
                    !memcmp(messageUUID, state.uuid.bytes, 16))
                    handleOutput(state, handler, message, holder);
                else handler(message, holder);
                outputScope = previous;
            }
        };
        OSStatus status = originalInstall(uuid, wrapped, weak);
        if (status != noErr) {
            os_unfair_lock_lock(&statesLock);
            if (states[key] == state) [states removeObjectForKey:key];
            os_unfair_lock_unlock(&statesLock);
        }
        return status;
    }
}

static void removeHandler(const uint8_t *uuid) {
    if (!atomic_load(&enabled) || !uuid) { originalRemove(uuid); return; }
    @autoreleasepool {
        VPVideoDecoderState *state = findState(uuid);
        if (state) VPVideoDecodeStopClock(&state->flow, now());
        originalRemove(uuid);
        os_unfair_lock_lock(&statesLock);
        if (state && states[state.uuid] == state) [states removeObjectForKey:state.uuid];
        os_unfair_lock_unlock(&statesLock);
        // Apple's already queued blocks retain the wrapped handler, hence the
        // state and queue. No synchronous drain of the current output queue.
    }
}

// These detours also receive libdispatch's private, internally owned objects.
// ARC must not acquire an external reference merely to pass a C API argument
// through: worker-thread semaphores can have no external references at all.
static void dispatchAsync(__unsafe_unretained dispatch_queue_t queue,
                          __unsafe_unretained dispatch_block_t block) {
    uintptr_t caller = code(__builtin_return_address(0));
    if (atomic_load(&enabled) && caller == entries[VPVideoDispatchReturn] && block) {
        const uint8_t *bytes = (__bridge const void *)block;
        const void *invoke = NULL;
        memcpy(&invoke, bytes + 16, sizeof(invoke));
        if (code(invoke) == entries[VPVideoDispatchBlock]) {
            CMBlockBufferRef message = NULL;
            memcpy(&message, bytes + metadata.messageOffset, sizeof(message));
            uint8_t uuid[16];
            if (isMessage(message, 0x44627566, uuid)) { // Dbuf only
                @autoreleasepool {
                    VPVideoDecoderState *state = findState(uuid);
                    if (state) {
                        atomic_fetch_add(&state->routedBuffers, 1);
                        originalDispatchAsync(state.bufferQueue, block);
                        return;
                    }
                }
            }
        }
    }
    originalDispatchAsync(queue, block);
}

static void outputCallback(void *refcon, void *source, OSStatus status, VTDecodeInfoFlags flags,
                           CVImageBufferRef image, CMTime presentation, CMTime duration) {
    VPOutputScope *scope = outputScope;
    if (!scope) { originalOutput(refcon, source, status, flags, image, presentation, duration); return; }
    VPVideoDecoderState *state = scope->state;
    uint32_t owner = atomic_load_explicit((_Atomic uint32_t *)scope->lock, memory_order_relaxed);
    uint32_t thread = pthread_mach_thread_np(pthread_self());
    if ((owner & ~1u) != (thread & ~1u)) {
        atomic_fetch_add(&state->ownerMismatches, 1);
        originalOutput(refcon, source, status, flags, image, presentation, duration);
        return;
    }
    atomic_fetch_add(&state->outputCallbacks, 1);
    VPVideoDecodeBeginCallback(&state->flow, now());
    outputScope = NULL; // Nested callbacks cannot borrow this unlocked scope.
    os_unfair_lock_unlock(scope->lock);
    originalOutput(refcon, source, status, flags, image, presentation, duration);
    VPVideoDecodeEndCallback(&state->flow, now());
    os_unfair_lock_lock(scope->lock);
    outputScope = scope;
}

static OSStatus createSession(CFAllocatorRef allocator, CMVideoFormatDescriptionRef format,
    CFDictionaryRef specification, CFDictionaryRef attributes,
    const VTDecompressionOutputCallbackRecord *callback, uintptr_t options, VTDecompressionSessionRef *session) {
    if (atomic_load(&enabled) && callback && code((const void *)callback->decompressionOutputCallback) == entries[VPVideoOutputCallback]) {
        VTDecompressionOutputCallbackRecord replacement = *callback;
        replacement.decompressionOutputCallback = outputCallback;
        return originalCreate(allocator, format, specification, attributes, &replacement, options, session);
    }
    return originalCreate(allocator, format, specification, attributes, callback, options, session);
}

static OSStatus invalidateDecoder(CFTypeRef decoder) {
    if (!atomic_load(&enabled) || !decoder) return originalInvalidate(decoder);
    @autoreleasepool {
        uint8_t *storage = derivedStorage(decoderBase(decoder));
        VPVideoDecoderState *state = storage ? findState(storage + metadata.uuidOffset) : nil;
        if (!state) return originalInvalidate(decoder);
        bool owner = VPVideoDecodeBeginInvalidation(&state->flow, now());
        OSStatus status = originalInvalidate(decoder);
        if (owner) VPVideoDecodeEndInvalidation(&state->flow);
        return status;
    }
}

static OSStatus sendWithScope(CMBlockBufferRef message, CMTime timeout, CMBlockBufferRef *reply,
                              VPReplyScope *scope) {
    VPReplyScope *previous = replyScope;
    replyScope = scope;
    OSStatus status = originalSendSync(message, timeout, reply);
    replyScope = previous;
    return status;
}

static OSStatus sendSync(CMBlockBufferRef message, CMTime timeout, CMBlockBufferRef *reply) {
    uint8_t uuid[16];
    if (!atomic_load(&enabled) || !CMTIME_IS_NUMERIC(timeout) || timeout.value <= 0 ||
        timeout.timescale <= 0 || !isMessage(message, 0x6466726d, uuid)) // dfrm only
        return sendWithScope(message, timeout, reply, NULL);
    @autoreleasepool {
        VPVideoDecoderState *state = findState(uuid);
        double nanoseconds = CMTimeGetSeconds(timeout) * 1e9;
        if (!state || !(nanoseconds > 0 && nanoseconds < (double)INT64_MAX))
            return sendWithScope(message, timeout, reply, NULL);
        VPReplyScope scope = {state, (uint64_t)nanoseconds};
        return sendWithScope(message, timeout, reply, &scope);
    }
}

static long semaphoreWait(__unsafe_unretained dispatch_semaphore_t semaphore, dispatch_time_t deadline) {
    VPReplyScope *scope = replyScope;
    if (!scope || code(__builtin_return_address(0)) != entries[VPVideoReplyWaitReturn] ||
        deadline == DISPATCH_TIME_FOREVER || deadline == DISPATCH_TIME_NOW)
        return originalSemaphoreWait(semaphore, deadline);
    VPVideoDecoderState *state = scope->state;
    uint64_t start = now(), initial = VPVideoDecodeCallbackTime(&state->flow, start);
    bool reported = false;
    for (;;) {
        uint64_t current = now(), callbacks = VPVideoDecodeCallbackTime(&state->flow, current);
        uint64_t remaining = VPVideoDecodeRemaining(scope->budget, start, current, initial, callbacks);
        if (!remaining) return originalSemaphoreWait(semaphore, DISPATCH_TIME_NOW);
        if (!reported && callbacks > initial) {
            atomic_fetch_add(&state->pausedReplyWaits, 1);
            reported = true;
        }
        // A poll interval, not a replacement deadline. Cancellation freezes
        // callback accounting; the original host-response budget then expires.
        uint64_t slice = MIN(remaining, 100 * NSEC_PER_MSEC);
        long result = originalSemaphoreWait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)slice));
        if (result == 0) return 0;
    }
}

// MARK: - UUID and code admission

static bool readMetadata(void) {
    int file = open(metadataPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (file < 0) return false;
    struct stat info;
    bool valid = fstat(file, &info) == 0 && S_ISREG(info.st_mode) && info.st_size == sizeof(metadata);
    if (valid) valid = read(file, &metadata, sizeof(metadata)) == sizeof(metadata);
    close(file);
    return valid && !memcmp(metadata.magic, "VPVD\1\0\0\0", 8) && metadata.entryCount == VPVideoEntryCount &&
        metadata.lockOffset >= 16 && metadata.lockOffset < 256 && metadata.lockOffset % 4 == 0 &&
        metadata.uuidOffset >= metadata.lockOffset + 4 && metadata.uuidOffset < 256 &&
        metadata.uuidOffset % 8 == 0 && metadata.messageOffset >= 32 && metadata.messageOffset <= 96 &&
        metadata.messageOffset % 8 == 0;
}

static bool validateImage(const struct mach_header_64 *header) {
    if (!header || header->magic != MH_MAGIC_64 || header->sizeofcmds > 65536) return false;
    const uint8_t *begin = (const uint8_t *)(header + 1), *end = begin + header->sizeofcmds;
    bool uuid = false, hasText = false;
    uintptr_t slide = 0;
    for (const uint8_t *p = begin; p < end;) {
        if ((size_t)(end - p) < sizeof(struct load_command)) return false;
        const struct load_command *command = (const void *)p;
        if (command->cmdsize < sizeof(*command) || command->cmdsize > (size_t)(end - p)) return false;
        if (command->cmd == LC_UUID && command->cmdsize == sizeof(struct uuid_command))
            uuid = !memcmp(((const struct uuid_command *)command)->uuid, metadata.imageUUID, 16);
        if (command->cmd == LC_SEGMENT_64 && command->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *segment = (const void *)command;
            if (!strncmp(segment->segname, "__TEXT", 16)) {
                // A shared-cache image keeps its cache-relative file offset.
                // dladdr gives its live Mach-O header at the start of __TEXT;
                // the preferred VM address, not fileoff, determines the slide.
                if (hasText || !(segment->initprot & VM_PROT_READ) ||
                    segment->vmsize < sizeof(*header) + header->sizeofcmds) return false;
                slide = (uintptr_t)header - segment->vmaddr;
                hasText = true;
            }
        }
        p += command->cmdsize;
    }
    if (!uuid || !hasText) return false;
    for (unsigned index = 0; index < VPVideoEntryCount; index++) {
        uint64_t offset = metadata.entries[index].offset;
        if (offset > 64 * 1024 * 1024 || offset % 4) return false;
        uintptr_t address = (uintptr_t)header + offset;
        bool executable = false;
        for (const uint8_t *p = begin; p < end;) {
            const struct load_command *command = (const void *)p;
            if (command->cmd == LC_SEGMENT_64 && command->cmdsize >= sizeof(struct segment_command_64)) {
                const struct segment_command_64 *segment = (const void *)command;
                uintptr_t start = segment->vmaddr + slide;
                if ((segment->initprot & VM_PROT_EXECUTE) && address >= start &&
                    segment->vmsize >= 16 && address - start <= segment->vmsize - 16) executable = true;
            }
            p += command->cmdsize;
        }
        if (!executable || memcmp((void *)address, metadata.entries[index].original, 16)) return false;
        entries[index] = address;
    }
    return true;
}

__attribute__((constructor)) static void install(void) {
    if (strcmp(getprogname(), "videocodecd") || access(metadataPath, R_OK)) return;
    @autoreleasepool {
        void *framework = dlopen(frameworkPath, RTLD_NOW | RTLD_LOCAL);
        Dl_info information = {0};
        void *anchor = framework ? dlsym(framework, "VTVideoDecoderGetCMBaseObject") : NULL;
        if (!anchor || !dladdr((void *)code(anchor), &information) || !readMetadata() || !validateImage(information.dli_fbase)) {
            note(@"inactive: metadata, framework UUID or original code mismatch");
            return;
        }
        decoderBase = (void *)anchor;
        derivedStorage = dlsym(RTLD_DEFAULT, "CMBaseObjectGetDerivedStorage");
        copyWeakObject = dlsym(RTLD_DEFAULT, "FigCFWeakReferenceHolderCopyReferencedObject");
        if (!derivedStorage || !copyWeakObject) { note(@"inactive: CoreMedia entry points unavailable"); return; }
        messageInfo = callable(entries[VPVideoMessageInfo]);
        originalOutput = callable(entries[VPVideoOutputCallback]);
        states = [NSMutableDictionary dictionary];
        struct { const char *name; void *target; void *replacement; void **original; } hooks[] = {
            {"PV install handler", callable(entries[VPVideoInstallHandler]), (void *)installHandler, (void **)&originalInstall},
            {"PV remove handler", callable(entries[VPVideoRemoveHandler]), (void *)removeHandler, (void **)&originalRemove},
            {"VT create with options", callable(entries[VPVideoCreateSession]), (void *)createSession, (void **)&originalCreate},
            {"PV invalidate", callable(entries[VPVideoInvalidateDecoder]), (void *)invalidateDecoder, (void **)&originalInvalidate},
            {"PV synchronous request", callable(entries[VPVideoSendSync]), (void *)sendSync, (void **)&originalSendSync},
            {"PV buffer dispatch", (void *)&dispatch_async, (void *)dispatchAsync, (void **)&originalDispatchAsync},
            {"PV reply wait", (void *)&dispatch_semaphore_wait, (void *)semaphoreWait, (void **)&originalSemaphoreWait},
        };
        // The library is loaded by SystemHook during process construction, before
        // the daemon accepts clients. Until every detour is ready, wrappers are
        // pass-through. A refused prologue never produces a half-active repair.
        for (unsigned index = 0; index < sizeof(hooks) / sizeof(hooks[0]); index++) {
            MISFixDetourResult result = MISFixDetour(hooks[index].name, hooks[index].target,
                                                     hooks[index].replacement, hooks[index].original);
            if (result != MISFixDetourOK) {
                note([NSString stringWithFormat:@"inactive: %s: %s", hooks[index].name, MISFixDetourDescribe(result)]);
                return;
            }
        }
        atomic_store(&enabled, true);
        note(@"active: PV Dbuf queue, output lifetime gate, callback-aware reply budget");
    }
}
