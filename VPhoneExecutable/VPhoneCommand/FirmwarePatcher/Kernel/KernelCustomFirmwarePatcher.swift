// KernelCustomFirmwarePatcher.swift — CFW kernel patcher orchestrator.
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.

import Foundation
import VPhonePatchKit

/// CFW kernel patcher across 3 groups. Variant- and feature-gated methods can
/// change the emitted record count; iOS-27-only patches are gated by `applyIOS27`
/// and Frida Stalker relaxations by `applyFrida`, which the pipeline sets from the
/// plan — the `com.vphone.patchset.kernel.frida` patches, off in `standard`.
///
/// Group A: Core gate-bypass methods
/// Group B: Pattern/string anchored methods
/// Group C: Shellcode/trampoline heavy methods
public final class KernelCustomFirmwarePatcher: KernelCustomFirmwarePatcherBase, BufferedPatcher {
    public let component = "kernelcache_cfw"

    /// Gates the iOS-27-only kernel patches. These target an iOS-27 userland running
    /// on the 26.4 kernel; on a 26.x base they are unnecessary and some are actively
    /// harmful (e.g. the IOMFB SwapEnd size gate would reject 26.x's native 0x588 swap
    /// struct → dead display, the 26.5 regression). The pipeline sets this from the
    /// iPhone base ProductVersion (false for 18.x/26.x → byte-identical to pre-branch);
    /// standalone patch-component defaults it true so the dev tool exercises the full
    /// set (override with --target-os).
    public var applyIOS27 = false

    /// Whether that 27 userland runs on the **26.4** kernel, the pairing every
    /// patch below was revealed against. A cloudOS 27.2 kernel is itself 27-era,
    /// so the shims that make 26.4 behave like 27 have nothing to match there —
    /// and applying half of one is worse than applying none. Set by the pipeline
    /// from the cloudOS ProductVersion; `applyIOS27` alone no longer implies it.
    public var applyIOS27LegacyKernel = false

    /// The AppleSEPKeyStore keybag-unlock count-5 acceptance. iOS 26.6 is where
    /// Apple's external method began sending inputScalarCount == 5 (26.5 and
    /// earlier send 4), so a 26.6-or-newer userland needs it on the 26.4 kernel —
    /// not only a 27 base. The pipeline sets this from the iPhone base; the patch
    /// anchor self-guards on a kernel that already accepts 5, so it no-ops where
    /// unneeded. False here so a patcher built directly preserves the reference corpus.
    public var applyAksUnlockBag5 = false

    /// Opt-in Frida Stalker kernel relaxations. Set from the plan: `standard` blocks
    /// both, `experimental` and a per-VM checkmark turn them on, and their own
    /// cloudOS 26.4+ gate then decides whether they land. Baseline CFW/EXP firmware is
    /// byte-identical when false.
    public var applyFrida = false

    /// ProMotion, the 120 Hz display timing. Set from the plan, and `standard`
    /// turns it on; a VM that blocks it keeps the host's 60 Hz mode. False here so
    /// a patcher built directly writes what the reference records were taken from.
    public var applyProMotion = false

    /// Opt-in plain-arm64 tvOS shared-cache compatibility; off by default.
    public var applyTVTPROPagers = false

    /// On a base older than 27: a narrow allowlist at the same sandbox gate, so a
    /// process outside an app sandbox can open the paravirtual GPU, video decoder,
    /// Neural Engine and IOSurface scaler user clients and nothing else. Set from
    /// the plan, and `standard` turns it on. False here so a patcher built directly
    /// writes what the reference records were taken from.
    public var applyParavirtUserClients = false

    /// Paravirtual GPU binary version 252 (Task3). Set from the plan; `standard`
    /// enables it. False here so direct patchers preserve the reference corpus.
    public var applyParavirtTask3 = false

    /// The paravirtual GPU's OpenGL ES renderer. Set from the plan; `standard`
    /// enables it. False here so direct patchers preserve the reference corpus.
    public var applyParavirtGLES = false

    public func findAll() throws -> [PatchRecord] {
        parseMachO()
        buildADRPIndex()
        buildBLIndex()
        buildSymbolTable()
        findPanic()

        if applyTVTPROPagers {
            guard patchTVTPROPagers() else {
                throw NSError(domain: "FirmwarePatcher.TVTPROPagers", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot validate sprr_tpro_pagers tunable; kernel unchanged by this operation"])
            }
        }

        // Group A
        patchAmfiCdhashInTrustcache()
        patchTaskConversionEvalInternal()
        patchSandboxHooksExtended()
        patchIoucFailedMacf()

        // iOS-27-only (gated — a 26.x base skips these entirely).
        //
        // Needed by the 27 userland whatever kernel carries it:
        //  - IOUC sandbox gate bypass: the IOKit user-client open path's Sandbox gate
        //    (separate from the MACF gate above) spuriously denies backboardd its
        //    IOMFB/IOSurface/HID user clients → no present + nil main display →
        //    SpringBoard crash-loop. Mirrors the MACF gate.
        //  - CSSC: emulate the instructions 27's binaries carry.
        //
        // The rest only make the 26.4 kernel behave like a 27 one, so they are
        // `applyIOS27LegacyKernel` and a 27.2 kernel skips them:
        //  - DiskImages2 DDI ABI (kernel driver v9 vs iOS-27 controller/daemon v11) +
        //    RegisterNotificationPort off-by-one, so the personalized DDI attaches
        //    (/System/Developer auto-mount). Pairs with the sandbox ops[124] allow
        //    and the diskimagesiod isMountComplete→YES userland patch (cfw_install).
        //    A 27 kernel ships ABI 11 and the fixed array: nothing to match, and the
        //    port-array widen alone would grow a buffer whose bound checks are stock.
        //  - Shared region size: the arm64 region widens from 6 GiB to 7 GiB so a
        //    27 cache (0x185804000 on 27.0.1 iPhone18,x) maps at all. A 26.x base's
        //    own cache fits the stock region, so the kernel is left stock there.
        //  - ARM64E_X1 admission: a 27 kernel already grades CPU subtype 12 in
        //    `ml_grade_binary` (`cmp w1,#0xc` beside the stock `cmp w1,#2`), so there
        //    is no subtype-2-only gate to widen and no reason to fail the run.
        if applyIOS27 {
            patchIoucFailedSandbox()
            try patchCSSC()
            if applyIOS27LegacyKernel {
                patchDiskImages2ClientAbi()
                patchSharedRegionSize()
                if gate.isEnabled("kernel-boot-arm64e_x1"), !patchArm64eX1Admission() {
                    throw PatcherError.invalidFormat("cannot validate required ARM64E_X1 kernel admission")
                }
            }
        } else if applyParavirtUserClients {
            patchParavirtUserClientsNarrow()
        }

        // AppleSEPKeyStore keybag unlock: accept the 5 scalars an iOS 26.6-or-newer
        // userland sends (26.5 and earlier send 4). Gated on the base, not on
        // applyIOS27, so a 26.6/26.6.1 base on the 26.4 kernel gets it too; the
        // anchor self-guards on a kernel that already accepts 5.
        if applyAksUnlockBag5 {
            patchAksUnlockBagCount5()
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

        // Opt-in Frida support, from the kernel.frida patch set: existing-thread
        // follow (thread_set_state), repeated VM_PROT_COPY overwrite
        // (vm_map_delete), spawn (TPRO), syscall-filtered targets, and fork
        // after instrumentation (the child of an entitled parent keeps its
        // permission to run rewritten code). The gate writes each only when its
        // own identifier is selected.
        if applyFrida {
            patchThreadSetStateEntitlementFlag()
            patchVmMapDeleteImmutableCode()
            patchTproOff()
            patchSyscallFilterOff()
            patchForkInheritInvalidCode()
        }

        // The paravirtual display advertises 120 Hz instead of the host's
        // fixed 60 Hz mode, unless the VM blocked it.
        if applyProMotion {
            patchParavirtDisplayRefreshRate()
        }

        // Negotiate Task3 and identify the executable before registration.
        if applyParavirtTask3 {
            guard patchParavirtTask3Version() else {
                throw NSError(domain: "FirmwarePatcher.ParavirtTask3", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Cannot resolve the complete Task3 shader-cache patch; kernel was not installed",
                ])
            }
        }

        // Name the GLES renderer in the paravirtual GPU's personality.
        if applyParavirtGLES {
            patchParavirtGLESRenderer()
        }

        // Group C
        patchCredLabelUpdateExecve()
        patchHookCredLabelUpdateExecve()
        patchKcall10()
        patchSyscallmaskApplyToProc()

        // iOS-27-only (gated — a 26.x base skips these entirely), and unnecessary or
        // actively harmful on 26.x.
        //
        // Needed by the 27 userland whatever kernel carries it:
        //  - exec ip_mac_return SECURITY_POLICY kill bypass: AMFI's exec hooks reject a
        //    userland newer than the kernel (27 binaries' validation category) →
        //    ip_mac_return != 0 → core daemons die at exec → boot deadlock. 26.x
        //    binaries pass (ip_mac_return == 0), so it is not needed there.
        //
        // Shims for the 26.4 kernel, skipped on a 27 one (`applyIOS27LegacyKernel`):
        //  - container-manager exec-upcall force-success: iOS 27 deleted the kernel-side
        //    containermanagerd upcall, so on the 26.4 kernel it fails for every 27 app →
        //    autoboxed into temporary-sandbox → Campo/intelligencetasksd/feedbackd
        //    crash-loop. On 26.x the upcall succeeds, so it is not needed. A 27 kernel
        //    has no upcall to force, which is why the reveal finds nothing there.
        //  - IOMFB SwapEnd size gates: 27's force-kern present (cfw_patch_iomfb_force_kern)
        //    sends a 0x6e0 SwapEnd struct; the 26.4 userclient exact-checks 0x588 in two
        //    places, so both gates are relaxed to accept 0x6e0. HARMFUL on 26.x — it
        //    sends the native 0x588, which the retargeted handler gate would then reject
        //    → every framebuffer swap fails → dead display (the 26.5 regression). A 27
        //    userclient takes 0x6e0 already.
        if applyIOS27 {
            patchExecSecurityPolicyKill()
            if applyIOS27LegacyKernel {
                // The fpfs trampoline is a 27-userland fix written with vphone600
                // struct offsets: it walks TPIDR_EL1 -> uthread +0x3F0 -> proc +0x18
                // -> p_comm +0x56C to read the process name. A 27 kernel lays those
                // out differently, so the walk dereferences garbage and takes a
                // kernel data abort the first time launchd opens a vnode. Until the
                // offsets are recovered for that kernel it stays on the pairing it
                // was measured against.
                patchFpfsScopedVnodeOpen() // ops[267] → FileProvider-scoped trampoline
                patchContainerManagerUpcall()
                patchIomfbSwapEndVariableSize() // dispatch checkStructureInputSize → variable
                patchIomfbSwapEndHandlerSize() // handler cmp w2,#0x588 → 0x6e0
            }
        }

        return patches
    }

    public func apply() throws -> Int {
        // `emit()` already wrote every record through to `buffer.data`.
        let records = try (patches.isEmpty ? findAll() : patches)
        return records.count
    }
}
