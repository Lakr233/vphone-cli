// KernelJBPatchVmMapDelete.swift — optional Frida Stalker support (--frida).
//
// Frida's write-then-flip leaves a permanent CSM mapping at current RW / max RWX;
// vm_map_delete's immutable-code exception tests current-protection EXECUTE, which
// is clear, so re-instrumentation fails with KERN_PROTECTION_FAILURE. Retarget the
// test from current-X (packed [entry,#0x38] bit 9) to max-X (bit 13).
// Reveal + validation: research/kernel_patch_jb/patch_vm_map_delete_immutable_code.md.

import Capstone
import Foundation

extension KernelJBPatcher {
    private struct VmMapDeleteGate {
        let offset: Int
        let register: UInt32
        let nonzero: Bool
        let target: Int
        let shape: String
    }

    @discardableResult
    func patchVmMapDeleteImmutableCode() -> Bool {
        log("\n[FRIDA] _vm_map_delete: allow debugger overwrite of RW/max-RWX permanent code")

        let gates = findVmMapDeleteImmutableCodeGates()
        if gates.isEmpty {
            // Older kernels predate this compiled CSM/permanent-entry shape.
            log("  [~] immutable-code current-protection gates not present; skipping")
            return true
        }
        guard gates.count == 2 else {
            log("  [-] expected 2 immutable-code execute gates, found \(gates.count); failing closed")
            return false
        }

        // Each gate must live inside a recovered function (the compiler may outline
        // the two source paths into separate local helpers).
        for gate in gates where findFunctionStart(gate.offset) == nil {
            log("  [-] could not recover function containing gate at 0x\(String(format: "%X", gate.offset))")
            return false
        }

        var replacements: [(VmMapDeleteGate, Data)] = []
        for gate in gates.sorted(by: { $0.offset < $1.offset }) {
            guard let bytes = ARM64Encoder.encodeTestBitBranch(
                nonzero: gate.nonzero, register: gate.register, bit: 13,
                from: gate.offset, to: gate.target
            ),
            let decoded = disasm.disassembleOne(bytes, at: UInt64(gate.offset)),
            decoded.mnemonic == (gate.nonzero ? "tbnz" : "tbz"),
            let ops = decoded.aarch64?.operands, ops.count == 3,
            ops[1].type == AARCH64_OP_IMM, ops[1].imm == 13,
            ops[2].type == AARCH64_OP_IMM, Int(ops[2].imm) == gate.target
            else {
                log("  [-] failed to assemble/verify max-X gate at 0x\(String(format: "%X", gate.offset))")
                return false
            }
            replacements.append((gate, bytes))
        }

        for (gate, bytes) in replacements {
            emit(gate.offset, bytes,
                 patchID: "kernelcache_frida.vm_map_delete_immutable_code",
                 virtualAddress: fileOffsetToVA(gate.offset),
                 description: "\(gate.nonzero ? "tbnz" : "tbz") entry max_protection.X [vm_map_delete immutable-code \(gate.shape), --frida]")
        }
        return true
    }

    // MARK: - Semantic matcher

    private func findVmMapDeleteImmutableCodeGates() -> [VmMapDeleteGate] {
        var hits: [VmMapDeleteGate] = []

        for range in codeRanges {
            var off = range.start
            while off + 4 <= min(range.end, buffer.count) {
                defer { off += 4 }
                // Cheap pre-filter: 32-bit `ldr wRt, [xN, #0x38]`.
                let word = buffer.readU32(at: off)
                guard word & 0xFFC0_0000 == 0xB940_0000,
                      ((word >> 10) & 0xFFF) * 4 == 0x38
                else { continue }

                if let gate = matchGate(at: off) {
                    hits.append(gate)
                }
            }
        }

        var seen = Set<Int>()
        return hits.filter { seen.insert($0.offset).inserted }
    }

    /// The window rooted at `ldr wF,[entry,#0x38] ; tbz wF,#19` (vme_permanent),
    /// carrying the inlined developer_mode_state() read and the immutable-code
    /// current-X test to retarget.
    private func matchGate(at ldrOff: Int) -> VmMapDeleteGate? {
        let insns = disasm.disassemble(in: buffer.data, at: ldrOff, count: 16)
        guard insns.count >= 8,
              let flagsReg = destRegister(insns[0]),
              bitBranch(insns[1], mnemonic: "tbz", register: flagsReg, bit: 19) != nil
        else { return nil }

        // Require the inlined developer_mode_state() read somewhere in the window:
        // `ldrb wD,[...] ; ... ; tbz/tbnz wD,#0`. Gating anchor for these gates.
        guard developerModeGatePresent(insns) else { return nil }

        // Shape A: the current-X test immediately follows a remove-flags argument
        // test and shares its fallback target.
        //   tbz wArg,#b, T
        //   tbz wF,  #9, T          <- retarget
        for i in 2 ..< (insns.count - 1) {
            guard let argTarget = bitBranchAnyBit(insns[i], mnemonic: "tbz"),
                  destRegister(insns[i]) != flagsReg,
                  let exec = bitBranch(insns[i + 1], mnemonic: "tbz", register: flagsReg, bit: 9),
                  exec == argTarget.target
            else { continue }
            return VmMapDeleteGate(
                offset: Int(insns[i + 1].address), register: flagsReg,
                nonzero: false, target: exec, shape: "shape-A")
        }

        // Shape B: developer mode is checked first, then the current-X test branches
        // to the same permanent-continuation target as the vme_permanent test.
        //   tbz wF,#19, P
        //   ... developer-mode gate ...
        //   tbnz wF,#9, P           <- retarget
        let permTarget = bitBranch(insns[1], mnemonic: "tbz", register: flagsReg, bit: 19)!
        for i in 3 ..< insns.count {
            guard let exec = bitBranch(insns[i], mnemonic: "tbnz", register: flagsReg, bit: 9),
                  exec == permTarget
            else { continue }
            return VmMapDeleteGate(
                offset: Int(insns[i].address), register: flagsReg,
                nonzero: true, target: exec, shape: "shape-B")
        }

        return nil
    }

    // MARK: - Instruction helpers

    /// The instruction's first operand as a W register number, if it is one.
    private func destRegister(_ insn: Instruction) -> UInt32? {
        guard let name = disasm.firstRegisterName(insn), name.hasPrefix("w"),
              let value = UInt32(name.dropFirst()), value < 32
        else { return nil }
        return value
    }

    /// A `tbz`/`tbnz wReg,#bit,target` matching the given mnemonic, register, and
    /// bit; returns the branch target file offset.
    private func bitBranch(_ insn: Instruction, mnemonic: String, register: UInt32, bit: Int64) -> Int? {
        guard insn.mnemonic == mnemonic,
              let ops = insn.aarch64?.operands, ops.count == 3,
              ops[0].type == AARCH64_OP_REG, destRegister(insn) == register,
              ops[1].type == AARCH64_OP_IMM, ops[1].imm == bit,
              ops[2].type == AARCH64_OP_IMM
        else { return nil }
        return Int(ops[2].imm)
    }

    /// Any `tbz`/`tbnz wReg,#bit,target` of the given mnemonic; returns bit + target.
    private func bitBranchAnyBit(_ insn: Instruction, mnemonic: String) -> (bit: Int64, target: Int)? {
        guard insn.mnemonic == mnemonic,
              let ops = insn.aarch64?.operands, ops.count == 3,
              ops[0].type == AARCH64_OP_REG,
              ops[1].type == AARCH64_OP_IMM, ops[2].type == AARCH64_OP_IMM
        else { return nil }
        return (ops[1].imm, Int(ops[2].imm))
    }

    /// The inlined `developer_mode_state()`: a byte load whose bit 0 is then tested
    /// (`ldrb wD,[...] ; … ; tbz/tbnz wD,#0`).
    private func developerModeGatePresent(_ insns: [Instruction]) -> Bool {
        for i in 0 ..< insns.count {
            guard insns[i].mnemonic == "ldrb", let devReg = destRegister(insns[i]) else { continue }
            for j in (i + 1) ..< min(insns.count, i + 4) {
                let m = insns[j].mnemonic
                if (m == "tbz" || m == "tbnz"),
                   bitBranch(insns[j], mnemonic: m, register: devReg, bit: 0) != nil {
                    return true
                }
            }
        }
        return false
    }
}
