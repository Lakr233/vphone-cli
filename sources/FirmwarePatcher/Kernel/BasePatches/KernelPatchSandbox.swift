// KernelPatchSandbox.swift — Sandbox MACF hook patches (10 patches).
//
// Stubs 5 Sandbox hook functions with: mov x0,#0; ret
// so that sandbox policy operations always succeed.
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.
// Algorithm:
//   1. Find the Sandbox mac_policy_conf struct by locating the "Sandbox" and
//      "Seatbelt sandbox policy" strings and scanning __DATA/__DATA_CONST for a
//      pointer pair that references them. The ops pointer lives at offset +32.
//   2. Discover the Sandbox kext __text range via __PRELINK_INFO so that
//      each function pointer can be validated before patching.
//   3. For each of the 5 hook indices in the mac_policy_ops table, decode the
//      chained fixup pointer and emit: mov x0,#0; ret.
//
// Hook indices (XNU xnu-11215+ mac_policy_ops struct):
//   file_check_mmap   → index 36
//   mount_check_mount → index 87
//   mount_check_remount → index 88
//   mount_check_umount  → index 91
//   vnode_check_rename  → index 120

import Foundation

extension KernelPatcher {
    // MARK: - Public Entry Point

    /// Patches 17-26: stub Sandbox MACF hooks with mov x0,#0; ret.
    @discardableResult
    func patchSandbox() -> Bool {
        log("\n[17-26] Sandbox MACF hooks")

        guard let opsTableOff = findSandboxOpsTable() else {
            return false
        }

        let sandboxRange = discoverSandboxTextRange()

        let hooks: [(name: String, index: Int)] = [
            ("file_check_mmap", 36),
            ("mount_check_mount", 87),
            ("mount_check_remount", 88),
            ("mount_check_umount", 91),
            ("vnode_check_rename", 120),
        ]

        var patchedCount = 0

        for hook in hooks {
            let entryOff = opsTableOff + hook.index * 8
            guard entryOff + 8 <= buffer.count else {
                log("  [-] ops[\(hook.index)] \(hook.name): offset out of bounds")
                continue
            }

            let raw = buffer.readU64(at: entryOff)
            let funcOff = decodeChainedPtr(raw)

            guard funcOff >= 0 else {
                log("  [-] ops[\(hook.index)] \(hook.name): NULL or invalid (raw=0x\(String(format: "%X", raw)))")
                continue
            }

            if let range = sandboxRange {
                guard funcOff >= range.start, funcOff < range.end else {
                    log("  [-] ops[\(hook.index)] \(hook.name): foff 0x\(String(format: "%X", funcOff)) outside Sandbox (0x\(String(format: "%X", range.start))-0x\(String(format: "%X", range.end)))")
                    continue
                }
            }

            let va = fileOffsetToVA(funcOff)
            emit(
                funcOff,
                ARM64.movX0_0,
                patchID: "kernel.sandbox.\(hook.name).mov_x0_0",
                virtualAddress: va,
                description: "mov x0,#0 [_hook_\(hook.name)]",
            )
            emit(
                funcOff + 4,
                ARM64.ret,
                patchID: "kernel.sandbox.\(hook.name).ret",
                virtualAddress: va.map { $0 + 4 },
                description: "ret [_hook_\(hook.name)]",
            )

            log("  [+] ops[\(hook.index)] \(hook.name) at foff 0x\(String(format: "%X", funcOff))")
            patchedCount += 1
        }

        return patchedCount > 0
    }

    // MARK: - mac_policy_conf / ops table discovery

    /// Find the Sandbox mac_policy_ops table via the mac_policy_conf struct.
    ///
    /// Strategy (aligned with Python _find_sandbox_ops_table_via_conf):
    ///   - Locate the "Sandbox" C string (preceded by a NUL byte) and
    ///     "Seatbelt sandbox policy" C string in the binary.
    ///   - Scan __DATA_CONST and __DATA segments for non-auth chained fixup
    ///     pointers where the low 43 bits match the string file offsets.
    ///   - The mpc_ops pointer is at offset +32 from the start of the struct,
    ///     also decoded from the low 43 bits.
    private func findSandboxOpsTable() -> Int? {
        log("  [*] Finding Sandbox mac_policy_ops via mac_policy_conf...")

        // Find "Sandbox\0" — search for \0Sandbox\0 so we get the exact symbol string.
        guard let sandboxRawOff = findNulPrefixedString("Sandbox") else {
            log("  [-] Sandbox string not found")
            return nil
        }

        // Find "Seatbelt sandbox policy\0"
        guard let seatbeltOff = buffer.findString("Seatbelt sandbox policy") else {
            log("  [-] Seatbelt sandbox policy string not found")
            return nil
        }

        log("  [*] Sandbox string at foff 0x\(String(format: "%X", sandboxRawOff)), Seatbelt at 0x\(String(format: "%X", seatbeltOff))")

        // Scan data segments for the mac_policy_conf struct.
        // Python approach: skip auth pointers (bit63=1), match low 43 bits directly
        // against file offsets for non-auth chained fixup pointers.
        for seg in segments {
            guard seg.name == "__DATA_CONST" || seg.name == "__DATA" else { continue }
            guard seg.fileSize > 40 else { continue }

            let segStart = Int(seg.fileOffset)
            let segEnd = segStart + Int(seg.fileSize)

            var i = segStart
            while i + 40 <= segEnd {
                let val0 = buffer.readU64(at: i)

                // Skip zero and auth pointers
                guard val0 != 0, val0 & (1 << 63) == 0 else {
                    i += 8
                    continue
                }

                // Check if low 43 bits match sandbox string offset
                guard Int(val0 & 0x7FF_FFFF_FFFF) == sandboxRawOff else {
                    i += 8
                    continue
                }

                // Next 8 bytes should point to "Seatbelt sandbox policy"
                let val1 = buffer.readU64(at: i + 8)
                guard val1 & (1 << 63) == 0,
                      Int(val1 & 0x7FF_FFFF_FFFF) == seatbeltOff
                else {
                    i += 8
                    continue
                }

                // mpc_ops is at offset +32, also decode low 43 bits
                let opsVal = buffer.readU64(at: i + 32)
                guard opsVal & (1 << 63) == 0 else {
                    i += 8
                    continue
                }
                let opsOff = Int(opsVal & 0x7FF_FFFF_FFFF)
                guard opsOff > 0, opsOff < buffer.count else {
                    i += 8
                    continue
                }

                log("  [+] mac_policy_conf at foff 0x\(String(format: "%X", i)), mpc_ops -> 0x\(String(format: "%X", opsOff))")
                return opsOff
            }
        }

        log("  [-] mac_policy_conf not found")
        return nil
    }

    // MARK: - Sandbox kext text range

    /// Discover the Sandbox kext __text range via __PRELINK_INFO.
    /// Returns nil if not found (patching will skip range validation).
    private func discoverSandboxTextRange() -> (start: Int, end: Int)? {
        // Find __PRELINK_INFO segment
        guard let prelinkSeg = segments.first(where: { $0.name == "__PRELINK_INFO" }),
              prelinkSeg.fileSize > 0
        else {
            return nil
        }

        let prelinkStart = Int(prelinkSeg.fileOffset)
        let prelinkEnd = prelinkStart + Int(prelinkSeg.fileSize)
        guard prelinkEnd <= buffer.count else { return nil }

        let prelinkData = buffer.data[prelinkStart ..< prelinkEnd]

        // Find the XML plist within the segment
        guard let xmlStart = prelinkData.range(of: Data("<?xml".utf8)),
              let plistEnd = prelinkData.range(of: Data("</plist>".utf8))
        else {
            return nil
        }

        let xmlRange = xmlStart.lowerBound ..< (plistEnd.upperBound)
        let xmlData = prelinkData[xmlRange]

        guard let plist = try? PropertyListSerialization.propertyList(
            from: Data(xmlData),
            format: nil
        ) as? [String: Any],
              let items = plist["_PrelinkInfoDictionary"] as? [[String: Any]]
        else {
            return nil
        }

        for item in items {
            guard let bid = item["CFBundleIdentifier"] as? String,
                  bid == "com.apple.security.sandbox"
            else {
                continue
            }

            // _PrelinkExecutableLoadAddr is the kext's load address
            guard let loadAddrRaw = item["_PrelinkExecutableLoadAddr"],
                  let loadAddrInt = (loadAddrRaw as? UInt64)
                      ?? (loadAddrRaw as? Int).map({ UInt64(bitPattern: Int64($0)) })
            else {
                continue
            }

            let loadAddr = loadAddrInt & 0xFFFF_FFFF_FFFF_FFFF
            guard loadAddr > baseVA else { continue }
            let kextFoff = Int(loadAddr - baseVA)
            guard kextFoff >= 0, kextFoff < buffer.count else { continue }

            if let range = parseKextTextRange(at: kextFoff) {
                log("  [*] Sandbox __text: 0x\(String(format: "%X", range.start))-0x\(String(format: "%X", range.end))")
                return range
            }
        }

        return nil
    }

    /// Parse an embedded kext Mach-O at the given file offset and return its
    /// __TEXT_EXEC.__text (or __TEXT_EXEC segment) range in file offsets.
    private func parseKextTextRange(at kextFoff: Int) -> (start: Int, end: Int)? {
        guard kextFoff + 32 <= buffer.count else { return nil }

        let magic = buffer.readU32(at: kextFoff)
        guard magic == 0xFEED_FACF else { return nil } // MH_MAGIC_64

        let ncmds = buffer.data.loadLE(UInt32.self, at: kextFoff + 16)
        var off = kextFoff + 32

        for _ in 0 ..< ncmds {
            guard off + 8 <= buffer.count else { break }
            let cmd = buffer.data.loadLE(UInt32.self, at: off)
            let cmdsize = buffer.data.loadLE(UInt32.self, at: off + 4)
            guard cmdsize >= 8, cmdsize < 0x10000 else { break }

            if cmd == 0x19 { // LC_SEGMENT_64
                let segNameData = buffer.data[off + 8 ..< min(off + 24, buffer.count)]
                let segName = String(data: segNameData, encoding: .utf8)?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""

                if segName == "__TEXT_EXEC" {
                    let vmAddr = buffer.data.loadLE(UInt64.self, at: off + 24)
                    let fileSize = buffer.data.loadLE(UInt64.self, at: off + 48)
                    let nsects = buffer.data.loadLE(UInt32.self, at: off + 64)

                    // Search sections for __text
                    var sectOff = off + 72
                    for _ in 0 ..< nsects {
                        guard sectOff + 80 <= buffer.count else { break }
                        let sectNameData = buffer.data[sectOff ..< min(sectOff + 16, buffer.count)]
                        let sectName = String(data: sectNameData, encoding: .utf8)?
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

                    // Fallback: use the segment itself
                    guard vmAddr >= baseVA else { break }
                    let segFoff = Int(vmAddr - baseVA)
                    return (segFoff, segFoff + Int(fileSize))
                }
            }
            off += Int(cmdsize)
        }
        return nil
    }

    // MARK: - Pointer helpers

    /// Decode an arm64e chained fixup pointer to a file offset.
    ///
    /// - auth rebase (bit63 = 1): foff = bits[31:0]
    /// - non-auth rebase (bit63 = 0): VA = (bits[50:43] << 56) | bits[42:0]
    private func decodeChainedPtr(_ val: UInt64) -> Int {
        guard val != 0 else { return -1 }
        if val & (1 << 63) != 0 {
            // Authenticated rebase: lower 32 bits are file offset
            return Int(val & 0xFFFF_FFFF)
        } else {
            // Non-authenticated rebase: reconstruct VA
            let low43 = val & 0x7FF_FFFF_FFFF
            let high8 = (val >> 43) & 0xFF
            let fullVA = (high8 << 56) | low43
            guard fullVA > baseVA else { return -1 }
            return Int(fullVA - baseVA)
        }
    }

    /// Resolve a 64-bit data pointer to a file offset, trying both chained
    /// fixup decoding and a plain (VA − baseVA) conversion.
    private func resolvePointerToFileOffset(_ val: UInt64) -> Int? {
        guard val != 0 else { return nil }

        // Try chained fixup first
        let decoded = decodeChainedPtr(val)
        if decoded > 0, decoded < buffer.count {
            return decoded
        }

        // Try plain VA → file offset
        if val > baseVA {
            let foff = Int(val - baseVA)
            if foff >= 0, foff < buffer.count {
                return foff
            }
        }

        return nil
    }

    /// Find a NUL-prefixed string (i.e. the exact C symbol "Sandbox" at a NUL boundary).
    /// Returns the file offset of the first character (after the NUL).
    private func findNulPrefixedString(_ string: String) -> Int? {
        guard let encoded = string.data(using: .utf8) else { return nil }
        var pattern = Data([0]) // NUL prefix
        pattern.append(contentsOf: encoded)
        pattern.append(0) // NUL terminator

        if let range = buffer.data.range(of: pattern) {
            return range.lowerBound + 1 // skip leading NUL
        }
        return nil
    }
}
