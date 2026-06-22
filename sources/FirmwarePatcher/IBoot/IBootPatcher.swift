// IBootPatcher.swift — iBoot chain patcher (iBSS, iBEC, LLB).
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.
// Each patch mirrors Python logic exactly — no hardcoded offsets.
//
// Patch schedule by mode:
//   ibss — serial labels + image4 callback
//   ibec — serial labels + image4 callback + boot-args + bootx precondition (if present)
//   llb  — serial labels + image4 callback + boot-args + rootfs bypass (5 patches) + panic bypass

import Capstone
import Foundation

/// Patcher for iBoot components (iBSS, iBEC, LLB).
public class IBootPatcher: Patcher {
    // MARK: - Types

    public enum Mode: String, Sendable {
        case ibss
        case ibec
        case llb
    }

    // MARK: - Constants

    /// Default custom boot-args string (Python: IBootPatcher.BOOT_ARGS)
    static let bootArgs = "serial=3 -v debug=0x2014e %s"

    /// Chunked disassembly parameters (Python: CHUNK_SIZE, OVERLAP)
    private static let chunkSize = 0x2000
    private static let chunkOverlap = 0x100

    // MARK: - Properties

    public let component: String
    public let verbose: Bool

    let buffer: BinaryBuffer
    let mode: Mode
    let disasm = ARM64Disassembler()
    var patches: [PatchRecord] = []

    // MARK: - Init

    public init(data: Data, mode: Mode, verbose: Bool = true) {
        buffer = BinaryBuffer(data)
        self.mode = mode
        component = mode.rawValue
        self.verbose = verbose
    }

    // MARK: - Patcher Protocol

    public func findAll() throws -> [PatchRecord] {
        patches = []

        patchSerialLabels()
        patchImage4Callback()

        if mode == .llb {
            patchBootArgs()
        }

        if mode == .ibec {
            patchBootArgs()
            patchBootxPrecondition()
        }

        if mode == .llb {
            patchRootfssBypass()
            patchPanicBypass()
        }

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
            print("\n  [\(patches.count) \(mode.rawValue) patches applied]")
        }
        return patches.count
    }

    /// Get the patched data.
    public var patchedData: Data {
        buffer.data
    }

    // MARK: - Emit Helpers

    /// Record a code patch (disassembles before/after for logging).
    func emit(_ offset: Int, _ patchBytes: Data, id: String, description: String) {
        let originalBytes = buffer.readBytes(at: offset, count: patchBytes.count)

        let beforeInsn = disasm.disassembleOne(in: buffer.original, at: offset)
        let afterInsn = disasm.disassembleOne(patchBytes, at: UInt64(offset))
        let beforeStr = beforeInsn.map { "\($0.mnemonic) \($0.operandString)" } ?? "???"
        let afterStr = afterInsn.map { "\($0.mnemonic) \($0.operandString)" } ?? "???"

        let record = PatchRecord(
            patchID: id,
            component: component,
            fileOffset: offset,
            originalBytes: originalBytes,
            patchedBytes: patchBytes,
            beforeDisasm: beforeStr,
            afterDisasm: afterStr,
            description: description
        )
        patches.append(record)

        if verbose {
            print(String(format: "  0x%06X: %@ → %@  [%@]", offset, beforeStr, afterStr, description))
        }
    }

    /// Record a string/data patch (not disassemblable).
    func emitString(_ offset: Int, _ data: Data, id: String, description: String) {
        let originalBytes = buffer.readBytes(at: offset, count: data.count)
        let txt = String(data: data, encoding: .ascii) ?? data.hex

        let record = PatchRecord(
            patchID: id,
            component: component,
            fileOffset: offset,
            originalBytes: originalBytes,
            patchedBytes: data,
            beforeDisasm: "",
            afterDisasm: repr(txt),
            description: description
        )
        patches.append(record)

        if verbose {
            print(String(format: "  0x%06X: → %@  [%@]", offset, repr(txt), description))
        }
    }

    private func repr(_ s: String) -> String {
        "\"\(s)\""
    }

    // MARK: - Pattern Search Helpers

    /// Encode `mov w8, #<imm16>` (MOVZ W8, #imm) as 4 little-endian bytes.
    /// MOVZ W encoding: [31]=0 sf, [30:29]=10, [28:23]=100101, [22:21]=hw=00,
    ///                   [20:5]=imm16, [4:0]=Rd=8
    func encodedMovW8(_ imm16: UInt32) -> Data {
        let insn: UInt32 = 0x5280_0000 | ((imm16 & 0xFFFF) << 5) | 8
        return withUnsafeBytes(of: insn.littleEndian) { Data($0) }
    }

    /// Encode `movk w8, #<imm16>, lsl #16` (MOVK W8, #imm, LSL #16).
    /// MOVK W: [31]=0, [30:29]=11, [28:23]=100101, [22:21]=hw=01,
    ///          [20:5]=imm16, [4:0]=Rd=8
    func encodedMovkW8Lsl16(_ imm16: UInt32) -> Data {
        let insn: UInt32 = 0x72A0_0000 | ((imm16 & 0xFFFF) << 5) | 8
        return withUnsafeBytes(of: insn.littleEndian) { Data($0) }
    }

    /// Find all file offsets where the given 4-byte pattern appears.
    /// Equivalent to Python `_find_asm_pattern(data, asm_str)`.
    func findPattern(_ pattern: Data) -> [Int] {
        buffer.findAll(pattern)
    }

    // MARK: - Chunked Disassembly

    /// Yield chunks of disassembled instructions over the whole binary.
    /// Mirrors Python `_chunked_disasm()` with CHUNK_SIZE=0x2000, OVERLAP=0x100.
    func chunkedDisasm() -> [[Instruction]] {
        let size = buffer.original.count
        var results: [[Instruction]] = []
        var off = 0
        while off < size {
            let end = min(off + IBootPatcher.chunkSize, size)
            let chunkLen = end - off
            let slice = buffer.original[off ..< off + chunkLen]
            let insns = disasm.disassemble(Data(slice), at: UInt64(off))
            results.append(insns)
            off += IBootPatcher.chunkSize - IBootPatcher.chunkOverlap
        }
        return results
    }

    // MARK: - 1. Serial Labels

    /// Find the two long '====...' banner runs and write the mode label into each.
    /// Python: `patch_serial_labels()`
    func patchSerialLabels() {
        let labelStr = switch mode {
        case .ibss: "Loaded iBSS"
        case .ibec: "Loaded iBEC"
        case .llb: "Loaded LLB"
        }
        guard let labelBytes = labelStr.data(using: .ascii) else { return }

        // Collect all runs of '=' (>=20 chars) — same logic as Python.
        let raw = buffer.original
        var eqRuns: [Int] = []
        var i = raw.startIndex

        while i < raw.endIndex {
            if raw[i] == UInt8(ascii: "=") {
                let start = i
                while i < raw.endIndex, raw[i] == UInt8(ascii: "=") {
                    i = raw.index(after: i)
                }
                let runLen = raw.distance(from: start, to: i)
                if runLen >= 20 {
                    eqRuns.append(raw.distance(from: raw.startIndex, to: start))
                }
            } else {
                i = raw.index(after: i)
            }
        }

        if eqRuns.count < 2 {
            if verbose { print("  [-] serial labels: <2 banner runs found") }
            return
        }

        for runStart in eqRuns.prefix(2) {
            let writeOff = runStart + 1 // Python: run_start + 1
            emitString(writeOff, labelBytes, id: "\(component).serial_label", description: "serial label")
        }
    }

    // MARK: - 2. image4_validate_property_callback

    /// Find the b.ne + mov x0, x22 pattern with a preceding cmp.
    /// Patch: b.ne → NOP, mov x0, x22 → mov x0, #0.
    /// Python: `patch_image4_callback()`
    func patchImage4Callback() {
        var candidates: [(addr: Int, hasNeg1: Bool)] = []

        for insns in chunkedDisasm() {
            let count = insns.count
            guard count >= 2 else { continue }
            for i in 0 ..< count - 1 {
                let a = insns[i]
                let b = insns[i + 1]

                // Must be: b.ne followed immediately by mov x0, x22
                guard a.mnemonic == "b.ne" else { continue }
                guard b.mnemonic == "mov", b.operandString == "x0, x22" else { continue }

                let addr = Int(a.address)

                // There must be a cmp within the 8 preceding instructions
                let lookback = max(0, i - 8)
                let hasCmp = insns[lookback ..< i].contains { $0.mnemonic == "cmp" }
                guard hasCmp else { continue }

                // Check if a movn w22 / mov w22, #-1 appears within 64 insns before (prefer this candidate)
                let far = max(0, i - 64)
                let hasNeg1 = insns[far ..< i].contains { insn in
                    if insn.mnemonic == "movn", insn.operandString.hasPrefix("w22,") {
                        return true
                    }
                    if insn.mnemonic == "mov", insn.operandString.contains("w22"),
                       insn.operandString.contains("#-1") || insn.operandString.contains("#0xffffffff")
                    {
                        return true
                    }
                    return false
                }

                candidates.append((addr: addr, hasNeg1: hasNeg1))
            }
        }

        if candidates.isEmpty {
            if verbose { print("  [-] image4 callback: pattern not found") }
            return
        }

        // Prefer the candidate that has a movn w22 (error return path)
        let off: Int = if let preferred = candidates.first(where: { $0.hasNeg1 }) {
            preferred.addr
        } else {
            candidates.last!.addr
        }

        emit(off, ARM64.nop, id: "\(component).image4_callback_bne", description: "image4 callback: b.ne → nop")
        emit(off + 4, ARM64.movX0_0, id: "\(component).image4_callback_mov", description: "image4 callback: mov x0,x22 → mov x0,#0")
    }

    // MARK: - 3. Boot-Args (iBEC / LLB)

    /// Redirect ADRP+ADD x2 to a custom boot-args string.
    /// Python: `patch_boot_args()`
    func patchBootArgs(newArgs: String = IBootPatcher.bootArgs) {
        guard let newArgsData = newArgs.data(using: .ascii) else { return }

        guard let fmtOff = findBootArgsFmt() else {
            if verbose { print("  [-] boot-args: format string not found") }
            return
        }

        guard let (adrpOff, addOff) = findBootArgsAdrp(fmtOff: fmtOff) else {
            if verbose { print("  [-] boot-args: ADRP+ADD x2 not found") }
            return
        }

        guard let newOff = findStringSlot(length: newArgsData.count) else {
            if verbose { print("  [-] boot-args: no NUL slot") }
            return
        }

        // Write the string itself
        emitString(newOff, newArgsData, id: "\(component).boot_args_string", description: "boot-args string")

        // Re-encode ADRP x2 → new page
        guard let newAdrp = ARM64Encoder.encodeADRP(rd: 2, pc: UInt64(adrpOff), target: UInt64(newOff)) else {
            if verbose { print("  [-] boot-args: ADRP encoding out of range") }
            return
        }
        emit(adrpOff, newAdrp, id: "\(component).boot_args_adrp", description: "boot-args: adrp x2 → new string page")

        // Re-encode ADD x2, x2, #offset
        let imm12 = UInt32(newOff & 0xFFF)
        guard let newAdd = ARM64Encoder.encodeAddImm12(rd: 2, rn: 2, imm12: imm12) else {
            if verbose { print("  [-] boot-args: ADD encoding out of range") }
            return
        }
        emit(addOff, newAdd, id: "\(component).boot_args_add", description: "boot-args: add x2 → new string offset")
    }

    /// Find the standalone "%s" format string near "rd=md0" or "BootArgs".
    /// Python: `_find_boot_args_fmt()`
    private func findBootArgsFmt() -> Int? {
        let raw = buffer.original

        // Find the anchor string
        var anchor: Int? = raw.range(of: Data("rd=md0".utf8)).map { raw.distance(from: raw.startIndex, to: $0.lowerBound) }
        if anchor == nil {
            anchor = raw.range(of: Data("BootArgs".utf8)).map { raw.distance(from: raw.startIndex, to: $0.lowerBound) }
        }
        guard let anchorOff = anchor else { return nil }

        // Search for "%s" within 0x40 bytes of the anchor
        let searchEnd = anchorOff + 0x40
        let pctS = Data([UInt8(ascii: "%"), UInt8(ascii: "s")])

        var off = anchorOff
        while off < searchEnd {
            guard let range = raw.range(of: pctS, in: off ..< min(searchEnd, raw.count)) else { return nil }
            let found = raw.distance(from: raw.startIndex, to: range.lowerBound)
            if found >= off + raw.count { return nil }

            // Must have NUL before and NUL after (isolated "%s\0")
            if found > 0, raw[found - 1] == 0, found + 2 < raw.count, raw[found + 2] == 0 {
                return found
            }
            off = found + 1
        }
        return nil
    }

    /// Find ADRP+ADD x2 pointing to the format string at fmtOff.
    /// Python: `_find_boot_args_adrp()`
    private func findBootArgsAdrp(fmtOff: Int) -> (Int, Int)? {
        for insns in chunkedDisasm() {
            let count = insns.count
            guard count >= 2 else { continue }
            for i in 0 ..< count - 1 {
                let a = insns[i]
                let b = insns[i + 1]

                guard a.mnemonic == "adrp", b.mnemonic == "add" else { continue }

                // First operand of ADRP must be x2
                guard a.operandString.hasPrefix("x2,") else { continue }

                guard let aDetail = a.aarch64, let bDetail = b.aarch64 else { continue }
                guard aDetail.operands.count >= 2, bDetail.operands.count >= 3 else { continue }

                // ADRP Rd must equal ADD Rn (same register)
                guard aDetail.operands[0].reg == bDetail.operands[1].reg else { continue }

                // ADRP page imm + ADD imm12 must equal fmt_off
                let pageImm = aDetail.operands[1].imm // already page-aligned VA
                let addImm = bDetail.operands[2].imm
                if Int(pageImm + addImm) == fmtOff {
                    return (Int(a.address), Int(b.address))
                }
            }
        }
        return nil
    }

    /// Find a run of NUL bytes ≥ 64 bytes long to write the new string into.
    /// Python: `_find_string_slot()`
    private func findStringSlot(length: Int, searchStart: Int = 0x14000) -> Int? {
        let raw = buffer.original
        var off = searchStart
        while off < raw.count {
            if raw[off] == 0 {
                let runStart = off
                while off < raw.count, raw[off] == 0 {
                    off += 1
                }
                let runLen = off - runStart
                if runLen >= 64 {
                    // Align write pointer to 16 bytes (Python: (run_start + 8 + 15) & ~15)
                    let writeOff = (runStart + 8 + 15) & ~15
                    if writeOff + length <= off {
                        return writeOff
                    }
                }
            } else {
                off += 1
            }
        }
        return nil
    }

    // MARK: - 4. Rootfs Bypass (LLB only)

    /// Apply all five rootfs bypass patches.
    /// Python: `patch_rootfs_bypass()`
    func patchRootfssBypass() {
        // 4a: cbz/cbnz before error code 0x3B7 → unconditional b
        patchCbzBeforeError(errorCode: 0x3B7, description: "rootfs: skip sig check (0x3B7)")
        // 4b: NOP b.hs after cmp x8, #0x400
        patchBhsAfterCmp0x400()
        // 4c: cbz/cbnz before error code 0x3C2 → unconditional b
        patchCbzBeforeError(errorCode: 0x3C2, description: "rootfs: skip sig verify (0x3C2)")
        // 4d: NOP cbz x8 null check (ldr x8, [xN, #0x78])
        patchNullCheck0x78()
        // 4e: cbz/cbnz before error code 0x110 → unconditional b
        patchCbzBeforeError(errorCode: 0x110, description: "rootfs: skip size verify (0x110)")
    }

    /// Find unique `mov w8, #<errorCode>` and convert the cbz/cbnz 4 bytes before
    /// it into an unconditional branch to the same target.
    /// Python: `_patch_cbz_before_error()`
    private func patchCbzBeforeError(errorCode: UInt32, description: String) {
        let pattern = encodedMovW8(errorCode)
        let locs = findPattern(pattern)

        guard locs.count == 1 else {
            if verbose {
                print("  [-] \(description): expected 1 'mov w8, #0x\(String(errorCode, radix: 16))', found \(locs.count)")
            }
            return
        }

        let errOff = locs[0]
        let cbzOff = errOff - 4

        guard let insn = disasm.disassembleOne(in: buffer.original, at: cbzOff) else {
            if verbose { print("  [-] \(description): no instruction at 0x\(String(format: "%X", cbzOff))") }
            return
        }
        guard insn.mnemonic == "cbz" || insn.mnemonic == "cbnz" else {
            if verbose { print("  [-] \(description): expected cbz/cbnz at 0x\(String(format: "%X", cbzOff)), got \(insn.mnemonic)") }
            return
        }

        // Extract branch target from the operand string (last operand is the immediate)
        guard let detail = insn.aarch64, detail.operands.count >= 2 else { return }
        let target = Int(detail.operands[1].imm)

        guard let bInsn = ARM64Encoder.encodeB(from: cbzOff, to: target) else {
            if verbose { print("  [-] \(description): B encoding out of range") }
            return
        }

        emit(cbzOff, bInsn, id: "\(component).rootfs_cbz_0x\(String(errorCode, radix: 16))", description: description)
    }

    /// NOP the `b.hs` of the unique `cmp x8,#0x400 ; b.hs` rootfs size gate.
    /// Anchoring on the cmp+b.hs pair disambiguates 26.4's three `cmp x8,#0x400`
    /// (the other two are followed by `b.hi`); 26.1/26.3 have just the one.
    /// Python: `_patch_bhs_after_cmp_0x400()`
    private func patchBhsAfterCmp0x400() {
        var bhsSites: [Int] = []
        for insns in chunkedDisasm() {
            for insn in insns where insn.mnemonic == "cmp" && insn.operandString == "x8, #0x400" {
                let bhsOff = Int(insn.address) + 4
                guard let next = disasm.disassembleOne(in: buffer.original, at: bhsOff),
                      next.mnemonic == "b.hs" else { continue }
                if !bhsSites.contains(bhsOff) { bhsSites.append(bhsOff) }
            }
        }

        guard bhsSites.count == 1 else {
            if verbose { print("  [-] rootfs b.hs: expected 1 'cmp x8,#0x400 ; b.hs' pair, found \(bhsSites.count)") }
            return
        }

        emit(bhsSites[0], ARM64.nop, id: "\(component).rootfs_bhs_0x400", description: "rootfs: NOP b.hs size check (0x400)")
    }

    /// Find `ldr xR, [xN, #0x78]; cbz xR` preceding the unique `mov w8, #0x110`
    /// and NOP the cbz.
    /// Python: `_patch_null_check_0x78()`
    private func patchNullCheck0x78() {
        let pattern = encodedMovW8(0x110)
        let locs = findPattern(pattern)

        guard locs.count == 1 else {
            if verbose { print("  [-] rootfs null check: expected 1 'mov w8, #0x110', found \(locs.count)") }
            return
        }

        let errOff = locs[0]

        // Walk backwards from errOff to find ldr x?, [xN, #0x78]; cbz x?
        let scanStart = max(errOff - 0x300, 0)
        var scan = errOff - 4
        while scan >= scanStart {
            guard let i1 = disasm.disassembleOne(in: buffer.original, at: scan),
                  let i2 = disasm.disassembleOne(in: buffer.original, at: scan + 4)
            else {
                scan -= 4
                continue
            }

            if i1.mnemonic == "ldr",
               i1.operandString.contains("#0x78"),
               i2.mnemonic == "cbz",
               i2.operandString.hasPrefix("x")
            {
                emit(scan + 4, ARM64.nop, id: "\(component).rootfs_null_check_0x78",
                     description: "rootfs: NOP cbz x8 null check (#0x78)")
                return
            }
            scan -= 4
        }

        if verbose { print("  [-] rootfs null check: ldr+cbz #0x78 pattern not found") }
    }

    // MARK: - 5. Panic Bypass (LLB only)

    /// Find `mov w8, #0x328; movk w8, #0x40, lsl #16; ...; bl X; cbnz w0`
    /// and NOP the cbnz.
    /// Python: `patch_panic_bypass()`
    func patchPanicBypass() {
        let mov328 = encodedMovW8(0x328)
        let locs = findPattern(mov328)

        for loc in locs {
            // Verify movk w8, #0x40, lsl #16 follows
            guard let nextInsn = disasm.disassembleOne(in: buffer.original, at: loc + 4) else { continue }
            guard nextInsn.mnemonic == "movk",
                  nextInsn.operandString.contains("w8"),
                  nextInsn.operandString.contains("#0x40"),
                  nextInsn.operandString.contains("lsl #16") else { continue }

            // Walk forward (up to 7 instructions past the movk) to find bl; cbnz w0
            var step = loc + 8
            while step < loc + 32 {
                guard let i = disasm.disassembleOne(in: buffer.original, at: step) else {
                    step += 4
                    continue
                }
                if i.mnemonic == "bl" {
                    if let ni = disasm.disassembleOne(in: buffer.original, at: step + 4),
                       ni.mnemonic == "cbnz"
                    {
                        emit(step + 4, ARM64.nop,
                             id: "\(component).panic_bypass",
                             description: "panic bypass: NOP cbnz w0")
                        return
                    }
                    break // bl found but no cbnz — keep scanning other mov candidates
                }
                step += 4
            }
        }

        if verbose { print("  [-] panic bypass: pattern not found") }
    }

    // MARK: - 6. Bootx-handoff precondition (modern iBoot, all stages)

    /// NOP the conditional branch gating the modern iBoot bootx-handoff
    /// panic. 
    ///
    /// Gate signature (Capstone-decoded):
    ///
    ///     BL  <bit_getter>            ; tiny 4-insn `return bit_N([global])` fn
    ///     TBZ w0, #0, <panic_block>   ; patch target — NOP'd
    ///     ...
    ///     <panic_block>:
    ///         BL  <hash_getter>       ; 5-insn 4×MOV/MOVK+RET source-hash fn
    ///         MOV w?, #<lineno>       ; source line (any value)
    ///         BL  <log_func>          ; panic/log dispatcher
    ///
    /// `<bit_getter>` is `ADRP; LDRB; UBFX Wd, Wn, #?, #1; RET` — a
    /// "return one bit of one byte at a global address" function (rare in
    /// iBoot). The combination of "TBZ w0, #0 → panic" where the preceding
    /// instruction is BL to such a function, and the TBZ target is a
    /// hash-getter/MOVZ-line/BL-log triple, is the distinctive shape.
    ///
    /// Refuses to patch on ambiguity (multiple matches).
    func patchBootxPrecondition() {
        let hashGetters = enumerateHashGetters()
        let bitGetters  = enumerateBitGetters()

        guard !hashGetters.isEmpty, !bitGetters.isEmpty else {
            if verbose {
                print("  [-] bootx precondition: hash-getter or bit-getter pattern absent")
            }
            return
        }

        let panicBlocks = enumeratePanicBlocks(hashGetters: hashGetters)
        if panicBlocks.isEmpty {
            if verbose { print("  [-] bootx precondition: no panic-shaped call blocks") }
            return
        }

        var gates = Set<Int>()
        for insns in chunkedDisasm() {
            guard insns.count >= 2 else { continue }
            for i in 1 ..< insns.count {
                let tbz = insns[i]
                let prev = insns[i - 1]
                guard tbz.mnemonic == "tbz" else { continue }
                guard
                    let tbzDet = tbz.aarch64,
                    tbzDet.operands.count >= 3,
                    tbzDet.operands[0].type == AARCH64_OP_REG,
                    tbzDet.operands[0].reg.rawValue == AARCH64_REG_W0.rawValue,
                    tbzDet.operands[1].type == AARCH64_OP_IMM,
                    tbzDet.operands[1].imm == 0,
                    tbzDet.operands[2].type == AARCH64_OP_IMM
                else { continue }
                let target = Int(tbzDet.operands[2].imm)
                guard panicBlocks.contains(target) else { continue }

                guard prev.mnemonic == "bl" else { continue }
                guard
                    let prevDet = prev.aarch64,
                    prevDet.operands.count >= 1,
                    prevDet.operands[0].type == AARCH64_OP_IMM
                else { continue }
                let blTarget = Int(prevDet.operands[0].imm)
                guard bitGetters.contains(blTarget) else { continue }

                gates.insert(Int(tbz.address))
            }
        }

        if gates.isEmpty {
            // 26.4+ construct; genuinely absent on previous iBoot versions.
            if verbose { print("  [.] bootx precondition: construct not present (pre-26.4 iBoot) — skipping") }
            return
        }
        if gates.count > 1 {
            if verbose {
                print("  [-] bootx precondition: ambiguous (\(gates.count) candidates)")
                for g in gates.sorted() { print(String(format: "      0x%X", g)) }
            }
            return
        }
        let gate = gates.first!
        emit(gate, ARM64.nop, id: "\(component).bootx_precondition",
             description: "bootx precondition: NOP gate TBZ")
    }

    /// Enumerate 5-insn `MOVZ + 3×MOVK + RET` functions assembling a 64-bit
    /// constant into a single X register (used by iBoot's panic/log calls
    /// to load the source-file hash). Returns the file offsets at which
    /// each such function starts.
    private func enumerateHashGetters() -> Set<Int> {
        var out = Set<Int>()
        for insns in chunkedDisasm() {
            guard insns.count >= 5 else { continue }
            for i in 0 ..< (insns.count - 4) {
                guard insns[i].mnemonic == "mov" || insns[i].mnemonic == "movz" else { continue }
                guard insns[i + 1].mnemonic == "movk" else { continue }
                guard insns[i + 2].mnemonic == "movk" else { continue }
                guard insns[i + 3].mnemonic == "movk" else { continue }
                guard insns[i + 4].mnemonic == "ret"  else { continue }
                // All four MOV/MOVK destinations must be the same register.
                var regs = Set<UInt32>()
                var ok = true
                for k in 0 ..< 4 {
                    guard
                        let det = insns[i + k].aarch64,
                        det.operands.count >= 1,
                        det.operands[0].type == AARCH64_OP_REG
                    else { ok = false; break }
                    regs.insert(det.operands[0].reg.rawValue)
                }
                guard ok, regs.count == 1 else { continue }
                out.insert(Int(insns[i].address))
            }
        }
        return out
    }

    /// Enumerate 4-insn `ADRP + LDRB + UBFX (width=1) + RET` functions —
    /// the "return one bit of one byte global" shape used as the
    /// precondition feature-check. Any bit position is accepted; only the
    /// width-1 extract is enforced.
    private func enumerateBitGetters() -> Set<Int> {
        var out = Set<Int>()
        for insns in chunkedDisasm() {
            guard insns.count >= 4 else { continue }
            for i in 0 ..< (insns.count - 3) {
                let mnems = [
                    insns[i].mnemonic, insns[i + 1].mnemonic,
                    insns[i + 2].mnemonic, insns[i + 3].mnemonic,
                ]
                guard mnems == ["adrp", "ldrb", "ubfx", "ret"] else { continue }
                guard
                    let det = insns[i + 2].aarch64,
                    det.operands.count >= 4,
                    det.operands[3].type == AARCH64_OP_IMM,
                    det.operands[3].imm == 1
                else { continue }
                out.insert(Int(insns[i].address))
            }
        }
        return out
    }

    /// Enumerate "panic block" call sites: 3-insn sequence of
    /// `BL <hash_getter>; MOV W?, #<imm>; BL <anything>`. Returns the file
    /// offset of the first BL in each such triple.
    private func enumeratePanicBlocks(hashGetters: Set<Int>) -> Set<Int> {
        var out = Set<Int>()
        for insns in chunkedDisasm() {
            guard insns.count >= 3 else { continue }
            for i in 0 ..< (insns.count - 2) {
                guard
                    insns[i].mnemonic == "bl",
                    (insns[i + 1].mnemonic == "mov" || insns[i + 1].mnemonic == "movz"),
                    insns[i + 2].mnemonic == "bl"
                else { continue }
                guard
                    let det = insns[i].aarch64,
                    det.operands.count >= 1,
                    det.operands[0].type == AARCH64_OP_IMM
                else { continue }
                let blTarget = Int(det.operands[0].imm)
                guard hashGetters.contains(blTarget) else { continue }
                out.insert(Int(insns[i].address))
            }
        }
        return out
    }
}
