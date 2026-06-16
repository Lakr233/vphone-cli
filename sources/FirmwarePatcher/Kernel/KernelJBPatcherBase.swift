// KernelJBPatcherBase.swift — JB kernel patcher base with extended infrastructure.
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.

import Capstone
import Foundation

/// Base class for JB kernel patching, extending KernelPatcherBase with:
/// - Symbol table parsing (nlist64 from LC_SYMTAB + fileset entries)
/// - Code cave finder (zeros/0xFF/UDF in executable segments)
/// - Branch encoding helpers (encodeB, encodeBL)
/// - Function boundary finders (findFuncEnd, findBLToPanicInRange)
/// - String-anchored function finders
/// - proc_info anchor cache
public class KernelJBPatcherBase: KernelPatcherBase {
    /// Symbol name → file offset map, built from nlist64 entries.
    var symbols: [String: Int] = [:]

    /// Cached _proc_security_policy file offset (-1 = scanned, not found).
    private var procSecurityPolicyOff: Int?

    /// JB scan cache for expensive searches.
    var jbScanCache: [String: Int] = [:]

    // MARK: - Symbol Table

    /// Build symbol table from LC_SYMTAB in the main Mach-O header AND all
    /// LC_FILESET_ENTRY sub-Mach-Os.
    ///
    /// Reads from `buffer.original` (Python: `self.raw`) so the table reflects
    /// unpatched data. Populates `self.symbols` with name → file offset.
    func buildSymbolTable() {
        symbols = [:]
        let raw = buffer.original
        guard raw.count > 32 else { return }

        let ncmds = raw.loadLE(UInt32.self, at: 16)

        // Pass 1: top-level LC_SYMTAB
        var tempOff = 32
        for _ in 0 ..< ncmds {
            guard tempOff + 8 <= raw.count else { break }
            let cmd = raw.loadLE(UInt32.self, at: tempOff)
            let cmdsize = raw.loadLE(UInt32.self, at: tempOff + 4)
            guard cmdsize >= 8 else { break }
            if cmd == 0x2, tempOff + 20 <= raw.count { // LC_SYMTAB
                let symoff = raw.loadLE(UInt32.self, at: tempOff + 8)
                let nsyms = raw.loadLE(UInt32.self, at: tempOff + 12)
                let stroff = raw.loadLE(UInt32.self, at: tempOff + 16)
                parseNlist(symoff: Int(symoff), nsyms: Int(nsyms), stroff: Int(stroff))
            }
            tempOff += Int(cmdsize)
        }

        // Pass 2: LC_FILESET_ENTRY sub-Mach-Os
        tempOff = 32
        for _ in 0 ..< ncmds {
            guard tempOff + 8 <= raw.count else { break }
            let cmd = raw.loadLE(UInt32.self, at: tempOff)
            let cmdsize = raw.loadLE(UInt32.self, at: tempOff + 4)
            guard cmdsize >= 8 else { break }
            if cmd == 0x8000_0035, tempOff + 24 <= raw.count { // LC_FILESET_ENTRY: fileoff at +16 (u64)
                let foffEntry = raw.loadLE(UInt64.self, at: tempOff + 16)
                parseFilesetSymtab(mhOff: Int(foffEntry))
            }
            tempOff += Int(cmdsize)
        }

        if verbose { print("[*] Symbol table: \(symbols.count) symbols resolved") }
    }

    /// Parse LC_SYMTAB from a fileset entry Mach-O whose header starts at `mhOff`.
    /// Reads from `buffer.original`. Mirrors Python `_parse_fileset_symtab(mh_off)`.
    private func parseFilesetSymtab(mhOff: Int) {
        let raw = buffer.original
        guard mhOff >= 0, mhOff + 32 <= raw.count else { return }
        let magic = raw.loadLE(UInt32.self, at: mhOff)
        guard magic == 0xFEED_FACF else { return }
        let ncmds = raw.loadLE(UInt32.self, at: mhOff + 16)
        var off = mhOff + 32
        for _ in 0 ..< ncmds {
            guard off + 8 <= raw.count else { break }
            let cmd = raw.loadLE(UInt32.self, at: off)
            let cmdsize = raw.loadLE(UInt32.self, at: off + 4)
            guard cmdsize >= 8 else { break }
            if cmd == 0x2, off + 20 <= raw.count { // LC_SYMTAB
                let symoff = raw.loadLE(UInt32.self, at: off + 8)
                let nsyms = raw.loadLE(UInt32.self, at: off + 12)
                let stroff = raw.loadLE(UInt32.self, at: off + 16)
                parseNlist(symoff: Int(symoff), nsyms: Int(nsyms), stroff: Int(stroff))
            }
            off += Int(cmdsize)
        }
    }

    /// Parse nlist64 entries: add defined function symbols (n_type & 0x0E == 0x0E) to `symbols`.
    /// Reads from `buffer.original` (Python: `self.raw`). Mirrors Python `_parse_nlist`.
    private func parseNlist(symoff: Int, nsyms: Int, stroff: Int) {
        let raw = buffer.original
        let size = raw.count
        for i in 0 ..< nsyms {
            let entryOff = symoff + i * 16 // sizeof(nlist_64) == 16
            guard entryOff + 16 <= size else { break }
            // nlist_64: n_strx(u32) n_type(u8) n_sect(u8) n_desc(u16) n_value(u64)
            let nStrx = raw.loadLE(UInt32.self, at: entryOff)
            let nType = raw.loadLE(UInt8.self, at: entryOff + 4)
            let nValue = raw.loadLE(UInt64.self, at: entryOff + 8)
            // n_type & 0x0E == 0x0E selects N_SECT | N_EXT (defined external symbols)
            guard nType & 0x0E == 0x0E, nValue != 0 else { continue }
            let nameOff = stroff + Int(nStrx)
            guard nameOff < size else { continue }
            var nameEnd = nameOff
            while nameEnd < size, nameEnd - nameOff < 512 {
                if raw[nameEnd] == 0 { break }
                nameEnd += 1
            }
            guard nameEnd > nameOff else { continue }
            guard let name = String(data: raw[nameOff ..< nameEnd], encoding: .ascii) else { continue }
            // foff = n_value - base_va
            let foff = Int(Int64(bitPattern: nValue) - Int64(bitPattern: baseVA))
            if foff >= 0, foff < size { symbols[name] = foff }
        }
    }

    /// Look up a function symbol, return file offset or nil.
    func resolveSymbol(_ name: String) -> Int? {
        symbols[name]
    }

    // MARK: - Code Cave

    /// Find a region of zeros/0xFF/UDF in executable memory for shellcode.
    /// Only searches __TEXT_EXEC and __TEXT_BOOT_EXEC segments.
    /// Reads from buffer.data (mutable) so previously allocated caves are skipped.
    func findCodeCave(size: Int, align: Int = 4) -> Int? {
        let execSegNames: Set = ["__TEXT_EXEC", "__TEXT_BOOT_EXEC"]
        // Collect exec segment ranges from parsed segments
        var execRanges: [(start: Int, end: Int)] = []
        for seg in segments {
            guard execSegNames.contains(seg.name), seg.fileSize > 0 else { continue }
            execRanges.append((Int(seg.fileOffset), Int(seg.fileOffset + seg.fileSize)))
        }
        // Fall back to codeRanges if no explicit exec segment found
        if execRanges.isEmpty {
            execRanges = codeRanges
        }
        execRanges.sort { $0.start < $1.start }

        let needed = (size + align - 1) / align * align

        for (rngStart, rngEnd) in execRanges {
            var runStart = -1
            var runLen = 0
            var off = rngStart
            while off + 4 <= rngEnd {
                let val = buffer.readU32(at: off)
                // Accept zeros, 0xFFFFFFFF, or UDF (0xD4200000)
                if val == 0x0000_0000 || val == 0xFFFF_FFFF || val == 0xD420_0000 {
                    if runStart < 0 {
                        runStart = off
                        runLen = 4
                    } else {
                        runLen += 4
                    }
                    if runLen >= needed {
                        return runStart
                    }
                } else {
                    runStart = -1
                    runLen = 0
                }
                off += 4
            }
        }
        return nil
    }

    // MARK: - Branch Encoding

    /// Encode an unconditional B instruction.
    func encodeB(from fromOff: Int, to toOff: Int) -> Data? {
        ARM64Encoder.encodeB(from: fromOff, to: toOff)
    }

    /// Encode a BL instruction.
    func encodeBL(from fromOff: Int, to toOff: Int) -> Data? {
        ARM64Encoder.encodeBL(from: fromOff, to: toOff)
    }

    // MARK: - Function Finders

    /// Find the end of a function by scanning forward for the next PACIBSP boundary.
    ///
    /// Reads from `buffer.original` (Python: `_rd32(self.raw, off)`).
    /// Mirrors Python `_find_func_end(func_start, max_size)`.
    func findFuncEnd(_ funcStart: Int, maxSize: Int = 0x4000) -> Int {
        let raw = buffer.original
        let limit = min(funcStart + maxSize, raw.count)
        var off = funcStart + 4
        while off + 4 <= limit {
            let insn = raw.loadLE(UInt32.self, at: off)
            if insn == ARM64.pacibspU32 { return off }
            off += 4
        }
        return limit
    }

    /// Find the first BL to `_panic` in `range`. Returns the file offset or nil.
    ///
    /// Reads from `buffer.original` (Python: `_rd32(self.raw, off)` via `_is_bl`).
    /// Mirrors Python `_find_bl_to_panic_in_range(start, end)`.
    func findBLToPanic(in range: Range<Int>) -> Int? {
        guard let panicOff = panicOffset else { return nil }
        let raw = buffer.original
        var off = range.lowerBound
        while off + 4 <= range.upperBound {
            guard off + 4 <= raw.count else { break }
            let insn = raw.loadLE(UInt32.self, at: off)
            if insn >> 26 == 0b100101 { // BL
                let imm26 = insn & 0x03FF_FFFF
                let signedImm = Int32(bitPattern: imm26 << 6) >> 6
                if off + Int(signedImm) * 4 == panicOff { return off }
            }
            off += 4
        }
        return nil
    }

    /// Find a function that references a given string constant.
    /// Returns the function-start file offset, or nil.
    /// Mirrors Python `_find_func_by_string(string, code_range)`.
    func findFuncByString(_ string: String, codeRange: (Int, Int)? = nil) -> Int? {
        guard let strOff = buffer.findString(string) else { return nil }
        let refs: [(adrpOff: Int, addOff: Int)] = if let (cs, ce) = codeRange {
            findStringRefs(strOff, in: (start: cs, end: ce))
        } else {
            findStringRefs(strOff)
        }
        guard let firstRef = refs.first else { return nil }
        return findFunctionStart(firstRef.adrpOff)
    }

    /// Find a function containing a string reference.
    /// Returns (funcStart, funcEnd, refs) or nil.
    /// Mirrors Python `_find_func_containing_string(string, code_range)`.
    func findFuncContainingString(
        _ string: String,
        codeRange: (Int, Int)? = nil
    ) -> (Int, Int, [(adrpOff: Int, addOff: Int)])? {
        guard let strOff = buffer.findString(string) else { return nil }
        let refs: [(adrpOff: Int, addOff: Int)] = if let (cs, ce) = codeRange {
            findStringRefs(strOff, in: (start: cs, end: ce))
        } else {
            findStringRefs(strOff)
        }
        guard let firstRef = refs.first else { return nil }
        guard let funcStart = findFunctionStart(firstRef.adrpOff) else { return nil }
        let funcEnd = findFuncEnd(funcStart)
        return (funcStart, funcEnd, refs)
    }

    // MARK: - proc_info Family Anchors (B6/B7)

    /// Find `_proc_security_policy` by its unique reference to `PRIV_GLOBAL_PROC_INFO`.
    ///
    /// Source: `bsd/kern/proc_info.c` — `proc_security_policy()` is the shared
    /// proc-info authorization gate. Its only distinctive constant is the privilege
    /// id passed to `priv_check_cred(my_cred, PRIV_GLOBAL_PROC_INFO, 0)`.
    /// `PRIV_GLOBAL_PROC_INFO` is `1002` (`0x3EA`) in `bsd/sys/priv.h`, a stable ABI
    /// value, so the function is located generically as the unique routine that
    /// loads `0x3EA` into `w1` immediately ahead of a `BL` (the priv-check call) —
    /// no offsets, no preassembled bytes, no version-pinned switch literal.
    func findProcSecurityPolicy() -> Int? {
        if let cached = procSecurityPolicyOff { return cached >= 0 ? cached : nil }
        let raw = buffer.original

        var funcs = Set<Int>()
        for (start, end) in codeRanges {
            var off = start
            let limit = min(end, raw.count) - 4
            while off <= limit {
                defer { off += 4 }
                let insn = raw.loadLE(UInt32.self, at: off)
                // movz w1, #0x3EA  (Rd=w1, imm16=PRIV_GLOBAL_PROC_INFO)
                guard ARM64Inst.isMOVZW(insn), ARM64Inst.rd(insn) == 1,
                      ARM64Inst.movImm16(insn) == 0x3EA else { continue }
                // Require a BL within the next two instructions (priv_check_cred call).
                let blA = off + 4 <= limit ? raw.loadLE(UInt32.self, at: off + 4) : 0
                let blB = off + 8 <= limit ? raw.loadLE(UInt32.self, at: off + 8) : 0
                guard ARM64Inst.isBL(blA) || ARM64Inst.isBL(blB) else { continue }
                if let fn = findFunctionStart(off) { funcs.insert(fn) }
            }
        }

        let result = funcs.count == 1 ? funcs.first! : -1
        procSecurityPolicyOff = result
        if verbose, result >= 0 {
            print("  [+] _proc_security_policy at 0x\(String(format: "%X", result)) (PRIV_GLOBAL_PROC_INFO anchor)")
        }
        return result >= 0 ? result : nil
    }

    // MARK: - Convenience Properties

    /// The `__TEXT_EXEC` range as (fileOffsetStart, fileOffsetEnd), or nil.
    /// Equivalent to Python `self.kern_text`.
    var kernTextRange: (Int, Int)? {
        if let seg = segments.first(where: { $0.name == "__TEXT_EXEC" }), seg.fileSize > 0 {
            return (Int(seg.fileOffset), Int(seg.fileOffset + seg.fileSize))
        }
        return codeRanges.first.map { ($0.start, $0.end) }
    }

    // MARK: - Disassemble Helper

    /// Disassemble one instruction at file offset in the mutable buffer.
    func disasAt(_ off: Int) -> Instruction? {
        guard off >= 0, off + 4 <= buffer.count else { return nil }
        return disasm.disassembleOne(in: buffer.data, at: off)
    }

    // MARK: - BL Decode Helper

    /// Decode the BL target at `offset`, or nil if not a BL.
    func jbDecodeBL(at offset: Int) -> Int? {
        guard offset + 4 <= buffer.count else { return nil }
        let insn = buffer.readU32(at: offset)
        guard insn >> 26 == 0b100101 else { return nil }
        let imm26 = insn & 0x03FF_FFFF
        let signedImm = Int32(bitPattern: imm26 << 6) >> 6
        return offset + Int(signedImm) * 4
    }

    /// Decode unconditional B target at `offset`, or nil if not a B.
    func jbDecodeBBranch(at offset: Int) -> Int? {
        guard offset + 4 <= buffer.count else { return nil }
        let insn = buffer.readU32(at: offset)
        guard (insn & 0x7C00_0000) == 0x1400_0000 else { return nil }
        let imm26 = insn & 0x03FF_FFFF
        let signedImm = Int32(bitPattern: imm26 << 6) >> 6
        return offset + Int(signedImm) * 4
    }

    // MARK: - Chained Pointer Decode

    /// Decode an arm64e auth-rebase chained fixup pointer to a file offset.
    /// Returns -1 if not an auth-rebase pointer or decode fails.
    func decodeChainedPtr(_ raw: UInt64) -> Int {
        guard (raw & (1 << 63)) != 0 else { return -1 }
        let target = Int(raw & 0x3FFF_FFFF)
        guard target > 0, target < buffer.count else { return -1 }
        return target
    }

    // MARK: - Shared code-range / branch helpers (Group B patches)

    /// Return true if `offset` falls within any known code range.
    func jbIsInCodeRange(_ offset: Int) -> Bool {
        codeRanges.contains { offset >= $0.start && offset < $0.end }
    }

    /// Decode a B, BL, B.cond, CBZ, or CBNZ target at `offset`.
    /// Returns (targetFileOffset, isCond) or nil if not a branch.
    func jbDecodeBranchTarget(at offset: Int) -> (target: Int, isCond: Bool)? {
        guard offset >= 0, offset + 4 <= buffer.count else { return nil }
        let insn = buffer.readU32(at: offset)
        let op6 = insn >> 26
        // Unconditional B
        if op6 == 0b000101 {
            let imm26 = insn & 0x03FF_FFFF
            let signedImm = Int32(bitPattern: imm26 << 6) >> 6
            return (offset + Int(signedImm) * 4, false)
        }
        // BL
        if op6 == 0b100101 {
            let imm26 = insn & 0x03FF_FFFF
            let signedImm = Int32(bitPattern: imm26 << 6) >> 6
            return (offset + Int(signedImm) * 4, false)
        }
        // B.cond: [31:24]=0x54, bit[4]=0
        if (insn >> 24) == 0x54, (insn & 0x10) == 0 {
            let imm19 = Int32(bitPattern: ((insn >> 5) & 0x7FFFF) << 13) >> 13
            return (offset + Int(imm19) * 4, true)
        }
        // CBZ/CBNZ W/X: match opcode class directly and ignore Rt/imm19.
        let cbzClass = insn & 0x7F00_0000
        if cbzClass == 0x3400_0000 || cbzClass == 0x3500_0000 ||
            cbzClass == 0xB400_0000 || cbzClass == 0xB500_0000
        {
            let imm19 = Int32(bitPattern: ((insn >> 5) & 0x7FFFF) << 13) >> 13
            return (offset + Int(imm19) * 4, true)
        }
        return nil
    }
}
