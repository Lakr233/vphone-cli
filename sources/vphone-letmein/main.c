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
// Requires: root, and SIP with debugging restrictions disabled
// (`csrutil enable --without debug`). Same prerequisites the rest of the
// project already has.
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
static site_t g_sites[2];
static int g_nsites = 0;
static int g_applied = 0;

static void die(const char *what, kern_return_t kr) {
    fprintf(stderr, "error: %s: %s\n", what, mach_error_string(kr));
    exit(1);
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

static void read_amfid(mach_vm_address_t addr, void *buf, size_t len) {
    mach_vm_size_t got = 0;
    kern_return_t kr = mach_vm_read_overwrite(g_task, addr, len, (mach_vm_address_t)buf, &got);
    if (kr != KERN_SUCCESS) die("mach_vm_read_overwrite", kr);
}

// Writing forces the shared-cache page to be copied into amfid privately, so
// every other process — including this one — keeps seeing the pristine code.
static void write_amfid(mach_vm_address_t addr, const uint32_t *words, int n) {
    mach_vm_address_t page = addr & ~(PAGE_SIZE_16K - 1);
    mach_vm_size_t span = PAGE_SIZE_16K * 2; // a site may straddle a page boundary
    kern_return_t kr = mach_vm_protect(g_task, page, span, FALSE,
                                       VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) die("mach_vm_protect(rw|copy)", kr);
    kr = mach_vm_write(g_task, addr, (vm_offset_t)words, (mach_msg_type_number_t)(n * 4));
    if (kr != KERN_SUCCESS) die("mach_vm_write", kr);
    kr = mach_vm_protect(g_task, page, span, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) die("mach_vm_protect(rx)", kr);
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
static int site_is_patched(const site_t *s) {
    uint32_t cur[2] = {0, 0};
    read_amfid(s->addr, cur, (size_t)s->words * 4);
    for (int i = 0; i < s->words; i++)
        if (cur[i] != s->want[i]) return 0;
    return 1;
}

static void apply_all(void) {
    for (int i = 0; i < g_nsites; i++) write_amfid(g_sites[i].addr, g_sites[i].want, g_sites[i].words);
    g_applied = 1;
}

// The pristine bytes are simply the ones still mapped in this process, since the
// patch only ever touched amfid's private copy.
static void restore_all(void) {
    if (!g_nsites) return;
    for (int i = 0; i < g_nsites; i++) {
        const uint32_t *pristine = (const uint32_t *)g_sites[i].addr;
        write_amfid(g_sites[i].addr, pristine, g_sites[i].words);
    }
    g_applied = 0;
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
    if (g_applied) restore_all();
}

static void locate_all(void) {
    printf("resolving patch sites (shared cache, same addresses in every process):\n");
    locate_validate_site(&g_sites[0]);
    locate_isapple_site(&g_sites[1]);
    g_nsites = 2;
}

static void attach(void) {
    if (geteuid() != 0) { fprintf(stderr, "error: must run as root\n"); exit(1); }
    pid_t pid = find_amfid();
    if (pid < 0) { fprintf(stderr, "error: amfid is not running\n"); exit(1); }
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &g_task);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "error: task_for_pid(%d): %s\n", pid, mach_error_string(kr));
        fprintf(stderr, "       needs root and `csrutil enable --without debug`\n");
        exit(1);
    }
    printf("amfid pid %d\n", pid);
}

static void usage(const char *argv0) {
    fprintf(stderr,
            "usage: sudo %s <command>\n"
            "\n"
            "  status              report whether amfid is currently patched\n"
            "  on                  patch amfid and exit (stays until `off` or reboot)\n"
            "  off                 restore amfid\n"
            "  exec [--hold N] [--detach] -- <path>...\n"
            "                      patch, run <path>, restore. Without --hold the patch\n"
            "                      stays until the command exits. With it, the patch is\n"
            "                      removed after N seconds but the command is still\n"
            "                      supervised, so its exit status and signals reach you.\n"
            "                      --detach (needs --hold) returns as soon as the patch\n"
            "                      is removed and leaves the command running.\n"
            "                      <path> must be an absolute path: there is no PATH\n"
            "                      lookup.\n"
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
            n += p;
            printf("  %-36s %s\n", g_sites[i].name, p ? "PATCHED" : "clean");
        }
        printf("\namfid is %s\n", n == g_nsites ? "PATCHED (bypass active)"
                                  : n == 0     ? "clean (no bypass)"
                                               : "PARTIALLY patched — run `off`");
        return n == g_nsites ? 0 : (n == 0 ? 1 : 2);
    }

    if (!strcmp(cmd, "on")) {
        attach();
        locate_all();
        apply_all();
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

    if (!strcmp(cmd, "exec")) {
        int i = 2, hold = -1, detach = 0;
        while (i < argc) {
            if (!strcmp(argv[i], "--hold")) {
                if (i + 1 >= argc) { usage(argv[0]); return 2; }
                hold = atoi(argv[i + 1]);
                i += 2;
            } else if (!strcmp(argv[i], "--detach")) {
                detach = 1;
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

        attach();
        locate_all();
        signal(SIGINT, restore_on_signal);
        signal(SIGTERM, restore_on_signal);
        signal(SIGHUP, restore_on_signal);
        atexit(restore_at_exit);
        apply_all();
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
            sleep((unsigned)hold);
            restore_all();
            printf("<<< held %ds; amfid restored\n", hold);
            if (detach) {
                printf("detached; pid %d keeps running\n", (int)child);
                return 0;
            }
        }

        while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
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
