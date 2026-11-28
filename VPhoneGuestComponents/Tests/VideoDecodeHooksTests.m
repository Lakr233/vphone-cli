// Exercise the native ARC/block ownership and callback wrappers on real host
// dispatch queues. No detours are installed; Apple entry points are test peers.
#include "../VideoDecodeFix/libvphonevideodecode.m"
#include <assert.h>

MISFixDetourResult MISFixDetour(const char *label, void *target, void *replacement, void **original) {
    (void)label; (void)target; (void)replacement; (void)original;
    abort();
}
const char *MISFixDetourDescribe(MISFixDetourResult result) { (void)result; return "test"; }

static VPMessageHandler installedHandler;
static _Atomic unsigned delivered;
static const uint8_t testUUID[16] = {1};

static void admitsCacheImageAndRejectsChangedCode(void) {
    struct {
        struct mach_header_64 header;
        struct uuid_command uuid;
        struct segment_command_64 text;
        uint8_t prefixes[VPVideoEntryCount][16];
    } image = {0};
    image.header.magic = MH_MAGIC_64;
    image.header.ncmds = 2;
    image.header.sizeofcmds = sizeof(image.uuid) + sizeof(image.text);
    image.uuid.cmd = LC_UUID;
    image.uuid.cmdsize = sizeof(image.uuid);
    memcpy(image.uuid.uuid, testUUID, sizeof(testUUID));
    memcpy(metadata.imageUUID, testUUID, sizeof(testUUID));
    image.text.cmd = LC_SEGMENT_64;
    image.text.cmdsize = sizeof(image.text);
    memcpy(image.text.segname, "__TEXT", sizeof("__TEXT"));
    image.text.vmaddr = (uintptr_t)&image - 4096;
    image.text.vmsize = sizeof(image);
    image.text.initprot = VM_PROT_READ | VM_PROT_EXECUTE;
    // Cached images do not have standalone file offsets, even at zero slide.
    image.text.fileoff = 0x2000;
    for (unsigned index = 0; index < VPVideoEntryCount; index++) {
        memset(image.prefixes[index], index + 1, sizeof(image.prefixes[index]));
        metadata.entries[index].offset = (uintptr_t)image.prefixes[index] - (uintptr_t)&image;
        memcpy(metadata.entries[index].original, image.prefixes[index], sizeof(image.prefixes[index]));
    }
    assert(validateImage(&image.header));
    for (unsigned index = 0; index < VPVideoEntryCount; index++)
        assert(entries[index] == (uintptr_t)image.prefixes[index]);
    image.text.fileoff = 0;
    assert(validateImage(&image.header));
    image.prefixes[VPVideoEntryCount - 1][0] ^= 1;
    assert(!validateImage(&image.header));
    image.prefixes[VPVideoEntryCount - 1][0] ^= 1;
    image.uuid.uuid[0] ^= 1;
    assert(!validateImage(&image.header));
    image.uuid.uuid[0] ^= 1;
    image.text.initprot = VM_PROT_READ;
    assert(!validateImage(&image.header));
    image.text.initprot |= VM_PROT_EXECUTE;
    image.text.vmsize = sizeof(image.header);
    assert(!validateImage(&image.header));
    memset(&metadata, 0, sizeof(metadata));
    memset(entries, 0, sizeof(entries));
}

static OSStatus peerInstall(const uint8_t *uuid, VPMessageHandler handler, CFTypeRef weak) {
    (void)uuid; (void)weak;
    installedHandler = [handler copy];
    return noErr;
}
static void peerRemove(const uint8_t *uuid) { (void)uuid; installedHandler = nil; }
static OSStatus peerMessageInfo(CMBlockBufferRef message, uint32_t *type, uint32_t *flags, uint8_t *uuid) {
    (void)message;
    *type = 0x44627566; *flags = 0; memcpy(uuid, testUUID, 16);
    return noErr;
}
static void waitFor(dispatch_semaphore_t semaphore) {
    assert(dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0);
}

static void queuedHandlerOwnsState(void) {
    dispatch_semaphore_t held = dispatch_semaphore_create(0), entered = dispatch_semaphore_create(0);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_queue_t queue;
    __weak VPVideoDecoderState *retiring;
    @autoreleasepool {
        VPMessageHandler handler = ^(CMBlockBufferRef message, CFTypeRef holder) {
            (void)message; (void)holder; atomic_fetch_add(&delivered, 1);
        };
        const void *invoke = NULL;
        memcpy(&invoke, (const uint8_t *)(__bridge const void *)handler + 16, sizeof(invoke));
        entries[VPVideoDecoderHandler] = code(invoke);
        assert(installHandler(testUUID, handler, NULL) == noErr);
        VPVideoDecoderState *state = findState(testUUID);
        assert(state);
        retiring = state;
        queue = state.bufferQueue;
        dispatch_async(queue, ^{ dispatch_semaphore_signal(entered); waitFor(held); });
        waitFor(entered);
        // Like Apple's dispatch block, this owns the installed handler while
        // queued. RemoveHandler may retire the dictionary before it executes.
        VPMessageHandler pending = installedHandler;
        dispatch_async(queue, ^{ pending((CMBlockBufferRef)kCFNull, NULL); dispatch_semaphore_signal(done); });
        removeHandler(testUUID);
        assert(!findState(testUUID));
        assert(!installedHandler);
    }
    assert(retiring && !atomic_load(&delivered));
    dispatch_semaphore_signal(held);
    waitFor(done);
    dispatch_sync(queue, ^{});
    assert(atomic_load(&delivered) == 1);
    assert(!retiring); // No state -> queue -> wrapped-handler retain cycle.
}

static os_unfair_lock borrowedLock = OS_UNFAIR_LOCK_INIT;
static void peerOutput(void *refcon, void *source, OSStatus status, VTDecodeInfoFlags flags,
                       CVImageBufferRef image, CMTime presentation, CMTime duration) {
    (void)refcon; (void)source; (void)status; (void)flags; (void)image; (void)presentation; (void)duration;
    assert(!outputScope);
    assert(os_unfair_lock_trylock(&borrowedLock));
    os_unfair_lock_unlock(&borrowedLock);
}

static void callbackLendsAndRestoresLock(void) {
    VPVideoDecoderState *state = [[VPVideoDecoderState alloc] initWithUUID:[NSData dataWithBytes:testUUID length:16]];
    VPOutputScope scope = {state, &borrowedLock};
    originalOutput = peerOutput;
    os_unfair_lock_lock(&borrowedLock);
    outputScope = &scope;
    outputCallback(NULL, NULL, noErr, 0, NULL, kCMTimeZero, kCMTimeZero);
    assert(outputScope == &scope);
    assert(atomic_load(&state->outputCallbacks) == 1);
    assert(!atomic_load(&state->ownerMismatches));
    uint32_t owner;
    memcpy(&owner, &borrowedLock, sizeof(owner));
    assert((owner & ~1u) == (pthread_mach_thread_np(pthread_self()) & ~1u));
    outputScope = NULL;
    os_unfair_lock_unlock(&borrowedLock);
}

static OSStatus peerSend(CMBlockBufferRef message, CMTime timeout, CMBlockBufferRef *reply) {
    (void)message; (void)timeout; (void)reply;
    assert(!replyScope); // A non-dfrm request must not inherit an outer budget.
    return 17;
}

static void nestedRequestDoesNotBorrowBudget(void) {
    VPReplyScope outer = {nil, 1100000000};
    originalSendSync = peerSend;
    replyScope = &outer;
    assert(sendSync((CMBlockBufferRef)kCFNull, CMTimeMake(1100, 1000), NULL) == 17);
    assert(replyScope == &outer);
    replyScope = NULL;
}

// A borrowed C argument need not support Objective-C retain/release. A plain
// sentinel makes an unintended ARC operation fail instead of being hidden by
// a normally retained public dispatch object. The peers never dereference it.
static uintptr_t borrowedObject;
static bool dispatchedBorrowedObject;
static long peerBorrowedWait(__unsafe_unretained dispatch_semaphore_t semaphore, dispatch_time_t deadline) {
    assert((__bridge void *)semaphore == &borrowedObject);
    assert(deadline == DISPATCH_TIME_FOREVER);
    return 23;
}
static void peerBorrowedDispatch(__unsafe_unretained dispatch_queue_t queue,
                                 __unsafe_unretained dispatch_block_t block) {
    assert((__bridge void *)queue == &borrowedObject);
    assert((__bridge void *)block == &borrowedObject);
    dispatchedBorrowedObject = true;
}
static void dispatchArgumentsStayBorrowed(void) {
    originalSemaphoreWait = peerBorrowedWait;
    originalDispatchAsync = peerBorrowedDispatch;
    replyScope = NULL;
    assert(semaphoreWait((__bridge dispatch_semaphore_t)(void *)&borrowedObject, DISPATCH_TIME_FOREVER) == 23);
    dispatchAsync((__bridge dispatch_queue_t)(void *)&borrowedObject,
                  (__bridge dispatch_block_t)(void *)&borrowedObject);
    assert(dispatchedBorrowedObject);
}

int main(void) {
    @autoreleasepool {
        admitsCacheImageAndRejectsChangedCode();
        states = [NSMutableDictionary dictionary];
        originalInstall = peerInstall; originalRemove = peerRemove; messageInfo = peerMessageInfo;
        atomic_store(&enabled, true);
        queuedHandlerOwnsState();
        callbackLendsAndRestoresLock();
        nestedRequestDoesNotBorrowBudget();
        dispatchArgumentsStayBorrowed();
        atomic_store(&enabled, false);
        assert(states.count == 0);
        puts("VideoDecodeHooksTests: cache admission, handler lifetime, lock restoration, nested scopes and borrowed dispatch arguments passed");
    }
    return 0;
}
