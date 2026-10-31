// backboardd: the inner display's own frames, for SpringBoard to show on the
// shared panel (FoldDisplayPanel.m).
//
// The inner display is a CAWindowServerVirtualDisplay. The render server
// draws it like any display: only when one of its contexts commits, only the
// damaged area, into three pages it takes turns with. Having the render
// server draw it again into a surface of SpringBoard's on every panel frame
// (CARenderServerRenderDisplay) is a second, full render: 120 times a second,
// blurs included, on the render server's one thread, idle or not. That kept
// backboardd near a core and held up every display's frames.
//
// So backboardd shows the page the inner display last finished in a layer of
// a context of its own, and SpringBoard hosts that context. It commits only
// when the inner display has finished a new page, so an idle inner display
// costs the panel nothing. The page being drawn is never the one shown: it is
// the one finished two pages before.
//
// No API hands out a display's pages; acquireFrozenSurface, the nearest,
// answers only for hardware displays. They are read the way QuartzCore reads
// them, each step taken from QuartzCore and checked before use:
// - the CAWindowServerDisplay's _impl, whose type encoding puts the Server
//   right after the impl's mutex;
// - -[CAWindowServerDisplay acquireFrozenSurface], which loads the server
//   from the impl, locks the server's mutex and loads the C++ display from
//   the server: the offsets come from those instructions;
// - the C++ display's virtual displayed_surface(bool), the one function in
//   its vtable with that body (load the shown page's index, load the page,
//   load its surface), which returns the shown page's CA::WindowServer::
//   IOSurface;
// - that surface's virtual iosurface() and id(), the one pair of getters for
//   an object and a 32-bit value right after it, checked against each other
//   with IOSurfaceGetID before the first use.
// Both mutexes are held while the page is read, as acquireFrozenSurface holds
// them. If a step does not match, backboardd publishes no context and
// SpringBoard draws the inner display itself.

#import "FoldDisplayPrivate.h"
#include <notify.h>
#include <pthread.h>
#include <ptrauth.h>

typedef struct __IOSurface *VPSurfaceRef;

// MARK: - instruction shapes

static const uint32_t vpReturn = 0xD65F03C0u;

// ldr xt, [xn, #offset]
static BOOL vpLoad64(uint32_t word, unsigned *rt, unsigned *rn, unsigned *offset) {
    if ((word & 0xFFC00000u) != 0xF9400000u) return NO;
    *rt = word & 31;
    *rn = (word >> 5) & 31;
    *offset = ((word >> 10) & 0xFFF) * 8;
    return YES;
}

// add xd, xn, #value
static BOOL vpAdd64(uint32_t word, unsigned *rd, unsigned *rn, unsigned *value) {
    if ((word & 0xFF800000u) != 0x91000000u) return NO;
    *rd = word & 31;
    *rn = (word >> 5) & 31;
    *value = ((word >> 10) & 0xFFF) << ((word >> 22) & 1 ? 12 : 0);
    return YES;
}

// mov wd, #value
static BOOL vpMove32(uint32_t word, unsigned rd, unsigned *value) {
    if ((word & 0xFFE0001Fu) != (0x52800000u | rd)) return NO;
    *value = (word >> 5) & 0xFFFF;
    return YES;
}

// ldr w0|x0, [x0, #offset]; ret
static BOOL vpGetter(const uint32_t *code, BOOL wide, unsigned *offset) {
    if ((code[0] & 0xFFC003FFu) != (wide ? 0xF9400000u : 0xB9400000u) || code[1] != vpReturn) return NO;
    *offset = ((code[0] >> 10) & 0xFFF) * (wide ? 8 : 4);
    return YES;
}

// mov w8, #pages; add x8, x0, x8; mov w9, #index; add x9, x0, x9;
// ldrb w9, [x9]; mov w10, #8; orr x9, x10, x9, lsl #4; ldr x8, [x8, x9];
// cbz x8, 1f; ldr x0, [x8, #surface]; ret
static BOOL vpDisplayedSurfaceBody(const uint32_t *code) {
    unsigned pages, index, rt, rn, surface;
    return vpMove32(code[0], 8, &pages) && code[1] == 0x8B080008u && vpMove32(code[2], 9, &index) &&
        code[3] == 0x8B090009u && code[4] == 0x39400129u && code[5] == 0x5280010Au && code[6] == 0xAA091149u &&
        code[7] == 0xF8696908u && code[8] == 0xB4000068u && vpLoad64(code[9], &rt, &rn, &surface) && rt == 0 &&
        rn == 8 && code[10] == vpReturn;
}

// MARK: - the inner display's pages

static BOOL vpInQuartzCore(const void *address) {
    Dl_info info;
    return dladdr(address, &info) && info.dli_fname && strstr(info.dli_fname, "/QuartzCore");
}

static const uint32_t *vpCode(const void *pointer) {
    return ptrauth_strip((const uint32_t *)pointer, ptrauth_key_function_pointer);
}

static void **vpVirtualTable(void *object) {
    return ptrauth_strip(*(void ***)object, ptrauth_key_process_independent_data);
}

static BOOL vpVirtualSlot(void **table, int slot) {
    return table[slot] && vpInQuartzCore(vpCode(table[slot]));
}

static void *vpCallable(const uint32_t *code) {
    return ptrauth_sign_unauthenticated((void *)code, ptrauth_key_function_pointer, 0);
}

static pthread_mutex_t *vpImplLock, *vpServerLock;
static void *vpDisplay;
static void *(*vpDisplayedSurface)(void *, bool);
static VPSurfaceRef (*vpSurfaceIOSurface)(void *);
static uint32_t (*vpSurfaceGetID)(VPSurfaceRef);
static BOOL vpSurfaceGetterResolved, vpSurfaceGetterFailed;

static BOOL vpResolveInnerDisplay(id display) {
    Ivar implIvar = class_getInstanceVariable(objc_getClass("CAWindowServerDisplay"), "_impl");
    const char *implType = implIvar ? ivar_getTypeEncoding(implIvar) : "missing";
    static const char serverAfterMutex[] = "^{CAWindowServerDisplayImpl={Mutex={_opaque_pthread_mutex_t=q[56c]}}^{Server}";
    if (strncmp(implType, serverAfterMutex, sizeof(serverAfterMutex) - 1) != 0) {
        vpFoldDisplayLog([NSString stringWithFormat:@"inner pages: impl layout unavailable (%.120s)", implType]);
        return NO;
    }
    Method acquire = class_getInstanceMethod(objc_getClass("CAWindowServerDisplay"), sel_registerName("acquireFrozenSurface"));
    if (!acquire || strcmp(method_getTypeEncoding(acquire), "^{__IOSurface=}16@0:8") != 0) {
        vpFoldDisplayLog(@"inner pages: acquireFrozenSurface unavailable");
        return NO;
    }
    const uint32_t *code = vpCode((void *)method_getImplementation(acquire));
    unsigned server = 32, lockOffset = 0, displayOffset = 0;
    for (int index = 0; index < 32 && !displayOffset; index++) {
        unsigned rt, rn, value;
        if (server == 32 && vpLoad64(code[index], &rt, &rn, &value) && value == sizeof(pthread_mutex_t))
            server = rt;
        else if (server != 32 && !lockOffset && vpAdd64(code[index], &rt, &rn, &value) && rt == 0 && rn == server)
            lockOffset = value;
        else if (server != 32 && lockOffset && vpLoad64(code[index], &rt, &rn, &value) && rt == 0 && rn == server)
            displayOffset = value;
    }
    if (!displayOffset) {
        vpFoldDisplayLog(@"inner pages: server path not found in acquireFrozenSurface");
        return NO;
    }
    uint8_t *impl = *(uint8_t **)((uint8_t *)(__bridge void *)display + ivar_getOffset(implIvar));
    uint8_t *serverObject = impl ? *(uint8_t **)(impl + sizeof(pthread_mutex_t)) : NULL;
    void *cppDisplay = serverObject ? *(void **)(serverObject + displayOffset) : NULL;
    if (!cppDisplay || !vpInQuartzCore(vpVirtualTable(cppDisplay))) {
        vpFoldDisplayLog(@"inner pages: display object unavailable");
        return NO;
    }
    void **table = vpVirtualTable(cppDisplay);
    int matches = 0, found = -1, slot = 0;
    for (; slot < 512 && vpVirtualSlot(table, slot); slot++)
        if (vpDisplayedSurfaceBody(vpCode(table[slot]))) { found = slot; matches++; }
    if (matches != 1) {
        vpFoldDisplayLog([NSString stringWithFormat:@"inner pages: %d displayed-surface functions in %d slots", matches, slot]);
        return NO;
    }
    vpImplLock = (pthread_mutex_t *)impl;
    vpServerLock = (pthread_mutex_t *)(serverObject + lockOffset);
    vpDisplay = cppDisplay;
    vpDisplayedSurface = vpCallable(vpCode(table[found]));
    vpFoldDisplayLog([NSString stringWithFormat:@"inner pages: display at server +0x%x, lock +0x%x, displayed surface slot %d",
        displayOffset, lockOffset, found]);
    return YES;
}

// Under both locks, with the first page the inner display shows.
static BOOL vpResolveSurfaceGetter(void *surface) {
    void **table = vpVirtualTable(surface);
    int pairs = 0, objectSlot = -1, identifierSlot = -1;
    for (int slot = 0; slot < 256 && vpVirtualSlot(table, slot); slot++) {
        unsigned objectOffset, identifierOffset;
        if (!vpGetter(vpCode(table[slot]), YES, &objectOffset)) continue;
        for (int other = 0; other < 256 && vpVirtualSlot(table, other); other++)
            if (vpGetter(vpCode(table[other]), NO, &identifierOffset) && identifierOffset == objectOffset + 8) {
                objectSlot = slot;
                identifierSlot = other;
                pairs++;
            }
    }
    if (pairs != 1) {
        vpFoldDisplayLog([NSString stringWithFormat:@"inner pages: %d surface getter pairs", pairs]);
        return NO;
    }
    VPSurfaceRef (*object)(void *) = vpCallable(vpCode(table[objectSlot]));
    uint32_t (*identifier)(void *) = vpCallable(vpCode(table[identifierSlot]));
    VPSurfaceRef iosurface = object(surface);
    if (!iosurface || vpSurfaceGetID(iosurface) != identifier(surface)) {
        vpFoldDisplayLog(@"inner pages: surface getters disagree");
        return NO;
    }
    vpSurfaceIOSurface = object;
    vpFoldDisplayLog([NSString stringWithFormat:@"inner pages: surface getters at slots %d and %d", objectSlot, identifierSlot]);
    return YES;
}

// The page the inner display last finished, retained; NULL before its first.
static VPSurfaceRef vpCopyShownPage(void) {
    pthread_mutex_lock(vpImplLock);
    pthread_mutex_lock(vpServerLock);
    void *surface = vpDisplayedSurface(vpDisplay, false);
    if (surface && !vpSurfaceGetterResolved && !vpSurfaceGetterFailed) {
        vpSurfaceGetterResolved = vpResolveSurfaceGetter(surface);
        vpSurfaceGetterFailed = !vpSurfaceGetterResolved;
    }
    VPSurfaceRef page = surface && vpSurfaceGetterResolved ? vpSurfaceIOSurface(surface) : NULL;
    if (page) CFRetain(page);
    pthread_mutex_unlock(vpServerLock);
    pthread_mutex_unlock(vpImplLock);
    return page;
}

// MARK: - the context SpringBoard hosts

static id vpPagesContext, vpPagesLayer;
static dispatch_source_t vpPagesTimer;
static VPSurfaceRef vpShownPage;

static void vpPublishPagesContext(uint32_t contextId) {
    int token;
    if (notify_register_check(vpInnerPagesNotification, &token) != NOTIFY_STATUS_OK) return;
    notify_set_state(token, contextId);
    notify_cancel(token);
    notify_post(vpInnerPagesNotification);
}

// On the pages queue, at the inner display's top rate. The context is
// published with its first page, so a host never shows it empty.
static void vpShowNewestPage(void) {
    VPSurfaceRef page = vpCopyShownPage();
    if (vpSurfaceGetterFailed) {
        dispatch_source_cancel(vpPagesTimer);
        return;
    }
    if (!page || page == vpShownPage) {
        if (page) CFRelease(page);
        return;
    }
    Class transaction = objc_getClass("CATransaction");
    ((void (*)(id, SEL))objc_msgSend)(transaction, sel_registerName("begin"));
    ((void (*)(id, SEL, BOOL))objc_msgSend)(transaction, sel_registerName("setDisableActions:"), YES);
    ((void (*)(id, SEL, id))objc_msgSend)(vpPagesLayer, sel_registerName("setContents:"), (__bridge id)page);
    ((void (*)(id, SEL))objc_msgSend)(transaction, sel_registerName("commit"));
    BOOL first = !vpShownPage;
    if (vpShownPage) CFRelease(vpShownPage);
    vpShownPage = page;
    if (first) {
        uint32_t contextId = ((uint32_t (*)(id, SEL))objc_msgSend)(vpPagesContext, sel_registerName("contextId"));
        vpPublishPagesContext(contextId);
        vpFoldDisplayLog([NSString stringWithFormat:@"inner pages: context %u published", contextId]);
    }
}

// From the main queue once the render server runs, never from its display
// detection: the context is a client of that server.
void vpShareInnerDisplayPages(id display) {
    vpPublishPagesContext(0);
    void *iosurface = dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_NOW);
    vpSurfaceGetID = iosurface ? dlsym(iosurface, "IOSurfaceGetID") : NULL;
    Method create = class_getClassMethod(objc_getClass("CAContext"), sel_registerName("remoteContextWithOptions:"));
    if (!vpSurfaceGetID || !create || strcmp(method_getTypeEncoding(create), "@24@0:8@16") != 0) {
        vpFoldDisplayLog(@"inner pages: context ABI unavailable");
        return;
    }
    if (!vpResolveInnerDisplay(display)) return;
    // Hosted only: never drawn on a display by itself, never hit-tested.
    CFStringRef *displayable = dlsym(RTLD_DEFAULT, "kCAContextDisplayable");
    CFStringRef *ignoresHitTest = dlsym(RTLD_DEFAULT, "kCAContextIgnoresHitTest");
    NSMutableDictionary *options = [NSMutableDictionary dictionary];
    if (displayable) options[(__bridge NSString *)*displayable] = @NO;
    if (ignoresHitTest) options[(__bridge NSString *)*ignoresHitTest] = @YES;
    vpPagesContext = ((id (*)(id, SEL, id))objc_msgSend)(objc_getClass("CAContext"), sel_registerName("remoteContextWithOptions:"), options);
    // In the inner display's pixels; SpringBoard's host scales and turns them.
    CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(display, sel_registerName("bounds"));
    vpPagesLayer = [objc_getClass("CALayer") new];
    ((void (*)(id, SEL, CGRect))objc_msgSend)(vpPagesLayer, sel_registerName("setFrame:"), (CGRect){CGPointZero, bounds.size});
    ((void (*)(id, SEL, id))objc_msgSend)(vpPagesContext, sel_registerName("setLayer:"), vpPagesLayer);
    dispatch_queue_t queue = dispatch_queue_create("com.vphone.folddisplay.inner-pages", DISPATCH_QUEUE_SERIAL);
    vpPagesTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(vpPagesTimer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 120, NSEC_PER_SEC / 1200);
    dispatch_source_set_event_handler(vpPagesTimer, ^{ vpShowNewestPage(); });
    dispatch_resume(vpPagesTimer);
    vpFoldDisplayLog([NSString stringWithFormat:@"inner pages: sharing {%.0f, %.0f}, %lu context options",
        bounds.size.width, bounds.size.height, (unsigned long)options.count]);
}
