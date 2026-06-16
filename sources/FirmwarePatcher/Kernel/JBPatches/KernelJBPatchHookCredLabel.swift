// KernelJBPatchHookCredLabel.swift — JB kernel patch: Faithful upstream C23 hook
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.
//
// Strategy (faithful upstream C23): Redirect mac_policy_ops[18]
// (_hook_cred_label_update_execve sandbox wrapper) to a code cave that:
//   1. Saves all argument registers + frame.
//   2. Calls vfs_context_current() to get the vfs context.
//   3. Calls vnode_getattr(vp, vap, ctx) to get owner/mode attributes.
//   4. If VSUID or VSGID bits set: copies owner uid/gid into the pending
//      credential and sets P_SUGID.
//   5. Restores all registers and branches back to the original sandbox wrapper.
//
// The ops[18] entry is an auth-rebase chained pointer. We re-encode it
// preserving PAC metadata but changing the target to our cave address.

import Capstone
import Foundation

extension KernelJBPatcher {
    // MARK: - Constants

    private static let hookCredLabelIndex = 18
    private static let c23CaveWords = 46 // Must match Python _C23_CAVE_WORDS

    // Stable prologue prefix of vfs_context_current (4 words, version-independent).
    // The function reads current_thread() from tpidr_el1, then loads the
    // uthread/uu_context pointer via `ldr x1, [x0, #uthread_off]`. Only that final
    // immediate drifts across versions (0x3E0 on 26.1, 0x3E8 on macOS 26.5.1,
    // 0x3F0 on iOS 26.5), so we match the 4 fixed words exactly and require the
    // 5th to be *any* `ldr x1, [x0, #imm]` — never pinning the version-specific offset.
    private static let vfsContextCurrentPrefix: [UInt32] = [
        ARM64.pacibspU32, // pacibsp
        ARM64.stpFP_LR_pre, // stp x29, x30, [sp, #-0x10]!
        ARM64.movFP_SP, // mov x29, sp
        ARM64.mrs_x0_tpidr_el1, // mrs x0, tpidr_el1
    ]

    // MARK: - Entry Point

    /// Faithful upstream C23: redirect ops[18] to a vnode-getattr trampoline.
    @discardableResult
    func patchHookCredLabelUpdateExecve() -> Bool {
        log("\n[JB] _hook_cred_label_update_execve: faithful upstream C23")

        // 1. Find sandbox ops[18] entry and current wrapper target.
        guard let (opsTable, entryOff, entryRaw, wrapperOff) = findHookCredLabelWrapper() else {
            return false
        }

        // 2. Find vfs_context_current by prologue shape scan.
        let vfsCtxOff = findVfsContextCurrentByShape()
        guard vfsCtxOff >= 0 else {
            log("  [-] vfs_context_current not resolved")
            return false
        }

        // 3. Find vnode_getattr by BL scan near its log string.
        let vnodeGetattrOff = findVnodeGetattrViaString()
        guard vnodeGetattrOff >= 0 else {
            log("  [-] vnode_getattr not resolved")
            return false
        }

        // 4. Allocate code cave for 46 instructions (184 bytes).
        let caveSize = Self.c23CaveWords * 4
        guard let caveOff = findCodeCave(size: caveSize) else {
            log("  [-] no executable code cave found for faithful C23 (\(caveSize) bytes)")
            return false
        }

        // 5. Build the C23 shellcode.
        guard let caveBytes = buildC23Cave(
            caveOff: caveOff,
            vfsContextCurrentOff: vfsCtxOff,
            vnodeGetattrOff: vnodeGetattrOff,
            wrapperOff: wrapperOff
        ) else {
            log("  [-] failed to encode faithful C23 branch/call relocations")
            return false
        }

        // 6. Retarget ops[18] to cave.
        guard let newEntry = encodeAuthRebaseLike(origVal: entryRaw, targetFoff: caveOff) else {
            log("  [-] failed to encode hook ops entry retarget")
            return false
        }

        emit(entryOff, newEntry,
             patchID: "jb.hook_cred_label.ops_retarget",
             description: "retarget ops[\(Self.hookCredLabelIndex)] to faithful C23 cave [_hook_cred_label_update_execve]")

        emit(caveOff, caveBytes,
             patchID: "jb.hook_cred_label.c23_cave",
             description: "faithful upstream C23 cave (vnode getattr -> uid/gid/P_SUGID fixup -> wrapper)")

        _ = opsTable
        return true
    }

    // MARK: - Sandbox Ops Table Finder

    /// Find the sandbox mac_policy_ops table via the mac_policy_conf struct.
    /// Mirrors Python `_find_sandbox_ops_table_via_conf()`: locates the conf
    /// struct by its "Sandbox" + "Seatbelt sandbox policy" string pair, then
    /// reads the mpc_ops pointer at conf+32.
    private func findSandboxOpsTable() -> Int? {
        guard let seatbeltOff = buffer.findString("Seatbelt sandbox policy") else {
            log("  [-] Sandbox/Seatbelt strings not found")
            return nil
        }
        // Find "\0Sandbox\0" and return offset of 'S'
        guard let sandboxPattern = "\u{0}Sandbox\u{0}".data(using: .utf8),
              let sandboxRange = buffer.data.range(of: sandboxPattern)
        else {
            log("  [-] Sandbox string not found")
            return nil
        }
        let sandboxOff = sandboxRange.lowerBound + 1 // skip leading NUL

        // Collect __DATA_CONST and __DATA segment ranges.
        var dataRanges: [(Int, Int)] = []
        for seg in segments {
            if seg.name == "__DATA_CONST" || seg.name == "__DATA", seg.fileSize > 0 {
                let s = Int(seg.fileOffset)
                dataRanges.append((s, s + Int(seg.fileSize)))
            }
        }

        for (dStart, dEnd) in dataRanges {
            var i = dStart
            while i <= dEnd - 40 {
                defer { i += 8 }
                let val = buffer.readU64(at: i)
                if val == 0 || (val & (1 << 63)) != 0 { continue }
                guard (val & 0x7FF_FFFF_FFFF) == UInt64(sandboxOff) else { continue }

                let val2 = buffer.readU64(at: i + 8)
                if (val2 & (1 << 63)) != 0 { continue }
                guard (val2 & 0x7FF_FFFF_FFFF) == UInt64(seatbeltOff) else { continue }

                let valOps = buffer.readU64(at: i + 32)
                if (valOps & (1 << 63)) == 0 {
                    let opsOff = Int(valOps & 0x7FF_FFFF_FFFF)
                    log("  [+] mac_policy_conf at foff 0x\(String(format: "%X", i)), mpc_ops -> 0x\(String(format: "%X", opsOff))")
                    return opsOff
                }
            }
        }

        log("  [-] mac_policy_conf not found")
        return nil
    }

    /// Find the sandbox ops[18] wrapper, returning (opsTable, entryOff, entryRaw, wrapperOff).
    private func findHookCredLabelWrapper() -> (Int, Int, UInt64, Int)? {
        guard let opsTable = findSandboxOpsTable() else {
            log("  [-] sandbox ops table not found")
            return nil
        }

        let entryOff = opsTable + Self.hookCredLabelIndex * 8
        guard entryOff + 8 <= buffer.count else {
            log("  [-] hook ops entry outside file")
            return nil
        }

        let entryRaw = buffer.readU64(at: entryOff)
        guard entryRaw != 0 else {
            log("  [-] hook ops entry is null")
            return nil
        }
        guard (entryRaw & (1 << 63)) != 0 else {
            log("  [-] hook ops entry is not auth-rebase encoded: 0x\(String(format: "%016X", entryRaw))")
            return nil
        }

        let wrapperOff = decodeChainedPtr(entryRaw)
        guard wrapperOff >= 0 else {
            log("  [-] decoded wrapper target invalid: 0x\(String(format: "%X", Int(entryRaw & 0x3FFF_FFFF)))")
            return nil
        }
        let inCode = codeRanges.contains { wrapperOff >= $0.start && wrapperOff < $0.end }
        guard inCode else {
            log("  [-] wrapper target not in code range: 0x\(String(format: "%X", wrapperOff))")
            return nil
        }

        log("  [+] hook cred-label wrapper ops[\(Self.hookCredLabelIndex)] entry 0x\(String(format: "%X", entryOff)) -> 0x\(String(format: "%X", wrapperOff))")
        return (opsTable, entryOff, entryRaw, wrapperOff)
    }

    // MARK: - vfs_context_current Finder

    /// Locate vfs_context_current generically: prefer the symbol, else match the
    /// stable 4-word prologue prefix followed by *any* `ldr x1, [x0, #imm]` (the
    /// uthread offset is version-specific and deliberately left unpinned).
    private func findVfsContextCurrentByShape() -> Int {
        let cacheKey = "c23_vfs_context_current"
        if let cached = jbScanCache[cacheKey] { return cached }

        // Symbol fast-path (version-independent; this research kernel is stripped here, but free + future-proof).
        if let sym = resolveSymbol("_vfs_context_current"),
           codeRanges.contains(where: { sym >= $0.start && sym < $0.end })
        {
            log("  [+] vfs_context_current body at 0x\(String(format: "%X", sym)) (symbol)")
            jbScanCache[cacheKey] = sym
            return sym
        }

        guard let (ks, ke) = kernTextRange else {
            jbScanCache[cacheKey] = -1
            return -1
        }
        let pre = Self.vfsContextCurrentPrefix
        var hits: [Int] = []

        var off = ks
        while off + (pre.count + 1) * 4 <= ke {
            var match = true
            for i in 0 ..< pre.count {
                if buffer.readU32(at: off + i * 4) != pre[i] {
                    match = false
                    break
                }
            }
            // 5th word must load the uthread/uu_context ptr: `ldr x1, [x0, #imm]` (imm unpinned).
            let w5 = buffer.readU32(at: off + pre.count * 4)
            if match, ARM64Inst.isLDRImm64(w5), ARM64Inst.rn(w5) == 0, ARM64Inst.rd(w5) == 1 {
                hits.append(off)
            }
            off += 4
        }

        let result = hits.count == 1 ? hits[0] : -1
        if result >= 0 {
            log("  [+] vfs_context_current body at 0x\(String(format: "%X", result)) (prologue shape)")
        } else {
            log("  [-] vfs_context_current shape scan ambiguous (\(hits.count) hits)")
        }
        jbScanCache[cacheKey] = result
        return result
    }

    // MARK: - vnode_getattr Finder

    /// Resolve vnode_getattr from a BL near its log string "vnode_getattr".
    private func findVnodeGetattrViaString() -> Int {
        guard let strOff = buffer.findString("vnode_getattr") else { return -1 }

        // Scan for references to this and nearby instances
        var searchStart = strOff
        for _ in 0 ..< 6 {
            let refs = findStringRefs(searchStart)
            if let ref = refs.first {
                let refOff = ref.adrpOff
                // Python scans backward from the string ref so we prefer the
                // nearest call site rather than the first BL in the window.
                var scanOff = refOff - 4
                let scanLimit = max(0, refOff - 80)
                while scanOff >= scanLimit {
                    let insn = buffer.readU32(at: scanOff)
                    if insn >> 26 == 0b100101 { // BL
                        let imm26 = insn & 0x03FF_FFFF
                        let signedImm = Int32(bitPattern: imm26 << 6) >> 6
                        let target = scanOff + Int(signedImm) * 4
                        let inCode = codeRanges.contains { target >= $0.start && target < $0.end }
                        if inCode {
                            log("  [+] vnode_getattr at 0x\(String(format: "%X", target)) (via BL at 0x\(String(format: "%X", scanOff)))")
                            return target
                        }
                    }
                    scanOff -= 4
                }
            }
            // Try next occurrence
            guard let nextOff = buffer.findString("vnode_getattr", from: searchStart + 1) else { break }
            searchStart = nextOff
        }
        return -1
    }

    // MARK: - C23 Cave Builder

    /// Build the faithful upstream C23 shellcode (exactly 46 instructions = 184 bytes).
    ///
    /// Layout (instruction offsets from caveOff):
    ///   0: nop
    ///   1: cbz x3, #0xa8       (skip if arg3=vp is null)
    ///   2: sub sp, sp, #0x400
    ///   3: stp x29, x30, [sp]
    ///   4: stp x0, x1, [sp, #0x10]
    ///   5: stp x2, x3, [sp, #0x20]
    ///   6: stp x4, x5, [sp, #0x30]
    ///   7: stp x6, x7, [sp, #0x40]
    ///   8: nop
    ///   9: bl vfs_context_current   (position-dependent)
    ///  10: mov x2, x0
    ///  11: ldr x0, [sp, #0x28]     (vp = saved x3)
    ///  12: add x1, sp, #0x80       (vap = &stack_vap)
    ///  13: mov w8, #0x380          (va_supported bitmask)
    ///  14: stp xzr, x8, [x1]      (vap->va_active = 0, vap->va_supported = 0x380)
    ///  15: stp xzr, xzr, [x1, #0x10]
    ///  16: nop
    ///  17: bl vnode_getattr         (position-dependent)
    ///  18: cbnz x0, #0x4c          (skip fixup on error)
    ///  19: mov w2, #0
    ///  20: ldr w8, [sp, #0xcc]     (vap + offset for va_mode bits)
    ///  21: tbz w8, #0xb, #0x14
    ///  22: ldr w8, [sp, #0xc4]
    ///  23: ldr x0, [sp, #0x18]     (new ucred*)
    ///  24: str w8, [x0, #0x18]     (ucred->cr_uid)
    ///  25: mov w2, #1
    ///  26: ldr w8, [sp, #0xcc]
    ///  27: tbz w8, #0xa, #0x14
    ///  28: mov w2, #1
    ///  29: ldr w8, [sp, #0xc8]
    ///  30: ldr x0, [sp, #0x18]
    ///  31: str w8, [x0, #0x28]     (ucred->cr_gid)
    ///  32: cbz w2, #0x14           (if nothing changed, skip P_SUGID)
    ///  33: ldr x0, [sp, #0x20]     (proc*)
    ///  34: ldr w8, [x0, #0x454]
    ///  35: orr w8, w8, #0x100      (set P_SUGID)
    ///  36: str w8, [x0, #0x454]
    ///  37: ldp x0, x1, [sp, #0x10]
    ///  38: ldp x2, x3, [sp, #0x20]
    ///  39: ldp x4, x5, [sp, #0x30]
    ///  40: ldp x6, x7, [sp, #0x40]
    ///  41: ldp x29, x30, [sp]
    ///  42: add sp, sp, #0x400
    ///  43: nop
    ///  44: b wrapperOff             (position-dependent)
    ///  45: nop
    private func buildC23Cave(
        caveOff: Int,
        vfsContextCurrentOff: Int,
        vnodeGetattrOff: Int,
        wrapperOff: Int
    ) -> Data? {
        var code: [Data] = []

        // 0: nop
        code.append(ARM64.nop)
        // 1: cbz x3, #0xa8  (skip entire body = 42 instructions forward)
        code.append(encodeU32(ARM64.c23_cbzX3_0xA8))
        // 2: sub sp, sp, #0x400
        code.append(encodeU32(ARM64.c23_subSP_0x400))
        // 3: stp x29, x30, [sp]
        code.append(encodeU32(ARM64.c23_stpFP_LR))
        // 4: stp x0, x1, [sp, #0x10]
        code.append(encodeU32(ARM64.c23_stpX0X1_0x10))
        // 5: stp x2, x3, [sp, #0x20]
        code.append(encodeU32(ARM64.c23_stpX2X3_0x20))
        // 6: stp x4, x5, [sp, #0x30]
        code.append(encodeU32(ARM64.c23_stpX4X5_0x30))
        // 7: stp x6, x7, [sp, #0x40]
        code.append(encodeU32(ARM64.c23_stpX6X7_0x40))
        // 8: nop
        code.append(ARM64.nop)

        // 9: bl vfs_context_current
        let blVfsOff = caveOff + code.count * 4
        guard let blVfs = encodeBL(from: blVfsOff, to: vfsContextCurrentOff) else { return nil }
        code.append(blVfs)

        // 10: mov x2, x0
        code.append(encodeU32(ARM64.c23_movX2_X0))
        // 11: ldr x0, [sp, #0x28]   (saved x3 = vp)
        code.append(encodeU32(ARM64.c23_ldrX0_sp_0x28))
        // 12: add x1, sp, #0x80
        code.append(encodeU32(ARM64.c23_addX1_sp_0x80))
        // 13: mov w8, #0x380
        code.append(encodeU32(ARM64.c23_movzW8_0x380))
        // 14: stp xzr, x8, [x1]
        code.append(encodeU32(ARM64.c23_stpXZR_X8))
        // 15: stp xzr, xzr, [x1, #0x10]
        code.append(encodeU32(ARM64.c23_stpXZR_XZR_0x10))
        // 16: nop
        code.append(ARM64.nop)

        // 17: bl vnode_getattr
        let blGetAttrOff = caveOff + code.count * 4
        guard let blGetAttr = encodeBL(from: blGetAttrOff, to: vnodeGetattrOff) else { return nil }
        code.append(blGetAttr)

        // 18: cbnz x0, #0x4c  (skip 19 instructions)
        code.append(encodeU32(ARM64.c23_cbnzX0_0x4c))
        // 19: mov w2, #0
        code.append(encodeU32(ARM64.c23_movW2_0))
        // 20: ldr w8, [sp, #0xcc]
        code.append(encodeU32(ARM64.c23_ldrW8_sp_0xcc))
        // 21: tbz w8, #0xb, #0x14  (skip 5 instrs)
        code.append(encodeU32(ARM64.c23_tbzW8_11_0x14))
        // 22: ldr w8, [sp, #0xc4]
        code.append(encodeU32(ARM64.c23_ldrW8_sp_0xc4))
        // 23: ldr x0, [sp, #0x18]
        code.append(encodeU32(ARM64.c23_ldrX0_sp_0x18))
        // 24: str w8, [x0, #0x18]
        code.append(encodeU32(ARM64.c23_strW8_x0_0x18))
        // 25: mov w2, #1
        code.append(encodeU32(ARM64.c23_movW2_1))
        // 26: ldr w8, [sp, #0xcc]
        code.append(encodeU32(ARM64.c23_ldrW8_sp_0xcc))
        // 27: tbz w8, #0xa, #0x14  (skip 5 instrs)
        code.append(encodeU32(ARM64.c23_tbzW8_10_0x14))
        // 28: mov w2, #1
        code.append(encodeU32(ARM64.c23_movW2_1))
        // 29: ldr w8, [sp, #0xc8]
        code.append(encodeU32(ARM64.c23_ldrW8_sp_0xc8))
        // 30: ldr x0, [sp, #0x18]
        code.append(encodeU32(ARM64.c23_ldrX0_sp_0x18))
        // 31: str w8, [x0, #0x28]
        code.append(encodeU32(ARM64.c23_strW8_x0_0x28))
        // 32: cbz w2, #0x14  (skip 5 instrs)
        code.append(encodeU32(ARM64.c23_cbzW2_0x14))
        // 33: ldr x0, [sp, #0x20]
        code.append(encodeU32(ARM64.c23_ldrX0_sp_0x20))
        // 34: ldr w8, [x0, #0x454]
        code.append(encodeU32(ARM64.c23_ldrW8_x0_0x454))
        // 35: orr w8, w8, #0x100
        code.append(encodeU32(ARM64.c23_orrW8_0x100))
        // 36: str w8, [x0, #0x454]
        code.append(encodeU32(ARM64.c23_strW8_x0_0x454))
        // 37: ldp x0, x1, [sp, #0x10]
        code.append(encodeU32(ARM64.c23_ldpX0X1_0x10))
        // 38: ldp x2, x3, [sp, #0x20]
        code.append(encodeU32(ARM64.c23_ldpX2X3_0x20))
        // 39: ldp x4, x5, [sp, #0x30]
        code.append(encodeU32(ARM64.c23_ldpX4X5_0x30))
        // 40: ldp x6, x7, [sp, #0x40]
        code.append(encodeU32(ARM64.c23_ldpX6X7_0x40))
        // 41: ldp x29, x30, [sp]
        code.append(encodeU32(ARM64.c23_ldpFP_LR))
        // 42: add sp, sp, #0x400
        code.append(encodeU32(ARM64.c23_addSP_0x400))
        // 43: nop
        code.append(ARM64.nop)

        // 44: b wrapperOff
        let branchBackOff = caveOff + code.count * 4
        guard let branchBack = encodeB(from: branchBackOff, to: wrapperOff) else { return nil }
        code.append(branchBack)

        // 45: nop
        code.append(ARM64.nop)

        guard code.count == Self.c23CaveWords else {
            log("  [-] C23 cave length drifted: \(code.count) insns, expected \(Self.c23CaveWords)")
            return nil
        }
        return code.reduce(Data(), +)
    }

    // MARK: - Auth-Rebase Pointer Encoder

    /// Retarget an auth-rebase chained pointer while preserving PAC metadata.
    private func encodeAuthRebaseLike(origVal: UInt64, targetFoff: Int) -> Data? {
        guard (origVal & (1 << 63)) != 0 else { return nil }
        // Preserve all bits above bit 31, replace the low 32 bits with target foff
        let newVal = (origVal & ~UInt64(0xFFFF_FFFF)) | (UInt64(targetFoff) & 0xFFFF_FFFF)
        return withUnsafeBytes(of: newVal.littleEndian) { Data($0) }
    }

    // MARK: - Encoding Helper

    private func encodeU32(_ value: UInt32) -> Data {
        ARM64.encodeU32(value)
    }
}
