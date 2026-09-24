// KernelPatcherBase.swift — Base infrastructure for kernel patching.
//
// Provides Mach-O parsing, ADRP/BL index building, string reference search,
// kext range discovery, and the emit() system.
// Historical note: this file replaces the old Python firmware patcher implementation.

import Capstone
import Foundation

/// Base class for kernel patchers providing shared infrastructure.
open class KernelPatcherBase {
    // MARK: - Properties

    /// Mutable working buffer.
    public let buffer: BinaryBuffer

    /// Verbose logging.
    public let verbose: Bool

    /// Collected patch records.
    public var patches: [PatchRecord] = []

    /// Base virtual address of the kernelcache __TEXT segment.
    public var baseVA: UInt64 = 0

    /// Code ranges (file offset start, end) for scanning.
    public var codeRanges: [(start: Int, end: Int)] = []

    /// All parsed segments.
    public var segments: [MachOSegmentInfo] = []

    /// Parsed sections keyed by "segment,section".
    public var sections: [String: MachOSectionInfo] = [:]

    /// ADRP index: page address → [file offsets of ADRP instructions].
    public var adrpIndex: [UInt64: [Int]] = [:]

    /// BL index: target file offset → [caller file offsets].
    public var blIndex: [Int: [Int]] = [:]

    /// Cached panic function file offset.
    public var panicOffset: Int?

    /// Disassembler instance.
    public let disasm = ARM64Disassembler()

    // MARK: - Init

    public init(data: Data, verbose: Bool = true) {
        buffer = BinaryBuffer(data)
        self.verbose = verbose
    }

    // MARK: - Mach-O Parsing

    /// Parse the Mach-O structure and build indices.
    public func parseMachO() {
        segments = MachOParser.parseSegments(from: buffer.data)
        sections = MachOParser.parseSections(from: buffer.data)

        // Find base VA from __TEXT segment
        if let textSeg = segments.first(where: { $0.name == "__TEXT" }) {
            baseVA = textSeg.vmAddr
        }

        // Build code ranges from __TEXT_EXEC or __TEXT,__text
        if let textExec = segments.first(where: { $0.name == "__TEXT_EXEC" }) {
            codeRanges.append((Int(textExec.fileOffset), Int(textExec.fileOffset + textExec.fileSize)))
        } else if let textText = sections["__TEXT,__text"] {
            codeRanges.append((Int(textText.fileOffset), Int(textText.fileOffset) + Int(textText.size)))
        }
    }

    // MARK: - Emit System

    /// Record a patch at the given file offset.
    public func emit(
        _ offset: Int,
        _ patchBytes: Data,
        patchID: String,
        virtualAddress: UInt64? = nil,
        description: String,
    ) {
        let originalBytes = buffer.readBytes(at: offset, count: patchBytes.count)

        // Disassemble before/after
        let beforeInsn = disasm.disassembleOne(in: buffer.original, at: offset)
        let afterInsn = disasm.disassembleOne(patchBytes, at: UInt64(offset))

        let beforeStr = beforeInsn.map { "\($0.mnemonic) \($0.operandString)" } ?? "???"
        let afterStr = afterInsn.map { "\($0.mnemonic) \($0.operandString)" } ?? "???"

        let record = PatchRecord(
            patchID: patchID,
            component: "kernelcache",
            fileOffset: offset,
            virtualAddress: virtualAddress,
            originalBytes: originalBytes,
            patchedBytes: patchBytes,
            beforeDisasm: beforeStr,
            afterDisasm: afterStr,
            description: description,
        )

        patches.append(record)

        // Write through to buffer.data so findCodeCave() sees previously
        // allocated shellcode and won't reuse the same cave region.
        buffer.writeBytes(at: offset, bytes: patchBytes)

        if verbose {
            print("  0x\(String(format: "%06X", offset)): \(beforeStr) → \(afterStr)  [\(description)]")
        }
    }

    /// Number of collected patches. `emit()` already wrote every record through to
    /// `buffer.data`, so there is nothing left to apply here.
    public func applyPatches() -> Int {
        patches.count
    }

    // MARK: - Index Building

    /// Build ADRP index for O(1) page-address lookups.
    public func buildADRPIndex() {
        adrpIndex = [:]
        for (start, end) in codeRanges {
            var offset = start
            while offset + 4 <= end {
                let insn = buffer.readU32(at: offset)
                // ADRP: [31]=1, [28:24]=10000
                if ARM64Inst.isADRP(insn) {
                    // Decode page address
                    let immhi = (insn >> 5) & 0x7FFFF
                    let immlo = (insn >> 29) & 0x3
                    let imm21 = (immhi << 2) | immlo
                    // Sign-extend
                    let signedImm = Int64(Int32(bitPattern: imm21 << 11) >> 11)
                    let pageAddr = (UInt64(offset) & ~0xFFF) &+ UInt64(bitPattern: signedImm << 12)

                    adrpIndex[pageAddr, default: []].append(offset)
                }
                offset += 4
            }
        }
    }

    /// Build BL index for target-to-callers mapping.
    public func buildBLIndex() {
        blIndex = [:]
        for (start, end) in codeRanges {
            var offset = start
            while offset + 4 <= end {
                if let target = decodeBL(at: offset) {
                    blIndex[target, default: []].append(offset)
                }
                offset += 4
            }
        }
    }

    // MARK: - String Reference Search

    /// Find all ADRP+ADD references to a string at the given file offset.
    public func findStringRefs(_ stringOffset: Int) -> [(adrpOff: Int, addOff: Int)] {
        let targetPage = UInt64(stringOffset) & ~0xFFF
        let pageOff = UInt64(stringOffset) & 0xFFF

        guard let adrpOffsets = adrpIndex[targetPage] else { return [] }

        var refs: [(Int, Int)] = []
        for adrpOff in adrpOffsets {
            // Check the next few instructions for ADD with matching page offset
            for delta in stride(from: 4, through: 32, by: 4) {
                let addCandOff = adrpOff + delta
                guard addCandOff + 4 <= buffer.count else { break }
                let addInsn = buffer.readU32(at: addCandOff)
                // ADD immediate: [31]=1, [30:29]=00, [28:24]=10001
                guard addInsn & 0xFF80_0000 == 0x9100_0000 else { continue }
                let imm12 = (addInsn >> 10) & 0xFFF
                let adrpInsn = buffer.readU32(at: adrpOff)
                let adrpRd = adrpInsn & 0x1F
                let addRn = (addInsn >> 5) & 0x1F
                guard adrpRd == addRn, imm12 == UInt32(pageOff) else { continue }
                refs.append((adrpOff, addCandOff))
                break
            }
        }
        return refs
    }

    /// Find all ADRP+ADD references to a string at the given file offset,
    /// filtered to a code range (start inclusive, end exclusive).
    public func findStringRefs(_ stringOffset: Int, in range: (start: Int, end: Int)) -> [(adrpOff: Int, addOff: Int)] {
        findStringRefs(stringOffset).filter { $0.adrpOff >= range.start && $0.adrpOff < range.end }
    }

    /// Convenience: find a string then return ranged ADRP+ADD refs.
    /// Returns empty if the string is not found or has no refs in range.
    public func findStringRefs(in range: (start: Int, end: Int), string: String) -> [(adrpOff: Int, addOff: Int)] {
        guard let strOff = buffer.findString(string) else { return [] }
        return findStringRefs(strOff, in: range)
    }

    // MARK: - Branch Helpers

    /// Decode the BL at `offset` and return its target as a file offset,
    /// or nil when the instruction there is not a BL.
    ///
    /// BL encoding: [31:26] = 0b100101, imm26 is PC-relative in 4-byte units.
    public func decodeBL(at offset: Int) -> Int? {
        guard offset >= 0, offset + 4 <= buffer.count else { return nil }
        let insn = buffer.readU32(at: offset)
        guard ARM64Inst.isBL(insn) else { return nil }
        let imm26 = insn & 0x03FF_FFFF
        let signedImm = Int32(bitPattern: imm26 << 6) >> 6
        return offset + Int(signedImm) * 4
    }

    /// Check whether the instruction at `offset` is a BL targeting `target` (file offset).
    /// Returns true if the BL opcode decodes to the exact target offset.
    public func isBL(at offset: Int, target: Int) -> Bool {
        decodeBL(at: offset) == target
    }

    // MARK: - Conditional Branch Helpers

    /// Set of conditional branch mnemonics that may gate a panic path.
    static let conditionalBranchMnemonics: Set<String> = [
        "b.eq", "b.ne", "b.cs", "b.hs", "b.cc", "b.lo", "b.mi", "b.pl",
        "b.vs", "b.vc", "b.hi", "b.ls", "b.ge", "b.lt", "b.gt", "b.le", "b.al",
        "cbz", "cbnz", "tbz", "tbnz",
    ]

    /// Decode a conditional branch instruction, returning its target as a file offset.
    /// Returns nil if the instruction is not a conditional branch.
    public func conditionalBranchTarget(insn: Instruction) -> Int? {
        guard KernelPatcherBase.conditionalBranchMnemonics.contains(insn.mnemonic) else { return nil }
        // Target is always the last IMM operand.
        guard let detail = insn.aarch64 else { return nil }
        for op in detail.operands.reversed() {
            if op.type == AARCH64_OP_IMM {
                return Int(op.imm)
            }
        }
        return nil
    }

    // MARK: - Panic Discovery

    /// Find _panic: the most-called function whose callers reference '@%s:%d' strings.
    /// Populates `panicOffset`.
    public func findPanic() {
        // Sort targets by call-site count, descending.
        let sorted = blIndex.sorted { $0.value.count > $1.value.count }

        for (targetOff, callers) in sorted.prefix(15) {
            guard callers.count >= 2000 else { break }
            var confirmed = 0
            for callerOff in callers.prefix(30) {
                // Look back up to 8 instructions for ADRP x0 + ADD x0 pattern
                // pointing at a string containing "@%s:%d".
                var back = callerOff - 4
                while back >= max(callerOff - 32, 0) {
                    let addInsn = buffer.readU32(at: back)
                    // ADD x0, x0, #imm  — [31:22]=1001000100, [9:5]=x0, [4:0]=x0
                    if (addInsn & 0xFFC0_03E0) == 0x9100_0000 {
                        let addImm = Int((addInsn >> 10) & 0xFFF)
                        if back >= 4 {
                            let adrpInsn = buffer.readU32(at: back - 4)
                            // ADRP x0: [31:24]=10010000, [4:0]=0 (x0)
                            if (adrpInsn & 0x9F00_001F) == 0x9000_0000 {
                                let immhi = (adrpInsn >> 5) & 0x7FFFF
                                let immlo = (adrpInsn >> 29) & 0x3
                                var imm = Int((immhi << 2) | immlo)
                                if imm & (1 << 20) != 0 {
                                    imm -= 1 << 21
                                }
                                let pageDelta = imm << 12
                                let pcPage = (back - 4) & ~0xFFF
                                let strFoff = pcPage + pageDelta + addImm
                                if strFoff >= 0, strFoff + 60 < buffer.count {
                                    let snippet = buffer.data[strFoff ..< strFoff + 60]
                                    if snippet.range(of: Data("@%s:%d".utf8)) != nil ||
                                        snippet.range(of: Data("%s:%d".utf8)) != nil
                                    {
                                        confirmed += 1
                                        break
                                    }
                                }
                            }
                        }
                        break
                    }
                    back -= 4
                }
                if confirmed >= 3 {
                    break
                }
            }
            if confirmed >= 3 {
                panicOffset = targetOff
                if verbose {
                    print(String(format: "  [*] _panic at foff 0x%X (%d callers)", targetOff, callers.count))
                }
                return
            }
        }

        // Fallback: use the 3rd most-called target (index 2), like Python.
        if sorted.count > 2 {
            panicOffset = sorted[2].key
        } else if let first = sorted.first {
            panicOffset = first.key
        }
        if let p = panicOffset {
            if verbose {
                print(String(format: "  [*] _panic (fallback) at foff 0x%X", p))
            }
        }
    }

    // MARK: - Function Discovery

    /// Find the start of the function containing the instruction at `offset`.
    /// Scans backward for PACIBSP or STP x29, x30, [sp, ...].
    public func findFunctionStart(_ offset: Int, maxBack: Int = 0x4000) -> Int? {
        let stop = max(0, offset - maxBack)
        var scan = offset - 4
        scan &= ~3
        while scan > stop {
            let insn = buffer.readU32(at: scan)
            if insn == ARM64.pacibspU32 {
                return scan
            }
            // STP x29, x30, [sp, #imm]  (common prologue)
            // Encoding: 1x101001xx011101_11110xxxxxxxxxxx
            if insn & 0x7FC0_7FFF == 0x2900_7BFD {
                // Check further back for PACIBSP (prologue may have
                // multiple STP instructions before x29,x30)
                let innerStop = max(0, scan - 0x24)
                var k = scan - 4
                while k > innerStop {
                    if buffer.readU32(at: k) == ARM64.pacibspU32 {
                        return k
                    }
                    k -= 4
                }
                return scan
            }
            scan -= 4
        }
        return nil
    }

    // MARK: - VA/Offset Conversion

    /// Convert file offset to virtual address.
    public func fileOffsetToVA(_ offset: Int) -> UInt64? {
        for seg in segments {
            let segStart = Int(seg.fileOffset)
            let segEnd = segStart + Int(seg.fileSize)
            if offset >= segStart, offset < segEnd {
                return seg.vmAddr + UInt64(offset - segStart)
            }
        }
        return nil
    }

    /// Convert virtual address to file offset.
    public func vaToFileOffset(_ va: UInt64) -> Int? {
        MachOParser.vaToFileOffset(va, segments: segments)
    }

    // MARK: - Kext Range Discovery

    /// File-offset range (start, end) of the AMFI kext's __TEXT_EXEC.__text section.
    ///
    /// Discovered from __PRELINK_INFO. Falls back to the full kernel code range.
    public func amfiTextRange() -> (start: Int, end: Int) {
        kextTextRange(bundleID: "com.apple.driver.AppleMobileFileIntegrity")
    }

    /// File-offset range (start, end) of the Sandbox kext's __TEXT_EXEC.__text section.
    ///
    /// Discovered from __PRELINK_INFO. Falls back to the full kernel code range.
    public func sandboxTextRange() -> (start: Int, end: Int) {
        kextTextRange(bundleID: "com.apple.security.sandbox")
    }

    /// File-offset range (start, end) of the APFS kext's __TEXT_EXEC.__text section.
    ///
    /// Discovered from __PRELINK_INFO. Falls back to the full kernel code range.
    public func apfsTextRange() -> (start: Int, end: Int) {
        kextTextRange(bundleID: "com.apple.filesystems.apfs")
    }

    /// Generic kext text range lookup by bundle identifier.
    ///
    /// Parses __PRELINK_INFO to find the kext's load address, then reads its
    /// embedded Mach-O to extract the __TEXT_EXEC.__text section range.
    /// Falls back to the full kernel code range on any failure.
    public func kextTextRange(bundleID: String) -> (start: Int, end: Int) {
        guard let prelinkSeg = segments.first(where: { $0.name == "__PRELINK_INFO" }),
              prelinkSeg.fileSize > 0
        else {
            return codeRanges.first ?? (0, buffer.count)
        }

        let pFoff = Int(prelinkSeg.fileOffset)
        let pEnd = min(pFoff + Int(prelinkSeg.fileSize), buffer.count)
        let prelinkSlice = buffer.data[pFoff ..< pEnd]

        guard let xmlStart = prelinkSlice.range(of: Data("<?xml".utf8)),
              let plistEnd = prelinkSlice.range(of: Data("</plist>".utf8))
        else {
            return codeRanges.first ?? (0, buffer.count)
        }

        let xmlData = prelinkSlice[xmlStart.lowerBound ..< plistEnd.upperBound]
        guard let plist = try? PropertyListSerialization.propertyList(from: xmlData, format: nil),
              let dict = plist as? [String: Any],
              let items = dict["_PrelinkInfoDictionary"] as? [[String: Any]]
        else {
            return codeRanges.first ?? (0, buffer.count)
        }

        for item in items {
            guard let bid = item["CFBundleIdentifier"] as? String,
                  bid == bundleID,
                  let execAddrAny = item["_PrelinkExecutableLoadAddr"]
            else { continue }

            var execAddr: UInt64 = 0
            if let n = execAddrAny as? UInt64 {
                execAddr = n
            } else if let n = execAddrAny as? Int {
                execAddr = UInt64(bitPattern: Int64(n))
            } else if let n = execAddrAny as? NSNumber {
                execAddr = n.uint64Value
            }
            execAddr &= 0xFFFF_FFFF_FFFF_FFFF
            guard execAddr > baseVA else { continue }
            let kextFoff = Int(execAddr - baseVA)
            guard kextFoff >= 0, kextFoff < buffer.count else { continue }

            if let range = parseKextTextExecRange(at: kextFoff) {
                return range
            }
        }

        return codeRanges.first ?? (0, buffer.count)
    }

    /// Parse an embedded kext Mach-O at `kextFoff` and return its __TEXT_EXEC.__text range.
    public func parseKextTextExecRange(at kextFoff: Int) -> (start: Int, end: Int)? {
        guard kextFoff + 32 <= buffer.count else { return nil }
        let magic = buffer.data.loadLE(UInt32.self, at: kextFoff)
        guard magic == 0xFEED_FACF else { return nil }

        let ncmds = buffer.data.loadLE(UInt32.self, at: kextFoff + 16)
        var off = kextFoff + 32

        for _ in 0 ..< ncmds {
            guard off + 8 <= buffer.count else { break }
            let cmd = buffer.data.loadLE(UInt32.self, at: off)
            let cmdsize = buffer.data.loadLE(UInt32.self, at: off + 4)

            if cmd == 0x19 { // LC_SEGMENT_64
                let nameBytes = buffer.data[off + 8 ..< off + 24]
                let segName = String(data: nameBytes, encoding: .utf8)?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""

                if segName == "__TEXT_EXEC" {
                    let vmAddr = buffer.data.loadLE(UInt64.self, at: off + 24)
                    let fileSize = buffer.data.loadLE(UInt64.self, at: off + 48)
                    let nsects = buffer.data.loadLE(UInt32.self, at: off + 64)

                    var sectOff = off + 72
                    for _ in 0 ..< nsects {
                        guard sectOff + 80 <= buffer.count else { break }
                        let sectNameBytes = buffer.data[sectOff ..< sectOff + 16]
                        let sectName = String(data: sectNameBytes, encoding: .utf8)?
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""

                        if sectName == "__text" {
                            let sectAddr = buffer.data.loadLE(UInt64.self, at: sectOff + 32)
                            let sectSize = buffer.data.loadLE(UInt64.self, at: sectOff + 40)
                            guard sectAddr >= baseVA else { break }
                            let sectFoff = Int(sectAddr - baseVA)
                            return (sectFoff, sectFoff + Int(sectSize))
                        }
                        sectOff += 80
                    }
                    // Fallback: use the full segment.
                    guard vmAddr >= baseVA else { break }
                    let segFoff = Int(vmAddr - baseVA)
                    return (segFoff, segFoff + Int(fileSize))
                }
            }
            off += Int(cmdsize)
        }
        return nil
    }
}
