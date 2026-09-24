// KernelPatchApfsGraft.swift — APFS graft patch (patch 12).
//
// Neutralizes root hash validation inside _apfs_graft by replacing the BL
// to validate_on_disk_root_hash with MOV W0, #0.
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.

import Foundation

extension KernelPatcher {
    // MARK: - Patch 12: _apfs_graft

    /// Patch 12: Replace the BL to validate_on_disk_root_hash inside _apfs_graft
    /// with `mov w0, #0`, bypassing root hash validation.
    ///
    /// Strategy:
    /// 1. Locate the `apfs_graft` C string (null-byte bounded) in the binary.
    /// 2. Follow ADRP+ADD references into code to find the _apfs_graft function start.
    /// 3. Locate validate_on_disk_root_hash via the `authenticate_root_hash` string.
    /// 4. Scan _apfs_graft for a BL whose resolved target is validate_on_disk_root_hash.
    /// 5. Emit MOV W0, #0 at that site.
    @discardableResult
    func patchApfsGraft() -> Bool {
        log("\n[12] _apfs_graft: mov w0,#0 (validate_root_hash BL)")

        // Step 1: Find the "apfs_graft" null-terminated C string.
        // Python: exact = self.raw.find(b"\x00apfs_graft\x00"); str_off = exact + 1
        guard let apfsGraftPattern = "apfs_graft".data(using: .utf8) else { return false }
        var nullPrefix = Data([0])
        nullPrefix.append(apfsGraftPattern)
        nullPrefix.append(0)

        guard let exactRange = buffer.data.range(of: nullPrefix) else {
            log("  [-] 'apfs_graft' string not found")
            return false
        }
        let strOff = exactRange.lowerBound + 1 // skip the leading null byte

        // Step 2: Find ADRP+ADD code references to that string.
        let refs = findStringRefs(strOff)
        guard let firstRef = refs.first else {
            log("  [-] no code refs to 'apfs_graft'")
            return false
        }

        // Step 3: Find the function start from the reference site.
        guard let graftStart = findFunctionStart(firstRef.adrpOff) else {
            log("  [-] _apfs_graft function start not found")
            return false
        }

        // Step 4: Locate validate_on_disk_root_hash via the `authenticate_root_hash` string.
        guard let vrhFunc = findValidateRootHashFunc() else {
            log("  [-] validate_on_disk_root_hash not found")
            return false
        }

        // Step 5: Scan _apfs_graft body for a BL whose target is vrhFunc.
        // Stop at PACIBSP (start of a new function). Mirror of Python logic:
        //   for scan in range(graft_start, graft_start + 0x2000, 4):
        //     if scan > graft_start + 8 and rd32(scan) == PACIBSP: break
        //     if _is_bl(scan) == vrh_func: emit(scan, MOV_W0_0, ...)
        let scanEnd = min(graftStart + 0x2000, buffer.count - 4)
        var scan = graftStart
        while scan <= scanEnd {
            if scan > graftStart + 8, buffer.readU32(at: scan) == ARM64.pacibspU32 {
                break
            }
            if let blTarget = decodeBL(at: scan), blTarget == vrhFunc {
                let va = fileOffsetToVA(scan)
                emit(
                    scan,
                    ARM64.movW0_0,
                    patchID: "apfs_graft",
                    virtualAddress: va,
                    description: "mov w0,#0 [_apfs_graft]",
                )
                return true
            }
            scan += 4
        }

        log("  [-] BL to validate_on_disk_root_hash not found in _apfs_graft")
        return false
    }

    // MARK: - Helpers

    /// Find validate_on_disk_root_hash by locating the `authenticate_root_hash` string
    /// and resolving the function that references it.
    private func findValidateRootHashFunc() -> Int? {
        guard let authHashStr = "authenticate_root_hash".data(using: .utf8) else { return nil }
        var searchData = authHashStr
        searchData.append(0) // null terminator

        // Try with null terminator first, then without
        var strOff: Int?
        if let range = buffer.data.range(of: searchData) {
            strOff = range.lowerBound
        } else if let range = buffer.data.range(of: authHashStr) {
            strOff = range.lowerBound
        }
        guard let foundOff = strOff else { return nil }

        let refs = findStringRefs(foundOff)
        guard let firstRef = refs.first else { return nil }

        return findFunctionStart(firstRef.adrpOff)
    }
}
