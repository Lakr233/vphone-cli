// vphone-letmein — opens a short AMFI window so vphone-vm can launch.
//
// Why this exists
// ---------------------------------------------------------------------------
// vphone-vm is signed with Apple-private virtualization entitlements (see
// sources/vphone.entitlements) but only ad-hoc signed, because we are not
// Apple. amfid rejects that combination, so the kernel kills vphone-vm at exec
// before a single line of it runs. This tool holds amfid's verdict open for
// the length of that exec and then puts it back.
//
// It is deliberately NOT a daemon. vphone-cli carries no entitlements at all,
// so it launches normally and can drive this itself:
//
//     sudo vphone-letmein exec --hold N -- <bundle>/Contents/MacOS/vphone-vm ...
//
// The check happens at exec, so N only has to cover the launch; the window
// closes while the VM keeps running. That is the whole reason the entitlements
// live on vphone-vm and not on the top-level binary -- it is what makes the
// window one launch long instead of permanently open.
//
// Build: clang and the macOS SDK, nothing else. No pip, no Python, no LLDB,
// no Xcode.app. Driven by scripts/build.sh; standalone equivalent:
//
//     clang -arch arm64 -framework Foundation -o vphone-letmein main.c
//     codesign --force --sign - vphone-letmein
//
// ---------------------------------------------------------------------------
// Why this does not use breakpoints
// ---------------------------------------------------------------------------
// The obvious implementation drives amfid with a debugger: break on
// -[AMFIPathValidator_macos validateWithError:], steps out, and overwrites the
// return register. That needs task_set_exception_ports() and thread_set_state()
// against amfid — and on macOS 26 amfid carries
// com.apple.developer.hardened-process, so both calls are gated behind Apple
// private entitlements:
//
//     com.apple.private.set-exception-port
//     com.apple.private.thread-set-state
//
// Those are exactly the entitlements Xcode's debugserver carries, which is why
// debugger-based tools have to route through LLDB at all rather than doing it
// themselves. An ad-hoc signed binary that calls task_set_exception_ports() on
// amfid is killed on the spot with EXC_GUARD / GUARD_TYPE_MACH_PORT
// (violation SET_EXCEPTION_BEHAVIOR). Measured, not assumed.
//
// task_for_pid(), mach_vm_read(), mach_vm_protect() and mach_vm_write() are NOT
// gated, so this tool patches amfid's code instead of interrupting it.
//
// ---------------------------------------------------------------------------
// What it patches
// ---------------------------------------------------------------------------
// AMFIPathValidator_macos lives in AppleMobileFileIntegrity.framework, i.e. in
// the dyld shared cache, which is mapped at the same address in every process.
// So the addresses are resolved here, in this process, with the ObjC runtime —
// amfid's Mach-O is never parsed and no slide is ever computed.
//
// 1. validateWithError: ends in a single epilogue that returns self->_isValid:
//
//        ldrb w19, [x19, #_isValid]     <- rewritten to `mov w19, #1`
//        ...
//        mov  x0, x19
//        retab
//
//    Patching that one load leaves the whole validation running — cdhash,
//    entitlements and the rest of the object are still populated — and only
//    the verdict is forced. Short-circuiting the function entry instead does
//    NOT work: the object stays empty and the kernel still kills the process.
//
// 2. isApple is a plain accessor, rewritten to `mov w0, #1; ret`, which is what
//    actually lets Apple-private entitlements through.
//
// Both sites are located by scanning for semantic anchors (the epilogue, the
// register feeding x0, the _isValid ivar offset taken from the live ObjC
// runtime). No file offset, virtual address or ivar offset is hardcoded.
//
// ---------------------------------------------------------------------------
// When this CANNOT work, and why
// ---------------------------------------------------------------------------
// Writing to amfid's __TEXT produces a private, dirty, unsigned executable
// page. If the host enforces code signing system-wide, the kernel validates
// that page on the next fault into it, finds no signature, and kills amfid:
//
//     exception    EXC_BAD_ACCESS, SIGKILL (Code Signature Invalid)
//     termination  namespace CODESIGNING, code 2, indicator "Invalid Page"
//     fault        inside -[AMFIPathValidator_macos validateWithError:]
//     region       __TEXT ... r-x/rwx SM=COW
//
// Measured on macOS 27.0 (26A428), arm64e, SIP `enabled --without debug`:
// amfid died at the instant this tool patched it. The gate is the read-only
// sysctl `vm.cs_system_enforcement`. At 1 this tool takes amfid down and
// nothing launches; at 0 the dirty page is allowed and the patch holds. So the
// value is checked before anything is written, and 1 is a refusal, not a
// warning -- killing the machine's amfid is not an acceptable failure mode.
//
// This is also why the LLDB-based predecessor worked where this does not: a
// debugger sets arm64 breakpoints in the CPU's debug registers and never
// writes to the text page at all. Doing that here would need
// task_set_exception_ports() and thread_set_state(), which are the gated calls
// described above -- the trade this tool made was "no debugger entitlements,
// but only on a host that permits dirty text".
//
// Two things that look like a way around it and are not, both on arm64e:
//
//   * Rebinding amfid's __DATA_CONST,__auth_got entries. The slots hold
//     PAC-signed pointers, and the signing keys are per-process, so a pointer
//     forged here fails authentication inside amfid.
//   * Swizzling -[AMFIPathValidator_macos validateWithError:]. Relative method
//     lists store an unsigned 32-bit offset, so the entry itself could be
//     rewritten -- but the ObjC method cache would keep serving the original
//     IMP, and _objc_flush_caches cannot be called in another process.
//
// The supported configuration for this project is a host where AMFI is not
// enforcing (see README). On such a host vphone-vm launches on its own and
// this tool is not needed; it exists for the narrower case of an enforcing
// amfid on a host that still permits dirty text.
//
// ---------------------------------------------------------------------------
// Scope, honestly stated
// ---------------------------------------------------------------------------
// This is a global switch: while the patch is in place EVERY signature amfid
// validates is reported valid and Apple-signed. A per-path / per-cdhash
// allowlist cannot be reproduced without the debugger entitlements above,
// because there is no way to run a decision per validation -- that requires
// interrupting amfid, which is exactly what is gated. Do not describe this
// tool as scoped to a path or a binary; it is not.
//
// The compensating control is time, not scope. `exec` holds the patch only for
// as long as the launch needs it, which is why vphone-cli uses that mode and
// why `on` exists mainly for debugging.
//
// The patch is made through a copy-on-write mapping, so it affects only amfid's
// private copy and never touches the shared cache on disk. It therefore does
// not survive a reboot, and `off` restores by writing this process's own
// (unmodified) bytes back -- there is no state file to lose.
//
// Requires: root; SIP with debugging restrictions disabled
// (`csrutil enable --without debug`), so task_for_pid works; and
// `vm.cs_system_enforcement == 0`, so the patched page may execute.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <errno.h>
#include <sys/wait.h>
#include <libproc.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <sys/sysctl.h>

#define AMFID_PATH "/usr/libexec/amfid"
#define AMFI_FRAMEWORK \
    "/System/Library/PrivateFrameworks/AppleMobileFileIntegrity.framework/AppleMobileFileIntegrity"
#define VALIDATOR_CLASS "AMFIPathValidator_macos"

#define PAGE_SIZE_16K 0x4000ULL
#define SCAN_INSNS 0x800 // how far into a method body to look for its epilogue
#define EPILOGUE_WINDOW 24 // instructions before the epilogue that may set up the result

#define INSN_RETAB 0xd65f0fffu
#define INSN_RET 0xd65f03c0u
#define INSN_MOV_W0_1 0x52800020u

// LDRB w<t>, [x<n>, #imm12] — unsigned offset, scale 1.
#define LDRB_BASE(imm12) (0x39400000u | ((uint32_t)(imm12) << 10))
#define LDRB_MASK 0xFFFFFC00u
// MOV x0, x<m> is ORR x0, xzr, x<m>.
#define MOV_X0_FROM(m) (0xAA0003E0u | ((uint32_t)(m) << 16))
// MOVZ w<d>, #1
#define MOVZ_W_1(d) (0x52800000u | (1u << 5) | (uint32_t)(d))

// --------------------------------------------------------------------------

typedef struct {
    const char *name;
    mach_vm_address_t addr; // address in the shared cache, valid in every process
    uint32_t want[2]; // what the patched form looks like
    int words;
} site_t;

static mach_port_t g_task = MACH_PORT_NULL;
static pid_t g_pid = -1;
static site_t g_sites[2];
static int g_nsites = 0;
static int g_applied = 0;
// Set while unwinding so the atexit handler does not try to touch amfid again.
// Without it a failed write inside restore_all() called die(), die() called
// exit(), exit() ran restore_at_exit(), and that tried the same write again --
// the same error printed twice and exit() re-entered.
static int g_bailing = 0;

static void die(const char *what, kern_return_t kr) {
    g_bailing = 1;
    fprintf(stderr, "error: %s: %s\n", what, mach_error_string(kr));
    exit(1);
}

// `vm.cs_system_enforcement` decides whether a dirty, unsigned executable page
// is a kill. Read-only at runtime, so this is a report, not a switch.
static int cs_system_enforcement(void) {
    int value = 0;
    size_t len = sizeof(value);
    if (sysctlbyname("vm.cs_system_enforcement", &value, &len, NULL, 0) != 0) return -1;
    return value;
}

static int amfid_is_alive(void) {
    if (g_pid <= 0) return 0;
    char path[PROC_PIDPATHINFO_MAXSIZE];
    return proc_pidpath(g_pid, path, sizeof(path)) > 0 && strcmp(path, AMFID_PATH) == 0;
}

static pid_t find_amfid(void) {
    pid_t pids[8192];
    int n = proc_listpids(PROC_ALL_PIDS, 0, pids, (int)sizeof(pids)) / (int)sizeof(pid_t);
    char path[PROC_PIDPATHINFO_MAXSIZE];
    for (int i = 0; i < n; i++)
        if (pids[i] > 0 && proc_pidpath(pids[i], path, sizeof(path)) > 0 &&
            strcmp(path, AMFID_PATH) == 0) return pids[i];
    return -1;
}

static Class validator_class(void) {
    static Class cls = Nil;
    if (cls) return cls;
    if (!dlopen(AMFI_FRAMEWORK, RTLD_NOW)) {
        fprintf(stderr, "error: dlopen AppleMobileFileIntegrity: %s\n", dlerror());
        exit(1);
    }
    cls = objc_getClass(VALIDATOR_CLASS);
    if (!cls) { fprintf(stderr, "error: class %s not found\n", VALIDATOR_CLASS); exit(1); }
    return cls;
}

static mach_vm_address_t imp_of(const char *sel_name) {
    Method m = class_getInstanceMethod(validator_class(), sel_registerName(sel_name));
    if (!m) { fprintf(stderr, "error: -[%s %s] not found\n", VALIDATOR_CLASS, sel_name); exit(1); }
    return (mach_vm_address_t)method_getImplementation(m);
}

static ptrdiff_t ivar_offset(const char *name) {
    Ivar iv = class_getInstanceVariable(validator_class(), name);
    if (!iv) { fprintf(stderr, "error: ivar %s not found on %s\n", name, VALIDATOR_CLASS); exit(1); }
    return ivar_getOffset(iv);
}

// --------------------------------------------------------------------------
// amfid memory
// --------------------------------------------------------------------------

// Every remote access returns its kern_return_t. A dead amfid is an ordinary
// outcome here -- it is a launch-on-demand job with EnablePressuredExit, so it
// can be gone between any two calls -- and the caller decides whether that is
// a failure or simply nothing left to do.
static kern_return_t try_read_amfid(mach_vm_address_t addr, void *buf, size_t len) {
    mach_vm_size_t got = 0;
    return mach_vm_read_overwrite(g_task, addr, len, (mach_vm_address_t)buf, &got);
}

// Writing forces the shared-cache page to be copied into amfid privately, so
// every other process — including this one — keeps seeing the pristine code.
static kern_return_t try_write_amfid(mach_vm_address_t addr, const uint32_t *words, int n,
                                     const char **what) {
    mach_vm_address_t page = addr & ~(PAGE_SIZE_16K - 1);
    mach_vm_size_t span = PAGE_SIZE_16K * 2; // a site may straddle a page boundary
    kern_return_t kr = mach_vm_protect(g_task, page, span, FALSE,
                                       VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) { *what = "mach_vm_protect(rw|copy)"; return kr; }
    kr = mach_vm_write(g_task, addr, (vm_offset_t)words, (mach_msg_type_number_t)(n * 4));
    if (kr != KERN_SUCCESS) { *what = "mach_vm_write"; return kr; }
    kr = mach_vm_protect(g_task, page, span, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) { *what = "mach_vm_protect(rx)"; return kr; }
    return KERN_SUCCESS;
}

// --------------------------------------------------------------------------
// Locating the patch sites
// --------------------------------------------------------------------------

// Walk validateWithError: to its single epilogue, find which register feeds x0,
// then find the load of self->_isValid that defines that register.
static void locate_validate_site(site_t *out) {
    mach_vm_address_t imp = imp_of("validateWithError:");
    const uint32_t *code = (const uint32_t *)imp; // pristine, in our own mapping
    ptrdiff_t off = ivar_offset("_isValid");

    int ret_idx = -1;
    for (int i = 0; i < SCAN_INSNS; i++)
        if (code[i] == INSN_RETAB || code[i] == INSN_RET) { ret_idx = i; break; }
    if (ret_idx < 0) {
        fprintf(stderr, "error: no epilogue in the first %d instructions of "
                        "validateWithError: — this macOS build is not supported\n", SCAN_INSNS);
        exit(1);
    }

    // Which register is returned? Look for `mov x0, x<m>` just before the epilogue.
    int result_reg = -1;
    for (int i = ret_idx; i >= 0 && i > ret_idx - EPILOGUE_WINDOW; i--) {
        for (int m = 0; m < 31; m++)
            if (code[i] == MOV_X0_FROM(m)) { result_reg = m; break; }
        if (result_reg >= 0) break;
    }
    if (result_reg < 0) {
        fprintf(stderr, "error: could not find the register feeding x0 before the epilogue\n");
        exit(1);
    }

    // And where does that register come from? `ldrb w<result>, [x<n>, #_isValid]`.
    int idx = -1;
    for (int i = ret_idx; i >= 0 && i > ret_idx - EPILOGUE_WINDOW; i--) {
        if ((code[i] & LDRB_MASK) == LDRB_BASE(off) && (int)(code[i] & 0x1F) == result_reg) {
            idx = i;
            break;
        }
    }
    if (idx < 0) {
        fprintf(stderr, "error: the return value is not a load of _isValid (+0x%lx) — "
                        "this macOS build is not supported\n", (long)off);
        exit(1);
    }

    out->name = "validateWithError: -> always valid";
    out->addr = imp + (mach_vm_address_t)idx * 4;
    out->want[0] = MOVZ_W_1(result_reg);
    out->words = 1;

    printf("  validateWithError:  0x%llx  epilogue +0x%x, returns w%d\n",
           (unsigned long long)imp, ret_idx * 4, result_reg);
    printf("    _isValid ivar     +0x%lx\n", (long)off);
    printf("    site              0x%llx  %08x (ldrb w%d, [x%d, #0x%lx]) -> %08x (mov w%d, #1)\n",
           (unsigned long long)out->addr, code[idx], result_reg,
           (int)((code[idx] >> 5) & 0x1F), (long)off, out->want[0], result_reg);
}

static void locate_isapple_site(site_t *out) {
    mach_vm_address_t imp = imp_of("isApple");
    out->name = "isApple -> always true";
    out->addr = imp;
    out->want[0] = INSN_MOV_W0_1;
    out->want[1] = INSN_RET;
    out->words = 2;
    printf("  isApple             0x%llx  -> %08x %08x (mov w0, #1; ret)\n",
           (unsigned long long)imp, out->want[0], out->want[1]);
}

// --------------------------------------------------------------------------
// Apply / restore
// --------------------------------------------------------------------------

// A site counts as patched when amfid's copy matches what we would write.
// Returns -1 when amfid could not be read at all, which is not the same as
// "clean" and must not be reported as one.
static int site_is_patched(const site_t *s) {
    uint32_t cur[2] = {0, 0};
    if (try_read_amfid(s->addr, cur, (size_t)s->words * 4) != KERN_SUCCESS) return -1;
    for (int i = 0; i < s->words; i++)
        if (cur[i] != s->want[i]) return 0;
    return 1;
}

// The patch is worthless unless it is still there, in a live amfid, when the
// kernel asks. So the write is read back, and a dead amfid at this point is
// reported as what it is rather than carried forward as success.
static void died_under_the_patch(void) {
    fprintf(stderr,
            "\nerror: amfid died while being patched.\n"
            "       vm.cs_system_enforcement is %d. At 1 the kernel validates the dirty\n"
            "       text page on the next fault into it, finds no signature, and kills\n"
            "       amfid with CODESIGNING/\"Invalid Page\" -- look for an amfid report in\n"
            "       /Library/Logs/DiagnosticReports. Nothing this tool can do from\n"
            "       another process avoids that; the host has to stop enforcing, and\n"
            "       with AMFI relaxed vphone-vm launches without this tool at all.\n",
            cs_system_enforcement());
}

// Does amfid's copy already hold `words`? Used to skip writes that would
// change nothing: every write dirties a page, and on a host that enforces code
// signing a needlessly dirtied page is a needlessly dead amfid.
static int site_already_reads(const site_t *s, const uint32_t *words) {
    uint32_t cur[2] = {0, 0};
    if (try_read_amfid(s->addr, cur, (size_t)s->words * 4) != KERN_SUCCESS) return -1;
    for (int i = 0; i < s->words; i++)
        if (cur[i] != words[i]) return 0;
    return 1;
}

static int apply_all(void) {
    for (int i = 0; i < g_nsites; i++) {
        if (site_already_reads(&g_sites[i], g_sites[i].want) == 1) continue;
        const char *what = "";
        kern_return_t kr = try_write_amfid(g_sites[i].addr, g_sites[i].want, g_sites[i].words, &what);
        if (kr != KERN_SUCCESS) {
            if (!amfid_is_alive()) { died_under_the_patch(); return 0; }
            die(what, kr);
        }
    }
    for (int i = 0; i < g_nsites; i++) {
        int state = site_is_patched(&g_sites[i]);
        if (state < 0) { died_under_the_patch(); return 0; }
        if (state == 0) {
            fprintf(stderr, "\nerror: %s did not take -- amfid still reads the original bytes\n",
                    g_sites[i].name);
            return 0;
        }
    }
    g_applied = 1;
    return 1;
}

// The pristine bytes are simply the ones still mapped in this process, since the
// patch only ever touched amfid's private copy. If amfid is gone, its private
// copy went with it and there is nothing left to undo -- that is a clean
// outcome, not a failure, and it is the common one for a job that idle-exits.
static void restore_all(void) {
    if (!g_nsites) return;
    g_applied = 0; // first: a failure below must not re-enter through atexit
    for (int i = 0; i < g_nsites; i++) {
        const uint32_t *pristine = (const uint32_t *)g_sites[i].addr;
        // Writing the original bytes back is still a write: it dirties the page
        // just as the patch did, and on an enforcing host that alone is fatal.
        // So a site that already reads pristine is left alone entirely.
        if (site_already_reads(&g_sites[i], pristine) == 1) continue;
        const char *what = "";
        kern_return_t kr = try_write_amfid(g_sites[i].addr, pristine, g_sites[i].words, &what);
        if (kr == KERN_SUCCESS) continue;
        if (!amfid_is_alive()) {
            printf("amfid is no longer running; its private copy went with it\n");
            return;
        }
        fprintf(stderr, "warning: could not restore %s: %s: %s\n",
                g_sites[i].name, what, mach_error_string(kr));
    }
}

// Set once `exec` has forked, so a signal can be passed on before we go.
static volatile pid_t g_child = 0;

static void restore_on_signal(int sig) {
    if (g_applied) restore_all();
    // Forward first, then leave. Without this a Ctrl-C at the terminal takes
    // down the supervisor and leaves the guest running with no parent, which
    // looks exactly like a hang.
    if (g_child > 0) kill(g_child, sig);
    _exit(128 + sig);
}

static void restore_at_exit(void) {
    if (g_bailing) return; // die() is already unwinding; do not touch amfid again
    if (g_applied) restore_all();
}

static void locate_all(void) {
    printf("resolving patch sites (shared cache, same addresses in every process):\n");
    locate_validate_site(&g_sites[0]);
    locate_isapple_site(&g_sites[1]);
    g_nsites = 2;
}

// Take (or retake) a task port on whatever amfid is running now. Quiet form
// for the watchdog, which calls it whenever the pid has moved.
static kern_return_t grab_amfid(pid_t pid) {
    if (g_task != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), g_task);
        g_task = MACH_PORT_NULL;
    }
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &g_task);
    if (kr == KERN_SUCCESS) g_pid = pid;
    return kr;
}

// amfid is launch-on-demand with EnablePressuredExit, so "not running" is a
// normal state rather than an error — wait briefly for it instead of failing.
static pid_t await_amfid(int seconds) {
    for (int i = 0; i <= seconds * 10; i++) {
        pid_t pid = find_amfid();
        if (pid > 0) return pid;
        usleep(100 * 1000);
    }
    return -1;
}

static void attach(void) {
    if (geteuid() != 0) { fprintf(stderr, "error: must run as root\n"); exit(1); }
    pid_t pid = await_amfid(5);
    if (pid < 0) {
        fprintf(stderr, "error: amfid is not running, and did not start within 5s\n");
        fprintf(stderr, "       it is launched on demand; any code-signature check starts it\n");
        exit(1);
    }
    kern_return_t kr = grab_amfid(pid);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "error: task_for_pid(%d): %s\n", pid, mach_error_string(kr));
        fprintf(stderr, "       needs root and `csrutil enable --without debug`\n");
        exit(1);
    }
    printf("amfid pid %d\n", pid);
}

// amfid can exit and be relaunched at any point in the window, and a fresh
// amfid is an unpatched one. Called in a tight loop while the window is open
// so a relaunch is repatched rather than silently letting the next launch die.
// Returns 0 once the patch can no longer be kept in place.
static int keep_patched(void) {
    pid_t pid = find_amfid();
    if (pid < 0) return 1; // between instances; nothing to patch yet
    if (pid != g_pid) {
        if (grab_amfid(pid) != KERN_SUCCESS) return 1; // it may already be gone again
        printf("amfid relaunched as pid %d; repatching\n", pid);
        return apply_all();
    }
    for (int i = 0; i < g_nsites; i++) {
        int state = site_is_patched(&g_sites[i]);
        if (state < 0) return 1; // gone mid-check; the next pass picks up its successor
        if (state == 0) return apply_all();
    }
    return 1;
}

// Refuse before writing anything if the host would kill amfid for it.
static int refuse_if_enforcing(int force) {
    int enforcing = cs_system_enforcement();
    if (enforcing <= 0) return 0; // 0 = permitted, -1 = sysctl absent, let it try
    fprintf(stderr,
            "error: vm.cs_system_enforcement is 1 — this host enforces code signing\n"
            "       system-wide, so patching amfid's text would get amfid killed with\n"
            "       CODESIGNING/\"Invalid Page\" the moment it runs the patched page.\n"
            "       That takes down the machine's amfid, so it is refused rather than\n"
            "       attempted. Measured on macOS 27.0 (26A428) arm64e; see the header\n"
            "       of this tool's source for the crash report it produced.\n"
            "\n"
            "       The sysctl is read-only, so this cannot be relaxed at runtime. Run\n"
            "       the host with AMFI not enforcing — and then vphone-vm launches\n"
            "       without this tool at all.\n"
            "\n"
            "       `--force` attempts it anyway; expect amfid to die.\n");
    return force ? 0 : 1;
}

static void usage(const char *argv0) {
    fprintf(stderr,
            "usage: sudo %s <command>\n"
            "\n"
            "  status              report whether amfid is currently patched, and\n"
            "                      whether this host would allow the patch at all\n"
            "  on [--force]        patch amfid and exit (stays until `off` or reboot)\n"
            "  off                 restore amfid\n"
            "  exec [--hold N] [--detach] [--force] -- <path>...\n"
            "                      patch, run <path>, restore. Without --hold the patch\n"
            "                      stays until the command exits. With it, the patch is\n"
            "                      removed after N seconds but the command is still\n"
            "                      supervised, so its exit status and signals reach you.\n"
            "                      --detach (needs --hold) returns as soon as the patch\n"
            "                      is removed and leaves the command running.\n"
            "                      <path> must be an absolute path: there is no PATH\n"
            "                      lookup.\n"
            "\n"
            "Requires `vm.cs_system_enforcement == 0`. On a host that enforces, the\n"
            "patched page is killed as CODESIGNING/\"Invalid Page\" and amfid dies with\n"
            "it, so `on` and `exec` refuse (exit 3) unless --force. Such a host needs\n"
            "AMFI relaxed instead -- and then vphone-vm launches without this tool.\n"
            "\n"
            "While patched, EVERY signature amfid checks is reported valid and\n"
            "Apple-signed -- this is a global switch, not an allowlist. Prefer\n"
            "`exec`, which keeps the window as short as the launch it is covering.\n",
            argv0);
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc < 2) { usage(argv[0]); return 2; }
    const char *cmd = argv[1];

    if (!strcmp(cmd, "status")) {
        attach();
        locate_all();
        int n = 0;
        printf("\n");
        for (int i = 0; i < g_nsites; i++) {
            int p = site_is_patched(&g_sites[i]);
            if (p < 0) {
                printf("\namfid went away while being read; nothing is patched\n");
                return 1;
            }
            n += p;
            printf("  %-36s %s\n", g_sites[i].name, p ? "PATCHED" : "clean");
        }
        printf("\namfid is %s\n", n == g_nsites ? "PATCHED (bypass active)"
                                  : n == 0     ? "clean (no bypass)"
                                               : "PARTIALLY patched — run `off`");
        printf("vm.cs_system_enforcement = %d%s\n", cs_system_enforcement(),
               cs_system_enforcement() > 0 ? "  (patching would kill amfid — see `on`)" : "");
        return n == g_nsites ? 0 : (n == 0 ? 1 : 2);
    }

    if (!strcmp(cmd, "on")) {
        int force = argc > 2 && !strcmp(argv[2], "--force");
        if (refuse_if_enforcing(force)) return 3;
        attach();
        locate_all();
        if (!apply_all()) return 1;
        g_applied = 0; // deliberately persistent: do not restore at exit
        printf("\namfid patched. Run `%s off` when you are done.\n", argv[0]);
        return 0;
    }

    if (!strcmp(cmd, "off")) {
        attach();
        locate_all();
        restore_all();
        printf("\namfid restored.\n");
        return 0;
    }

    if (!strcmp(cmd, "--help") || !strcmp(cmd, "-h")) {
        usage(argv[0]);
        return 0;
    }

    if (!strcmp(cmd, "exec")) {
        int i = 2, hold = -1, detach = 0, force = 0;
        while (i < argc) {
            if (!strcmp(argv[i], "--hold")) {
                if (i + 1 >= argc) { usage(argv[0]); return 2; }
                hold = atoi(argv[i + 1]);
                i += 2;
            } else if (!strcmp(argv[i], "--detach")) {
                detach = 1;
                i += 1;
            } else if (!strcmp(argv[i], "--force")) {
                force = 1;
                i += 1;
            } else {
                break;
            }
        }
        if (detach && hold < 0) {
            fprintf(stderr, "error: --detach requires --hold\n");
            return 2;
        }
        if (i < argc && !strcmp(argv[i], "--")) i++;
        if (i >= argc) { usage(argv[0]); return 2; }

        if (refuse_if_enforcing(force)) return 3;
        attach();
        locate_all();
        signal(SIGINT, restore_on_signal);
        signal(SIGTERM, restore_on_signal);
        signal(SIGHUP, restore_on_signal);
        atexit(restore_at_exit);
        // Nothing is launched on a patch that did not take: the child would be
        // killed at exec and the real reason would be buried under its output.
        if (!apply_all()) return 1;
        printf("\n>>> %s\n", argv[i]);

        pid_t child = fork();
        if (child < 0) { perror("fork"); restore_all(); return 1; }
        g_child = child;
        if (child == 0) {
            // execv, not execvp: a PATH lookup here would resolve the target
            // through the environment, and the whole point of the launch path
            // is that vphone-cli hands us a fixed path inside its own bundle.
            // It is also what the admission rule's source scan looks for.
            execv(argv[i], &argv[i]);
            fprintf(stderr, "exec %s: %s\n", argv[i], strerror(errno));
            _exit(127);
        }

        int status = 0;

        // The window only has to cover the launch, because amfid's verdict is
        // taken at exec. So --hold restores early and then goes right back to
        // supervising: the guest keeps running with a clean amfid, and its exit
        // status and signals still reach whoever started us. Detaching instead
        // would close the window just as early but throw that away, which is
        // why it is opt-in rather than what --hold does by itself.
        if (hold >= 0) {
            // Not a plain sleep. amfid idle-exits and is relaunched on demand,
            // and a relaunched amfid is an unpatched one — so the window is
            // only real if it is re-established for as long as it is open.
            // Also stop early once the child is gone: there is nothing left to
            // cover, and holding a global bypass open past its purpose is the
            // one thing this tool must not do.
            for (int tick = 0; tick < hold * 20; tick++) {
                usleep(50 * 1000);
                if (waitpid(child, &status, WNOHANG) == child) {
                    if (WIFSIGNALED(status))
                        printf("<<< child killed by signal %d during the window\n", WTERMSIG(status));
                    else
                        printf("<<< child exited with status %d during the window\n",
                               WEXITSTATUS(status));
                    child = -1;
                    break;
                }
                if (!keep_patched()) {
                    fprintf(stderr, "<<< could not keep amfid patched; closing the window\n");
                    break;
                }
            }
            restore_all();
            printf("<<< held %ds; amfid restored\n", hold);
            if (child < 0) return WIFSIGNALED(status) ? 128 + WTERMSIG(status) : WEXITSTATUS(status);
            if (detach) {
                printf("detached; pid %d keeps running\n", (int)child);
                return 0;
            }
        }

        while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
        if (WIFSIGNALED(status))
            printf("<<< child killed by signal %d\n", WTERMSIG(status));
        else
            printf("<<< child exited with status %d\n", WEXITSTATUS(status));
        if (g_applied) {
            restore_all();
            printf("amfid restored.\n");
        }
        return WEXITSTATUS(status);
    }

    usage(argv[0]);
    return 2;
}
