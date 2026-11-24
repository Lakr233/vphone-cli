// FirmwareRestoreImagePatchSet.swift — Manifest for the customised restore image.
//
// The patchless way to a guest: instead of patching the boot chain and kernel to
// accept a modified system, the restore installs one whose digests the boot chain
// already accepts. `fw patch` merges the AppOS and SystemOS cryptexes into the OS
// image, adds what the guest needs to run (GPU driver, activation, vphoned), seals
// the result again, and rehashes every component in the BuildManifest. The boot
// chain, kernel and TXM stay stock, and nothing writes the System volume after the
// restore, because that would break the seal.
//
// Only the `minimal` preset and its watch form, `watchos`, name this set,
// and both allow all of it but the launchd_cache_loader gate. Every patch in
// it but the three experiments is boot-essential for them, and naming it
// nowhere else keeps `standard` from counting them as dropped. A watchOS image
// has no cryptexes: for a watch the merge only reseals the image with the
// guest payload.

import Foundation
import VPhoneCoreKit
import VPhonePatchKit

public enum FirmwareRestoreImagePatchSet {
    public static let identifier = "com.vphone.patchset.restore.image"

    /// The merge and reseal of the OS image. Every other filesystem patch writes
    /// into the merged image, so they run only with it.
    public static let cryptexMerge = "filesystem-boot-cryptex_merge"
    public static let gpuDriver = "filesystem-boot-gpu_driver"
    /// Applies to an iOS 18 guest only; the patcher skips it on any other.
    public static let surfaceCompression = "filesystem-boot-ios18_surface_compression"
    public static let mobileActivation = "filesystem-boot-mobileactivationd_should_hactivate"
    public static let vphoned = "filesystem-boot-vphoned"
    /// No longer needed by `minimal` or `watchos`: the vphoned step re-signs the
    /// edited launchd.plist and the trust cache takes its cdhashes.
    public static let launchdCacheLoader = "filesystem-exp-launchd_cache_loader_unsecure_cache_gate"
    public static let virtualBluetooth = "filesystem-exp-btvc_le_connection"
    public static let watchAudio = "filesystem-exp-watch_audio"
    public static let debugserver = "filesystem-exp-debugserver"
    public static let launchdJetsam = "filesystem-exp-launchd_jetsam_panic_guard"
    /// Restores the guest as trusted darwinOS (`Ap,OSEnvironment` 6) and adds
    /// cryptexctl, so cryptexes can be installed while it runs. Changes the
    /// restore's ticket, so it reaches a guest only through a restore.
    public static let trustedDarwinOS = "filesystem-exp-trusted_darwinos"
    /// The `Ap,OSEnvironment` value of trusted darwinOS, which every cloudOS
    /// research identity carries; `/osenvironments/trusted-darwinos` in the
    /// device tree is its overlay.
    public static let trustedDarwinOSEnvironment = 6
    /// SystemVersion.plist says ReleaseType Internal, so libmis lets a free
    /// personal team's app run without the online authorization an
    /// offline-activated guest cannot get (CustomFirmwareInternalReleaseType).
    /// On in `minimal` for iPhone and iPad guests; a watch is left alone.
    public static let internalReleaseType = "filesystem-exp-internal_release_type"
    public static let digestRehash = "manifest-boot-digest_rehash"

    /// Patches a machine asks for by name (`--allow`, or a preset that lists them);
    /// `minimal` and `watchos` leave them off, so the plain presets stay a lifelike
    /// stock guest.
    public static let optInPatches: Set = [debugserver, launchdJetsam, trustedDarwinOS]
    /// What `minimal` and `watchos` select from this set: everything but the
    /// opt-in patches.
    public static var presetPatches: Set<String> {
        Set(manifest.patches.map(\.identifier)).subtracting(optInPatches)
    }

    /// Why a restore image cannot run on this pairing, or nil when it can.
    ///
    /// The restore image runs on a stock kernel, and an iOS 27 userland does
    /// not boot on a stock cloudOS 26 kernel (2026-11-24, Research
    /// 0_binary_patch_comparison.md, the `minimal` notes). iPhone17,3 27.2's
    /// shared cache spans 0x18FC94000, more than the kernel's 6 GiB region at
    /// any slide. iPad16,1 27.0.1's maps with its slide zeroed, and then
    /// launchd aborts, as on every iOS 27 userland whose libSystem queries the
    /// lockdown-mode sysctl that kernel lacks. `standard` patches the kernel
    /// for both. iPhone and iPad only: no other guest was tried.
    public static func cloudOSRefusal(
        plan: VPhonePatchPlan,
        family: VPhoneGuestDevice.Family,
        iOSBase: VPhoneVersion?,
        cloudOS: VPhoneVersion?,
    ) -> String? {
        guard plan.isEnabled(cryptexMerge),
              family == .iPhone || family == .iPad,
              let iOSBase, iOSBase.major >= 27,
              let cloudOS, cloudOS.major < 27
        else { return nil }
        let reason = "The \(plan.presetIdentifier) preset restores a resealed system onto a stock kernel, "
            + "and \(family.osName) \(iOSBase) does not boot on the stock cloudOS \(cloudOS) kernel: "
            + "its shared cache does not fit that kernel's shared region, and its launchd needs a "
            + "lockdown-mode sysctl that kernel lacks."
        guard let own = VPhoneFirmwareCatalog.researchBoardCloudOS(forVersion: iOSBase.description) else {
            return reason + " Use the standard preset, which patches the kernel for iOS \(iOSBase.major)."
        }
        return reason + " Use its own \(own.name), whose research board kernel needs no patch: "
            + "--cloudos-source \(own.url). Or use the standard preset, which patches the kernel."
    }

    private static func filesystem(_ identifier: String, _ title: String, _ summary: String) -> VPhonePatchDeclaration {
        VPhonePatchDeclaration(
            identifier: identifier,
            title: title,
            summary: summary,
            target: .firmware(.filesystem),
            bootEssential: true,
        )
    }

    public static let manifest = VPhonePatchSetManifest(
        identifier: identifier,
        name: "Restore Image",
        summary: "A pre-customised, resealed system image restored onto a stock boot chain",
        patches: [
            filesystem(
                cryptexMerge,
                "Cryptex merge",
                "Merges the AppOS and SystemOS cryptexes into the OS image and seals it again, so the stock boot chain mounts a system it has digests for.",
            ),
            filesystem(
                gpuDriver,
                "GPU driver",
                "Installs the paravirtual GPU driver from the cloudOS into the merged image.",
            ),
            filesystem(
                surfaceCompression,
                "iOS 18 surface compression",
                "On iOS 18, turns off CoreAnimation's IOSurface and framebuffer compression and its deep framebuffer, which that release's paravirtual IOSurface driver rejects, leaving the screen black.",
            ),
            filesystem(
                mobileActivation,
                "Activation",
                "Lets mobileactivationd activate the guest without Apple's activation servers.",
            ),
            filesystem(
                vphoned,
                "vphoned",
                "Installs the guest daemon and its launch daemon, which the host talks to, and signs the edited launchd.plist so the stock launchd_cache_loader accepts it.",
            ),
            VPhonePatchDeclaration(
                identifier: launchdCacheLoader,
                title: "Unsigned launch daemon cache",
                summary: "NOPs launchd_cache_loader's launchd_unsecure_cache= gate, so launchd takes launchd.plist without checking its detached signature against the trust cache. Not needed: the vphoned step signs the edited launchd.plist and the rebuilt trust cache holds its cdhashes.",
                target: .firmware(.filesystem),
            ),
            VPhonePatchDeclaration(
                identifier: virtualBluetooth,
                title: "Virtual Bluetooth",
                summary: "Turns on the feature flag that lets bluetoothd connect over its virtual controller, which a watch and its phone talk over once paired.",
                target: .firmware(.filesystem),
            ),
            VPhonePatchDeclaration(
                identifier: watchAudio,
                title: "Watch speaker",
                summary: "Installs the virtio sound HAL plugin on watchOS.",
                target: .firmware(.filesystem),
            ),
            VPhonePatchDeclaration(
                identifier: debugserver,
                title: "debugserver",
                summary: "Re-signs the guest's debugserver with task_for_pid-allow and no sandbox profile, before the reseal, so it can attach to a process in the guest. Off by default — a lifelike guest ships no debugger, and a stock userland carries debugserver only in the Developer disk image, where this is a no-op. On its own it does not run on minimal's stock kernel and TXM: turn on Userspace debugging, which adds the kernel and TXM patches it needs.",
                target: .firmware(.filesystem),
            ),
            VPhonePatchDeclaration(
                identifier: launchdJetsam,
                title: "launchd jetsam panic guard",
                summary: "Patches launchd, before the reseal, so a daemon without jetsam properties does not panic the guest. Off by default. With developer mode on, MobileStorageMounter mounts the Developer disk image, and launchd's guard against its daemons kills init (\"jetsam property category (Daemon) is not initialized\"). The cause is the jetsam product type the VM's syscfg cannot supply, which devicetree-exp-syscfg_placeholders restores without touching launchd. The same change cfw install makes with system-launchd-boot-jetsam_panic_guard_bypass.",
                target: .firmware(.filesystem),
            ),
            VPhonePatchDeclaration(
                identifier: trustedDarwinOS,
                title: "Trusted darwinOS environment",
                summary: "Restores the guest in the trusted darwinOS environment (Ap,OSEnvironment 6, as cloudOS runs) and installs cloudOS's cryptexctl, so cryptexes can be personalized and installed while the guest runs instead of restoring again. Off by default, and an iPhone or iPad guest only. The environment comes from the restore's ticket, so changing this box needs a new restore. In it AMFI enforces Restricted Execution Mode, so the rebuilt trust cache allows every binary in both phases. Developer Mode does not work there: TXM runs only platform code in trusted darwinOS, so apps built with Xcode do not launch. Leave it off for app development.",
                target: .firmware(.filesystem),
            ),
            VPhonePatchDeclaration(
                identifier: internalReleaseType,
                title: "Offline app authorization",
                summary: "Sets ReleaseType Internal in SystemVersion.plist, before the reseal, so libmis on a virtual device skips the online authorization of a free personal team's app. A guest activated without Apple's servers has no activation record to sign that request with, so without this such an app never launches and Verify App fails. On in minimal for iPhone and iPad guests. Adds /usr/share/misc/os_variant_override, which keeps os_variant's internal content, diagnostics, UI and security checks off, as on a customer build; code that reads ReleaseType itself still sees Internal.",
                target: .firmware(.filesystem),
            ),
            VPhonePatchDeclaration(
                identifier: digestRehash,
                title: "Manifest digests",
                summary: "Rewrites the BuildManifest digests to match the merged image, its trust cache and seal.",
                target: .firmware(.manifest),
                bootEssential: true,
            ),
        ],
        provides: ["vphone.restore.image"],
    )
}
