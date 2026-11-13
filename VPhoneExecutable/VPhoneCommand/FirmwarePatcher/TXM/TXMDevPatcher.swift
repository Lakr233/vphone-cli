// TXMDevPatcher.swift — Dev-variant TXM patcher (entitlements, debugger, developer mode).
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.

import Foundation
import VPhonePatchKit

/// Dev-variant patcher for TXM images.
///
/// Adds admission and runtime policies beyond the base trustcache bypass:
///   1. selector24 force PASS (mov w0, #0xa1 + b epilogue)
///   2. get-task-allow entitlement BL → mov x0, #1
///   3. selector42|29 shellcode hook + manifest flag force
///   4. debugger entitlement BL → mov w0, #1
///   5. developer-mode guard → nop
///   6. native signature classification for remapping
public final class TXMDevPatcher: TXMPatcher {
    static let precheckAdmissionID = "txm-exp-precheck_admission"

    override public func findAll() throws -> [PatchRecord] {
        patches = []
        do {
            if gate.isEnabled(Self.executableRemapID) {
                try patchExecutableRemap() // includes the base bypass with real cache queries
            } else {
                try patchTrustcacheBypass()
            }
        } catch {
            // A failed compatibility lookup must not leave an applicable
            // partial plan behind if the caller retries apply().
            patches = []
            throw error
        }
        // Legacy force-admit of the selector-24 pre-check walk. Restored as a
        // selectable patch: it admits every image (CS_ADHOC code included) at the
        // top of the ladder, which native classification does not, so injected
        // ad-hoc dylibs reach RX. It skips the native classification that
        // txm-cfw-executable_remap preserves, so the two are not meant to run
        // together; select one or the other per the VM's needs.
        if gate.isEnabled(Self.precheckAdmissionID) {
            patchPrecheckForcePass()
        }
        patchSelector24ForcePass()
        patchGetTaskAllowForceTrue()
        patchSelector42_29Shellcode()
        patchDebuggerEntitlementForceTrue()
        patchDeveloperModeBypass()
        return patches
    }

    // MARK: - Flat-binary ADRP+ADD string reference search

    /// Find all ADRP+ADD pairs in the flat binary that resolve to `targetOff`.
    ///
    /// TXM is a raw flat binary (no Mach-O), so we cannot use a pre-built ADRP index.
    /// This mirrors the Python `_find_refs_to_offset` full linear scan.
    ///
    /// Returns an array of `(adrpOff, addOff)` pairs.
    private func findRefsToOffset(_ targetOff: Int) -> [(adrpOff: Int, addOff: Int)] {
        let size = buffer.count
        var refs: [(Int, Int)] = []
        var off = 0
        while off + 8 <= size {
            let rawA = buffer.readU32(at: off)
            let rawB = buffer.readU32(at: off + 4)

            // ADRP: bits[31]=1, bits[28:24]=10000
            guard ARM64Inst.isADRP(rawA) else { off += 4; continue }
            // ADD immediate (64-bit): bits[31:24] = 0x91
            guard rawB & 0xFF80_0000 == 0x9100_0000 else { off += 4; continue }

            // Decode ADRP target page
            let adrpRd = rawA & 0x1F
            let immlo = (rawA >> 29) & 0x3
            let immhi = (rawA >> 5) & 0x7FFFF
            let imm21 = (immhi << 2) | immlo
            // Sign-extend imm21 from 21 bits
            let signedImm21 = Int64(Int32(bitPattern: imm21 << 11) >> 11)
            let pcPage = UInt64(off) & ~UInt64(0xFFF)
            let adrpPage = UInt64(bitPattern: Int64(pcPage) + (signedImm21 << 12))

            // Decode ADD: Rn must equal ADRP's Rd; imm12 is the page offset
            let addRn = (rawB >> 5) & 0x1F
            let addImm12 = (rawB >> 10) & 0xFFF

            guard adrpRd == addRn else { off += 4; continue }

            let resolved = Int(adrpPage) + Int(addImm12)
            if resolved == targetOff {
                refs.append((off, off + 4))
            }
            off += 4
        }
        guard refs.isEmpty else { return refs }

        // The iOS 18 TXMs reach their strings with a lone `adr` (the linker
        // relaxed `adrp` + `add` into `adr` + `nop`). Such a reference is its
        // own ADD: both offsets are the `adr`.
        off = 0
        while off + 4 <= size {
            let raw = buffer.readU32(at: off)
            // ADR: bit[31]=0, bits[28:24]=10000
            if raw & 0x9F00_0000 == 0x1000_0000 {
                let imm21 = (((raw >> 5) & 0x7FFFF) << 2) | ((raw >> 29) & 0x3)
                let signedImm21 = Int(Int32(bitPattern: imm21 << 11) >> 11)
                if off + signedImm21 == targetOff {
                    refs.append((off, off))
                }
            }
            off += 4
        }
        return refs
    }

    /// Find all ADRP+ADD instruction pairs referencing any occurrence of `needle` in the binary.
    ///
    /// Returns `(stringOff, adrpOff, addOff)` tuples — mirrors Python `_find_string_refs`.
    private func findStringRefs(_ needle: Data) -> [(stringOff: Int, adrpOff: Int, addOff: Int)] {
        var results: [(Int, Int, Int)] = []
        var seen = Set<Int>()
        var search = 0
        while let range = buffer.data.range(of: needle, in: search ..< buffer.count) {
            let sOff = range.lowerBound
            search = sOff + 1
            for (adrpOff, addOff) in findRefsToOffset(sOff) {
                if !seen.contains(adrpOff) {
                    seen.insert(adrpOff)
                    results.append((sOff, adrpOff, addOff))
                }
            }
        }
        return results
    }

    /// Find string refs using a UTF-8 string literal.
    private func findStringRefs(_ needle: String) -> [(stringOff: Int, adrpOff: Int, addOff: Int)] {
        guard let data = needle.data(using: .utf8) else { return [] }
        return findStringRefs(data)
    }

    // MARK: - Helpers

    /// Scan backward from `off` for PACIBSP — mirrors Python `_find_func_start`.
    private func findFuncStart(_ off: Int, back: Int = 0x1000) -> Int? {
        let start = max(0, off - back)
        var scan = off & ~3
        while scan >= start {
            if buffer.readU32(at: scan) == ARM64.pacibspU32 {
                return scan
            }
            scan -= 4
        }
        return nil
    }

    /// Find a zero-filled cave of at least `minInsns * 4` bytes — mirrors Python `_find_udf_cave`.
    ///
    /// The Python logic:
    ///   - Scan forward for a run of zero words.
    ///   - Prefer a run immediately after a branch instruction (with 8-byte safety pad).
    ///   - Otherwise, return the nearest run to `nearOff`.
    private func findUdfCave(minInsns: Int, nearOff: Int? = nil, maxDistance: Int = 0x80000) -> Int? {
        let need = minInsns * 4
        let size = buffer.count
        let searchStart = nearOff.map { max(0, $0 - 0x1000) } ?? 0
        let searchEnd = nearOff.map { min(size, $0 + maxDistance) } ?? size

        var best: Int? = nil
        var bestDist = Int.max
        var off = searchStart

        let branchMnemonics: Set = ["b", "b.eq", "b.ne", "b.lo", "b.hs", "cbz", "cbnz", "tbz", "tbnz"]

        while off < searchEnd {
            // Count consecutive zero words starting at off
            var run = off
            while run < searchEnd, buffer.readU32(at: run) == 0 {
                run += 4
            }

            if run - off >= need {
                // Check instruction before the run
                if off >= 4, let prev = disasm.disassembleOne(in: buffer.data, at: off - 4) {
                    if branchMnemonics.contains(prev.mnemonic) {
                        // 2-word safety gap after the preceding branch
                        let padded = off + 8
                        return (padded + need <= run) ? padded : off
                    }
                }
                // Not after a branch — track nearest to nearOff
                if let near = nearOff {
                    let dist = abs(off - near)
                    if dist < bestDist {
                        best = off
                        bestDist = dist
                    }
                }
            }

            off = (run > off) ? run + 4 : off + 4
        }
        return best
    }

    /// Find the function start of the debugger-gate function containing the
    /// `com.apple.private.cs.debugger` BL site — mirrors Python `_find_debugger_gate_func_start`.
    ///
    /// Pattern (at BL site):
    ///   [scan-8] mov x0, #0
    ///   [scan-4] mov x2, #0
    ///   [scan+0] bl  <entitlement_check>
    ///   [scan+4] tbnz w0, #0, <...>
    private func findDebuggerGateFuncStart() -> Int? {
        let refs = findStringRefs(Data("com.apple.private.cs.debugger".utf8))
        var starts = Set<Int>()

        for (_, _, addOff) in refs {
            let scanEnd = min(addOff + 0x20, buffer.count - 8)
            var scan = addOff
            while scan < scanEnd {
                guard
                    let i = disasm.disassembleOne(in: buffer.data, at: scan),
                    let n = disasm.disassembleOne(in: buffer.data, at: scan + 4),
                    scan >= 8,
                    let p1 = disasm.disassembleOne(in: buffer.data, at: scan - 4),
                    let p2 = disasm.disassembleOne(in: buffer.data, at: scan - 8)
                else { scan += 4; continue }

                let tbnzOk = n.mnemonic == "tbnz" && n.operandString.hasPrefix("w0, #0,")
                let p1ok = p1.mnemonic == "mov" && p1.operandString == "x2, #0"
                let p2ok = p2.mnemonic == "mov" && p2.operandString == "x0, #0"

                if i.mnemonic == "bl", tbnzOk, p1ok, p2ok {
                    if let fs = findFuncStart(scan) {
                        starts.insert(fs)
                    }
                }
                scan += 4
            }
        }

        guard starts.count == 1 else { return nil }
        return starts.first
    }

    /// The `strb w0, [x20, #flag]` for the flag byte the debugger gate at `fn`
    /// tests with `add xT, xObj, #flag ; ldarb wF, [xT]`.
    private func debuggerGateFlagStore(_ fn: Int) -> (bytes: Data, label: String)? {
        var flags = Set<Int64>()
        var scan = fn
        let end = min(fn + 0x400, buffer.count - 8)
        while scan < end {
            if scan > fn, buffer.readU32(at: scan) == ARM64.pacibspU32 { break }
            if let add = disasm.disassembleOne(in: buffer.data, at: scan),
               add.mnemonic == "add",
               let ops = add.detail?.operands, ops.count == 3,
               ops[0].type == .register, ops[1].type == .register, ops[2].type == .immediate,
               let load = disasm.disassembleOne(in: buffer.data, at: scan + 4),
               load.mnemonic == "ldarb",
               let loadOps = load.detail?.operands, loadOps.count == 2,
               loadOps[1].type == .memory, loadOps[1].mem.base == ops[0].reg
            {
                flags.insert(ops[2].imm)
            }
            scan += 4
        }
        guard flags.count == 1 else { return nil }
        switch flags.first! {
        case 0x30: return (ARM64.strbW0X20_30, "0x30")
        case 0x20: return (ARM64.strbW0X20_20, "0x20")
        default: return nil
        }
    }

    // MARK: - Dev Patches

    /// Force the selector-24 pre-check policy walk to admit every manifest.
    ///
    /// On an iOS 27.0.1 iPhone guest the walk (`sub_30BAC` in cloudOS 26.4's
    /// TXM 187.100.3) rejects everything — Apple's own launchd included —
    /// because the trust state it consults never loads from a 27.0.1 restore;
    /// the selector-24 caller then falls through its ad-hoc, CMS and third
    /// fallback branches and kills init (0x32202 / 0x12491). Forcing the
    /// walk's PASS exit admits at the top of the ladder, before any of those
    /// branches run. See Research/Firmware/txm_selector24_cms_gate.md.
    ///
    /// Anchor: the walk is the only function that invokes its policy
    /// callbacks with PAC selector `0x7e51` (`mov x17, #0x7e51` immediately
    /// followed by `blraa x8, x17`) after walking a policy table with a
    /// post-indexed `ldr x22, [x20], #0x40`. The patch replaces the first
    /// four body instructions with:
    ///
    ///     mov  w8, #0xa          ; tolerated validation-type byte
    ///     strb w8, [x19]         ; *out = 0xa, as the tolerated path writes
    ///     mov  w0, #0x90         ; the walk's PASS status
    ///     b    <epilogue>
    func patchPrecheckForcePass() {
        let size = buffer.count
        var off = 0
        while off + 8 <= size {
            defer { off += 4 }

            guard let selector = disasm.disassembleOne(in: buffer.data, at: off),
                  selector.mnemonic == "mov",
                  let selOps = selector.detail?.operands, selOps.count == 2,
                  selOps[0].type == .register, selOps[0].reg == .x(17),
                  selOps[1].type == .immediate, selOps[1].imm == 0x7E51,
                  let call = disasm.disassembleOne(in: buffer.data, at: off + 4),
                  call.mnemonic == "blraa"
            else {
                if verbose, let ins = disasm.disassembleOne(in: buffer.data, at: off),
                   ins.mnemonic == "mov",
                   let ops = ins.detail?.operands,
                   ops.count == 2, ops[1].type == .immediate, ops[1].imm == 0x7E51
                {
                    let next = disasm.disassembleOne(in: buffer.data, at: off + 4)
                    print("  [·] TXM: selector 0x7e51 at \(String(format: "%06X", off)); next: \(next.map { "\($0.mnemonic) \($0.operandString)" } ?? "decode-fail")")
                }
                continue
            }

            guard let funcStart = findFuncStart(off) else { continue }

            // The walk dereferences the policy table through a writeback
            // load (`ldr x22, [x20], #0x40`, the only three-operand ldr in
            // the function); confirm it is here before trusting the site.
            // The operand string is matched whole — as `patchSelector24ForcePass`
            // matches its own anchors — because capstone reports post-index
            // loads with an operand-shape that varies by version.
            var sawTableWalk = false
            var scan = funcStart
            while scan + 4 <= off {
                if let i = disasm.disassembleOne(in: buffer.data, at: scan),
                   i.mnemonic == "ldr",
                   i.operandString == "x22, [x20], #0x40"
                {
                    sawTableWalk = true
                    break
                }
                scan += 4
            }
            guard sawTableWalk else { continue }

            // Body starts after the two argument-register moves that open it.
            var body: Int? = nil
            var p = funcStart
            while p + 8 <= off {
                guard
                    let a = disasm.disassembleOne(in: buffer.data, at: p),
                    let b = disasm.disassembleOne(in: buffer.data, at: p + 4)
                else { p += 4; continue }
                if a.mnemonic == "mov", let aops = a.detail?.operands, aops.count == 2,
                   aops[0].reg == .x(19), aops[1].reg == .x(1),
                   b.mnemonic == "mov", let bops = b.detail?.operands, bops.count == 2,
                   bops[0].reg == .x(20), bops[1].reg == .x(0)
                {
                    body = p + 8
                    break
                }
                p += 4
            }
            guard let bodyStart = body else {
                log("  [-] TXM: pre-check walk body start not found")
                return
            }

            // Epilogue: the walk's retab, back to its frame restore.
            var epilogue: Int? = nil
            var r = off
            while r < min(off + 0x200, size) {
                if let ri = disasm.disassembleOne(in: buffer.data, at: r), ri.mnemonic == "retab" {
                    var e = r - 4
                    while e > max(r - 0x40, funcStart) {
                        if let ei = disasm.disassembleOne(in: buffer.data, at: e),
                           ei.mnemonic == "ldp", ei.operandString.contains("x29, x30")
                        {
                            epilogue = e
                            break
                        }
                        e -= 4
                    }
                    break
                }
                r += 4
            }
            guard let epilogueOff = epilogue else {
                log("  [-] TXM: pre-check walk epilogue not found")
                return
            }

            emit(bodyStart, ARM64.movW8_0xA, patchID: "txm-exp-precheck_admission.mark_type",
                 description: "pre-check admission: mov w8, #0xa (tolerated type)")
            emit(bodyStart + 4, ARM64.strbW8X19, patchID: "txm-exp-precheck_admission.store_type",
                 description: "pre-check admission: strb w8, [x19]")
            emit(bodyStart + 8, ARM64.movW0_0x90, patchID: "txm-exp-precheck_admission.pass",
                 description: "pre-check admission: mov w0, #0x90 (PASS)")
            guard let bInsn = ARM64Encoder.encodeB(from: bodyStart + 12, to: epilogueOff) else {
                log("  [-] TXM: pre-check admission branch encoding failed")
                return
            }
            emit(bodyStart + 12, bInsn, patchID: "txm-exp-precheck_admission.branch",
                 description: "pre-check admission: b epilogue")
            return
        }

        log("  [-] TXM: pre-check walk (selector 0x7e51 policy callbacks) not found")
    }


    /// Patch selector24 handler to return 0xA1 (PASS) immediately.
    ///
    /// Inserts `mov w0, #0xa1 ; b <epilogue>` right after the prologue,
    /// skipping validation while preserving the stack frame.
    func patchSelector24ForcePass() {
        let size = buffer.count

        // Scan for any `mov w0, #0xa1` in the binary
        var off = 0
        while off + 4 <= size {
            guard let ins = disasm.disassembleOne(in: buffer.data, at: off),
                  ins.mnemonic == "mov", ins.operandString == "w0, #0xa1"
            else { off += 4; continue }

            guard let funcStart = findFuncStart(off) else { off += 4; continue }

            // Verify this is selector24 by searching for the characteristic
            // LDR X1,[Xn,#0x38] / ADD X2,... / BL / LDP pattern in [funcStart, off)
            var patternFound = false
            var scan = funcStart
            while scan + 12 < off {
                guard
                    let i0 = disasm.disassembleOne(in: buffer.data, at: scan),
                    let i1 = disasm.disassembleOne(in: buffer.data, at: scan + 4),
                    let i2 = disasm.disassembleOne(in: buffer.data, at: scan + 8),
                    let i3 = disasm.disassembleOne(in: buffer.data, at: scan + 12)
                else { scan += 4; continue }

                let ldrOk = i0.mnemonic == "ldr"
                    && i0.operandString.contains("x1,")
                    && i0.operandString.contains("#0x38]")
                let addOk = i1.mnemonic == "add" && i1.operandString.hasPrefix("x2,")
                let blOk = i2.mnemonic == "bl"
                let ldpOk = i3.mnemonic == "ldp"

                if ldrOk, addOk, blOk, ldpOk {
                    patternFound = true
                    break
                }
                scan += 4
            }

            guard patternFound else { off += 4; continue }

            // Find prologue end: scan for `add x29, sp, #imm`
            var bodyStart: Int? = nil
            var p = funcStart + 4
            while p < funcStart + 0x30 {
                if let pi = disasm.disassembleOne(in: buffer.data, at: p),
                   pi.mnemonic == "add", pi.operandString.hasPrefix("x29, sp,")
                {
                    bodyStart = p + 4
                    break
                }
                p += 4
            }

            guard let body = bodyStart else {
                log("  [-] TXM: selector24 prologue end not found")
                return
            }

            // Find epilogue: scan forward from `off` for retab/ret,
            // then walk back for `ldp x29, x30, ...`
            var epilogue: Int? = nil
            var r = off
            while r < min(off + 0x200, size) {
                if let ri = disasm.disassembleOne(in: buffer.data, at: r),
                   ri.mnemonic == "retab" || ri.mnemonic == "ret"
                {
                    var e = r - 4
                    while e > max(r - 0x20, funcStart) {
                        if let ei = disasm.disassembleOne(in: buffer.data, at: e),
                           ei.mnemonic == "ldp", ei.operandString.contains("x29, x30")
                        {
                            epilogue = e
                            break
                        }
                        e -= 4
                    }
                    break
                }
                r += 4
            }

            guard let epilogueOff = epilogue else {
                log("  [-] TXM: selector24 epilogue not found")
                return
            }

            emit(
                body,
                ARM64.movW0_0xA1,
                patchID: "txm-boot-selector24_bypass.mov",
                description: "selector24 bypass: mov w0, #0xa1 (PASS)",
            )

            guard let bInsn = ARM64Encoder.encodeB(from: body + 4, to: epilogueOff) else {
                log("  [-] TXM: selector24 branch encoding failed")
                return
            }
            emit(
                body + 4,
                bInsn,
                patchID: "txm-boot-selector24_bypass.b",
                description: "selector24 bypass: b epilogue",
            )
            return
        }

        log("  [-] TXM: selector24 handler not found")
    }

    /// Force get-task-allow entitlement check to return true (BL → mov x0, #1).
    func patchGetTaskAllowForceTrue() {
        let refs = findStringRefs(Data("get-task-allow".utf8))
        guard !refs.isEmpty else {
            log("  [-] TXM: get-task-allow string refs not found")
            return
        }

        var cands: [Int] = []
        for (_, _, addOff) in refs {
            let scanEnd = min(addOff + 0x20, buffer.count - 4)
            var scan = addOff
            while scan < scanEnd {
                guard
                    let i = disasm.disassembleOne(in: buffer.data, at: scan),
                    let n = disasm.disassembleOne(in: buffer.data, at: scan + 4)
                else { scan += 4; continue }

                if i.mnemonic == "bl",
                   n.mnemonic == "tbnz",
                   n.operandString.hasPrefix("w0, #0,")
                {
                    cands.append(scan)
                }
                scan += 4
            }
        }

        guard cands.count == 1 else {
            log("  [-] TXM: expected 1 get-task-allow BL site, found \(cands.count)")
            return
        }

        emit(
            cands[0],
            ARM64.movX0_1,
            patchID: "txm-cfw-get_task_allow",
            description: "get-task-allow: bl -> mov x0,#1",
        )
    }

    /// Selector 42|29 patch via dynamic cave shellcode + branch redirect.
    ///
    /// Shellcode (6 instructions in a zero-filled cave):
    ///   nop                    (safety padding)
    ///   mov x0, #1
    ///   strb w0, [x20, #0x30]
    ///   mov x0, x20
    ///   b   <stub_off + 4>     (return to original flow)
    func patchSelector42_29Shellcode() {
        guard let fn = findDebuggerGateFuncStart() else {
            log("  [-] TXM: debugger-gate function not found (selector42|29)")
            return
        }

        // Find the stub: bti j; mov x0,x20; bl <fn>; mov x1,x21; mov x2,x22; bl <fn>; b ...
        var stubs: [Int] = []
        let size = buffer.count

        var off = 4
        while off + 24 <= size {
            guard
                let p = disasm.disassembleOne(in: buffer.data, at: off - 4),
                let i0 = disasm.disassembleOne(in: buffer.data, at: off),
                let i1 = disasm.disassembleOne(in: buffer.data, at: off + 4),
                let i2 = disasm.disassembleOne(in: buffer.data, at: off + 8),
                let i3 = disasm.disassembleOne(in: buffer.data, at: off + 12),
                let i4 = disasm.disassembleOne(in: buffer.data, at: off + 16),
                let i5 = disasm.disassembleOne(in: buffer.data, at: off + 20)
            else { off += 4; continue }

            guard p.mnemonic == "bti", p.operandString == "j" else { off += 4; continue }
            guard i0.mnemonic == "mov", i0.operandString == "x0, x20" else { off += 4; continue }
            guard i1.mnemonic == "bl" else { off += 4; continue }
            guard i2.mnemonic == "mov", i2.operandString == "x1, x21" else { off += 4; continue }
            guard i3.mnemonic == "mov", i3.operandString == "x2, x22" else { off += 4; continue }
            guard i4.mnemonic == "bl" else { off += 4; continue }
            guard i5.mnemonic == "b" else { off += 4; continue }

            // i4's branch target must point to fn (the debugger-gate function)
            let i4u32 = buffer.readU32(at: off + 16)
            if let tgt = ARM64Encoder.decodeBranchTarget(insn: i4u32, pc: UInt64(off + 16)),
               Int(tgt) == fn
            {
                stubs.append(off)
            }
            off += 4
        }

        guard stubs.count == 1 else {
            log("  [-] TXM: selector42|29 stub expected 1, found \(stubs.count)")
            return
        }
        let stubOff = stubs[0]

        // The flag the shellcode raises is the byte the gate itself tests
        // (`add xT, xObj, #flag ; ldarb wF, [xT] ; tbnz wF, #0`): +0x30 in the
        // 26.x TXMs, +0x20 in the iOS 18 ones, where +0x30 holds a pointer.
        guard let flagStore = debuggerGateFlagStore(fn) else {
            log("  [-] TXM: selector42|29 flag offset not recognised in the debugger gate")
            return
        }

        guard let cave = findUdfCave(minInsns: 6, nearOff: stubOff) else {
            log("  [-] TXM: no UDF cave found for selector42|29 shellcode")
            return
        }

        // Redirect stub entry to shellcode cave
        guard let branchToShellcode = ARM64Encoder.encodeB(from: stubOff, to: cave) else {
            log("  [-] TXM: selector42|29 branch-to-cave encoding failed")
            return
        }
        emit(
            stubOff,
            branchToShellcode,
            patchID: "txm-boot-sel42_29.branch",
            description: "selector42|29: branch to shellcode",
        )

        // Shellcode body at cave
        emit(
            cave,
            ARM64.nop,
            patchID: "txm-boot-sel42_29.shell_nop",
            description: "selector42|29 shellcode pad: udf -> nop",
        )
        emit(
            cave + 4,
            ARM64.movX0_1,
            patchID: "txm-boot-sel42_29.shell_mov1",
            description: "selector42|29 shellcode: mov x0,#1",
        )
        emit(
            cave + 8,
            flagStore.bytes,
            patchID: "txm-boot-sel42_29.shell_strb",
            description: "selector42|29 shellcode: strb w0,[x20,#\(flagStore.label)]",
        )
        emit(
            cave + 12,
            ARM64.movX0X20,
            patchID: "txm-boot-sel42_29.shell_mov20",
            description: "selector42|29 shellcode: mov x0,x20",
        )

        // Branch back to stub_off + 4 (skip the redirected first instruction)
        guard let branchBack = ARM64Encoder.encodeB(from: cave + 16, to: stubOff + 4) else {
            log("  [-] TXM: selector42|29 branch-back encoding failed")
            return
        }
        emit(
            cave + 16,
            branchBack,
            patchID: "txm-boot-sel42_29.shell_ret",
            description: "selector42|29 shellcode: branch back",
        )
    }

    /// Force debugger entitlement check to return true (BL → mov w0, #1).
    ///
    /// Pattern (at BL site):
    ///   [scan-8] mov x0, #0
    ///   [scan-4] mov x2, #0
    ///   [scan+0] bl  <entitlement_check>
    ///   [scan+4] tbnz w0, #0, <...>
    func patchDebuggerEntitlementForceTrue() {
        let refs = findStringRefs(Data("com.apple.private.cs.debugger".utf8))
        guard !refs.isEmpty else {
            log("  [-] TXM: debugger refs not found")
            return
        }

        var cands: [Int] = []
        for (_, _, addOff) in refs {
            let scanEnd = min(addOff + 0x20, buffer.count - 4)
            var scan = addOff
            while scan < scanEnd {
                guard
                    scan >= 8,
                    let i = disasm.disassembleOne(in: buffer.data, at: scan),
                    let n = disasm.disassembleOne(in: buffer.data, at: scan + 4),
                    let p1 = disasm.disassembleOne(in: buffer.data, at: scan - 4),
                    let p2 = disasm.disassembleOne(in: buffer.data, at: scan - 8)
                else { scan += 4; continue }

                if i.mnemonic == "bl",
                   n.mnemonic == "tbnz",
                   n.operandString.hasPrefix("w0, #0,"),
                   p1.mnemonic == "mov", p1.operandString == "x2, #0",
                   p2.mnemonic == "mov", p2.operandString == "x0, #0"
                {
                    cands.append(scan)
                }
                scan += 4
            }
        }

        guard cands.count == 1 else {
            log("  [-] TXM: expected 1 debugger BL site, found \(cands.count)")
            return
        }

        emit(
            cands[0],
            ARM64.movW0_1,
            patchID: "txm-cfw-debugger_entitlement",
            description: "debugger entitlement: bl -> mov w0,#1",
        )
    }

    /// Developer-mode bypass: NOP conditional guard before deny log path.
    ///
    /// Finds `tbz/tbnz/cbz/cbnz w9, #0, <...>` just before the
    /// "developer mode enabled due to system policy configuration" string ref,
    /// then NOPs it.
    func patchDeveloperModeBypass() {
        let needle = "developer mode enabled due to system policy configuration"
        let refs = findStringRefs(Data(needle.utf8))
        guard !refs.isEmpty else {
            log("  [-] TXM: developer-mode string ref not found")
            return
        }

        let guardMnemonics: Set = ["tbz", "tbnz", "cbz", "cbnz"]
        var cands: [Int] = []

        for (_, _, addOff) in refs {
            var back = addOff - 4
            while back > max(addOff - 0x20, 0) {
                guard let ins = disasm.disassembleOne(in: buffer.data, at: back) else { back -= 4; continue }
                if guardMnemonics.contains(ins.mnemonic),
                   ins.operandString.hasPrefix("w9, #0,")
                {
                    cands.append(back)
                }
                back -= 4
            }
        }

        if cands.count == 1 {
            emit(
                cands[0],
                ARM64.nop,
                patchID: "txm-boot-developer_mode_bypass",
                description: "developer mode bypass",
            )
            return
        }

        // iOS 18 compiles the same decision the other way round: the block
        // that enables developer mode by system policy (`mov w, #1` then the
        // string) sits out of line, and `cbz/tbz w9` earlier in the function
        // jumps to it. Making that jump unconditional enables it the same way.
        if cands.isEmpty, let ref = refs.first.map({ $0.addOff }), let fn = findFuncStart(ref) {
            var jumps: [(off: Int, target: Int)] = []
            var scan = fn
            while scan < ref {
                if let ins = disasm.disassembleOne(in: buffer.data, at: scan),
                   ins.mnemonic == "cbz" || ins.mnemonic == "tbz",
                   ins.operandString.hasPrefix("w9,"),
                   let last = ins.detail?.operands.last, last.type == .immediate,
                   case let target = Int(last.imm),
                   target >= ref - 8, target <= ref
                {
                    jumps.append((scan, target))
                }
                scan += 4
            }
            if jumps.count == 1, let b = ARM64Encoder.encodeB(from: jumps[0].off, to: jumps[0].target) {
                emit(
                    jumps[0].off,
                    b,
                    patchID: "txm-boot-developer_mode_bypass",
                    description: "developer mode bypass: always take the system-policy enable",
                )
                return
            }
        }

        log("  [-] TXM: expected 1 developer mode guard, found \(cands.count)")
    }
}
