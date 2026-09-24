// KernelPatchLaunchConstraints.swift — Launch constraints patches (patches 4–5).
//
// Stubs _proc_check_launch_constraints with `mov w0, #0; ret` so that
// the AMFI launch-constraint gate always returns 0 (success).
//
// The kernel wrapper for _proc_check_launch_constraints does not embed the
// symbol name string directly. Instead the underlying AMFI function references
// "AMFI: Validation Category info", which is used as the anchor.
//
// Strategy (mirrors Python kernel_patch_launch_constraints.py):
//   1. Find the "AMFI: Validation Category info" string in the binary.
//   2. Find ADRP+ADD references into code.
//   3. Walk backward from each ADRP to locate the enclosing function start.
//   4. Emit `mov w0, #0` at funcStart and `ret` at funcStart+4.
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.

import Foundation

extension KernelPatcher {
    // MARK: - Patches 4–5: _proc_check_launch_constraints

    /// Patches 4–5: Stub _proc_check_launch_constraints with `mov w0, #0; ret`.
    ///
    /// Returns true when both instructions are emitted, false on any failure.
    @discardableResult
    func patchLaunchConstraints() -> Bool {
        log("\n[4-5] _proc_check_launch_constraints: stub with mov w0,#0; ret")

        // Step 1: Locate the anchor string used inside the AMFI function.
        guard let strOff = buffer.findString("AMFI: Validation Category info") else {
            log("  [-] 'AMFI: Validation Category info' string not found")
            return false
        }

        // Step 2: Find ADRP+ADD references from AMFI code into the string.
        let amfiRange = amfiTextRange()
        let refs = findStringRefs(strOff, in: amfiRange)
        guard !refs.isEmpty else {
            log("  [-] no code refs to 'AMFI: Validation Category info'")
            return false
        }

        // Step 3: Walk each reference and find the enclosing function start.
        for (adrpOff, _) in refs {
            guard let funcStart = findFunctionStart(adrpOff) else { continue }

            // Step 4: Emit the two-instruction stub at the function entry point.
            let va0 = fileOffsetToVA(funcStart)
            let va1 = fileOffsetToVA(funcStart + 4)

            emit(
                funcStart,
                ARM64.movW0_0,
                patchID: "launch_constraints_mov",
                virtualAddress: va0,
                description: "mov w0,#0 [_proc_check_launch_constraints]",
            )
            emit(
                funcStart + 4,
                ARM64.ret,
                patchID: "launch_constraints_ret",
                virtualAddress: va1,
                description: "ret [_proc_check_launch_constraints]",
            )
            return true
        }

        log("  [-] function start not found for any ref to 'AMFI: Validation Category info'")
        return false
    }
}
