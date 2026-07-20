// AVPBooterPatcher.swift — AVPBooter DGST bypass patcher.
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.
//
// Strategy:
//   1. Disassemble the entire binary.
//   2. Find the first instruction that references the DGST marker constant
//      (0x4447 appears as a 16-bit immediate in a MOVZ/MOVK encoding of 0x44475354).
//   3. Scan forward (up to 512 instructions) for the nearest RET/RETAA/RETAB.
//   4. Scan backward from RET (up to 32 instructions) for the last `mov x0, ...`
//      or conditional-select instruction writing x0/w0.
//   5. Patch that instruction to `mov x0, #0`.

import Foundation

/// Patcher for AVPBooter DGST bypass.
public final class AVPBooterPatcher: Patcher {
    public let component = "avpbooter"
    public let verbose: Bool

    let buffer: BinaryBuffer
    let disasm = ARM64Disassembler()
    var patches: [PatchRecord] = []

    // MARK: - Constants

    /// The hex string fragment Capstone emits when an instruction encodes 0x4447
    /// (lower half of "DGST" / 0x44475354 little-endian).
    private static let dgstSearch = "0x4447"

    /// Mnemonics that write to x0/w0 via conditional selection.
    private static let cselMnemonics: Set<String> = ["cset", "csinc", "csinv", "csneg"]

    /// Mnemonics that terminate a scan region (branch or return).
    private static let stopMnemonics: Set<String> = ["ret", "retaa", "retab", "b", "bl", "br", "blr"]

    public init(data: Data, verbose: Bool = true) {
        buffer = BinaryBuffer(data)
        self.verbose = verbose
    }

    // MARK: - Patcher

    public func findAll() throws -> [PatchRecord] {
        patches = []
        try patchDGSTBypass()
        return patches
    }

    @discardableResult
    public func apply() throws -> Int {
        if patches.isEmpty {
            let _ = try findAll()
        }
        for record in patches {
            buffer.writeBytes(at: record.fileOffset, bytes: record.patchedBytes)
        }
        if verbose, !patches.isEmpty {
            print("\n  [\(patches.count) AVPBooter patch(es) applied]")
        }
        return patches.count
    }

    public var patchedData: Data {
        buffer.data
    }

    // MARK: - DGST Bypass

    private func patchDGSTBypass() throws {
        // Disassemble entire binary (raw ARM64, base address 0).
        let insns = disasm.disassemble(buffer.data, at: 0)
        guard !insns.isEmpty else {
            throw PatcherError.invalidFormat("AVPBooter: disassembly produced no instructions")
        }

        // Step 1 — locate the first movz/movk instruction that loads the DGST constant.
        // Only match immediate-loading mnemonics to avoid false positives from branch
        // targets whose address happens to contain "4447" (e.g. `bl #0x4447c`).
        guard let hitIdx = insns.firstIndex(where: { insn in
            let mn = insn.mnemonic
            guard mn == "movz" || mn == "movk" || mn == "mov" else { return false }
            return insn.operandString.contains(Self.dgstSearch)
        }) else {
            throw PatcherError.patchSiteNotFound("AVPBooter DGST: constant 0x4447 not found in binary")
        }

        // Step 2 — scan forward up to 512 instructions for a RET epilogue.
        let scanEnd = min(hitIdx + 512, insns.count)
        guard let retIdx = insns[hitIdx ..< scanEnd].firstIndex(where: { insn in
            insn.mnemonic == "ret" || insn.mnemonic == "retaa" || insn.mnemonic == "retab"
        }) else {
            throw PatcherError.patchSiteNotFound("AVPBooter DGST: epilogue RET not found within 512 instructions")
        }

        // Step 3 — scan backward from RET (up to 32 instructions) for x0/w0 setter.
        let backStart = max(retIdx - 32, 0)
        var x0Idx: Int? = nil

        // Iterate backward: from retIdx-1 down to backStart.
        var i = retIdx - 1
        while i >= backStart {
            let insn = insns[i]
            let mn = insn.mnemonic
            let op = insn.operandString

            if mn == "mov", op.hasPrefix("x0,") || op.hasPrefix("w0,") {
                x0Idx = i
                break
            }
            if Self.cselMnemonics.contains(mn), op.hasPrefix("x0,") || op.hasPrefix("w0,") {
                x0Idx = i
                break
            }
            // Stop if we cross a function boundary or unconditional branch.
            if Self.stopMnemonics.contains(mn) {
                break
            }
            i -= 1
        }

        guard let targetIdx = x0Idx else {
            throw PatcherError.patchSiteNotFound("AVPBooter DGST: x0 setter not found before RET")
        }

        let target = insns[targetIdx]
        let fileOff = Int(target.address) // base address is 0, so VA == file offset

        let originalBytes = buffer.readBytes(at: fileOff, count: 4)
        let patchedBytes = ARM64.movX0_0

        let beforeStr = "\(target.mnemonic) \(target.operandString)"
        let afterInsn = disasm.disassembleOne(patchedBytes, at: UInt64(fileOff))
        let afterStr = afterInsn.map { "\($0.mnemonic) \($0.operandString)" } ?? "mov x0, #0"

        let record = PatchRecord(
            patchID: "avpbooter.dgst_bypass",
            component: component,
            fileOffset: fileOff,
            virtualAddress: nil,
            originalBytes: originalBytes,
            patchedBytes: patchedBytes,
            beforeDisasm: beforeStr,
            afterDisasm: afterStr,
            description: "DGST validation bypass: force x0=0 return value"
        )
        patches.append(record)

        if verbose {
            print(String(format: "  0x%06X: %@ → %@  [avpbooter.dgst_bypass]",
                         fileOff, beforeStr, afterStr))
        }
    }
}
