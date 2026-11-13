// SPTMSecondaryCPUPatcher.swift — SPTM's reset path for a secondary CPU, on a VM.
//
// cloudOS 18's SPTM applies a core tunable when a CPU other than the boot CPU
// comes out of reset. It reads MIDR_EL1, and for part number 0 it loads a
// register base from the CPU's own data and rewrites the top byte of the word
// at offset 0x218 of it (XNU's CORE_THRTL_CFG2, the c1pptThrtlRate field):
//
//     mrs  x6, MIDR_EL1
//     and  x2, x6, #0xfff0
//     cmp  x2, #0
//     b.eq apply            <- the patch: nop
//     b    skip
//   apply:
//     ldr  x2, [x1, #0xc90]
//     movk x3, #0x218
//     ldr  x4, [x2, x3]
//     ...
//     str  x4, [x2, x3]
//   skip:
//     ... msr VBAR_EL1, x0
//
// A Virtualization.framework vCPU reports MIDR_EL1 0x610f0000, part number 0,
// and has no such register: the base is 0. The load from 0x218 takes a
// synchronous external abort before VBAR_EL1 is set, the CPU vectors to 0x200,
// and the instruction abort that follows is one Virtualization.framework does
// not handle, so the whole virtual machine stops ("The virtual machine stopped
// unexpectedly"). Only a secondary CPU takes this path, which is why one vCPU
// boots. cloudOS 26's SPTM has no such block.
//
// The patch turns the `b.eq` into a nop, so every CPU takes the branch that
// skips the tunable. See Research/0_binary_patch_comparison.md.

import Foundation
import VPhonePatchKit

public final class SPTMSecondaryCPUPatcher: BufferedPatcher {
    public static let patchIdentifier = "sptm-boot-secondary_cpu_throttle_tunable"

    public let component = "sptm"
    public let verbose: Bool
    public var gate: VPhonePatchGate = .unrestricted

    let buffer: BinaryBuffer
    let disasm = ARM64Disassembler()
    var patches: [PatchRecord] = []

    public init(data: Data, verbose: Bool = true) {
        buffer = BinaryBuffer(data)
        self.verbose = verbose
    }

    public var patchedData: Data {
        buffer.data
    }

    // MARK: - Patcher

    public func findAll() throws -> [PatchRecord] {
        patches = []
        guard let text = MachOParser.parseSections(from: buffer.original)["__TEXT_EXEC,__text"] else {
            throw PatcherError.invalidFormat("SPTM: no __TEXT_EXEC,__text")
        }
        let start = Int(text.fileOffset)
        let end = start + Int(text.size)
        guard start >= 0, end <= buffer.count, start < end else {
            throw PatcherError.invalidFormat("SPTM: __TEXT_EXEC,__text lies outside the image")
        }
        let code = buffer.original.subdata(in: start ..< end)
        let sites = Self.tunableBranches(in: disasm.disassemble(code, at: text.address))
        guard sites.count <= 1 else {
            throw PatcherError.patchSiteNotFound("SPTM: \(sites.count) secondary CPU tunable branches, expected 1")
        }
        guard let site = sites.first else {
            // An SPTM without the tunable, or one patched before.
            log("  [.] secondary CPU throttle tunable: construct not present — skipping")
            return []
        }
        guard gateAllows(Self.patchIdentifier) else { return [] }

        let offset = start + Int(site - text.address)
        let before = disasm.disassembleOne(in: buffer.original, at: offset, address: site)
        let after = disasm.disassembleOne(ARM64.nop, at: site)
        let record = PatchRecord(
            patchID: Self.patchIdentifier,
            component: component,
            fileOffset: offset,
            virtualAddress: site,
            originalBytes: buffer.readBytes(at: offset, count: ARM64.nop.count),
            patchedBytes: ARM64.nop,
            beforeDisasm: before.map { "\($0.mnemonic) \($0.operandString)" } ?? "???",
            afterDisasm: after.map { "\($0.mnemonic) \($0.operandString)" } ?? "???",
            description: "secondary CPU reset: skip the core throttle tunable no vCPU has",
        )
        patches.append(record)
        if verbose {
            print(String(format: "  0x%06X: %@ → %@  [%@]", offset, record.beforeDisasm, record.afterDisasm, record.patchDescription))
        }
        return patches
    }

    @discardableResult
    public func apply() throws -> Int {
        if patches.isEmpty {
            _ = try findAll()
        }
        for record in patches {
            buffer.writeBytes(at: record.fileOffset, bytes: record.patchedBytes)
        }
        if verbose, !patches.isEmpty {
            print("\n  [\(patches.count) SPTM patches applied]")
        }
        return patches.count
    }

    // MARK: - Site

    /// The addresses of every `b.eq` that guards the tunable: the branch a CPU
    /// whose MIDR_EL1 part number is 0 takes into a block that loads a word
    /// through a register-indexed pointer and stores it back.
    static func tunableBranches(in instructions: [ARM64Instruction]) -> [UInt64] {
        var sites: [UInt64] = []
        guard instructions.count >= 6 else { return sites }
        for index in 0 ..< instructions.count - 5 {
            let read = instructions[index]
            // A system register has no register-operand identity to compare.
            guard read.mnemonic == "mrs", read.operandString.lowercased().hasSuffix("midr_el1"),
                  let identity = read.detail?.operands.first, identity.type == .register
            else { continue }

            let mask = instructions[index + 1]
            guard mask.mnemonic == "and", let maskOperands = mask.detail?.operands, maskOperands.count == 3,
                  maskOperands[0].type == .register,
                  maskOperands[1].type == .register, maskOperands[1].reg == identity.reg,
                  maskOperands[2].type == .immediate, maskOperands[2].imm == 0xFFF0
            else { continue }

            let compare = instructions[index + 2]
            guard compare.mnemonic == "cmp", let compareOperands = compare.detail?.operands, compareOperands.count == 2,
                  compareOperands[0].type == .register, compareOperands[0].reg == maskOperands[0].reg,
                  compareOperands[1].type == .immediate, compareOperands[1].imm == 0
            else { continue }

            let taken = instructions[index + 3]
            let skip = instructions[index + 4]
            guard taken.mnemonic == "b.eq", taken.detail?.conditionCode == .eq,
                  let applyTarget = Self.branchTarget(taken), applyTarget == skip.address + 4,
                  skip.mnemonic == "b", let skipTarget = Self.branchTarget(skip), skipTarget > applyTarget
            else { continue }

            // The block between the two targets reads a word and writes it back
            // through the same base and index registers.
            let block = instructions[(index + 5)...].prefix { $0.address < skipTarget }
            let loads = block.filter { $0.mnemonic == "ldr" }.compactMap(Self.indexedMemory)
            let stores = block.filter { $0.mnemonic == "str" }.compactMap(Self.indexedMemory)
            guard loads.contains(where: stores.contains) else { continue }

            sites.append(taken.address)
        }
        return sites
    }

    private static func branchTarget(_ instruction: ARM64Instruction) -> UInt64? {
        guard let operand = instruction.detail?.operands.first, operand.type == .immediate else { return nil }
        return UInt64(bitPattern: operand.imm)
    }

    /// The memory operand of a load or store addressed by base plus index register.
    private static func indexedMemory(_ instruction: ARM64Instruction) -> ARM64MemoryOperand? {
        guard let operand = instruction.detail?.operands.last, operand.type == .memory,
              operand.mem.base != .invalid, operand.mem.index != .invalid
        else { return nil }
        return operand.mem
    }
}
