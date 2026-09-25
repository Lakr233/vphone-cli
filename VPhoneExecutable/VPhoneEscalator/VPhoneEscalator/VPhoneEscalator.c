// vphone-escalator — let an ad-hoc signed binary carry Apple-private
// entitlements, without writing a single byte into anyone's __TEXT.
//
// This is the project's copy of github.com/Lakr233/amfi-allow (MIT), built
// by its own Xcode target for arm64e. Keep it in step with upstream.
//
// It exists because vphone-vm is the one binary here that holds
// com.apple.private.* entitlements, and amfid refuses it. The bundled helper
// allows the binaries the current build just produced. Their
// cdhashes change every time they are signed, so that is a per-build step, not
// a once-per-machine one.
//
// Build with the VPhoneEscalator Xcode target (arm64e, then ad-hoc signed
// during bundle staging). No Python or LLDB is needed.
//
// ---------------------------------------------------------------------------
// Why this exists
// ---------------------------------------------------------------------------
// An ad-hoc signed binary carrying com.apple.private.* entitlements is refused
// by amfid, so the kernel kills it at exec. The usual answers rewrite amfid's
// code:
//
//   * debugger-based tools break on -[AMFIPathValidator_macos
//     validateWithError:] and patch the result register. LLDB's default is a
//     software breakpoint, which plants BRK in amfid's __TEXT.
//   * patchers overwrite the ldrb that loads _isValid in that method's
//     epilogue.
//
// Both produce a dirty, unsigned executable page in amfid. On a host with
// vm.cs_system_enforcement = 1 the kernel validates that page on the next
// fault and kills amfid: CODESIGNING / "Invalid Page". The sysctl is read-only
// at runtime, so no amount of care makes "patch the code" survive it.
//
// ---------------------------------------------------------------------------
// What this does instead
// ---------------------------------------------------------------------------
// AMFI already ships the feature we want. -[AMFIRequirementsManager
// checkCodeRequirementsPreferenceUnsynchronized] reads
//
//     /Library/Preferences/com.apple.security.coderequirements.plist
//
// and takes two keys out of it:
//
//     Entitlements               a code requirement string; it *replaces*
//                                _restrictedRequirement, which is the
//                                requirement a binary must satisfy to be
//                                allowed to carry restricted entitlements.
//     AllowUnsafeDynamicLinking  a BOOL; it becomes the validator's
//                                _shouldUnrestrict, i.e. processes stop being
//                                marked restricted, so DYLD_INSERT_LIBRARIES
//                                is honoured again.
//
// -[AMFIPathValidator_macos validateWithError:] calls
// SecStaticCodeCheckValidityWithErrors(code, 6, restrictedRequirement, &err)
// on exactly that requirement. So `cdhash H"..."` in the Entitlements key is a
// per-binary allowlist, evaluated by Apple's own code.
//
// The whole preference is gated on one BOOL ivar:
//
//     _isRunningInternalBuild = (csr_check(CSR_ALLOW_APPLE_INTERNAL) == 0)
//
// set once in -[AMFIRequirementsManager init] and read in exactly four places,
// all of them about this preference. (Its only other reader, the validator's
// init, uses it to consult the sysctl security.mac.amfi.qa_root_certs_allowed,
// which is 0 on a production machine.)
//
// So this tool writes ONE BYTE: that ivar, in the singleton, on amfid's heap.
//
//   * The singleton pointer lives in a static slot inside the dyld shared
//     cache, at the same address in every process. This tool finds the slot by
//     decoding +[AMFIRequirementsManager sharedManager] and testing each
//     address it loads against the singleton this process just created --
//     nothing is hardcoded, and a layout change is a refusal, not a wild write.
//   * The target is malloc'd heap. No mach_vm_protect, no copy-on-write of a
//     shared-cache page, no executable memory, nothing for the code-signing
//     monitor to object to. vm.cs_system_enforcement is irrelevant.
//   * The ivar offset comes from the live ObjC runtime, never a constant.
//
// It needs root and task_for_pid, i.e. SIP with debugging restrictions off --
// the same prerequisite the old tools had, and the same one that makes amfid
// honour the preference at all (see the csr_check note above).
//
// `off` removes only hashes this tool added, then restarts amfid. It preserves
// the preference and every other value, including AllowUnsafeDynamicLinking.
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <ptrauth.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <unistd.h>

#define AMFID_PATH "/usr/libexec/amfid"
#define AMFI_FRAMEWORK                                                         \
    "/System/Library/PrivateFrameworks/AppleMobileFileIntegrity.framework/"    \
    "AppleMobileFileIntegrity"
#define MANAGER_CLASS "AMFIRequirementsManager"
#ifndef PREFS_PATH
#define PREFS_PATH "/Library/Preferences/com.apple.security.coderequirements.plist"
#endif
// Persistent preference key; changing the executable name must not orphan
// hashes already written under this key.
#define MANAGED_KEY CFSTR("VPhoneEscalator")

#define SCAN_INSNS 64 // +sharedManager is short; this is generous

static mach_port_t g_task = MACH_PORT_NULL;
static pid_t g_amfid = -1;

// --------------------------------------------------------------------------
// this process
// --------------------------------------------------------------------------

static Class manager_class(void) {
    static Class cls = Nil;
    if (cls) return cls;
    if (!dlopen(AMFI_FRAMEWORK, RTLD_NOW)) {
        fprintf(stderr, "error: dlopen AppleMobileFileIntegrity: %s\n", dlerror());
        exit(1);
    }
    cls = objc_getClass(MANAGER_CLASS);
    if (!cls) {
        fprintf(
            stderr,
            "error: class %s not found — this macOS build is not supported\n",
            MANAGER_CLASS
        );
        exit(1);
    }
    return cls;
}

static ptrdiff_t ivar_offset(const char *name) {
    Ivar iv = class_getInstanceVariable(manager_class(), name);
    if (!iv) {
        fprintf(
            stderr,
            "error: ivar %s not found on %s — this macOS build is not supported\n",
            name,
            MANAGER_CLASS
        );
        exit(1);
    }
    return ivar_getOffset(iv);
}

// Read from this process without faulting on an unmapped address.
static int peek_self(uintptr_t addr, void *buf, size_t len) {
    mach_vm_size_t got = 0;
    return mach_vm_read_overwrite(mach_task_self(), addr, len, (mach_vm_address_t)buf, &got) ==
               KERN_SUCCESS &&
           got == len;
}

// Decode +[AMFIRequirementsManager sharedManager] and return the static slot it
// loads the singleton out of. The slot is identified by its contents — the
// singleton this process just built — so a recompiled method that keeps the
// same shape still resolves, and one that does not is reported instead of
// guessed at.
static mach_vm_address_t singleton_slot(void) {
    Class cls = manager_class();
    id local = ((id(*)(id, SEL))objc_msgSend)((id)cls, sel_registerName("sharedManager"));
    if (!local) {
        fprintf(stderr, "error: +[%s sharedManager] returned nil\n", MANAGER_CLASS);
        exit(1);
    }

    Method m = class_getClassMethod(cls, sel_registerName("sharedManager"));
    const uint32_t *code =
        ptrauth_strip((void *)method_getImplementation(m), ptrauth_key_function_pointer);

    uint64_t page[32];
    int have[32];
    memset(have, 0, sizeof(have));
    mach_vm_address_t found = 0;
    int matches = 0;

    for (int i = 0; i < SCAN_INSNS; i++) {
        uint32_t w = code[i];
        if ((w & 0x9F000000u) == 0x90000000u) { // ADRP Xd, #imm
            int rd = (int)(w & 0x1F);
            int64_t imm = (int64_t)((((w >> 5) & 0x7FFFF) << 2) | ((w >> 29) & 3));
            if (imm & (1 << 20)) imm -= (1 << 21); // sign extend 21 bits
            page[rd] = (((uint64_t)(uintptr_t)&code[i]) & ~0xFFFULL) + (uint64_t)(imm << 12);
            have[rd] = 1;
        } else if ((w & 0xFFC00000u) == 0xF9400000u) { // LDR Xt, [Xn, #imm12*8]
            int rn = (int)((w >> 5) & 0x1F);
            if (!have[rn]) continue;
            mach_vm_address_t slot = (mach_vm_address_t)(page[rn] + (((w >> 10) & 0xFFF) * 8));
            uintptr_t value = 0;
            if (peek_self((uintptr_t)slot, &value, sizeof(value)) && value == (uintptr_t)local) {
                if (found && found != slot) matches++;
                found = slot;
                matches++;
            }
        } else if (w == 0xD65F0FFFu || w == 0xD65F03C0u) { // retab / ret
            break;
        }
    }

    if (!found) {
        fprintf(stderr,
                "error: could not find the singleton slot in +[%s sharedManager] — "
                "this macOS build is not supported\n",
                MANAGER_CLASS);
        exit(1);
    }
    (void)matches; // several loads of the same slot are normal
    return found;
}

// --------------------------------------------------------------------------
// amfid
// --------------------------------------------------------------------------

static pid_t find_amfid(void) {
    pid_t pids[8192];
    int n = proc_listpids(PROC_ALL_PIDS, 0, pids, (int)sizeof(pids)) / (int)sizeof(pid_t);
    char path[PROC_PIDPATHINFO_MAXSIZE];
    for (int i = 0; i < n; i++)
        if (pids[i] > 0 && proc_pidpath(pids[i], path, sizeof(path)) > 0 &&
            strcmp(path, AMFID_PATH) == 0)
            return pids[i];
    return -1;
}

// amfid is launch-on-demand. Validating this binary — ad-hoc signed, so the
// kernel has to ask — both starts it and makes it build the singleton.
static void poke_amfid(const char *self_path) {
    pid_t child = 0;
    char *const argv[] = {(char *)self_path, (char *)"--nop", NULL};
    if (posix_spawn(&child, self_path, NULL, NULL, argv, NULL) == 0) {
        int status = 0;
        waitpid(child, &status, 0);
    }
}

static int attach_amfid(const char *self_path) {
    g_amfid = find_amfid();
    if (g_amfid < 0) {
        poke_amfid(self_path);
        g_amfid = find_amfid();
    }
    if (g_amfid < 0) {
        fprintf(stderr, "error: amfid is not running\n");
        return 0;
    }
    kern_return_t kr = task_for_pid(mach_task_self(), g_amfid, &g_task);
    if (kr != KERN_SUCCESS) {
        fprintf(
            stderr,
            "error: task_for_pid(%d): %s\n"
            "       needs root and SIP debugging restrictions off "
            "(csrutil enable --without debug)\n",
            g_amfid,
            mach_error_string(kr)
        );
        return 0;
    }
    return 1;
}

static int read_amfid(mach_vm_address_t addr, void *buf, size_t len) {
    mach_vm_size_t got = 0;
    kern_return_t kr = mach_vm_read_overwrite(g_task, addr, len, (mach_vm_address_t)buf, &got);
    if (kr != KERN_SUCCESS) {
        fprintf(
            stderr,
            "error: read %#llx from amfid: %s\n",
            (unsigned long long)addr,
            mach_error_string(kr)
        );
        return 0;
    }
    return got == len;
}

// One byte, into a malloc'd object. No protection change, no COW of a
// shared-cache page, nothing executable — which is the entire point.
static int write_amfid_byte(mach_vm_address_t addr, uint8_t value) {
    uint8_t current = 0;
    if (!read_amfid(addr, &current, 1)) return 0;
    if (current == value) return 1; // never write what is already there
    kern_return_t kr = mach_vm_write(g_task, addr, (vm_offset_t)&value, 1);
    if (kr != KERN_SUCCESS) {
        fprintf(
            stderr,
            "error: write %#llx in amfid: %s\n",
            (unsigned long long)addr,
            mach_error_string(kr)
        );
        return 0;
    }
    uint8_t back = 0;
    if (!read_amfid(addr, &back, 1) || back != value) {
        fprintf(stderr, "error: write did not take (read back %u, wanted %u)\n", back, value);
        return 0;
    }
    return 1;
}

// The singleton, with enough checking that a wrong answer stops the tool.
static mach_vm_address_t amfid_manager(const char *self_path) {
    mach_vm_address_t slot = singleton_slot();
    uintptr_t remote = 0;
    if (!read_amfid(slot, &remote, sizeof(remote))) return 0;

    if (!remote) { // amfid is up but has not validated anything yet
        poke_amfid(self_path);
        usleep(200 * 1000);
        if (!read_amfid(slot, &remote, sizeof(remote))) return 0;
    }
    if (!remote) {
        fprintf(stderr, "error: amfid has not created its %s yet\n", MANAGER_CLASS);
        return 0;
    }

    // An ObjC object here, not a stale word: the class bits of its isa have to
    // match the class bits of ours.
    const uintptr_t kISAClassBits = 0x0000000FFFFFFFF8ULL;
    uintptr_t remote_isa = 0, local_isa = (uintptr_t)manager_class();
    if (!read_amfid((mach_vm_address_t)remote, &remote_isa, sizeof(remote_isa))) return 0;
    if ((remote_isa & kISAClassBits) != (local_isa & kISAClassBits)) {
        fprintf(
            stderr,
            "error: %#lx in amfid is not an %s (isa %#lx)\n",
            (unsigned long)remote,
            MANAGER_CLASS,
            (unsigned long)remote_isa
        );
        return 0;
    }

    // Both BOOL ivars must actually read as booleans.
    uint8_t flags[2] = {0, 0};
    if (!read_amfid((mach_vm_address_t)remote + ivar_offset("_allowUnsafeDynamicLinking"),
                    &flags[0], 1) ||
        !read_amfid((mach_vm_address_t)remote + ivar_offset("_isRunningInternalBuild"), &flags[1],
                    1))
        return 0;
    if (flags[0] > 1 || flags[1] > 1) {
        fprintf(
            stderr,
            "error: %s ivars do not read as booleans (%u, %u)\n",
            MANAGER_CLASS,
            flags[0],
            flags[1]
        );
        return 0;
    }
    return (mach_vm_address_t)remote;
}

// --------------------------------------------------------------------------
// cdhashes and the preference
// --------------------------------------------------------------------------

// What amfid would use if this tool had never run. -init builds it through
// -resetRestrictedRequirement, so this process's own singleton is carrying it
// right now: ask that one rather than hardcoding a string that changes with
// the OS. Ours is then this, plus a cdhash — strictly more permissive, never
// less.
static CFStringRef stock_requirement(void) {
    Class cls = manager_class();
    id mgr = ((id(*)(id, SEL))objc_msgSend)((id)cls, sel_registerName("sharedManager"));
    SecRequirementRef stock = ((SecRequirementRef(*)(id, SEL))objc_msgSend)(
        mgr,
        sel_registerName("restrictedRequirement")
    );
    CFStringRef text = NULL;
    if (!stock || SecRequirementCopyString(stock, kSecCSDefaultFlags, &text) != errSecSuccess ||
        !text) {
        fprintf(stderr, "error: cannot read the stock restricted requirement — "
                        "this macOS build is not supported\n");
        exit(1);
    }
    return text;
}

static CFMutableArrayRef cdhashes_for(int count, char **paths) {
    CFMutableArrayRef result = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    for (int i = 0; i < count; i++) {
        CFURLRef url = CFURLCreateFromFileSystemRepresentation(
            NULL,
            (const UInt8 *)paths[i],
            (CFIndex)strlen(paths[i]),
            false
        );
        SecStaticCodeRef code = NULL;
        OSStatus st = SecStaticCodeCreateWithPath(url, kSecCSDefaultFlags, &code);
        CFRelease(url);
        if (st != errSecSuccess) {
            fprintf(stderr, "error: %s: not signed code (%d)\n", paths[i], (int)st);
            exit(1);
        }

        // kSecCSSigningInformation is what fills in kSecCodeInfoCdHashes — every
        // code directory, so a universal binary gets each slice allowlisted
        // rather than only the one kSecCodeInfoUnique happens to name.
        CFDictionaryRef info = NULL;
        st = SecCodeCopySigningInformation(code, kSecCSSigningInformation, &info);
        CFRelease(code);
        if (st != errSecSuccess) {
            fprintf(
                stderr,
                "error: %s: cannot read signing information (%d)\n",
                paths[i],
                (int)st
            );
            exit(1);
        }

        CFArrayRef hashes = CFDictionaryGetValue(info, kSecCodeInfoCdHashes);
        CFDataRef unique = CFDictionaryGetValue(info, kSecCodeInfoUnique);
        CFIndex n = hashes ? CFArrayGetCount(hashes) : (unique ? 1 : 0);
        if (n == 0) {
            fprintf(stderr, "error: %s: no cdhash\n", paths[i]);
            exit(1);
        }
        for (CFIndex h = 0; h < n; h++) {
            CFDataRef d = hashes ? CFArrayGetValueAtIndex(hashes, h) : unique;
            CFMutableStringRef hash = CFStringCreateMutable(NULL, 0);
            const UInt8 *b = CFDataGetBytePtr(d);
            for (CFIndex k = 0; k < CFDataGetLength(d); k++)
                CFStringAppendFormat(hash, NULL, CFSTR("%02x"), b[k]);
            if (!CFArrayContainsValue(result, CFRangeMake(0, CFArrayGetCount(result)), hash))
                CFArrayAppendValue(result, hash);
            CFRelease(hash);
        }
        CFRelease(info);
    }
    return result;
}

static CFStringRef requirement_with_hashes(CFStringRef base, CFArrayRef hashes) {
    CFMutableStringRef req = CFStringCreateMutableCopy(NULL, 0, base);
    for (CFIndex i = 0; i < CFArrayGetCount(hashes); i++) {
        CFStringAppend(req, CFSTR(" or cdhash H\""));
        CFStringAppend(req, CFArrayGetValueAtIndex(hashes, i));
        CFStringAppend(req, CFSTR("\""));
    }

    // It has to compile here, or amfid would silently keep the old one.
    SecRequirementRef parsed = NULL;
    OSStatus st = SecRequirementCreateWithString(req, kSecCSDefaultFlags, &parsed);
    if (st != errSecSuccess) {
        fprintf(stderr, "error: the requirement does not compile (%d)\n", (int)st);
        exit(1);
    }
    CFRelease(parsed);
    return req;
}

static bool valid_hashes(CFArrayRef hashes) {
    if (!hashes || CFGetTypeID(hashes) != CFArrayGetTypeID()) return false;
    for (CFIndex i = 0; i < CFArrayGetCount(hashes); i++) {
        CFTypeRef value = CFArrayGetValueAtIndex(hashes, i);
        if (CFGetTypeID(value) != CFStringGetTypeID()) return false;
        CFStringRef hash = value;
        CFIndex length = CFStringGetLength(hash);
        if (length < 2 || length > 128 || length % 2) return false;
        for (CFIndex j = 0; j < length; j++) {
            UniChar c = CFStringGetCharacterAtIndex(hash, j);
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
        }
    }
    return true;
}

static CFMutableDictionaryRef read_prefs(bool *existed) {
    int fd = open(PREFS_PATH, O_RDONLY | O_NOFOLLOW);
    if (fd < 0 && errno == ENOENT) {
        *existed = false;
        return CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                         &kCFTypeDictionaryValueCallBacks);
    }
    if (fd < 0) {
        fprintf(stderr, "error: open %s: %s\n", PREFS_PATH, strerror(errno));
        return NULL;
    }
    *existed = true;
    struct stat st;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_size < 0 || st.st_size > 1024 * 1024) {
        fprintf(stderr, "error: %s is not a regular plist under 1 MiB\n", PREFS_PATH);
        close(fd);
        return NULL;
    }
    UInt8 *bytes = malloc(st.st_size ? (size_t)st.st_size : 1);
    if (!bytes) { close(fd); return NULL; }
    size_t done = 0;
    while (done < (size_t)st.st_size) {
        ssize_t n = read(fd, bytes + done, (size_t)st.st_size - done);
        if (n <= 0) break;
        done += (size_t)n;
    }
    close(fd);
    if (done != (size_t)st.st_size) {
        fprintf(stderr, "error: could not read %s completely\n", PREFS_PATH);
        free(bytes);
        return NULL;
    }
    CFDataRef data = CFDataCreate(NULL, bytes, (CFIndex)done);
    free(bytes);
    CFPropertyListRef plist = CFPropertyListCreateWithData(NULL, data,
        kCFPropertyListMutableContainersAndLeaves, NULL, NULL);
    CFRelease(data);
    if (!plist || CFGetTypeID(plist) != CFDictionaryGetTypeID()) {
        fprintf(stderr, "error: %s is not a valid dictionary plist\n", PREFS_PATH);
        if (plist) CFRelease(plist);
        return NULL;
    }
    return (CFMutableDictionaryRef)plist;
}

static int write_prefs(CFDictionaryRef d) {
    CFDataRef data = CFPropertyListCreateData(NULL, d, kCFPropertyListXMLFormat_v1_0, 0, NULL);
    if (!data) return 0;

    char tmp[] = PREFS_PATH ".XXXXXX";
    int fd = mkstemp(tmp);
    if (fd < 0) {
        fprintf(stderr, "error: %s: %s\n", tmp, strerror(errno));
        CFRelease(data);
        return 0;
    }
    const UInt8 *bytes = CFDataGetBytePtr(data);
    size_t length = (size_t)CFDataGetLength(data), done = 0;
    while (done < length) {
        ssize_t n = write(fd, bytes + done, length - done);
        if (n <= 0) break;
        done += (size_t)n;
    }
    CFRelease(data);
    struct stat old;
    bool had_old = stat(PREFS_PATH, &old) == 0;
    int ok = done == length && fchmod(fd, had_old ? old.st_mode & 0777 : 0644) == 0 &&
             fchown(fd, had_old ? old.st_uid : geteuid(),
                    had_old ? old.st_gid : getegid()) == 0 &&
             fsync(fd) == 0;
    if (close(fd) != 0) ok = 0;
    if (!ok) {
        fprintf(stderr, "error: could not write %s: %s\n", tmp, strerror(errno));
        unlink(tmp);
        return 0;
    }
    if (rename(tmp, PREFS_PATH) != 0) {
        fprintf(stderr, "error: rename %s: %s\n", PREFS_PATH, strerror(errno));
        unlink(tmp);
        return 0;
    }
    return 1;
}

// launchd watches this path and pokes amfid; touching it is the reload.
static void trigger_reload(void) { utimes(PREFS_PATH, NULL); }

// --------------------------------------------------------------------------
// reporting
// --------------------------------------------------------------------------

static int sysctl_int(const char *name) {
    int value = 0;
    size_t len = sizeof(value);
    return sysctlbyname(name, &value, &len, NULL, 0) == 0 ? value : -1;
}

static void report(const char *self_path) {
    printf("host\n");
    printf(
        "  vm.cs_system_enforcement   %d%s\n",
        sysctl_int("vm.cs_system_enforcement"),
        sysctl_int("vm.cs_system_enforcement") == 1 ? "  (code patching is fatal here)" : ""
    );
    printf("  preference file            %s\n",
           access(PREFS_PATH, R_OK) == 0 ? PREFS_PATH : PREFS_PATH " (absent)");

    CFStringRef stock = stock_requirement();
    char buf[4096];
    if (CFStringGetCString(stock, buf, sizeof(buf), kCFStringEncodingUTF8))
        printf("  stock requirement          %s\n", buf);
    CFRelease(stock);

    if (!attach_amfid(self_path)) return;
    printf("amfid\n");
    printf("  pid                        %d\n", g_amfid);
    printf("  singleton slot             %#llx  (shared cache, same in every process)\n",
           (unsigned long long)singleton_slot());

    mach_vm_address_t mgr = amfid_manager(self_path);
    if (!mgr) return;
    uint8_t internal = 0, unsafe_linking = 0;
    uintptr_t restricted = 0;
    read_amfid(mgr + ivar_offset("_isRunningInternalBuild"), &internal, 1);
    read_amfid(mgr + ivar_offset("_allowUnsafeDynamicLinking"), &unsafe_linking, 1);
    read_amfid(mgr + ivar_offset("_restrictedRequirement"), &restricted, sizeof(restricted));
    printf("  %s          %#llx\n", MANAGER_CLASS, (unsigned long long)mgr);
    printf("  _isRunningInternalBuild    %u%s\n", internal, internal ? "  (preference honoured)" : "");
    printf("  _allowUnsafeDynamicLinking %u\n", unsafe_linking);
    printf(
        "  _restrictedRequirement     %#lx%s\n",
        (unsigned long)restricted,
        restricted ? "" : "  (nothing would be allowed)"
    );
}

// --------------------------------------------------------------------------

static int update_allow_preferences(int count, char **paths) {
    bool existed = false;
    CFMutableDictionaryRef prefs = read_prefs(&existed);
    if (!prefs) return 1;
    CFTypeRef current = CFDictionaryGetValue(prefs, CFSTR("Entitlements"));
    CFTypeRef unsafe = CFDictionaryGetValue(prefs, CFSTR("AllowUnsafeDynamicLinking"));
    CFDictionaryRef managed = CFDictionaryGetValue(prefs, MANAGED_KEY);
    if ((current && CFGetTypeID(current) != CFStringGetTypeID()) ||
        (managed && CFGetTypeID(managed) != CFDictionaryGetTypeID())) {
        fprintf(stderr, "error: %s has unexpected value types\n", PREFS_PATH);
        CFRelease(prefs);
        return 1;
    }
    CFStringRef base = NULL;
    CFMutableArrayRef hashes = NULL;
    bool had_entitlements = current != NULL;
    if (managed) {
        base = CFDictionaryGetValue(managed, CFSTR("Base"));
        CFArrayRef saved = CFDictionaryGetValue(managed, CFSTR("Hashes"));
        CFTypeRef original_entitlements = CFDictionaryGetValue(managed, CFSTR("HadEntitlements"));
        if (!base || CFGetTypeID(base) != CFStringGetTypeID() || !valid_hashes(saved) ||
            !original_entitlements ||
            CFGetTypeID(original_entitlements) != CFBooleanGetTypeID()) {
            fprintf(stderr, "error: invalid %s metadata in %s\n", "vphone-escalator", PREFS_PATH);
            CFRelease(prefs);
            return 1;
        }
        hashes = CFArrayCreateMutableCopy(NULL, 0, saved);
        CFStringRef expected = requirement_with_hashes(base, hashes);
        bool matches = current && CFEqual(current, expected);
        CFRelease(expected);
        if (!matches) {
            fprintf(stderr, "error: Entitlements changed since vphone-escalator wrote it\n");
            CFRelease(hashes);
            CFRelease(prefs);
            return 1;
        }
        had_entitlements = CFBooleanGetValue(original_entitlements);
    } else {
        base = current ? CFRetain(current) : stock_requirement();
        hashes = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    }

    CFMutableArrayRef incoming = cdhashes_for(count, paths);
    bool added = false;
    for (CFIndex i = 0; i < CFArrayGetCount(incoming); i++) {
        CFStringRef hash = CFArrayGetValueAtIndex(incoming, i);
        CFMutableStringRef clause = CFStringCreateMutable(NULL, 0);
        CFStringAppend(clause, CFSTR("cdhash H\""));
        CFStringAppend(clause, hash);
        CFStringAppend(clause, CFSTR("\""));
        bool already_present = CFStringFind(base, clause, kCFCompareCaseInsensitive).location !=
                               kCFNotFound;
        CFRelease(clause);
        if (!already_present && !CFArrayContainsValue(hashes, CFRangeMake(0, CFArrayGetCount(hashes)), hash)) {
            CFArrayAppendValue(hashes, hash);
            added = true;
        }
    }
    CFRelease(incoming);
    CFStringRef req = requirement_with_hashes(base, hashes);
    char buf[4096];
    if (CFStringGetCString(req, buf, sizeof(buf), kCFStringEncodingUTF8))
        printf("requirement: %s\n", buf);
    else
        printf("requirement: %ld characters\n", CFStringGetLength(req));

    if (added) {
        CFMutableDictionaryRef tracking = CFDictionaryCreateMutable(NULL, 0,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFDictionarySetValue(tracking, CFSTR("Base"), base);
        CFDictionarySetValue(tracking, CFSTR("Hashes"), hashes);
        CFDictionarySetValue(tracking, CFSTR("HadEntitlements"), had_entitlements ? kCFBooleanTrue : kCFBooleanFalse);
        CFDictionarySetValue(prefs, MANAGED_KEY, tracking);
        CFRelease(tracking);
        CFDictionarySetValue(prefs, CFSTR("Entitlements"), req);
    }
    // Entitlements without this key enables unsafe dynamic linking globally.
    // Leave any existing value untouched, including values set by another tool.
    if (!unsafe) CFDictionarySetValue(prefs, CFSTR("AllowUnsafeDynamicLinking"), kCFBooleanFalse);
    if (added || !unsafe) {
        if (!write_prefs(prefs)) {
            CFRelease(req);
            CFRelease(hashes);
            if (!managed) CFRelease(base);
            CFRelease(prefs);
            return 1;
        }
        printf("updated %s\n", PREFS_PATH);
    } else {
        printf("cdhash already allowed; left %s unchanged\n", PREFS_PATH);
    }
    CFRelease(req);
    CFRelease(hashes);
    if (!managed) CFRelease(base);
    CFRelease(prefs);
    return 0;
}

static int cmd_allow(const char *self_path, int count, char **paths, int hold_seconds) {
    if (update_allow_preferences(count, paths)) return 1;
    if (!attach_amfid(self_path)) return 1;
    mach_vm_address_t mgr = amfid_manager(self_path);
    if (!mgr) return 1;

    // amfid is already holding the stock requirement, so "non-NULL" proves
    // nothing. Adoption is the pointer changing: the preference path releases
    // the old SecRequirementRef and stores a freshly built one.
    ptrdiff_t req_off = ivar_offset("_restrictedRequirement");
    uintptr_t before = 0;
    if (!read_amfid(mgr + req_off, &before, sizeof(before))) return 1;
    printf("amfid pid %d: _restrictedRequirement was %#lx\n", g_amfid, (unsigned long)before);

    ptrdiff_t off = ivar_offset("_isRunningInternalBuild");
    if (!write_amfid_byte(mgr + off, 1)) return 1;
    printf("amfid pid %d: %s+%#lx = 1\n", g_amfid, MANAGER_CLASS, (long)off);

    trigger_reload();

    for (int i = 0; i < 30; i++) {
        uintptr_t restricted = 0;
        if (read_amfid(mgr + req_off, &restricted, sizeof(restricted)) && restricted &&
            restricted != before) {
            printf(
                "amfid adopted the requirement (_restrictedRequirement %#lx -> %#lx)\n",
                (unsigned long)before,
                (unsigned long)restricted
            );
            goto live;
        }
        usleep(100 * 1000);
    }
    fprintf(stderr,
            "error: amfid did not adopt the requirement within 3s "
            "(_restrictedRequirement never moved off %#lx)\n",
            (unsigned long)before);
    return 1;

live:
    if (hold_seconds <= 0) return 0;

    // amfid has EnablePressuredExit, so it can be replaced under us; a new one
    // starts with the byte back at zero. Re-apply for as long as asked.
    printf("holding for %ds (re-applying if amfid restarts); ^C to stop\n", hold_seconds);
    for (int elapsed = 0; elapsed < hold_seconds * 5; elapsed++) {
        usleep(200 * 1000);
        if (find_amfid() == g_amfid) continue;
        printf("amfid restarted; re-applying\n");
        mach_port_deallocate(mach_task_self(), g_task);
        g_task = MACH_PORT_NULL;
        if (!attach_amfid(self_path)) return 1;
        mgr = amfid_manager(self_path);
        if (!mgr || !write_amfid_byte(mgr + off, 1)) return 1;
        trigger_reload();
    }
    return 0;
}

static int remove_allow_preferences(bool *changed) {
    *changed = false;
    bool existed = false;
    CFMutableDictionaryRef prefs = read_prefs(&existed);
    if (!prefs) return 0;
    CFDictionaryRef managed = CFDictionaryGetValue(prefs, MANAGED_KEY);
    if (managed) {
        if (CFGetTypeID(managed) != CFDictionaryGetTypeID()) {
            fprintf(stderr, "error: invalid vphone-escalator metadata\n");
            CFRelease(prefs);
            return 0;
        }
        CFStringRef base = CFDictionaryGetValue(managed, CFSTR("Base"));
        CFArrayRef hashes = CFDictionaryGetValue(managed, CFSTR("Hashes"));
        CFTypeRef had_entitlements = CFDictionaryGetValue(managed, CFSTR("HadEntitlements"));
        if (!base || CFGetTypeID(base) != CFStringGetTypeID() || !valid_hashes(hashes) ||
            !had_entitlements ||
            CFGetTypeID(had_entitlements) != CFBooleanGetTypeID()) {
            fprintf(stderr, "error: invalid vphone-escalator metadata\n");
            CFRelease(prefs);
            return 0;
        }
        CFStringRef expected = requirement_with_hashes(base, hashes);
        CFTypeRef current = CFDictionaryGetValue(prefs, CFSTR("Entitlements"));
        bool matches = current && CFGetTypeID(current) == CFStringGetTypeID() &&
                       CFEqual(current, expected);
        CFRelease(expected);
        if (!matches) {
            fprintf(stderr, "error: Entitlements changed since vphone-escalator wrote it; refusing to remove other rules\n");
            CFRelease(prefs);
            return 0;
        }
        if (CFBooleanGetValue(had_entitlements))
            CFDictionarySetValue(prefs, CFSTR("Entitlements"), base);
        else
            CFDictionaryRemoveValue(prefs, CFSTR("Entitlements"));
        CFDictionaryRemoveValue(prefs, MANAGED_KEY);
        if (!write_prefs(prefs)) { CFRelease(prefs); return 0; }
        printf("removed vphone-escalator cdhashes from %s\n", PREFS_PATH);
    } else {
        printf("no vphone-escalator entries to remove\n");
        CFRelease(prefs);
        return 1;
    }
    CFRelease(prefs);
    *changed = true;
    return 1;
}

static int cmd_off(const char *self_path) {
    bool changed = false;
    if (!remove_allow_preferences(&changed)) return 1;
    if (!changed) return 0;
    // The requirement amfid already built lives in its heap; the honest way to
    // drop it is to let launchd hand us a fresh amfid.
    pid_t pid = find_amfid();
    if (pid > 0) {
        if (kill(pid, SIGKILL) == 0)
            printf("killed amfid pid %d (launch-on-demand; it comes back clean)\n", pid);
        else
            fprintf(stderr, "error: kill %d: %s\n", pid, strerror(errno));
    }
    (void)self_path;
    return 0;
}

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "--nop") == 0) return 0; // the amfid poke

    setvbuf(stdout, NULL, _IOLBF, 0); // keep stdout in step with stderr
    const char *self_path = argv[0];
    const char *verb = argc > 1 ? argv[1] : "status";

    if (strcmp(verb, "status") == 0) {
        report(self_path);
        return 0;
    }
    if (strcmp(verb, "off") == 0) {
        if (geteuid() != 0) { fprintf(stderr, "error: This command needs root. Run it with sudo.\n"); return 1; }
        return cmd_off(self_path);
    }
    if (strcmp(verb, "allow") == 0) {
        if (geteuid() != 0) { fprintf(stderr, "error: This command needs root. Run it with sudo.\n"); return 1; }
        int hold = 0, first = 2;
        if (argc > 3 && strcmp(argv[2], "--hold") == 0) {
            hold = atoi(argv[3]);
            first = 4;
        }
        if (first >= argc) {
            fprintf(stderr, "error: Specify at least one binary to allow.\n");
            return 2;
        }
        return cmd_allow(self_path, argc - first, argv + first, hold);
    }

    fprintf(stderr,
            "usage:\n"
            "  vphone-escalator status\n"
            "  sudo vphone-escalator allow [--hold N] <binary> [<binary>...]\n"
            "  sudo vphone-escalator off\n"
            "\n"
            "Allow both signed vphone-vm copies after each build.\n");
    return 2;
}
