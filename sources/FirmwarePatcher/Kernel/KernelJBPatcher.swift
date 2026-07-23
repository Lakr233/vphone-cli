// KernelJBPatcher.swift — JB kernel patcher orchestrator.
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.

import Foundation

/// JB kernel patcher: 84 patches across 3 groups.
///
/// Group A: Core gate-bypass methods (5 patches)
/// Group B: Pattern/string anchored methods (16 patches)
/// Group C: Shellcode/trampoline heavy methods (4 patches)
public final class KernelJBPatcher: KernelJBPatcherBase, Patcher {
    public let component = "kernelcache_jb"

    /// Gates the iOS-27-only kernel patches. These target an iOS-27 userland running
    /// on the 26.4 kernel; on a 26.x base they are unnecessary and some are actively
    /// harmful (e.g. the IOMFB SwapEnd size gate would reject 26.x's native 0x588 swap
    /// struct → dead display, the 26.5 regression). The pipeline sets this from the
    /// iPhone base ProductVersion (false for 18.x/26.x → byte-identical to pre-branch);
    /// standalone patch-component defaults it true so the dev tool exercises the full
    /// set (override with --target-os).
    public var applyIOS27 = false

    public func findAll() throws -> [PatchRecord] {
        try parseMachO()
        buildADRPIndex()
        buildBLIndex()
        buildSymbolTable()
        findPanic()

        // Group A
        patchAmfiCdhashInTrustcache()
        patchTaskConversionEvalInternal()
        patchSandboxHooksExtended()
        patchIoucFailedMacf()

        // iOS-27-only (gated — a 26.x base skips these entirely). Both target a 27
        // userland on the 26.4 kernel:
        //  - IOUC sandbox gate bypass: the IOKit user-client open path's Sandbox gate
        //    (separate from the MACF gate above) spuriously denies backboardd its
        //    IOMFB/IOSurface/HID user clients → no present + nil main display →
        //    SpringBoard crash-loop. Mirrors the MACF gate.
        //  - DiskImages2 DDI ABI (kernel driver v9 vs iOS-27 controller/daemon v11) +
        //    RegisterNotificationPort off-by-one, so the personalized DDI attaches
        //    (/System/Developer auto-mount). Pairs with the sandbox ops[124] allow
        //    and the diskimagesiod isMountComplete→YES userland patch (cfw_install).
        if applyIOS27 {
            patchIoucFailedSandbox()
            patchDiskImages2ClientAbi()
        }

        // Group B
        patchPostValidationAdditional()
        patchProcSecurityPolicy()
        patchProcPidinfo()
        patchConvertPortToMap()
        patchBsdInitAuth()
        patchDounmount()
        patchIoSecureBsdRoot()
        patchLoadDylinker()
        patchMacMount()
        patchNvramVerifyPermission()
        patchSharedRegionMap()
        patchSpawnValidatePersona()
        patchTaskForPid()
        patchThidShouldCrash()
        patchVmFaultEnterPrepare()
        patchVmMapProtect()

        // Group C
        patchCredLabelUpdateExecve()
        patchHookCredLabelUpdateExecve()
        patchKcall10()
        patchSyscallmaskApplyToProc()

        // iOS-27-only (gated — a 26.x base skips these entirely). All target a 27
        // userland on the 26.4 kernel and are unnecessary or actively harmful on 26.x:
        //  - exec ip_mac_return SECURITY_POLICY kill bypass: AMFI's exec hooks reject a
        //    userland newer than the kernel (27 binaries' validation category) →
        //    ip_mac_return != 0 → core daemons die at exec → boot deadlock. 26.x
        //    binaries pass (ip_mac_return == 0), so it is not needed there.
        //  - container-manager exec-upcall force-success: iOS 27 deleted the kernel-side
        //    containermanagerd upcall, so on the 26.4 kernel it fails for every 27 app →
        //    autoboxed into temporary-sandbox → Campo/intelligencetasksd/feedbackd
        //    crash-loop. On 26.x the upcall succeeds, so it is not needed.
        //  - IOMFB SwapEnd size gates: 27's force-kern present (cfw_patch_iomfb_force_kern)
        //    sends a 0x6e0 SwapEnd struct; the 26.4 userclient exact-checks 0x588 in two
        //    places, so both gates are relaxed to accept 0x6e0. HARMFUL on 26.x — it
        //    sends the native 0x588, which the retargeted handler gate would then reject
        //    → every framebuffer swap fails → dead display (the 26.5 regression).
        if applyIOS27 {
            patchExecSecurityPolicyKill()
            patchContainerManagerUpcall()
            patchIomfbSwapEndVariableSize()      // dispatch checkStructureInputSize → variable
            patchIomfbSwapEndHandlerSize()       // handler cmp w2,#0x588 → 0x6e0
            patchFpfsScopedVnodeOpen()           // ops[267] → FileProvider-scoped trampoline (fpfs respring fix)
        }

        return patches
    }

    public func apply() throws -> Int {
        let records = try (patches.isEmpty ? findAll() : patches)
        for record in records {
            buffer.writeBytes(at: record.fileOffset, bytes: record.patchedBytes)
        }
        return records.count
    }
}
