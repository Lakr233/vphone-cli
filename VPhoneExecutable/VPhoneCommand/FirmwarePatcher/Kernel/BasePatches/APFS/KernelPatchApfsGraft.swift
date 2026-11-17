// KernelPatchApfsGraft.swift — APFS graft patch (patch 12).
//
// Neutralizes root hash validation inside _apfs_graft by replacing the BL
// to validate_on_disk_root_hash with MOV W0, #0.
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.

import Foundation
import VPhonePatchKit

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
        guard !refs.isEmpty else {
            log("  [-] no code refs to 'apfs_graft'")
            return false
        }

        // Step 3: Locate validate_on_disk_root_hash via its own __FUNCTION__ string.
        guard let vrhFunc = findValidateRootHashFunc() else {
            log("  [-] validate_on_disk_root_hash not found")
            return false
        }

        // Step 4: The string names the routine in its own log lines, but other apfs
        // routines name it too (_handle_fsioc_graft logs about grafting), so the
        // first reference is not necessarily inside _apfs_graft — on 27.2 it is not.
        // _apfs_graft is the referencing function that calls the validator, so try
        // each reference and take the one whose body holds that call.
        for ref in refs {
            guard let graftStart = findFunctionStart(ref.adrpOff) else { continue }

            // Scan the body for a BL to vrhFunc, stopping at the next function.
            let scanEnd = min(graftStart + 0x2000, buffer.count - 4)
            var scan = graftStart
            while scan <= scanEnd {
                if scan > graftStart + 8, buffer.readU32(at: scan) == ARM64.pacibspU32 {
                    break
                }
                if isCall(at: scan, to: vrhFunc) {
                    let va = fileOffsetToVA(scan)
                    emit(
                        scan,
                        ARM64.movW0_0,
                        patchID: "kernel-boot-apfs_graft",
                        virtualAddress: va,
                        description: "mov w0,#0 [_apfs_graft]",
                    )
                    return true
                }
                scan += 4
            }
        }

        log("  [-] BL to validate_on_disk_root_hash not found in _apfs_graft")
        return false
    }

    // MARK: - Helpers

    /// Find validate_on_disk_root_hash by its own `__FUNCTION__` string and the
    /// function that references it.
    ///
    /// apfs renamed that routine between the two kernels — `authenticate_root_hash`
    /// up to 26.x, `validate_root_hash` on 27 — keeping the same slot in the string
    /// table and the same neighbours, so both names are accepted. Neither is a
    /// substring of `validate_on_disk_root_hash`, which also appears, so the search
    /// stays unambiguous.
    private func findValidateRootHashFunc() -> Int? {
        for name in ["authenticate_root_hash", "validate_root_hash"] {
            guard let nameData = name.data(using: .utf8) else { continue }
            var searchData = nameData
            searchData.append(0) // null terminator

            // Try with null terminator first, then without
            var strOff: Int?
            if let range = buffer.data.range(of: searchData) {
                strOff = range.lowerBound
            } else if let range = buffer.data.range(of: nameData) {
                strOff = range.lowerBound
            }
            guard let foundOff = strOff, let firstRef = findStringRefs(foundOff).first else { continue }
            if let start = findFunctionStart(firstRef.adrpOff) { return start }
        }
        return nil
    }
}
