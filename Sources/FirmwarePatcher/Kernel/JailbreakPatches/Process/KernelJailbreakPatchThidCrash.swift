// KernelJailbreakPatchThidCrash.swift — JB kernel patch: thid_should_crash bypass
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.

import Foundation

extension KernelJailbreakPatcher {
    /// Zero out `_thid_should_crash` via the nearby sysctl metadata.
    ///
    /// The raw PCC 26.1 kernels do not provide a usable runtime symbol table,
    /// so this patch always resolves through the sysctl name string
    /// `thid_should_crash` and the adjacent `sysctl_oid` data.
    @discardableResult
    func patchThidShouldCrash() -> Bool {
        log("\n[JB] _thid_should_crash: zero out")

        guard let strOff = buffer.findString("thid_should_crash") else {
            log("  [-] string not found")
            return false
        }
        log("  [*] string at foff 0x\(String(format: "%X", strOff))")

        // Find DATA_CONST ranges for validation
        let dataConstRanges: [(Int, Int)] = segments.compactMap { seg in
            guard seg.name == "__DATA_CONST", seg.fileSize > 0 else { return nil }
            return (Int(seg.fileOffset), Int(seg.fileOffset + seg.fileSize))
        }
        let dataRanges: [(Int, Int)] = segments.compactMap { seg in
            guard seg.name.contains("DATA"), seg.fileSize > 0 else { return nil }
            return (Int(seg.fileOffset), Int(seg.fileOffset + seg.fileSize))
        }

        // Scan up to 128 bytes forward from string for a sysctl_oid pointer
        for delta in stride(from: 0, through: 128, by: 8) {
            let check = strOff + delta
            guard check + 8 <= buffer.count else { break }
            let val = buffer.readU64(at: check)
            guard val != 0 else { continue }
            let low32 = Int(val & 0xFFFF_FFFF)
            guard low32 > 0, low32 < buffer.count else { continue }
            let targetVal = buffer.readU32(at: low32)
            guard targetVal >= 1, targetVal <= 255 else { continue }

            let inDataConst = dataConstRanges.contains { $0.0 <= low32 && low32 < $0.1 }
            let inData = inDataConst || dataRanges.contains { $0.0 <= low32 && low32 < $0.1 }
            guard inData else { continue }

            log("  [+] variable at foff 0x\(String(format: "%X", low32)) (value=\(targetVal), found via sysctl_oid at str+0x\(String(format: "%X", delta)))")
            let va = fileOffsetToVA(low32)
            emit(
                low32,
                Data([0, 0, 0, 0]),
                patchID: "kernelcache_jb.thid_should_crash",
                virtualAddress: va,
                description: "zero [_thid_should_crash]",
            )
            return true
        }

        log("  [-] variable not found")
        return false
    }
}
