// KernelPatchDyldPolicy.swift — DYLD policy patches (2 patches).
//
// Replaces two BL calls in _check_dyld_policy_internal with mov w0,#1.
// The function is located via its reference to the Swift Playgrounds
// entitlement string. The two BLs that immediately precede the string
// reference (each followed by a conditional branch on w0) are patched.
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.

import Foundation

extension KernelPatcher {
    /// Patches 10–11: Replace two BL calls in _check_dyld_policy_internal with mov w0,#1.
    @discardableResult
    func patchDyldPolicy() -> Bool {
        log("\n[10-11] _check_dyld_policy_internal: mov w0,#1 (two BLs)")

        // Anchor: entitlement string referenced from within the function.
        guard let strOff = buffer.findString(
            "com.apple.developer.swift-playgrounds-app.development-build",
        ) else {
            log("  [-] swift-playgrounds entitlement string not found")
            return false
        }

        let refs = findStringRefs(strOff)
        guard !refs.isEmpty else {
            log("  [-] no code refs found for swift-playgrounds entitlement string")
            return false
        }

        for (adrpOff, _) in refs {
            // Walk backward from the ADRP (exclusive), up to 80 bytes back,
            // collecting (bl_offset, bl_target) pairs where the instruction
            // immediately following the BL is a conditional branch on w0/x0.
            var blsWithCond: [(blOff: Int, blTarget: Int)] = []

            let scanStart = max(adrpOff - 80, 0)
            // Iterate in 4-byte steps from adrpOff-4 down to scanStart
            var back = adrpOff - 4
            while back >= scanStart {
                defer { back -= 4 }
                guard back >= 0, back + 4 <= buffer.count else { continue }

                if let target = decodeBL(at: back),
                   isCondBranchOnW0(at: back + 4)
                {
                    blsWithCond.append((blOff: back, blTarget: target))
                }
            }

            guard blsWithCond.count >= 2 else { continue }

            // blsWithCond[0] is closest to ADRP (@2), [1] is farther (@1).
            // The two BLs must call DIFFERENT functions to distinguish
            // _check_dyld_policy_internal from functions that repeat a single helper.
            let bl2 = blsWithCond[0] // closer  to ADRP → @2
            let bl1 = blsWithCond[1] // farther from ADRP → @1

            guard bl1.blTarget != bl2.blTarget else { continue }

            let va1 = fileOffsetToVA(bl1.blOff)
            let va2 = fileOffsetToVA(bl2.blOff)

            emit(
                bl1.blOff,
                ARM64.movW0_1,
                patchID: "dyld_policy_1",
                virtualAddress: va1,
                description: "mov w0,#1 (was BL) [_check_dyld_policy_internal @1]",
            )
            emit(
                bl2.blOff,
                ARM64.movW0_1,
                patchID: "dyld_policy_2",
                virtualAddress: va2,
                description: "mov w0,#1 (was BL) [_check_dyld_policy_internal @2]",
            )
            return true
        }

        log("  [-] _check_dyld_policy_internal BL pair not found")
        return false
    }

    // MARK: - Private Helpers

    /// Return true when the instruction at `offset` is a conditional branch
    /// that tests w0 or x0 (CBZ, CBNZ, TBZ, TBNZ on register 0).
    private func isCondBranchOnW0(at offset: Int) -> Bool {
        guard offset >= 0, offset + 4 <= buffer.count else { return false }
        let insn = buffer.readU32(at: offset)

        // CBZ / CBNZ  — encoding: [31]=sf, [30:25]=011010 (CBZ) or 011011 (CBNZ)
        //               Rt = bits[4:0]; sf=0 → 32-bit (w), sf=1 → 64-bit (x)
        let op54 = (insn >> 24) & 0xFF
        if op54 == 0b0011_0100 || op54 == 0b0011_0101 // CBZ  w/x
            || op54 == 0b1011_0100 || op54 == 0b1011_0101 // CBNZ w/x
        {
            return (insn & 0x1F) == 0 // Rt == 0  (w0 / x0)
        }

        // TBZ / TBNZ — encoding: [31:24] = 0x36 (TBZ) or 0x37 (TBNZ), any bit
        //              Rt = bits[4:0]
        if op54 == 0x36 || op54 == 0x37 || op54 == 0xB6 || op54 == 0xB7 {
            return (insn & 0x1F) == 0 // Rt == 0
        }

        // B.cond — encoding: [31:24] = 0x54, bit[4] = 0
        //          B.cond does not test a specific register, so we skip it —
        //          the Python reference only uses cbz/cbnz/tbz/tbnz on w0.

        return false
    }
}
