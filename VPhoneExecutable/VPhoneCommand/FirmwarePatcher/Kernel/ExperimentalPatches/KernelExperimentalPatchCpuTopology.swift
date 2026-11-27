// KernelExperimentalPatchCpuTopology.swift — EXP kernel patch: the CPU count
// sysctls answer a phone's topology instead of the VM's.
//
// hw.ncpu, hw.activecpu, hw.physicalcpu, hw.physicalcpu_max, hw.logicalcpu and
// hw.logicalcpu_max come from one handler, `sysctl_hw_generic`, which copies
// the live counts out of the kernel's host and cluster tables on every call.
// A VM with 4 vCPUs therefore answers 4, which no iPhone since the iPhone 8
// does: every iPhone profile in VPhoneGuestDevice is a 6-core A-series part
// with no SMT, so the six answers are all the same number.
//
// Only the sysctl's answers change. The scheduler, the per-CPU arrays, the
// IPI loops and the Mach `host_info(HOST_BASIC_INFO)` trap keep the real
// counts, so the kernel stays consistent with itself. The trap is the gap an
// app can still ask directly; see
// Research/KernelCustomFirmwarePatches/patch_hw_cpu_topology.md.
//
// Reveal (LC_SYMTAB is stripped, so nothing is looked up by symbol):
//   1. `ncpu\0` occurs once in the cstring pool.
//   2. __DATA_CONST holds the OID's oid_name slot: a chained pointer whose
//      low word is that cstring's image offset. oid_handler is the next slot.
//   3. In that handler's prologue, `LDR wA, [xN]` and `LDR wB, [xM, #d]`
//      within six instructions before `STP wA, wB, [sp, #D]` copy max_cpus
//      and avail_cpus into the host_basic_info the switch reads: the two
//      loads become MOVZ.
//   4. `ADD x9, sp, #D` then `ADD x1, x9, #L` is the logicalcpu (or _max)
//      case handing stack slot D + L to the output helper: the pair becomes
//      MOVZ w9 / STR w9, [sp, #D+L]; x10 already holds sp + D and the next
//      instruction rebuilds x1 from it.
//   5. `MOV x8, x20` then `LDR w9, [x0, #8]` (or `#0x10`) after the cluster
//      table call is physicalcpu (or _max): the load becomes MOVZ.
//
// Replacement instructions come from ARM64Encoder, as the kernel patcher
// guardrails require. A handler on another build that misses a step writes
// nothing for that step and says so. Idempotent: a replaced load is no
// longer a load.

import Foundation
import VPhonePatchKit

extension KernelExperimentalPatcher {
    /// The six CPU count sysctls answer this. Every iPhone this project
    /// presents (iPhone 15 through 18) is a 6-core part without SMT.
    static let phoneCoreCount: UInt16 = 6

    /// Point the CPU count sysctls at a phone's topology. Returns true if
    /// any byte was modified.
    @discardableResult
    func patchCpuTopology() -> Bool {
        let id = "kernel-exp-cpu_topology"
        guard gateAllows("kernel-exp-cpu_topology") else { return false }
        log("\n[EXP] CPU topology sysctls: answer \(Self.phoneCoreCount) cores")

        guard let handler = sysctlHandler(oidNamed: "ncpu") else { return false }
        let count = Self.phoneCoreCount
        var changed = false

        // 3. max_cpus and avail_cpus, copied into the stack host_basic_info.
        let loads = hostCountLoads(in: handler)
        if loads.isEmpty {
            log("  [-] no host count copy (LDR/LDR/STP) in the handler — hw.ncpu and hw.activecpu left alone")
        }
        for (offset, register) in loads {
            guard let movz = ARM64Encoder.encodeMovzW(rd: register, imm16: count) else { continue }
            emit(offset, movz, patchID: id, description: "CPU counts: host table load -> \(count)")
            changed = true
        }

        // 4. logicalcpu and logicalcpu_max, handed to the helper from a stack
        // slot. The case is three words (`add x9, sp, #D`, `add x1, x9, #L`,
        // `b out`) and the replacement needs four, so the third word branches
        // into a cave that hands the slot over and takes the original branch.
        let handoffs = stackSlotHandoffs(in: handler)
        if !handoffs.isEmpty, let cave = findCodeCave(size: 8 * handoffs.count) {
            var caveWords: [Data] = []
            var siteWords: [(Int, Data)] = []
            for (index, handoff) in handoffs.enumerated() {
                let entry = cave + 8 * index
                guard let movz = ARM64Encoder.encodeMovzW(rd: 9, imm16: count),
                      let store = ARM64Encoder.encodeStrWUnsignedOffset(rt: 9, rn: 31, offset: UInt32(handoff.slot)),
                      let jump = ARM64Encoder.encodeB(from: handoff.site + 8, to: entry),
                      let address = ARM64Encoder.encodeAddImm12(rd: 1, rn: 31, imm12: UInt32(handoff.slot)),
                      let back = ARM64Encoder.encodeB(from: entry + 4, to: handoff.exit)
                else { continue }
                siteWords += [(handoff.site, movz), (handoff.site + 4, store), (handoff.site + 8, jump)]
                caveWords += [address, back]
            }
            if siteWords.count == 3 * handoffs.count {
                emit(cave, caveWords.reduce(into: Data()) { $0.append($1) }, patchID: id, virtualAddress: fileOffsetToVA(cave),
                     description: "CPU counts: logical CPU slot handoffs")
                for (offset, word) in siteWords {
                    emit(offset, word, patchID: id, description: "CPU counts: &logicalcpu slot -> \(count)")
                }
                changed = true
            }
        }
        if handoffs.count < 2 { log("  [-] \(handoffs.count) logical CPU handoff(s) found, expected 2") }

        // 5. physicalcpu and physicalcpu_max, read from the cluster table.
        var clusterLoads = 0
        for offset in stride(from: handler, to: handler + 0x800, by: 4) {
            guard let loadOffset = clusterCountLoad(after: offset),
                  let movz = ARM64Encoder.encodeMovzW(rd: 9, imm16: count) else { continue }
            emit(loadOffset, movz, patchID: id, description: "CPU counts: cluster table load -> \(count)")
            clusterLoads += 1
            changed = true
        }
        if clusterLoads < 2 { log("  [-] \(clusterLoads) cluster count load(s) found, expected 2") }

        if !changed { log("  [-] handler found but no count source matched — nothing written") }
        return changed
    }

    // MARK: - Reveal

    func instruction(_ offset: Int) -> ARM64Instruction? {
        disasm.disassembleOne(in: buffer.data, at: offset)
    }

    /// The handler behind the sysctl OID named `name`: the one __DATA_CONST
    /// slot whose chained pointer's low word is the cstring's image offset,
    /// then the next slot's target (struct sysctl_oid: oid_name, then
    /// oid_handler). Same reveal as `patchBootargsEmpty`.
    func sysctlHandler(oidNamed name: String) -> Int? {
        let hits = buffer.findAll(Data(name.utf8) + Data([0])).filter { $0 == 0 || buffer.data[$0 - 1] == 0 }
        guard hits.count == 1, let dc = segments.first(where: { $0.name == "__DATA_CONST" }),
              let text = segments.first(where: { $0.name == "__TEXT" }),
              let nameVA = fileOffsetToVA(hits[0]), nameVA >= text.vmAddr
        else {
            log("  [-] expected exactly 1 '\(name)' cstring and the segment map, found \(hits.count) — refusing")
            return nil
        }
        let imageOffset = UInt32(truncatingIfNeeded: nameVA - text.vmAddr)
        var slot = Int(dc.fileOffset)
        while slot + 16 <= Int(dc.fileOffset + dc.fileSize) {
            defer { slot += 8 }
            let raw = buffer.readU64(at: slot)
            guard raw >> 63 == 0, UInt32(truncatingIfNeeded: raw) == imageOffset else { continue }
            let target = Int(UInt32(truncatingIfNeeded: buffer.readU64(at: slot + 8)))
            if codeRanges.contains(where: { $0.start <= target && target < $0.end }) { return target }
        }
        log("  [-] no __DATA_CONST slot points at '\(name)' with code after it — refusing")
        return nil
    }

    /// The two `LDR wN, [xM(, #d)]` whose registers an `STP wA, wB, [sp, #D]`
    /// in the prologue stores, with their register numbers.
    private func hostCountLoads(in handler: Int) -> [(offset: Int, register: UInt32)] {
        for offset in stride(from: handler, to: handler + 0x100, by: 4) {
            guard let stp = instruction(offset), stp.mnemonic == "stp",
                  let ops = stp.detail?.operands, ops.count == 3,
                  ops[0].type == .register, ops[1].type == .register,
                  ops[2].type == .memory, ops[2].mem.base == .sp, ops[2].mem.index == .invalid
            else { continue }
            // Word registers only: the frame saves are pairs of x registers.
            let pair = [ops[0].reg, ops[1].reg]
            guard pair.allSatisfy({ wNumber($0) != nil }) else { continue }
            var found: [(Int, UInt32)] = []
            for back in stride(from: offset - 4, through: max(handler, offset - 24), by: -4) {
                guard let (loadOffset, register) = wordLoad(at: back), pair.contains(register) else { continue }
                if let number = wNumber(register), !found.contains(where: { $0.1 == number }) {
                    found.append((loadOffset, number))
                }
            }
            // The host_basic_info copy is the pair whose two registers were both
            // just loaded from a table; anything else is a frame save.
            if found.count == 2 { return found }
        }
        return []
    }

    /// `LDR wR, [xN, #disp]`, as its offset and register.
    private func wordLoad(at offset: Int) -> (Int, ARM64Register)? {
        guard let insn = instruction(offset), insn.mnemonic == "ldr",
              let ops = insn.detail?.operands, ops.count == 2,
              ops[0].type == .register, wNumber(ops[0].reg) != nil,
              ops[1].type == .memory, ops[1].mem.index == .invalid
        else { return nil }
        return (offset, ops[0].reg)
    }

    /// Every `ADD x9, sp, #D`, `ADD x1, x9, #0x1c or #0x24`, `B`: the
    /// logicalcpu (or _max) case handing its host_basic_info field to the
    /// output helper, as the site of the first add, the stack slot and the
    /// branch's target. `#0x20` between the two is physical_cpu_max of the host
    /// struct, which the cluster patch below must not be confused with.
    private func stackSlotHandoffs(in handler: Int) -> [(site: Int, slot: Int, exit: Int)] {
        var found: [(Int, Int, Int)] = []
        for offset in stride(from: handler, to: handler + 0x800, by: 4) {
            guard let (a, b) = adjacentAdds(offset), a.0 == ARM64Register.x(9), a.1 == .sp,
                  b.0 == ARM64Register.x(1), b.1 == ARM64Register.x(9),
                  let base = smallImmediate(a.2), [0x1c, 0x24].contains(b.2.imm),
                  let branch = instruction(offset + 8), branch.mnemonic == "b",
                  let ops = branch.detail?.operands, ops.count == 1, ops[0].type == .immediate,
                  ops[0].imm > offset, ops[0].imm < offset + 0x1000
            else { continue }
            found.append((offset, base + Int(b.2.imm), Int(ops[0].imm)))
        }
        return found
    }

    /// Two `ADD xD, xN, #imm` in a row: (destination, source, immediate operand).
    private func adjacentAdds(_ offset: Int) -> ((ARM64Register, ARM64Register, ARM64Operand),
                                                (ARM64Register, ARM64Register, ARM64Operand))? {
        guard let add = instruction(offset), let next = instruction(offset + 4),
              add.mnemonic == "add", next.mnemonic == "add",
              let a = add.detail?.operands, let b = next.detail?.operands,
              a.count == 3, b.count == 3,
              a[0].type == .register, a[1].type == .register, a[2].type == .immediate,
              b[0].type == .register, b[1].type == .register, b[2].type == .immediate
        else { return nil }
        return ((a[0].reg, a[1].reg, a[2]), (b[0].reg, b[1].reg, b[2]))
    }

    /// `MOV x8, x20` then `LDR w9, [x0, #8 or #0x10]` within four instructions:
    /// the physicalcpu (or _max) case after the cluster table call. Returns
    /// the load's offset.
    private func clusterCountLoad(after offset: Int) -> Int? {
        guard let mov = instruction(offset), mov.mnemonic == "mov",
              let ops = mov.detail?.operands, ops.count == 2,
              ops[0].type == .register, ops[0].reg == ARM64Register.x(8),
              ops[1].type == .register, ops[1].reg == ARM64Register.x(20)
        else { return nil }
        for next in stride(from: offset + 4, to: offset + 20, by: 4) {
            guard let insn = instruction(next), insn.mnemonic == "ldr",
                  let load = insn.detail?.operands, load.count == 2,
                  load[0].type == .register, load[0].reg == ARM64Register.w(9),
                  load[1].type == .memory, load[1].mem.base == ARM64Register.x(0),
                  load[1].mem.index == .invalid, [8, 0x10].contains(load[1].mem.disp)
            else { continue }
            return next
        }
        return nil
    }

    private func smallImmediate(_ operand: ARM64Operand) -> Int? {
        guard operand.imm >= 0, operand.imm < 0x1000 else { return nil }
        return Int(operand.imm)
    }

    private func wNumber(_ register: ARM64Register) -> UInt32? {
        (0 ... 30).first { ARM64Register.w($0) == register }.map(UInt32.init)
    }
}
