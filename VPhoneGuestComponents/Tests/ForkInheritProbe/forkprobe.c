// forkprobe.c — does a fork child keep running code its parent rewrote?
//
// The guest-side check for `kernel-exp-frida_fork_inherit_invalid_code`. The
// parent takes a private, writable copy of a shared-cache text page the way
// Frida's Interceptor does (VM_PROT_COPY, write, re-protect RX), turns `cbrt`
// into `mov w0, #42 ; ret`, runs it, then forks. The child prints its region
// (vm_region) and runs the function again, and exits 0 when it answers 42; the
// parent prints how the child ended. Without the patch, or without the
// entitlement, the child's copy of the page is r--/rw- and the call dies with
// CODESIGNING "Invalid Page" (SIGKILL). It also tries a MAP_JIT page (43); on
// the 27.0.1 guest mmap(MAP_JIT) answers EINVAL, and the test continues without.
//
// Diagnostics, none needed for the four-way test:
//   --trace-me          ptrace(PT_TRACE_ME) in the parent before the fork
//   --child-trace-me    the same in the child (cs_allow_invalid on the child)
//   --child-reprotect   the child redoes VM_PROT_COPY on the inherited page
//   --child-fresh       the child rewrites a fresh function (`erfc`) itself
//   --share             vm_inherit(VM_INHERIT_SHARE) on the page before fork
//
// Build and sign: build.zsh. Run in the guest through vphoned's `proc.run`.

#include <dlfcn.h>
#include <errno.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <ptrauth.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

// <sys/codesign.h>, <sys/ptrace.h> and <mach/mach_vm.h> are not in the iOS SDK.
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
extern int ptrace(int request, pid_t pid, char *addr, int data);
#define PT_TRACE_ME 0
#define CS_OPS_STATUS 0
#define CS_VALID 0x00000001
#define CS_GET_TASK_ALLOW 0x00000004
#define CS_HARD 0x00000100
#define CS_KILL 0x00000200
#define CS_ENFORCEMENT 0x00001000
#define CS_PLATFORM_BINARY 0x04000000
#define CS_DEBUGGED 0x10000000

typedef int (*int_fn)(int);

// Print the protection and sharing of the region holding `fn`.
static void print_region(const char *who, void *fn) {
    vm_address_t addr = (vm_address_t)ptrauth_strip(fn, ptrauth_key_function_pointer);
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t kr = vm_region_64(mach_task_self(), &addr, &size, VM_REGION_BASIC_INFO_64,
                                    (vm_region_info_t)&info, &count, &object);
    if (kr != KERN_SUCCESS) {
        printf("%s: vm_region failed: %s\n", who, mach_error_string(kr));
        return;
    }
    printf("%s: region 0x%lx+0x%lx prot %d max %d shared %d inherit %d behavior %d\n", who,
           (unsigned long)addr, (unsigned long)size, info.protection, info.max_protection,
           info.shared, info.inheritance, info.behavior);
}

static void print_status(const char *who) {
    uint32_t flags = 0;
    if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof flags) != 0) {
        printf("%s: csops failed: %s\n", who, strerror(errno));
    } else {
        printf("%s: pid %d csflags 0x%08x%s%s%s%s%s%s%s\n", who, getpid(), flags,
               (flags & CS_VALID) ? " VALID" : "",
               (flags & CS_GET_TASK_ALLOW) ? " GET_TASK_ALLOW" : "",
               (flags & CS_HARD) ? " HARD" : "",
               (flags & CS_KILL) ? " KILL" : "",
               (flags & CS_ENFORCEMENT) ? " ENFORCEMENT" : "",
               (flags & CS_PLATFORM_BINARY) ? " PLATFORM" : "",
               (flags & CS_DEBUGGED) ? " DEBUGGED" : "");
    }
    fflush(stdout);
}

static const uint32_t kMovW0_42 = 0x52800540; // mov w0, #42
static const uint32_t kMovW0_43 = 0x52800560; // mov w0, #43
static const uint32_t kRet = 0xD65F03C0;      // ret

// Rewrite the first two instructions of a shared-cache function in a private
// copy. `cbrt` lives in libsystem_m, a page nothing else in this program runs
// from, so taking the page's execute bit away does not stall the program itself.
static int_fn rewrite_function(const char *who, const char *name, uint32_t first) {
    void *sym = dlsym(RTLD_DEFAULT, name);
    if (sym == NULL) {
        printf("%s: dlsym(%s) failed\n", who, name);
        return NULL;
    }
    // On arm64e dlsym hands back a signed pointer; the page math needs the raw address.
    vm_address_t addr = (vm_address_t)ptrauth_strip(sym, ptrauth_key_function_pointer);
    vm_address_t page = addr & ~(vm_page_size - 1);
    kern_return_t kr = vm_protect(mach_task_self(), page, vm_page_size, FALSE,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        printf("%s: vm_protect(RW|COPY) failed: %s\n", who, mach_error_string(kr));
        return NULL;
    }
    uint32_t *code = (uint32_t *)addr;
    code[0] = first;
    code[1] = kRet;
    sys_icache_invalidate(code, 8);
    kr = vm_protect(mach_task_self(), page, vm_page_size, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) {
        printf("%s: vm_protect(RX) failed: %s\n", who, mach_error_string(kr));
        return NULL;
    }
    printf("%s: rewrote %s at %p (page %p)\n", who, name, sym, (void *)page);
    fflush(stdout);
    return (int_fn)sym;
}

// A MAP_JIT page holding `mov w0, #43 ; ret`, as Stalker's code cache would.
// With dynamic-codesigning an iOS MAP_JIT page is writable and executable at once.
static int_fn make_jit_function(void) {
    void *mem = mmap(NULL, vm_page_size, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    if (mem == MAP_FAILED) {
        printf("parent: mmap(MAP_JIT) failed: %s\n", strerror(errno));
        return NULL;
    }
    uint32_t *code = mem;
    code[0] = kMovW0_43;
    code[1] = kRet;
    sys_icache_invalidate(mem, 8);
    printf("parent: jit page at %p\n", mem);
    fflush(stdout);
    return (int_fn)mem;
}

static int run_both(const char *who, int_fn rewritten, int_fn jit) {
    int ok = 1;
    if (rewritten) {
        printf("%s: calling rewritten cbrt...\n", who);
        fflush(stdout);
        int r = rewritten(0);
        printf("%s: rewritten cbrt(0) = %d (%s)\n", who, r, r == 42 ? "ok" : "unexpected");
        ok &= (r == 42);
    }
    if (jit) {
        printf("%s: calling jit page...\n", who);
        fflush(stdout);
        int r = jit(0);
        printf("%s: jit(0) = %d (%s)\n", who, r, r == 43 ? "ok" : "unexpected");
        ok &= (r == 43);
    }
    fflush(stdout);
    return ok;
}

int main(int argc, char **argv) {
    int trace_me = 0, child_trace_me = 0, child_reprotect = 0, child_fresh = 0, share = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--trace-me") == 0) trace_me = 1;
        if (strcmp(argv[i], "--child-trace-me") == 0) child_trace_me = 1;
        if (strcmp(argv[i], "--child-reprotect") == 0) child_reprotect = 1;
        if (strcmp(argv[i], "--child-fresh") == 0) child_fresh = 1;
        if (strcmp(argv[i], "--share") == 0) share = 1;
    }
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("forkprobe: page size %lu%s\n", (unsigned long)vm_page_size, trace_me ? ", PT_TRACE_ME" : "");
    if (trace_me && ptrace(PT_TRACE_ME, 0, NULL, 0) != 0) {
        printf("parent: ptrace(PT_TRACE_ME) failed: %s\n", strerror(errno));
    }
    print_status("parent");

    int_fn rewritten = rewrite_function("parent", "cbrt", kMovW0_42);
    int_fn jit = make_jit_function();
    if (rewritten == NULL) {
        printf("RESULT setup_failed\n");
        return 2;
    }
    if (jit == NULL) {
        printf("parent: no jit page; testing the rewritten page only\n");
    }
    if (share) {
        // Diagnostic: share the rewritten page with the child instead of copying it.
        vm_address_t a = (vm_address_t)ptrauth_strip((void *)rewritten, ptrauth_key_function_pointer);
        kern_return_t kr = vm_inherit(mach_task_self(), a & ~(vm_page_size - 1), vm_page_size, VM_INHERIT_SHARE);
        printf("parent: vm_inherit(SHARE): %s\n", mach_error_string(kr));
    }
    print_region("parent", (void *)rewritten);
    if (!run_both("parent", rewritten, jit)) {
        printf("RESULT parent_failed\n");
        return 2;
    }

    pid_t pid = fork();
    if (pid < 0) {
        printf("parent: fork failed: %s\n", strerror(errno));
        printf("RESULT fork_failed\n");
        return 2;
    }
    if (pid == 0) {
        if (child_trace_me && ptrace(PT_TRACE_ME, 0, NULL, 0) != 0) {
            printf("child: ptrace(PT_TRACE_ME) failed: %s\n", strerror(errno));
        }
        if (child_reprotect) {
            // Diagnostic: redo the parent's VM_PROT_COPY dance on the inherited
            // page, which re-registers it as a debug region in this address space.
            vm_address_t a = (vm_address_t)ptrauth_strip((void *)rewritten, ptrauth_key_function_pointer);
            vm_address_t pg = a & ~(vm_page_size - 1);
            kern_return_t kr = vm_protect(mach_task_self(), pg, vm_page_size, FALSE,
                                          VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
            kern_return_t kr2 = vm_protect(mach_task_self(), pg, vm_page_size, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
            printf("child: reprotect %s / %s\n", mach_error_string(kr), mach_error_string(kr2));
        }
        if (child_fresh) {
            // Diagnostic: can this child's address space register a debug region
            // of its own? Rewrite another shared-cache function here and run it.
            int_fn fresh = rewrite_function("child", "erfc", kMovW0_43);
            if (fresh) {
                int r = fresh(0);
                printf("child: fresh erfc(0) = %d (%s)\n", r, r == 43 ? "ok" : "unexpected");
            }
        }
        print_status("child");
        print_region("child", (void *)rewritten);
        int ok = run_both("child", rewritten, jit);
        printf("child: exiting %d\n", ok ? 0 : 3);
        _exit(ok ? 0 : 3);
    }

    int status = 0;
    if (waitpid(pid, &status, 0) < 0) {
        printf("parent: waitpid failed: %s\n", strerror(errno));
        printf("RESULT wait_failed\n");
        return 2;
    }
    if (WIFEXITED(status)) {
        printf("parent: child %d exited %d\n", pid, WEXITSTATUS(status));
        printf("RESULT child_exit=%d\n", WEXITSTATUS(status));
        return WEXITSTATUS(status) == 0 ? 0 : 1;
    }
    if (WIFSIGNALED(status)) {
        printf("parent: child %d killed by signal %d (%s)\n", pid, WTERMSIG(status), strsignal(WTERMSIG(status)));
        printf("RESULT child_signal=%d\n", WTERMSIG(status));
        return 1;
    }
    printf("RESULT child_status=0x%x\n", status);
    return 1;
}
