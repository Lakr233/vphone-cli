// KernelJailbreakPatchContainerUpcall.swift — JB kernel patch: force the sandbox exec-time
// container-manager upcall onto its success path (neutralize the autobox / kill).
//
// At exec, the sandbox hook `_hook_cred_label_update_execve` resolves each process's
// containers by a SYNCHRONOUS MIG upcall to containermanagerd over the container-manager
// host special port:
//
//     w0 = container_manager_get_process_containers(...)   // 0 = success
//     if (w0 != 0) {                                        // upcall failed
//         os_log("... failed to upcall to containermanagerd for a platform app");
//         ... // KILL the process, or autobox it into the restrictive
//             // `temporary-sandbox` profile
//     }
//     // success path: use the returned container-derived sandbox
//
// iOS 27 DELETED this kernel-side upcall entirely (the stock iOS 27 kernel has no
// HOST_CONTAINERD_PORT / CM_KERN_* protocol — container resolution moved out of the
// kernel), so 27's containermanagerd no longer implements the reply server. On the 26.4
// vphone600 kernel running a 27.0 userland, the upcall therefore fails
// (MACH_SEND_INVALID_DEST) for every platform app → they are autoboxed into
// `temporary-sandbox`, which denies e.g. `mach-lookup com.apple.backboard.display.services`
// → Campo (the wallpaper renderer) crash-loops (no wallpaper), plus intelligencetasksd /
// feedbackd. Re-registering the host special port is NOT an option: it makes the kernel
// SEND the MIG request and BLOCK for a reply 27 cannot produce → early-boot deadlock.
//
// Fix: flip the `cbz w0, <success>` guard (taken when the upcall returns 0) to an
// unconditional `b <success>`, so a failed upcall takes the same path as a successful one
// instead of autobox/kill. Safe for version-matched userlands: there the upcall succeeds
// (w0 == 0), so the original cbz already branches to <success> — the unconditional b is
// behaviourally identical (no-op in effect). Validated on-device: iOS 27.0 wallpaper
// renders, Campo/SpringBoard/backboardd stable, boot clean (no freeze, no panic).
//
// Anchor (structural, no hardcoded offsets/bytes): the os_log format string
// "failed to upcall to containermanagerd for a platform app" is loaded (adrp+add) on the
// failure fall-through; the guard is the `cbz w0, <back-branch>` immediately preceding
// that load, itself immediately preceded by the `bl <container upcall>`. The branch is
// backward (the success continuation precedes the call site). Replacement bytes come from
// the Keystone-backed ARM64Encoder.

import Foundation

extension KernelJailbreakPatcher {
    @discardableResult
    func patchContainerManagerUpcall() -> Bool {
        log("\n[JB] container-manager exec upcall: cbz w0 -> b (force success; skip autobox/temporary-sandbox)")

        guard let strOff = buffer.findString("failed to upcall to containermanagerd") else {
            log("  [-] 'failed to upcall to containermanagerd' string not found")
            return false
        }

        // The string ref (adrp+add loading the format string) sits on the failure
        // fall-through. The guard we flip is the cbz two instructions before the adrp:
        //   bl  <container upcall>     ; adrpOff - 8
        //   cbz w0, <success>          ; adrpOff - 4   <- patch to `b <success>`
        //   adrp xN, "failed to..."    ; adrpOff       <- the string ref
        var hits: [(cbzOff: Int, target: Int)] = []
        for ref in findStringRefs(strOff) {
            let adrpOff = ref.adrpOff
            let cbzOff = adrpOff - 4
            let blOff = adrpOff - 8
            guard blOff >= 0 else { continue }
            guard let cbz = disasAt(cbzOff), cbz.mnemonic == "cbz",
                  cbz.operandString.hasPrefix("w0"), // upcall status is a 32-bit w0
                  let bl = disasAt(blOff), bl.mnemonic == "bl" // the container upcall call
            else { continue }

            // Decode the cbz forward/backward target (imm19 << 2).
            let word = buffer.readU32(at: cbzOff)
            let imm19 = Int((word >> 5) & 0x7FFFF)
            let signed = imm19 >= (1 << 18) ? imm19 - (1 << 19) : imm19
            let target = cbzOff + signed * 4
            // The success continuation precedes the upcall call site (backward branch),
            // and must land in executable code.
            if target < cbzOff, codeRanges.contains(where: { target >= $0.start && target < $0.end }) {
                hits.append((cbzOff, target))
            }
        }

        guard hits.count == 1 else {
            log("  [-] container-manager upcall guard not found uniquely (found \(hits.count))")
            return false
        }

        let (cbzOff, target) = hits[0]
        guard let bBytes = ARM64Encoder.encodeB(from: cbzOff, to: target) else {
            log("  [-] failed to encode B to 0x\(String(target, radix: 16))")
            return false
        }

        let va = fileOffsetToVA(cbzOff)
        emit(
            cbzOff,
            bBytes,
            patchID: "container_manager_upcall_force_success",
            virtualAddress: va,
            description: "cbz w0 -> b [force container-manager exec upcall success; skip autobox/temporary-sandbox]",
        )
        return true
    }
}
