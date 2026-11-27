// KernelExperimentalPatchBootargs.swift — EXP kernel patch: make the
// `kern.bootargs` sysctl answer an empty string.
//
// Every vphone guest passes `serial=3 -v debug=0x2014e` on the kernel command
// line (IBootPatcher.bootArgs), and XNU exposes it to any process through
// `sysctlbyname("kern.bootargs")`. A stock iPhone answers "", so the string
// is a VM sign that needs no jailbreak to read.
//
// The kernel keeps the real arguments: the serial console and the debug
// output are configured from them, so PE_state.bootArgs is left alone. Only
// the sysctl's answer changes, and the OID keeps its name — a missing
// `kern.bootargs` would be as telling as the vphone one.
//
// Reveal (LC_SYMTAB is stripped, so nothing is looked up by symbol):
//   1. `bootargs\0` occurs once in the image, in the kernel's cstring pool.
//   2. __DATA_CONST holds the OID's oid_name slot: a chained pointer whose
//      low word is that cstring's image offset. oid_handler is the next
//      slot, with the handler's image offset in its low word.
//   3. The handler builds the string address as `LDR xN, [xN, #imm]`
//      (= &PE_state) and, within 0x60 bytes, `ADD xM, xN, #off` (=
//      &PE_state.bootArgs). That xM is what the string helper reads.
//   4. The empty string is the NUL that ends the cstring before `bootargs`.
//
// Replacement instructions come from ARM64Encoder, as the kernel patcher
// guardrails require. A handler on another build that does not match
// step 3, or a string out of ADRP reach, refuses. Idempotent: the patched
// handler no longer has the LDR, so a second run finds nothing to write.

import Foundation
import VPhonePatchKit

extension KernelExperimentalPatcher {
    /// Point `kern.bootargs` at an empty string. Returns true if any byte
    /// was modified.
    @discardableResult
    func patchBootargsEmpty() -> Bool {
        log("\n[EXP] kern.bootargs: answer an empty string")

        // 1. The OID name and the empty string just before it.
        let nameHits = buffer.findAll(Data("bootargs".utf8) + Data([0]))
        guard nameHits.count == 1 else {
            log("  [-] expected exactly 1 'bootargs' cstring, found \(nameHits.count) — refusing")
            return false
        }
        let nameOffset = nameHits[0]
        guard nameOffset > 0, buffer.data[nameOffset - 1] == 0,
              let emptyVA = fileOffsetToVA(nameOffset - 1) else {
            log("  [-] no NUL before 'bootargs' to answer with — refusing")
            return false
        }

        // 2. The OID: oid_name slot, then oid_handler in the next slot.
        guard let dc = segments.first(where: { $0.name == "__DATA_CONST" }) else {
            log("  [-] no __DATA_CONST — refusing")
            return false
        }
        // Chained targets are offsets from the image base, __TEXT's vmAddr.
        guard let text = segments.first(where: { $0.name == "__TEXT" }),
              let nameVA = fileOffsetToVA(nameOffset), nameVA >= text.vmAddr else {
            log("  [-] cannot map the 'bootargs' cstring to an image offset — refusing")
            return false
        }
        let nameImageOffset = UInt32(truncatingIfNeeded: nameVA - text.vmAddr)
        var handlerOffset: Int?
        var slot = Int(dc.fileOffset)
        while slot + 16 <= Int(dc.fileOffset + dc.fileSize) {
            defer { slot += 8 }
            let raw = buffer.readU64(at: slot)
            // Kernel-cache chained pointer: image offset in the low word,
            // ptrauth material above it. Unauthenticated for a cstring.
            guard raw >> 63 == 0, UInt32(truncatingIfNeeded: raw) == nameImageOffset else { continue }
            let handlerRaw = buffer.readU64(at: slot + 8)
            let handlerImageOffset = UInt64(UInt32(truncatingIfNeeded: handlerRaw))
            let candidateVA = text.vmAddr + handlerImageOffset
            guard let candidate = vaToFileOffset(candidateVA),
                  codeRanges.contains(where: { $0.start <= candidate && candidate < $0.end }) else { continue }
            handlerOffset = candidate
            break
        }
        guard let handler = handlerOffset else {
            log("  [-] no __DATA_CONST slot points at 'bootargs' with code after it — refusing")
            return false
        }

        // 3. The handler reloads xN twice (a GOT slot, then &PE_state), so the
        // load that matters is the one nearest the ADD: for each
        // `ADD xM, xN, #off` take the closest preceding `LDR xN, [xN, #imm]`
        // that an `ADRP xN` set up, within 0x20 bytes. xM is what the string
        // helper reads, xN + off is &PE_state.bootArgs.
        var ldrOffset: Int?
        var addOffset: Int?
        var stringRegister: ARM64Register?
        for offset in stride(from: handler, to: handler + 0x60, by: 4) {
            guard let addInsn = disasm.disassembleOne(in: buffer.data, at: offset),
                  let addOps = addInsn.detail?.operands, addOps.count == 3,
                  addInsn.mnemonic == "add", addOps[0].type == .register,
                  addOps[1].type == .register, addOps[2].type == .immediate else { continue }
            let peRegister = addOps[1].reg
            for load in stride(from: offset - 4, through: max(handler, offset - 0x20), by: -4) {
                guard let ldrInsn = disasm.disassembleOne(in: buffer.data, at: load),
                      let ldrOps = ldrInsn.detail?.operands, ldrOps.count == 2,
                      ldrInsn.mnemonic == "ldr", ldrOps[0].reg == peRegister,
                      ldrOps[1].type == .memory, ldrOps[1].mem.base == peRegister,
                      let pageInsn = disasm.disassembleOne(in: buffer.data, at: load - 4),
                      pageInsn.mnemonic == "adrp", let pageOps = pageInsn.detail?.operands,
                      pageOps.count == 2, pageOps[0].reg == peRegister else { continue }
                ldrOffset = load
                addOffset = offset
                stringRegister = addOps[0].reg
                break
            }
            if addOffset != nil { break }
        }
        guard let ldr = ldrOffset, let add = addOffset, let stringRegister,
              let stringRegisterNumber = (0 ... 30).first(where: { ARM64Register.x($0) == stringRegister }).map(UInt32.init) else {
            log("  [-] handler does not build &PE_state.bootArgs with LDR+ADD — refusing")
            return false
        }

        // 4. Address the empty string instead.
        guard let adrp = ARM64Encoder.encodeADRP(rd: stringRegisterNumber, pc: fileOffsetToVA(ldr) ?? 0, target: emptyVA),
              let addInsn = ARM64Encoder.encodeAddImm12(rd: stringRegisterNumber, rn: stringRegisterNumber, imm12: UInt32(emptyVA & 0xFFF)) else {
            log("  [-] the empty string is outside ADRP reach of the handler — refusing")
            return false
        }
        emit(ldr, adrp, patchID: "kernel-exp-bootargs",
             description: "kern.bootargs handler: &PE_state load -> ADRP x\(stringRegisterNumber), page of \"\"")
        emit(add, addInsn, patchID: "kernel-exp-bootargs",
             description: "kern.bootargs handler: &PE_state.bootArgs -> \"\"")
        return true
    }
}
