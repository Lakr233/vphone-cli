// MISFixDetour.c — the four-word absolute jump, and the trampoline behind it.
//
// See MISFixDetour.h for why a detour rather than an interpose. This file is
// the mechanics, and every instruction word it emits was checked against the
// assembler rather than remembered:
//
//     ldr x16, #8              58000050
//     br  x16                  d61f0200
//     movz x5, #0x1234         d2824685      (base d2800000 | imm<<5 | Rd)
//     movk x5, #0xabcd, lsl 16 f2b579a5      (base f2a00000)
//     movk x5, #1, lsl 32      f2c00025      (base f2c00000)
//     movk x5, #0, lsl 48      f2e00005      (base f2e00000)
//     adrp x9, .               90000009      (mask 9f000000 -> 90000000)
//     adr  x9, .               10000009      (mask 9f000000 -> 10000000)
//
// x16 is IP0, scratch at a function boundary by the procedure call standard,
// which is what makes the literal-load jump safe as the first thing a function
// does. The literal form is used rather than `adrp`+`add` because it has no
// range limit: the trampoline arena and the shared cache need not be within
// ±4GB of each other.

#include "MISFixDetour.h"
#include "MISFixConditionalBranch.h"

#include "MISFixConfig.h"

#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <ptrauth.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>

/// Instructions displaced from the top of the target. Four words is what the
/// absolute jump costs.
#define kDetourWords 4u
#define kDetourBytes (kDetourWords * 4u)

/// Room for one trampoline: four displaced instructions, each of which may
/// expand to eight words when it has to be rewritten, plus the four-word jump
/// back.
#define kTrampolineBytes 128u

// MARK: - Encoding

static uint32_t vpMovz(unsigned rd, uint16_t value) {
    return 0xD2800000u | ((uint32_t)value << 5) | (rd & 0x1Fu);
}

static uint32_t vpMovk(unsigned rd, uint16_t value, unsigned shift) {
    static const uint32_t bases[] = { 0xF2800000u, 0xF2A00000u, 0xF2C00000u, 0xF2E00000u };
    return bases[shift & 3u] | ((uint32_t)value << 5) | (rd & 0x1Fu);
}

/// `value` into `rd`, always four words so a caller can size buffers without
/// asking. The redundant `movk`s cost two cycles once, at load.
static void vpEmitAbsolute(uint32_t *out, unsigned rd, uint64_t value) {
    out[0] = vpMovz(rd, (uint16_t)(value & 0xFFFFu));
    out[1] = vpMovk(rd, (uint16_t)((value >> 16) & 0xFFFFu), 1);
    out[2] = vpMovk(rd, (uint16_t)((value >> 32) & 0xFFFFu), 2);
    out[3] = vpMovk(rd, (uint16_t)((value >> 48) & 0xFFFFu), 3);
}

/// `ldr x16, #8 ; br x16 ; .quad target` — four words, no range limit.
static void vpEmitJump(uint32_t *out, uint64_t target) {
    out[0] = 0x58000050u;
    out[1] = 0xD61F0200u;
    memcpy(&out[2], &target, sizeof(target));
}

/// Sign-extend the low `bits` of `value`.
static int64_t vpSignExtend(uint64_t value, unsigned bits) {
    uint64_t mask = 1ull << (bits - 1);
    return (int64_t)((value ^ mask) - mask);
}

/// Whether `insn` ends the function it appears in — a return in any of its
/// three authenticated spellings, or an unconditional branch away.
///
/// This is the test for "the target is shorter than the patch", and it is not
/// hypothetical: `MISValidateSignatureAndCopyInfo` is a two-instruction thunk
/// in front of `…WithProgress`, so a four-word jump written over it would land
/// in whatever libmis put next.
static int vpIsTerminator(uint32_t insn) {
    return insn == 0xD65F03C0u     // ret
        || insn == 0xD65F0BFFu     // retaa
        || insn == 0xD65F0FFFu     // retab
        || (insn & 0xFC000000u) == 0x14000000u; // b
}

// MARK: - Relocation

/// Rewrite one displaced instruction so it means the same thing from its new
/// address. Returns the number of words written, or 0 when the instruction is
/// PC-relative in a way this does not handle — in which case the whole detour
/// is abandoned, because half a relocation is a corrupted function.
static unsigned vpRelocate(uint32_t insn, uint64_t pc, uint32_t *out) {
    // PACIBSPPC binds LR to both SP and this instruction's original PC.
    // Executing it verbatim in the trampoline would sign with the wrong PC.
    // x15-x17 are caller-saved scratch at function entry; the installer below
    // accepts this expansion only as the first displaced instruction.
    if (insn == 0xDAC1A7FEu) {
        out[0] = 0xAA1E03F1u; // mov x17, x30
        out[1] = 0x910003F0u; // mov x16, sp
        vpEmitAbsolute(out + 2, 15, pc);
        out[6] = 0xDAC18FFEu; // pacib171615: sign x17 with SP=x16, PC=x15
        out[7] = 0xAA1103FEu; // mov x30, x17
        return 8;
    }

    // ADR / ADRP. Both put a PC-relative address in a register, and both
    // become "materialise that same absolute address".
    if ((insn & 0x1F000000u) == 0x10000000u) {
        unsigned rd = insn & 0x1Fu;
        uint64_t immhi = (insn >> 5) & 0x7FFFFu;
        uint64_t immlo = (insn >> 29) & 0x3u;
        int64_t offset = vpSignExtend((immhi << 2) | immlo, 21);
        int isPage = (insn & 0x80000000u) != 0;
        uint64_t address = isPage ? ((pc & ~0xFFFull) + (uint64_t)(offset << 12))
                                  : (pc + (uint64_t)offset);
        vpEmitAbsolute(out, rd, address);
        return 4;
    }

    // Unconditional B. Becomes an absolute jump to where it went.
    if ((insn & 0xFC000000u) == 0x14000000u) {
        int64_t offset = vpSignExtend(insn & 0x03FFFFFFu, 26) * 4;
        vpEmitJump(out, pc + (uint64_t)offset);
        return 4;
    }

    // Everything else that reads PC is refused rather than guessed at: BL
    // (0x94000000), the conditional and compare branches (B.cond 0x54000000,
    // CBZ/CBNZ 0x34000000, TBZ/TBNZ 0x36000000), and the literal loads
    // (0x18000000). A prologue normally contains none of them; when one turns
    // up, the log says so and nothing is written.
    if ((insn & 0xFC000000u) == 0x94000000u  // BL
        || (insn & 0xFF000000u) == 0x54000000u  // B.cond/BC.cond (ordinary B.cond handled by caller)
        || (insn & 0x7E000000u) == 0x34000000u  // CBZ/CBNZ/TBZ/TBNZ
        || (insn & 0x3B000000u) == 0x18000000u) // LDR/LDRSW literal, PRFM literal
    {
        return 0;
    }

    out[0] = insn;
    return 1;
}

// MARK: - Trampoline storage

/// A slab inside this dylib's own `__TEXT` was the intended fallback for a
/// process that may not map executable memory, and it is deliberately not
/// here. Filling it means making its page writable, which means dropping
/// execute from a page of `__TEXT` — and the section's other occupant is the
/// code doing the dropping. Page-aligning a 16 KB hole to avoid sharing would
/// work and costs 16 KB in every guest, for a fallback the guest turns out not
/// to need: `mmap` RW then `mprotect` RX then call was measured working in
/// installd on test-26.4.

static kern_return_t vpProtect(const void *address, size_t length, vm_prot_t protection) {
    vm_size_t page = vm_page_size;
    vm_address_t start = (vm_address_t)(uintptr_t)address & ~(vm_address_t)(page - 1);
    vm_address_t end = ((vm_address_t)(uintptr_t)address + length + page - 1)
        & ~(vm_address_t)(page - 1);
    return vm_protect(mach_task_self(), start, end - start, FALSE, protection);
}

/// Writable memory for one trampoline, or NULL. The caller fills it and then
/// makes it executable; it is never both at once, for the reason in
/// ``vpProtect``'s callers below.
static void *vpAllocateTrampoline(void) {
    void *page = mmap(NULL, kTrampolineBytes, PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANON, -1, 0);
    return page == MAP_FAILED ? NULL : page;
}

// MARK: - Installing

const char *MISFixDetourDescribe(MISFixDetourResult result) {
    switch (result) {
    case MISFixDetourOK: return "installed";
    case MISFixDetourNoTarget: return "the symbol did not bind";
    case MISFixDetourUnrelocatable: return "a displaced instruction is PC-relative";
    case MISFixDetourTooShort: return "the target is shorter than the jump";
    case MISFixDetourNoTrampoline: return "no executable memory for the trampoline";
    case MISFixDetourPageReadOnly: return "the target page could not be made writable";
    case MISFixDetourWriteFailed: return "the detour did not read back as written";
    }
    return "unknown";
}

MISFixDetourResult MISFixDetour(
    const char *label,
    void *function,
    void *replacement,
    void **original
) {
    if (function == NULL)
        return MISFixDetourNoTarget;
    const uint8_t *target = ptrauth_strip(function, ptrauth_key_function_pointer);

    // Build the trampoline before touching the target, so a refusal costs
    // nothing: the displaced instructions relocated, then a jump back to the
    // first instruction the detour did not overwrite.
    uint32_t displaced[kDetourWords];
    memcpy(displaced, target, sizeof(displaced));

    uint32_t body[kTrampolineBytes / 4];
    unsigned words = 0;
    for (unsigned index = 0; index < kDetourWords; index += 1) {
        if (index + 1 < kDetourWords && vpIsTerminator(displaced[index]))
            return MISFixDetourTooShort;
        // Do not clobber scratch values established by an earlier prologue.
        if (displaced[index] == 0xDAC1A7FEu && index != 0)
            return MISFixDetourUnrelocatable;
        uint64_t start = (uint64_t)(uintptr_t)target;
        uint64_t pc = start + index * 4u;
        unsigned written = (displaced[index] & 0xFF000010u) == 0x54000000u
            ? vpRelocateConditionalBranch(displaced[index], pc, start, start + kDetourBytes, body + words)
            : vpRelocate(displaced[index], pc, body + words);
        if (written == 0)
            return MISFixDetourUnrelocatable;
        words += written;
    }
    vpEmitJump(body + words, (uint64_t)(uintptr_t)target + kDetourBytes);
    words += 4;

    // Write, then make executable — never both, and this is measured rather
    // than stylistic. Apple silicon enforces write-xor-execute in hardware
    // below the VM permissions, so a page mapped RWX comes back `prot=7` and
    // then faults on the store:
    //
    //     EXC_BAD_ACCESS (SIGBUS), UNKNOWN_0x32
    //
    // on a region `vm_region_64` reported as `rwx/rwx SM=COW`. Found the hard
    // way, by crash-looping installd on test-26.4.
    void *trampoline = vpAllocateTrampoline();
    if (trampoline == NULL)
        return MISFixDetourNoTrampoline;
    memcpy(trampoline, body, words * 4u);
    if (vpProtect(trampoline, words * 4u, VM_PROT_READ | VM_PROT_EXECUTE) != KERN_SUCCESS) {
        munmap(trampoline, kTrampolineBytes);
        return MISFixDetourNoTrampoline;
    }
    sys_icache_invalidate(trampoline, words * 4u);

    // Hand the trampoline over before the jump goes in, not after. The target
    // is live from the instant its first word changes, and a replacement that
    // reached `*original` while it was still NULL would call zero.
    if (original != NULL) {
        *original = ptrauth_sign_unauthenticated(
            trampoline,
            ptrauth_key_function_pointer,
            0
        );
    }

    // Now the target: copy-on-write, because the cache is mapped shared and
    // read-execute. Execute is given up for the duration, which is safe here
    // and would not be on the page this code is running from.
    if (vpProtect(target, kDetourBytes, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY)
        != KERN_SUCCESS)
    {
        munmap(trampoline, kTrampolineBytes);
        return MISFixDetourPageReadOnly;
    }

    uint32_t detour[kDetourWords];
    vpEmitJump(detour, (uint64_t)(uintptr_t)ptrauth_strip(replacement,
                                                          ptrauth_key_function_pointer));
    memcpy((void *)(uintptr_t)target, detour, sizeof(detour));
    sys_icache_invalidate((void *)(uintptr_t)target, kDetourBytes);

    int landed = memcmp(target, detour, sizeof(detour)) == 0;
    vpProtect(target, kDetourBytes, VM_PROT_READ | VM_PROT_EXECUTE);
    if (!landed) {
        if (original != NULL)
            *original = NULL;
        return MISFixDetourWriteFailed;
    }

    // The owning image is named because the one way this goes quietly wrong is
    // a target that resolved back into libmisfix — see the header on `dlsym`.
    MISFixNote("detour: %s at %p in %s -> %p, trampoline %p (%u words)",
               label,
               (const void *)target,
               MISFixCallerImage(target),
               replacement,
               trampoline,
               words);
    return MISFixDetourOK;
}
