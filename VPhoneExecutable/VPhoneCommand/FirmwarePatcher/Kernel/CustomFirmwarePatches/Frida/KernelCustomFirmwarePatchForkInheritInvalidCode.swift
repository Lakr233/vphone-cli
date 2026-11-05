// KernelCustomFirmwarePatchForkInheritInvalidCode.swift — optional Frida
// fork-after-instrumentation support.
//
// Declared as `kernel-exp-frida_fork_inherit_invalid_code`, off in `standard`.
//
// Frida rewrites code the way a debugger does: vm_protect(VM_PROT_COPY), write,
// re-protect executable. vm_map_protect then calls vm_map_entry_cs_associate
// with vmkf_remap_prot_copy, which registers the range with the code-signing
// monitor as a debug region and marks the entry `vme_xnu_user_debug` and
// `csm_associated`. That association is what lets the process run the page.
// vm_map_fork copies each entry with both bits cleared (non-macOS
// vm_map_entry_copy_csm_assoc), and TXM's fork hook does nothing, so a fork
// child has no debug region: its first execute fault re-validates the page in
// the VM, finds it tainted and kills it with CODESIGNING "Invalid Page".
//
// The child's entry is associated anyway, as ordinary signed code:
// vm_map_store_entry_link calls vm_map_entry_cs_associate(map, entry, flags)
// with the flags it was given, NONE in fork. The monitor refuses a modified
// page, and the failure path strips VM_PROT_EXECUTE from both protections, so
// the child sees the page r--/rw-. This patch hooks the one link call
// vm_map_fork's share and fast-copy paths make and changes only its flags:
// when the parent's entry was a debug entry and the parent (the current task)
// holds `com.apple.private.cs.debugger`, the link passes
// vmkf_remap_prot_copy, so the association takes the debug-region path —
// exactly what the parent's own vm_protect(VM_PROT_COPY) did. The child gets
// the same per-region permission the parent had, and nothing else: no
// CS_DEBUGGED, no CS_KILL change, no other region. Exec and posix_spawn never
// run vm_map_fork; an unentitled parent's child is copied as today.
// Reveal + validation: Research/KernelCustomFirmwarePatches/patch_fork_inherit_invalid_code.md.

import Foundation
import VPhonePatchKit

extension KernelCustomFirmwarePatcher {
    /// The entitlement a parent must hold for its fork children to inherit
    /// its debug-region association of rewritten code pages. It is Apple's
    /// own debugger key, the one TXM's debugger gate asks for; vphone adds
    /// no entitlement of its own.
    static let forkInheritInvalidCodeEntitlement = "com.apple.private.cs.debugger"

    private static let forkInheritInvalidCodeID = "kernel-exp-frida_fork_inherit_invalid_code"
    private static let threadSetStateEntitlement = "com.apple.private.thread-set-state"
    private static let vmMapForkPanic = "vm_map_fork(%p): attempting to fork from a kernel map @%s:%d"
    private static let vmMapProtectPanic = "vm_map_protect(%p,0x%llx,0x%llx) new=0x%x wired=%x @%s:%d"
    /// Offset of the packed flags word in `struct vm_map_entry` (vm_map_xnu.h:
    /// links, store and the alias/offset qword precede it).
    private static let entryFlagsOffset: Int64 = 0x38

    @discardableResult
    func patchForkInheritInvalidCode() -> Bool {
        log("\n[FRIDA] fork: an entitled parent's debug regions are re-associated in the child")

        guard let fork = functionReferencing(Self.vmMapForkPanic) else {
            log("  [-] vm_map_fork not recovered from its kernel-map panic; failing closed")
            return false
        }
        guard let protect = functionReferencing(Self.vmMapProtectPanic) else {
            log("  [-] vm_map_protect not recovered from its panic; failing closed")
            return false
        }
        guard let assoc = findCsAssociateCall(in: protect) else {
            log("  [-] vm_map_protect: no unique `mov x2, #remap_prot_copy ; bl vm_map_entry_cs_associate`; failing closed")
            return false
        }
        guard let debugBit = debugEntryBit(in: assoc.function) else {
            log("  [-] vm_map_entry_cs_associate: no vme_xnu_user_debug store after the debug-region call; failing closed")
            return false
        }
        guard let site = findForkEntryLink(in: fork) else {
            log("  [-] vm_map_fork: no unique share/fast-copy entry link with a callee-saved old entry; failing closed")
            return false
        }
        guard let hasEntitlement = findIOTaskHasEntitlement() else {
            log("  [-] IOTaskHasEntitlement not recovered from the thread-set-state checks; failing closed")
            return false
        }
        log("  [+] vm_map_fork at 0x\(String(fork, radix: 16)), link hook at 0x\(String(site.call, radix: 16)) (old entry x\(site.oldEntry))")
        log("  [+] vm_map_entry_cs_associate at 0x\(String(assoc.function, radix: 16)) with flags 0x\(String(assoc.flags, radix: 16)), debug bit \(debugBit)")
        log("  [+] IOTaskHasEntitlement at 0x\(String(hasEntitlement, radix: 16))")

        let entitlement = Array(Self.forkInheritInvalidCodeEntitlement.utf8) + [0]
        let caveSize = Self.forkInheritCaveWords * 4 + (entitlement.count + 3) / 4 * 4
        guard let cave = findCodeCave(size: caveSize) else {
            log("  [-] no executable code cave of \(caveSize) bytes")
            return false
        }
        guard let caveData = buildForkInheritCave(
            at: cave,
            link: site.callee,
            oldEntry: site.oldEntry,
            debugBit: debugBit,
            hasEntitlement: hasEntitlement,
            flags: assoc.flags,
            entitlement: entitlement,
        ) else {
            log("  [-] cave assembly or Capstone round-trip failed")
            return false
        }
        guard let hook = ARM64Encoder.encodeBL(from: site.call, to: cave),
              let check = disasm.disassembleOne(hook, at: UInt64(site.call)),
              check.mnemonic == "bl", check.detail?.operands.first?.imm == Int64(cave)
        else {
            log("  [-] cannot encode the branch from vm_map_fork to the cave")
            return false
        }

        emit(
            cave,
            caveData,
            patchID: Self.forkInheritInvalidCodeID + ".cave",
            virtualAddress: fileOffsetToVA(cave),
            description: "fork cave: old entry debug && IOTaskHasEntitlement(NULL, \(Self.forkInheritInvalidCodeEntitlement)) ? link with flags = remap_prot_copy : link [frida]",
        )
        emit(
            site.call,
            hook,
            patchID: Self.forkInheritInvalidCodeID + ".hook",
            virtualAddress: fileOffsetToVA(site.call),
            description: "bl 0x\(String(site.callee, radix: 16)) -> bl cave 0x\(String(cave, radix: 16)) [vm_map_fork entry link, frida]",
        )
        return true
    }

    // MARK: - Semantic matchers

    /// The one function holding every ADRP+ADD reference to `string`.
    private func functionReferencing(_ string: String) -> Int? {
        guard let strOff = buffer.findString(string) else { return nil }
        let starts = Set(findStringRefs(strOff).compactMap { findFunctionStart($0.adrpOff) })
        guard starts.count == 1, let fn = starts.first else { return nil }
        return fn
    }

    private func moveImmediate(_ insn: ARM64Instruction, to rd: ARM64Register) -> Int64? {
        guard insn.mnemonic == "mov" || insn.mnemonic == "movz",
              let o = insn.detail?.operands, o.count == 2,
              o[0].type == .register, o[0].reg == rd, o[1].type == .immediate
        else { return nil }
        // Capstone folds the `lsl #n` of a movz alias into the immediate; a
        // shift it leaves on the operand is applied here.
        return o[1].shift.type == .lsl ? o[1].imm << Int64(o[1].shift.amount) : o[1].imm
    }

    private func moveRegister(_ insn: ARM64Instruction) -> (rd: ARM64Register, rm: ARM64Register)? {
        guard insn.mnemonic == "mov", let o = insn.detail?.operands, o.count == 2,
              o[0].type == .register, o[1].type == .register
        else { return nil }
        return (o[0].reg, o[1].reg)
    }

    /// In vm_map_protect, `vm_map_entry_cs_associate(map, current, flags)` with
    /// flags = VM_MAP_KERNEL_FLAGS_NONE + vmkf_remap_prot_copy: a single-bit
    /// `mov x2, #imm` right before the `bl`, and a callee that tests that bit
    /// of x2 (`tbz/tbnz x2, #n`). Exactly one such call.
    private func findCsAssociateCall(in protect: Int) -> (function: Int, flags: UInt64)? {
        let end = findFuncEnd(protect, maxSize: 0x2000)
        let count = (end - protect) / 4
        let w = disasm.disassemble(in: buffer.data, at: protect, count: count)
        guard w.count == count else { return nil }
        var hits: [(Int, UInt64)] = []
        for i in 1 ..< count where w[i].mnemonic == "bl" {
            guard let imm = moveImmediate(w[i - 1], to: .x(2)), imm > 0,
                  imm & (imm - 1) == 0,
                  let callee = decodeBL(at: protect + i * 4), jbIsInCodeRange(callee)
            else { continue }
            let bit = Int64(UInt64(imm).trailingZeroBitCount)
            let body = disasm.disassemble(in: buffer.data, at: callee, count: 0x100 / 4)
            let testsFlag = body.contains { insn in
                guard insn.mnemonic == "tbz" || insn.mnemonic == "tbnz",
                      let o = insn.detail?.operands, o.count == 3
                else { return false }
                return o[0].reg == .x(2) && o[1].type == .immediate && o[1].imm == bit
            }
            if testsFlag { hits.append((callee, UInt64(imm))) }
        }
        guard Set(hits.map(\.0)).count == 1, let first = hits.first else { return nil }
        return first
    }

    /// The `vme_xnu_user_debug` bit: in vm_map_entry_cs_associate, the
    /// debug-region path stores `ldr wF, [x1, #0x38] ; orr wF, wF, #(1 << b) ;
    /// str wF, [x1, #0x38]` right after the call into the monitor. The first
    /// such single-bit store after a `bl` is that one.
    private func debugEntryBit(in assoc: Int) -> Int? {
        let count = 0x400 / 4
        let w = disasm.disassemble(in: buffer.data, at: assoc, count: count)
        guard w.count == count, let firstCall = w.firstIndex(where: { $0.mnemonic == "bl" }) else { return nil }
        func flagsAccess(_ insn: ARM64Instruction, _ mnemonic: String) -> ARM64Register? {
            guard insn.mnemonic == mnemonic, let o = insn.detail?.operands, o.count == 2,
                  o[0].type == .register, o[1].type == .memory, o[1].mem.base == .x(1),
                  o[1].mem.index == .invalid, Int64(o[1].mem.disp) == Self.entryFlagsOffset
            else { return nil }
            return o[0].reg
        }
        for i in (firstCall + 1) ..< (count - 2) {
            guard let reg = flagsAccess(w[i], "ldr"), w[i + 1].mnemonic == "orr",
                  let o = w[i + 1].detail?.operands, o.count == 3,
                  o[0].reg == reg, o[1].reg == reg, o[2].type == .immediate,
                  o[2].imm > 0, o[2].imm & (o[2].imm - 1) == 0,
                  flagsAccess(w[i + 2], "str") == reg
            else { continue }
            let bit = UInt64(o[2].imm).trailingZeroBitCount
            // The packed word ends at bit 31; the flag is above the protections.
            return bit > 14 && bit < 32 ? bit : nil
        }
        return nil
    }

    /// vm_map_fork's link of a shared or quickly copied entry:
    ///
    ///     mov x0, xMap ; mov x1, xNew ; mov x2, #0 ; mov x3, #0 ; mov x4, #0
    ///     bl  vm_map_store_entry_link
    ///
    /// The old entry is the register R of the inlined vm_map_entry_copy's
    /// "inherit permanent" step: `ldr wA, [R, #0x38] ; and wA, wA, #(1 << 19)`
    /// followed by a store of the merged word to `[xNew, #0x38]`. Two link
    /// sites share the callee; the slow-copy loop links a copy entry, so the
    /// right one is where x1 is the new entry and differs from R. R must be
    /// callee-saved and outside the cave's own x19…x23 (x24…x28).
    private func findForkEntryLink(in fork: Int) -> (call: Int, callee: Int, oldEntry: UInt32)? {
        let end = findFuncEnd(fork, maxSize: 0x2000)
        let count = (end - fork) / 4
        let w = disasm.disassemble(in: buffer.data, at: fork, count: count)
        guard w.count == count else { return nil }
        func ops(_ i: Int) -> [ARM64Operand] { w[i].detail?.operands ?? [] }
        func flagsMem(_ i: Int) -> ARM64Register? {
            guard let m = ops(i).last, m.type == .memory, m.mem.index == .invalid,
                  Int64(m.mem.disp) == Self.entryFlagsOffset
            else { return nil }
            return m.mem.base
        }

        // The inherit-permanent step: old entry R, new entry N.
        var pairs = Set<[UInt32]>()
        for i in 0 ..< max(0, count - 6) where w[i].mnemonic == "ldr" {
            guard let old = flagsMem(i), w[i + 1].mnemonic == "and",
                  ops(i + 1).count == 3, ops(i + 1)[2].type == .immediate, ops(i + 1)[2].imm == 1 << 19,
                  let store = (i + 2 ... i + 5).first(where: { w[$0].mnemonic == "str" && flagsMem($0) != nil }),
                  let new = flagsMem(store), new != old,
                  let rOld = registerNumber(old), let rNew = registerNumber(new)
            else { continue }
            pairs.insert([rOld, rNew])
        }
        guard pairs.count == 1, let pair = pairs.first else { return nil }
        let (oldEntry, newEntry) = (pair[0], pair[1])
        guard (24 ... 28).contains(oldEntry) else { return nil }

        var sites: [(Int, Int)] = []
        for i in 5 ..< count where w[i].mnemonic == "bl" {
            guard let m0 = moveRegister(w[i - 5]), m0.rd == .x(0),
                  let m1 = moveRegister(w[i - 4]), m1.rd == .x(1),
                  registerNumber(m1.rm) == newEntry,
                  moveImmediate(w[i - 3], to: .x(2)) == 0,
                  moveImmediate(w[i - 2], to: .x(3)) == 0,
                  moveImmediate(w[i - 1], to: .x(4)) == 0,
                  let callee = decodeBL(at: fork + i * 4), jbIsInCodeRange(callee)
            else { continue }
            sites.append((fork + i * 4, callee))
        }
        guard sites.count == 1, let site = sites.first else { return nil }
        return (site.0, site.1, oldEntry)
    }

    private func registerNumber(_ reg: ARM64Register) -> UInt32? {
        guard let name = reg.name, name.count > 1, let kind = name.first, "wx".contains(kind),
              let value = UInt32(name.dropFirst()), value < 31
        else { return nil }
        return value
    }

    /// `IOTaskHasEntitlement(task, name)`: the call every reference to the
    /// thread-set-state entitlement string feeds (string in x1, the second
    /// argument). The cave passes a NULL task, which the function resolves to
    /// the current task (iokit/bsddev/IOKitBSDInit.cpp); its entry must show
    /// that: `cbnz x0` then `mrs x0, tpidr_el1`.
    private func findIOTaskHasEntitlement() -> Int? {
        guard let strOff = buffer.findString(Self.threadSetStateEntitlement) else { return nil }
        let refs = findStringRefs(strOff)
        guard !refs.isEmpty else { return nil }
        var targets = Set<Int>()
        for ref in refs {
            guard ARM64Inst.rd(buffer.readU32(at: ref.addOff)) == 1 else { return nil }
            var target: Int?
            for off in stride(from: ref.addOff + 4, through: ref.addOff + 16, by: 4) {
                if let t = decodeBL(at: off) { target = t; break }
            }
            guard let target else { return nil }
            targets.insert(target)
        }
        guard targets.count == 1, let fn = targets.first, fn + 8 * 4 <= buffer.count else { return nil }
        let head = disasm.disassemble(in: buffer.data, at: fn, count: 8)
        guard head.count == 8, head[0].mnemonic == "pacibsp",
              let cbnz = head.firstIndex(where: { $0.mnemonic == "cbnz" && $0.detail?.operands.first?.reg == .x(0) }),
              (cbnz + 1 ..< 8).contains(where: { buffer.readU32(at: fn + $0 * 4) == ARM64.mrs_x0_tpidr_el1 })
        else { return nil }
        return fn
    }

    // MARK: - Cave

    private static let forkInheritCaveWords = 35
    private static let forkInheritCaveShape = [
        "pacibsp", "sub", "stp", "stp", "stp", "str", "mov", "mov", "mov", "mov",
        "mov", "mov", "ldr", "tbz", "mov", "adrp", "add", "bl", "cbz", "mov",
        "mov", "mov", "mov", "mov", "mov", "bl", "ldr", "ldr", "ldr", "ldr",
        "ldr", "ldr", "ldr", "add", "retab",
    ]

    /// The cave vm_map_fork calls in place of
    /// `vm_map_store_entry_link(map, entry, 0, 0, flags = 0)`. The link
    /// associates the entry with the code-signing monitor using `flags`; the
    /// cave changes only that argument:
    ///
    ///       pacibsp
    ///       sub  sp, sp, #0x40
    ///       stp  x29, x30, [sp] ; stp x19, x20, [sp, #0x10] ; stp x21, x22, [sp, #0x20]
    ///       str  x23, [sp, #0x30]
    ///       mov  x29, sp
    ///       mov  x19…x23, x0…x4             ; the link's arguments
    ///       ldr  w8, [xOLD, #0x38]          ; the parent's entry (callee-saved in vm_map_fork)
    ///       tbz  w8, #debug, link           ; not a debug region in the parent
    ///       mov  x0, #0                     ; NULL task: the current (parent) task
    ///       adrp x1, entitlement ; add x1, x1, #lo12
    ///       bl   IOTaskHasEntitlement
    ///       cbz  w0, link
    ///       movz x23, #flags                ; vmkf_remap_prot_copy, as vm_map_protect passes it
    /// link: mov  x0…x4, x19…x23
    ///       bl   vm_map_store_entry_link    ; its result stays in x0
    ///       ldr  x29, x30, x19…x23 from the frame
    ///       add  sp, sp, #0x40
    ///       retab
    ///       <entitlement string, NUL, padded to a word>
    private func buildForkInheritCave(
        at cave: Int,
        link: Int,
        oldEntry: UInt32,
        debugBit: Int,
        hasEntitlement: Int,
        flags: UInt64,
        entitlement: [UInt8],
    ) -> Data? {
        guard (24 ... 28).contains(oldEntry) else { return nil }
        let frame: UInt32 = 0x40
        let strOff = cave + Self.forkInheritCaveWords * 4
        guard let caveVA = fileOffsetToVA(cave), let strVA = fileOffsetToVA(strOff) else { return nil }
        // The flags are one bit; express it as one movz lane.
        guard flags.nonzeroBitCount == 1 else { return nil }
        let bit = flags.trailingZeroBitCount
        let lane = UInt32(bit / 16 * 16)
        let laneValue = UInt16(truncatingIfNeeded: flags >> UInt64(lane))
        func pc(_ i: Int) -> Int { cave + i * 4 }
        let call = 20
        var words: [Data?] = [
            ARM64.pacibsp,
            ARM64Encoder.encodeSubImm12(rd: 31, rn: 31, imm12: frame),
            ARM64Encoder.encodeStpX(rt1: 29, rt2: 30, rn: 31, offset: 0),
            ARM64Encoder.encodeStpX(rt1: 19, rt2: 20, rn: 31, offset: 0x10),
            ARM64Encoder.encodeStpX(rt1: 21, rt2: 22, rn: 31, offset: 0x20),
            ARM64Encoder.encodeStrXUnsignedOffset(rt: 23, rn: 31, offset: 0x30),
            ARM64Encoder.encodeAddImm12(rd: 29, rn: 31, imm12: 0),
        ]
        for k: UInt32 in 0 ... 4 {
            words.append(ARM64Encoder.encodeMovX(rd: 19 + k, rm: k))
        }
        words += [
            ARM64Encoder.encodeLdrWUnsignedOffset(rt: 8, rn: oldEntry, offset: UInt32(Self.entryFlagsOffset)),
            ARM64Encoder.encodeTestBitBranch(nonzero: false, register: 8, bit: UInt32(debugBit), from: pc(13), to: pc(call)),
            ARM64.movX0_0,
            ARM64Encoder.encodeADRP(rd: 1, pc: caveVA + 15 * 4, target: strVA),
            ARM64Encoder.encodeAddImm12(rd: 1, rn: 1, imm12: UInt32(strVA & 0xFFF)),
            ARM64Encoder.encodeBL(from: pc(17), to: hasEntitlement),
            ARM64Encoder.encodeCompareBranch(nonzero: false, register: 0, from: pc(18), to: pc(call)),
            ARM64Encoder.encodeMovzX(rd: 23, imm16: laneValue, shift: lane),
        ]
        for k: UInt32 in 0 ... 4 {
            words.append(ARM64Encoder.encodeMovX(rd: k, rm: 19 + k))
        }
        words.append(ARM64Encoder.encodeBL(from: pc(25), to: link))
        for (rt, offset): (UInt32, UInt32) in [(29, 0), (30, 8), (19, 0x10), (20, 0x18), (21, 0x20), (22, 0x28), (23, 0x30)] {
            words.append(ARM64Encoder.encodeLdrXUnsignedOffset(rt: rt, rn: 31, offset: offset))
        }
        words.append(ARM64Encoder.encodeAddImm12(rd: 31, rn: 31, imm12: frame))
        words.append(ARM64.retab)
        guard words.count == Self.forkInheritCaveWords else { return nil }
        var code = Data()
        for word in words {
            guard let word else { return nil }
            code.append(word)
        }

        // Capstone round-trip: the shape, every branch where it was aimed, the
        // old-entry register, the tested bit and the flags.
        let check = disasm.disassemble(code, at: UInt64(cave), count: Self.forkInheritCaveWords)
        func op(_ i: Int, _ k: Int) -> ARM64Operand? {
            guard i < check.count, let o = check[i].detail?.operands, o.count > k else { return nil }
            return o[k]
        }
        guard check.count == Self.forkInheritCaveWords,
              check.map(\.mnemonic) == Self.forkInheritCaveShape,
              op(12, 1)?.mem.base == .x(Int(oldEntry)),
              op(13, 1)?.imm == Int64(debugBit), op(13, 2)?.imm == Int64(pc(call)),
              op(17, 0)?.imm == Int64(hasEntitlement),
              op(18, 1)?.imm == Int64(pc(call)),
              op(19, 1).map({ $0.shift.type == .lsl ? $0.imm << Int64($0.shift.amount) : $0.imm }) == Int64(bitPattern: flags),
              op(25, 0)?.imm == Int64(link)
        else { return nil }

        // The string's padding must not look like free space: findCodeCave
        // takes any all-zero, all-ones or `udf #0` word, and a later patch's
        // cave would overwrite the terminator (a 36-byte key puts its NUL at the
        // start of a word, which zero padding would leave all zero).
        var data = code
        data.append(contentsOf: entitlement)
        while data.count % 4 != 0 {
            data.append(0xFF)
        }
        for i in stride(from: 0, to: data.count, by: 4) {
            let word = data.loadLE(UInt32.self, at: i)
            guard word != 0, word != 0xFFFF_FFFF, word != 0xD420_0000 else { return nil }
        }
        return data
    }
}
