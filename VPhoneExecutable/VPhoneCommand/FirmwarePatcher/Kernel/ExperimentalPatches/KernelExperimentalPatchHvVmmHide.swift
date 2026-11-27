// KernelExperimentalPatchHvVmmHide.swift — EXP kernel patch: the
// `hv_vmm_present` sysctl answers ENOENT to userland, the truth to the kernel.
//
// `kernel-exp-hv_vmm` renames the OID, but any process can still walk the MIB
// (`sysctl.name2oid` / `sysctl.next` are world-readable) and read `1` under
// the new name. A stock iPhone has no such OID at all, so what an app must see
// is ENOENT.
//
// The handler, `sysctl_vmm_present(oidp, arg1, arg2, req)`, is one
// `IODTGetDefault("vmm-present", &v, 4)` and `SYSCTL_OUT(req, &v, 4)`. A
// request from userland carries the calling `proc` in `req->p`; the kernel's
// own `kernel_sysctlbyname` callers (AMFI, the kexts that would otherwise
// panic with "No PMGR?") pass a req whose `p` is NULL. So the handler keeps
// its name, its place in the tree and its answer, and learns one rule: a
// caller that names itself is told the OID does not exist.
//
// Reveal (LC_SYMTAB is stripped):
//   1. `\0hv_vmm_present\0` occurs once in the cstring pool.
//   2. __DATA_CONST holds the OID's oid_name slot: a chained pointer whose
//      low word is that cstring's image offset. oid_handler is two slots on
//      (oid_arg1, oid_arg2, oid_name, oid_handler).
//   3. The handler's shape: `MOV x19, x3` (req), `STR wzr, [sp, #0]` (the
//      zeroed answer), `ADRP x0` (the "vmm-present" key). The store is
//      replaced by a branch to the trampoline, which replays it.
//
// Trampoline, in a code cave: `LDR x8, [x19]` (req->p); `CBNZ x8` to the
// ENOENT exit; `STR wzr, [sp]`; `B` back to the ADRP. The exit restores the
// handler's own frame (`LDP x29, x30`, `LDP x20, x19`, `ADD sp`) and returns 2
// with `RETAB`, as a userland call to a missing OID would after the walk.
//
// Replacement instructions come from ARM64Encoder and the ARM64 constants, as
// the kernel patcher guardrails require. A handler on another build that
// misses a step writes nothing. Idempotent: the store is no longer a store.

import Foundation
import VPhonePatchKit

extension KernelExperimentalPatcher {
    /// Make `hv_vmm_present` ENOENT for processes. Returns true if any byte
    /// was modified.
    @discardableResult
    func patchHvVmmHideFromUser() -> Bool {
        let id = "kernel-exp-hv_vmm.user"
        guard gateAllows("kernel-exp-hv_vmm") else { return false }
        log("\n[EXP] hv_vmm_present: ENOENT to userland, the truth to the kernel")

        guard let handler = sysctlHandler(oidNamed: "hv_vmm_present"),
              let (site, slot) = userCheckSite(in: handler)
        else { return false }

        // The handler's epilogue, replayed by the ENOENT exit.
        guard let restore = handlerEpilogue(after: site, in: handler) else {
            log("  [-] handler found but its epilogue is not the shape this patch replays — refusing")
            return false
        }

        let cave = findCodeCave(size: 4 * 8)
        guard let cave else {
            log("  [-] no code cave for the trampoline — refusing")
            return false
        }
        var words: [Data?] = []
        func put(_ word: Data?) { words.append(word) }
        func pc() -> Int { cave + words.count * 4 }

        put(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 8, rn: 19, offset: 0))
        let branch = words.count; put(nil)
        put(ARM64Encoder.encodeStrWUnsignedOffset(rt: 31, rn: 31, offset: UInt32(slot)))
        put(ARM64Encoder.encodeB(from: pc(), to: site + 4))
        // The exit.
        let exit = pc()
        put(ARM64Encoder.encodeMovzW(rd: 0, imm16: 2))
        for word in restore { put(word) }
        put(ARM64.retab)
        words[branch] = ARM64Encoder.encodeCompareBranch(nonzero: true, register: 8, from: cave + branch * 4, to: exit, width64: true)

        guard words.allSatisfy({ $0 != nil }), let jump = ARM64Encoder.encodeB(from: site, to: cave) else { return false }
        let code = words.compactMap { $0 }.reduce(into: Data()) { $0.append($1) }
        emit(cave, code, patchID: id, virtualAddress: fileOffsetToVA(cave), description: "hv_vmm_present: userland check trampoline")
        emit(site, jump, patchID: id, virtualAddress: fileOffsetToVA(site),
             description: "hv_vmm_present: handler -> trampoline")
        return true
    }

    /// `MOV x19, x3`, `STR wzr, [sp]`, `ADRP x0` in a row: the offset of the store.
    private func userCheckSite(in handler: Int) -> (site: Int, slot: Int)? {
        for offset in stride(from: handler, to: handler + 0x40, by: 4) {
            guard let mov = instruction(offset), mov.mnemonic == "mov",
                  let m = mov.detail?.operands, m.count == 2,
                  m[0].reg == ARM64Register.x(19), m[1].reg == ARM64Register.x(3),
                  let store = instruction(offset + 4), store.mnemonic == "str",
                  let s = store.detail?.operands, s.count == 2,
                  s[0].reg == .wzr, s[1].type == .memory, s[1].mem.base == .sp, s[1].mem.index == .invalid,
                  s[1].mem.disp >= 0, s[1].mem.disp < 0x1000, s[1].mem.disp % 4 == 0,
                  let adrp = instruction(offset + 8), adrp.mnemonic == "adrp"
            else { continue }
            return (offset + 4, Int(s[1].mem.disp))
        }
        return nil
    }

    /// `LDP x29, x30, [sp, #a]`, `LDP x20, x19, [sp, #b]`, `ADD sp, sp, #frame`:
    /// the handler's epilogue instructions, as this build encodes them.
    private func handlerEpilogue(after site: Int, in handler: Int) -> [Data]? {
        for offset in stride(from: site, to: handler + 0x80, by: 4) {
            guard let a = instruction(offset), a.mnemonic == "ldp",
                  let ao = a.detail?.operands, ao.count == 3,
                  ao[0].reg == .x(29), ao[1].reg == .x(30),
                  let b = instruction(offset + 4), b.mnemonic == "ldp",
                  let bo = b.detail?.operands, bo.count == 3,
                  bo[0].reg == .x(20), bo[1].reg == .x(19),
                  let add = instruction(offset + 8), add.mnemonic == "add",
                  let ad = add.detail?.operands, ad.count == 3,
                  ad[0].reg == .sp, ad[1].reg == .sp, ad[2].type == .immediate,
                  let ret = instruction(offset + 12), ret.mnemonic == "retab"
            else { continue }
            return (0 ..< 3).map { buffer.readBytes(at: offset + $0 * 4, count: 4) }
        }
        return nil
    }
}
