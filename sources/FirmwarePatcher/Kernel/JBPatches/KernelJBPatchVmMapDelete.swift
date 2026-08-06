// KernelJBPatchVmMapDelete.swift — allow debugger VM_PROT_COPY overwrite of
// permanent USER_DEBUG mappings whose current protection is RW but max protection is RWX.
//
// XNU's immutable-code exception in vm_map_delete tests entry->protection for EXECUTE.
// Repeated VM_PROT_COPY can leave a CSM-associated permanent entry at RW/max-RWX, so the
// fixed-overwrite path rejects it with KERN_PROTECTION_FAILURE. Retarget both compiled
// forms of that exception to the packed max_protection EXECUTE bit instead:
//
//   current protection EXECUTE: bit 9
//   max_protection EXECUTE:     bit 13
//
// Guardrails: no hardcoded file offsets, VAs, registers, or instruction bytes. Both sites
// are recovered from the source-backed micro-CFG rooted at the packed vm_map_entry load:
// `ldr wFlags,[entry,#0x38] ; tbz wFlags,#19` (vme_permanent), followed by the
// VM_MAP_REMOVE_IMMUTABLE_CODE bit-6 check and developer-mode gate. Replacement branches
// are assembled from their decoded mnemonic/register/target with only bit 9 changed to 13.

import Capstone
import Foundation

extension KernelJBPatcher {
    @discardableResult
    func patchVmMapDeleteImmutableCode() -> Bool {
        log("\n[FRIDA] _vm_map_delete: use max protection for immutable-code overwrite")

        let gates = findVmMapDeleteImmutableCodeGates()
        if gates.isEmpty {
            // Older supported kernels predate this compiled CSM/permanent-entry shape.
            log("  [~] immutable-code current-protection gates not present; skipping")
            return true
        }
        guard gates.count == 2 else {
            log("  [-] expected 2 immutable-code execute gates, found \(gates.count)")
            return false
        }

        // The compiler can outline the two source paths into separate local helpers.
        // Validate each gate against its own recovered function rather than assuming
        // both remain in one monolithic vm_map_delete body.
        for gate in gates {
            guard let functionStart = findFunctionStart(gate.offset) else {
                log("  [-] could not recover function containing immutable-code gate")
                return false
            }
            let functionEnd = findFuncEnd(functionStart, maxSize: 0x3000)
            guard gate.offset >= functionStart && gate.offset < functionEnd else {
                log("  [-] immutable-code gate escaped recovered function bounds")
                return false
            }
        }

        var replacements: [(VmMapDeleteGate, Data)] = []
        for gate in gates.sorted(by: { $0.offset < $1.offset }) {
            guard let bytes = ARM64Encoder.encodeTestBitBranch(
                nonzero: gate.nonzero,
                register: gate.register,
                bit: 13,
                from: gate.offset,
                to: gate.target
            ), let decoded = disasm.disassembleOne(bytes, at: UInt64(gate.offset)),
            decoded.mnemonic == (gate.nonzero ? "tbnz" : "tbz"),
            let ops = decoded.aarch64?.operands, ops.count == 3,
            ops[1].type == AARCH64_OP_IMM, ops[1].imm == 13,
            ops[2].type == AARCH64_OP_IMM, Int(ops[2].imm) == gate.target
            else {
                log("  [-] failed to assemble/verify immutable-code gate at 0x\(String(format: "%X", gate.offset))")
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

    private struct VmMapDeleteGate {
        let offset: Int
        let target: Int
        let register: UInt32
        let nonzero: Bool
        let shape: String
    }

    private func findVmMapDeleteImmutableCodeGates() -> [VmMapDeleteGate] {
        var hits: [VmMapDeleteGate] = []

        for range in codeRanges {
            var off = range.start
            while off + 0x30 <= range.end {
                defer { off += 4 }
                let insns = disasm.disassemble(in: buffer.data, at: off, count: 12)
                guard insns.count >= 10,
                      let entryReg = packedEntryFlagsRegister(insns[0]),
                      bitBranchTarget(insns[1], mnemonic: "tbz", register: entryReg, bit: 19) != nil,
                      let immutableFallback = bitBranchTarget(insns[2], mnemonic: "tbz", bit: 6)
                else { continue }

                let permanentTarget = bitBranchTarget(
                    insns[1], mnemonic: "tbz", register: entryReg, bit: 19
                )!

                // Shape A: current-X test immediately follows the immutable-code test.
                // Both absent-condition branches must share the same fallback, followed
                // by the developer-mode byte/bit-0 gate.
                if let executeFallback = bitBranchTarget(
                    insns[3], mnemonic: "tbz", register: entryReg, bit: 9
                ), executeFallback == immutableFallback,
                let devGateIndex = developerModeGateIndex(
                    in: insns, start: 4, end: min(insns.count, 12)
                ), conditionalTarget(insns[devGateIndex]) == immutableFallback + 4
                {
                    if let regIndex = wRegisterIndex(insns[3]) {
                        hits.append(VmMapDeleteGate(
                            offset: Int(insns[3].address), target: executeFallback,
                            register: regIndex, nonzero: false, shape: "shape-A"
                        ))
                    }
                    continue
                }

                // Shape B: developer mode is checked first; current-X then branches to
                // the same allow target as the non-permanent path.
                if let devGateIndex = developerModeGateIndex(in: insns, start: 3, end: min(insns.count, 10)) {
                    let executeIndex = devGateIndex + 1
                    if executeIndex < insns.count,
                       let allowTarget = bitBranchTarget(
                           insns[executeIndex], mnemonic: "tbnz", register: entryReg, bit: 9
                       ), allowTarget == permanentTarget,
                       let devFallback = conditionalTarget(insns[devGateIndex]),
                       devFallback == immutableFallback,
                       let regIndex = wRegisterIndex(insns[executeIndex])
                    {
                        hits.append(VmMapDeleteGate(
                            offset: Int(insns[executeIndex].address), target: allowTarget,
                            register: regIndex, nonzero: true, shape: "shape-B"
                        ))
                    }
                }
            }
        }

        // A malformed/overlapping decode must not turn one site into multiple patches.
        var seen = Set<Int>()
        return hits.filter { seen.insert($0.offset).inserted }
    }

    /// `ldr wFlags, [xEntry, #0x38]` — packed vm_map_entry protection/permanent fields.
    private func packedEntryFlagsRegister(_ insn: Instruction) -> aarch64_reg? {
        guard insn.mnemonic == "ldr",
              let ops = insn.aarch64?.operands, ops.count == 2,
              ops[0].type == AARCH64_OP_REG,
              ops[1].type == AARCH64_OP_MEM, ops[1].mem.disp == 0x38,
              disasm.firstRegisterName(insn)?.hasPrefix("w") == true
        else { return nil }
        return ops[0].reg
    }

    private func bitBranchTarget(
        _ insn: Instruction,
        mnemonic: String,
        register: aarch64_reg? = nil,
        bit: Int64
    ) -> Int? {
        guard insn.mnemonic == mnemonic,
              let ops = insn.aarch64?.operands, ops.count == 3,
              ops[0].type == AARCH64_OP_REG,
              register == nil || ops[0].reg == register,
              ops[1].type == AARCH64_OP_IMM, ops[1].imm == bit,
              ops[2].type == AARCH64_OP_IMM
        else { return nil }
        return Int(ops[2].imm)
    }

    private func conditionalTarget(_ insn: Instruction) -> Int? {
        guard let ops = insn.aarch64?.operands, let target = ops.last,
              target.type == AARCH64_OP_IMM
        else { return nil }
        return Int(target.imm)
    }

    /// Find `ldrb wDev,[xDev] ; ... ; tbz wDev,#0,fallback` in a bounded local window.
    private func developerModeGateIndex(in insns: [Instruction], start: Int, end: Int) -> Int? {
        guard start < end else { return nil }
        for loadIndex in start ..< end {
            let load = insns[loadIndex]
            guard load.mnemonic == "ldrb",
                  let loadOps = load.aarch64?.operands, loadOps.count == 2,
                  loadOps[0].type == AARCH64_OP_REG,
                  loadOps[1].type == AARCH64_OP_MEM,
                  disasm.firstRegisterName(load)?.hasPrefix("w") == true
            else { continue }
            let devReg = loadOps[0].reg
            let branchEnd = min(end, loadIndex + 4)
            guard loadIndex + 1 < branchEnd else { continue }
            for branchIndex in (loadIndex + 1) ..< branchEnd {
                if bitBranchTarget(
                    insns[branchIndex], mnemonic: "tbz", register: devReg, bit: 0
                ) != nil {
                    return branchIndex
                }
            }
        }
        return nil
    }

    private func wRegisterIndex(_ insn: Instruction) -> UInt32? {
        guard let name = disasm.firstRegisterName(insn), name.hasPrefix("w"),
              let value = UInt32(name.dropFirst()), value < 32
        else { return nil }
        return value
    }
}
