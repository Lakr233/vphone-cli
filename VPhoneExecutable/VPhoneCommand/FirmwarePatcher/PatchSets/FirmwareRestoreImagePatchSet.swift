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
    public static let digestRehash = "manifest-boot-digest_rehash"

    /// Patches a machine asks for by name (`--allow`, or a preset that lists them);
    /// `minimal` and `watchos` leave them off, so the plain presets stay a lifelike
    /// stock guest.
    public static let optInPatches: Set = [debugserver]
    /// What `minimal` and `watchos` select from this set: everything but the
    /// opt-in patches.
    public static var presetPatches: Set<String> {
        Set(manifest.patches.map(\.identifier)).subtracting(optInPatches)
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
