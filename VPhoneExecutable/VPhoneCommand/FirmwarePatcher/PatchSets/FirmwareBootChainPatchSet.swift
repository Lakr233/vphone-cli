import Foundation
import VPhonePatchKit

public enum FirmwareBootChainPatchSet {
    public static let identifier = "com.vphone.patchset.bootchain"

    public static let manifest = VPhonePatchSetManifest(
        identifier: identifier,
        name: "Boot Chain",
        summary: "Boot images, restore-environment compatibility, and boot-policy patches",
        patches: [
            // MARK: AVPBooter

            VPhonePatchDeclaration(
                identifier: "avpbooter-boot-dgst_bypass",
                title: "AVPBooter digest bypass",
                summary: "Accepts the resealed boot images instead of the stock digests.",
                target: .firmware(.avpBooter),
                bootEssential: true,
            ),

            // MARK: iBSS

            VPhonePatchDeclaration(
                identifier: "ibss-cfw-serial_label",
                title: "iBSS serial label",
                summary: "Tags iBSS serial output so the boot log names its stage.",
                target: .firmware(.iBSS),
            ),
            VPhonePatchDeclaration(
                identifier: "ibss-boot-image4_callback",
                title: "iBSS image-4 callback",
                summary: "Lets iBSS load the resealed next stage.",
                target: .firmware(.iBSS),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "ibss-boot-skip_generate_nonce",
                title: "iBSS nonce generation skip",
                summary: "Keeps the boot nonce stable so a personalised image stays valid.",
                target: .firmware(.iBSS),
                bootEssential: true,
            ),

            // MARK: iBEC

            VPhonePatchDeclaration(
                identifier: "ibec-cfw-serial_label",
                title: "iBEC serial label",
                summary: "Tags iBEC serial output so the boot log names its stage.",
                target: .firmware(.iBEC),
            ),
            VPhonePatchDeclaration(
                identifier: "ibec-boot-image4_callback",
                title: "iBEC image-4 callback",
                summary: "Lets iBEC load the resealed kernelcache.",
                target: .firmware(.iBEC),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "ibec-boot-boot_args",
                title: "iBEC boot arguments",
                summary: "Installs the research boot-args string iBEC hands the kernel.",
                target: .firmware(.iBEC),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "ibec-boot-bootx_precondition",
                title: "iBEC bootx precondition",
                summary: "Drops the precondition that would refuse a patched chain.",
                target: .firmware(.iBEC),
                bootEssential: true,
            ),

            // MARK: LLB

            VPhonePatchDeclaration(
                identifier: "llb-cfw-serial_label",
                title: "LLB serial label",
                summary: "Tags LLB serial output so the boot log names its stage.",
                target: .firmware(.llb),
            ),
            VPhonePatchDeclaration(
                identifier: "llb-boot-image4_callback",
                title: "LLB image-4 callback",
                summary: "Lets LLB load the resealed next stage.",
                target: .firmware(.llb),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "llb-boot-boot_args",
                title: "LLB boot arguments",
                summary: "Installs the research boot-args string LLB passes along.",
                target: .firmware(.llb),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "llb-boot-rootfs",
                title: "LLB root filesystem checks",
                summary: "Skips the signature, size and null checks on the patched root image.",
                target: .firmware(.llb),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "llb-boot-panic_bypass",
                title: "LLB panic bypass",
                summary: "Turns LLB's image-policy panic into a continue.",
                target: .firmware(.llb),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "llb-cfw-display_scale",
                title: "LLB display scale",
                summary: "Gives a guest, including iPad and iPhone SE, its own screen scale instead of the virtual phone's 3x.",
                target: .firmware(.llb),
            ),

            // MARK: TXM

            VPhonePatchDeclaration(
                identifier: "txm-cfw-executable_remap",
                title: "TXM native signature classification",
                summary: "Preserves real classification and native mapping bounds. Admits CMS-less installer signatures and temporarily tolerates absent or mismatched ordinary-library Team IDs. With AMFI trust-cache bypass enabled, also waives missing profile authorization for type 4; present-profile, category and remap checks remain.",
                target: .firmware(.txm),
            ),
            VPhonePatchDeclaration(
                identifier: "txm-exp-precheck_admission",
                title: "TXM pre-check admission (legacy force-admit)",
                summary: "Forces the selector-24 pre-check policy walk to admit every image, CS_ADHOC code included, before native classification runs. This is the pre-#831 behaviour that let injected ad-hoc dylibs (ellekit/roothide) reach RX in every host. Off by default; standard uses txm-cfw-executable_remap instead. Select it when the guest injects CS_ADHOC code; it supersedes txm-cfw-executable_remap, which is then not emitted, so an app can no longer remap its own executable code. iOS 27 only; it also satisfies the 27.0.1 first-boot admission the walk otherwise rejects.",
                target: .firmware(.txm),
                applicability: VPhonePatchApplicability(iOSBase: .major(27)),
            ),
            VPhonePatchDeclaration(
                identifier: "txm-boot-trustcache_bypass",
                title: "TXM trust cache bypass",
                summary: "Lets TXM admit the guest's own trust cache entries.",
                target: .firmware(.txm),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "txm-cfw-get_task_allow",
                title: "TXM get-task-allow",
                summary: "Grants get-task-allow so a debugger can attach in the guest.",
                target: .firmware(.txm),
            ),
            VPhonePatchDeclaration(
                identifier: "txm-cfw-debugger_entitlement",
                title: "TXM debugger entitlement",
                summary: "Grants the task_for_pid debugger entitlement.",
                target: .firmware(.txm),
            ),
            VPhonePatchDeclaration(
                identifier: "txm-boot-developer_mode_bypass",
                title: "TXM developer mode",
                summary: "Reports developer mode on without the enrolment dance.",
                target: .firmware(.txm),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "txm-boot-selector24_bypass",
                title: "TXM selector 24 bypass",
                summary: "Lets the selector-24 code-signing query succeed.",
                target: .firmware(.txm),
                bootEssential: true,
            ),
            VPhonePatchDeclaration(
                identifier: "txm-boot-sel42_29",
                title: "TXM selector 42/29 shellcode",
                summary: "Installs the selector-42/29 stub that admits guest signatures.",
                target: .firmware(.txm),
                bootEssential: true,
            ),

            // MARK: SPTM

            VPhonePatchDeclaration(
                identifier: SPTMSecondaryCPUPatcher.patchIdentifier,
                title: "SPTM secondary CPU tunable",
                summary: "Skips the core throttle tunable cloudOS 18's SPTM applies when a second CPU starts. No vCPU has that register, and the access stops the virtual machine, so without it the guest runs on one vCPU only.",
                target: .firmware(.sptm),
                applicability: VPhonePatchApplicability(cloudOS: .major(18)),
                bootEssential: true,
            ),

            // MARK: Restore environment

            VPhonePatchDeclaration(
                identifier: RestoreRamDiskSealPatcher.patchIdentifier,
                title: "iOS 27 APFS seal hash",
                summary: "Uses sha3_256_4k for iOS 27 images that select it in SystemVolume metadata; leaves SHA-256 restore images unchanged.",
                target: .firmware(.restoreRamDisk),
                applicability: VPhonePatchApplicability(
                    iOSBase: .major(27),
                    cloudOS: .release(major: 26, minor: 4),
                ),
                bootEssential: true,
            ),
        ],
        provides: ["vphone.bootchain"],
    )
}
