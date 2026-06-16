// KernelJBPatchProcSecurity.swift — JB: stub _proc_security_policy with mov x0,#0; ret.
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.
//
// Reveal (version-independent): _proc_security_policy is the shared proc-info
//   authorization gate (bsd/kern/proc_info.c). It is located by its unique
//   reference to PRIV_GLOBAL_PROC_INFO (1002 = 0x3EA, bsd/sys/priv.h) — the
//   privilege id handed to priv_check_cred(my_cred, PRIV_GLOBAL_PROC_INFO, 0).
//   See KernelJBPatcherBase.findProcSecurityPolicy(). Stubbing its entry to
//   `mov x0,#0; ret` forces the gate to allow, so proc-info/proc-control paths
//   used by jailbreak userland never hit cross-identity authorization denials.

import Foundation

extension KernelJBPatcher {
    /// Stub _proc_security_policy: mov x0,#0; ret.
    @discardableResult
    func patchProcSecurityPolicy() -> Bool {
        log("\n[JB] _proc_security_policy: mov x0,#0; ret")

        guard let policy = findProcSecurityPolicy() else {
            log("  [-] _proc_security_policy not identified (PRIV_GLOBAL_PROC_INFO anchor)")
            return false
        }

        emit(policy, ARM64.movX0_0,
             patchID: "jb.proc_security_policy.mov_x0_0",
             virtualAddress: fileOffsetToVA(policy),
             description: "mov x0,#0 [_proc_security_policy]")
        emit(policy + 4, ARM64.ret,
             patchID: "jb.proc_security_policy.ret",
             virtualAddress: fileOffsetToVA(policy + 4),
             description: "ret [_proc_security_policy]")
        return true
    }
}
