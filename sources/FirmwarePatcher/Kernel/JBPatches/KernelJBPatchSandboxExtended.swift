// KernelJBPatchSandboxExtended.swift — JB kernel patch: Extended sandbox hooks bypass
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.
//
// Strategy (ops-table retargeting — matches upstream patch_fw.py):
//   1. Locate mac_policy_conf via the "Seatbelt sandbox policy" and "Sandbox" strings
//      in __DATA_CONST / __DATA segments. The conf struct at offset +32 holds a tagged
//      pointer to mac_policy_ops.
//   2. Find the common Sandbox allow stub (mov x0,#0 ; ret) — the highest-address
//      instance in sandbox text is the canonical one.
//   3. For each extended hook index (201–316), read the 8-byte tagged pointer from
//      ops_table + index * 8, retarget its low 32 bits to allow_stub while preserving
//      the high 32 bits (PAC/auth-rebase metadata), and emit the new value.

import Foundation

extension KernelJBPatcher {
    /// Extended sandbox hooks bypass: retarget ops entries to the allow stub.
    @discardableResult
    func patchSandboxHooksExtended() -> Bool {
        log("\n[JB] Sandbox extended hooks: retarget ops entries to allow stub")

        guard let opsTable = findSandboxOpsTableViaConf() else {
            return false
        }

        guard let allowStub = findSandboxAllowStub() else {
            log("  [-] common Sandbox allow stub not found")
            return false
        }

        // Extended hook index table (name → ops slot index). Entries 201..316 are the
        // base JB sandbox bypass and apply on every JB base; the iOS-27-only
        // syscall-unix entry (124) is appended below, gated on applyIOS27.
        var hookIndices: [(String, Int)] = [
            ("iokit_check_201", 201),
            ("iokit_check_202", 202),
            ("iokit_check_203", 203),
            ("iokit_check_204", 204),
            ("iokit_check_205", 205),
            ("iokit_check_206", 206),
            ("iokit_check_207", 207),
            ("iokit_check_208", 208),
            ("iokit_check_209", 209),
            ("iokit_check_210", 210),
            ("vnode_check_getattr", 245),
            ("proc_check_get_cs_info", 249),
            ("proc_check_set_cs_info", 250),
            ("proc_check_set_cs_info2", 252),
            ("vnode_check_chroot", 254),
            ("vnode_check_create", 255),
            ("vnode_check_deleteextattr", 256),
            ("vnode_check_exchangedata", 257),
            ("vnode_check_exec", 258),
            ("vnode_check_getattrlist", 259),
            ("vnode_check_getextattr", 260),
            ("vnode_check_ioctl", 261),
            ("vnode_check_link", 264),
            ("vnode_check_listextattr", 265),
            // vnode_check_open (267) is appended conditionally below.
            ("vnode_check_readlink", 270),
            ("vnode_check_setattrlist", 275),
            ("vnode_check_setextattr", 276),
            ("vnode_check_setflags", 277),
            ("vnode_check_setmode", 278),
            ("vnode_check_setowner", 279),
            ("vnode_check_setutimes", 280),
            ("vnode_check_stat", 281),
            ("vnode_check_truncate", 282),
            ("vnode_check_unlink", 283),
            ("vnode_check_fsgetpath", 316),
        ]

        // iOS-27-only: mpo_proc_check_syscall_unix[124] → allow lets the mount_apfs that
        // MobileStorageMounter spawns make the mount(2) syscall (unix 167) for the iOS-27
        // personalized DDI (/System/Developer). Gated so a 26.x base keeps its syscall-unix
        // MAC filter intact (else kernel Sandbox: "Protobox: mount_apfs deny(1) syscall-unix
        // 167"). Index 124 is calibrated against this kernel's mac_policy_ops layout: the
        // vnode_check_open==267 / vnode_check_fsgetpath==316 entries above match the
        // reference XNU struct order exactly, so mpo_proc_check_syscall_unix==124 holds.
        if applyIOS27 {
            hookIndices.append(("proc_check_syscall_unix", 124))
        }

        // On iOS 27, leave ops[267] real so KernelJBPatchFpfsScopedOpen can retarget it to a
        // FileProvider-scoped trampoline (the fpfs walk needs the stock check as its terminus,
        // else ResolverService balloons → respring). Neuter it as usual on every other base.
        if !applyIOS27 {
            hookIndices.append(("vnode_check_open", 267))
        }

        var patched = 0
        for (hookName, idx) in hookIndices {
            let entryOff = opsTable + idx * 8
            guard entryOff + 8 <= buffer.count else { continue }

            let entryRaw = buffer.readU64(at: entryOff)
            guard entryRaw != 0 else { continue }

            guard let newEntry = encodeAuthRebaseLike(origVal: entryRaw, targetOff: allowStub) else {
                continue
            }

            var newBytes = Data(count: 8)
            withUnsafeBytes(of: newEntry.littleEndian) { src in
                newBytes.replaceSubrange(0 ..< 8, with: src)
            }
            emit(entryOff, newBytes,
                 patchID: "sandbox_ext_\(idx)",
                 virtualAddress: nil,
                 description: "ops[\(idx)] -> allow stub [_hook_\(hookName)]")
            patched += 1
        }

        if patched == 0 {
            log("  [-] no extended sandbox hooks retargeted")
            return false
        }
        return true
    }

    // MARK: - Sandbox ops table discovery

    /// Locate the Sandbox mac_policy_ops table via mac_policy_conf.
    ///
    /// Searches __DATA_CONST and __DATA segments for the conf struct:
    ///   [0..7]  tagged ptr → "Sandbox\0"
    ///   [8..15] tagged ptr → "Seatbelt sandbox policy\0"
    ///   [32..39] tagged ptr → mac_policy_ops table
    private func findSandboxOpsTableViaConf() -> Int? {
        log("\n[*] Finding Sandbox mac_policy_ops via mac_policy_conf...")

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

        log("  [*] Sandbox string at foff 0x\(String(format: "%X", sandboxOff)), Seatbelt at 0x\(String(format: "%X", seatbeltOff))")

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
                // Must not be zero or a tagged (high-bit set) pointer at position [0].
                if val == 0 || (val & (1 << 63)) != 0 { continue }
                // Low 43 bits must point to sandboxOff (auth-rebase chained ptr format).
                guard (val & 0x7FF_FFFF_FFFF) == UInt64(sandboxOff) else { continue }

                let val2 = buffer.readU64(at: i + 8)
                if (val2 & (1 << 63)) != 0 { continue }
                guard (val2 & 0x7FF_FFFF_FFFF) == UInt64(seatbeltOff) else { continue }

                // Offset +32: tagged ptr to mac_policy_ops.
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

    // MARK: - Allow stub discovery

    /// Find the Sandbox common allow stub: `mov x0, #0 ; ret`.
    ///
    /// Scans sandbox kext text for consecutive MOV_X0_0 + RET pairs and returns
    /// the highest-address hit (matches upstream patch_fw.py choice).
    private func findSandboxAllowStub() -> Int? {
        // Use the Sandbox kext's __TEXT_EXEC.__text range (matches Python self.sandbox_text).
        let sbRange = sandboxTextRange()
        let (sbStart, sbEnd) = (sbRange.start, sbRange.end)

        var hits: [Int] = []
        var off = sbStart
        while off < sbEnd - 8 {
            if buffer.readU32(at: off) == ARM64.movX0_0_U32,
               buffer.readU32(at: off + 4) == ARM64.retU32
            {
                hits.append(off)
            }
            off += 4
        }

        guard let stub = hits.max() else { return nil }
        log("  [+] common Sandbox allow stub at 0x\(String(format: "%X", stub))")
        return stub
    }

    // MARK: - Auth-rebase pointer retargeting

    /// Retarget an auth-rebase chained pointer while preserving PAC metadata.
    ///
    /// Auth-rebase format (high bit set): [63]=1, [62:32]=auth/diversity bits, [31:0]=target
    /// Replace the low 32 bits with the new target offset.
    private func encodeAuthRebaseLike(origVal: UInt64, targetOff: Int) -> UInt64? {
        // Must be a tagged (auth) pointer — bit 63 must be set.
        guard (origVal & (1 << 63)) != 0 else { return nil }
        let highBits = origVal & 0xFFFF_FFFF_0000_0000
        let newLow = UInt64(targetOff) & 0xFFFF_FFFF
        return highBits | newLow
    }
}
