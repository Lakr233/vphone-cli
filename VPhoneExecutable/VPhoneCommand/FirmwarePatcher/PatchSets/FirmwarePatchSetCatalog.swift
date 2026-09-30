// FirmwarePatchSetCatalog.swift — The patch sets built into the bundle.
//
// These are the sets a preset can name as `Bundled`. They are compiled in rather
// than loaded, so `cfw install` running as root never has to open a file to learn
// what the bundle's own patches are — an external `.vphonepatchset` is the only
// thing that has to be imported and pinned first.

import Foundation
import VPhonePatchKit

public enum FirmwarePatchSetCatalog {
    /// Every bundled set, in the order the pipeline would run them.
    public static let bundled: [VPhonePatchSetManifest] = [
        FirmwareBootChainPatchSet.manifest,
        FirmwareKernelBasePatchSet.manifest,
        FirmwareKernelJailbreakPatchSet.manifest,
        FirmwareKernelHypervisorPatchSet.manifest,
        FirmwareKernelFridaPatchSet.manifest,
        FirmwareDeviceTreePatchSet.manifest,
        FirmwareGuestSystemPatchSet.manifest,
        FirmwareGuestDisplayPatchSet.manifest,
        FirmwareGuestIdentityPatchSet.manifest,
    ]

    /// Every bundled set, as a preset references them.
    ///
    /// Both shipped presets name all of them. A preset picks patches with its
    /// selection, not by leaving a set out, so the editor always sees the whole
    /// catalogue and can turn any patch on or off.
    public static let bundledReferences: [VPhonePatchSetReference] =
        bundled.map { .bundled($0.identifier) }

    public static func manifest(identifier: String) -> VPhonePatchSetManifest? {
        bundled.first { $0.identifier == identifier }
    }

    /// Every declared patch across every bundled set.
    public static var allDeclarations: [VPhonePatchDeclaration] {
        bundled.flatMap(\.patches)
    }

    // MARK: - Built-in Presets

    /// Patches that are declared but off unless someone asks for them.
    ///
    /// The Frida relaxations widen what any process in the guest may do and
    /// nothing needs them to boot, so `standard` leaves them off. They stay in the
    /// catalogue, version-gated like everything else, and a VM can check them on.
    ///
    /// The hypervisor concealment pair is off for a harder reason: it stops a
    /// freshly restored 26.4 guest booting at all. See
    /// ``hypervisorConcealmentPatches``. The rest of the former EXP variant is
    /// off with it, bar the camera: see ``experimentalIdentityPatches``.
    public static let manualOnlyPatches: Set<String> =
        Set(FirmwareKernelFridaPatchSet.manifest.patches.map(\.identifier))
            .union(hypervisorConcealmentPatches)
            .union(experimentalIdentityPatches)

    /// The former EXP patches that make the guest claim to be an iPhone17,3.
    ///
    /// `standard` is the JB baseline plus the camera. The camera needs the device
    /// tree's `/product/camera`, ISP and SMC nodes and `dyld-cfw-camera`, which stay on;
    /// it does not need the identity rewrites. They shipped on with the hypervisor
    /// concealment when EXP joined the JB flow, and guests from that build lost
    /// location (issue #438), so they go back to opt-in with it. `extended` or a
    /// per-VM checkmark turns them back on.
    public static let experimentalIdentityPatches: Set<String> = [
        "devicetree-exp-target_sub_type",
        "devicetree-exp-compatible_secondary",
        "devicetree-exp-product_fdr_product_type",
        "devicetree-exp-product_sub_product_type",
        "devicetree-exp-product_unique_model",
        "devicetree-exp-product_gestalt_variants_rename",
        "devicetree-exp-arm_io_device_type",
        "devicetree-exp-arm_io_soc_generation",
        FirmwareGuestIdentityPatchSet.prebootDeviceTreeIdentity,
    ]

    /// The `hv_vmm_present` concealment, which is one patch in everything but name
    /// and has to be selected as a whole.
    ///
    /// Renaming the OID without mangling the shared cache breaks the graphics and
    /// ML paths; mangling the cache without the rename does nothing. watchdogd
    /// caches the sysctl at startup and, when the renamed OID returns ENOENT,
    /// reaches a `brk` that launchd turns into a panic, so its patch goes with the
    /// rename and is pointless without it. All three are off
    /// in `standard` because on a freshly restored 26.4 guest the rename makes
    /// `bluetoothd`'s cached `kern.hv_vmm_present` lookup fail, which sends it down
    /// the `MGIsDeviceOneOfType` path, leaves its transport singleton NULL and
    /// crash-loops it until launchd throttles it; `locationd` then blocks on the
    /// throttled Bluetooth XPC service, the data migrator hangs, and SpringBoard
    /// waits on migration forever — a black screen with no panic. See
    /// `Research/Patches/hv_vmm_present_usermode_xrefs.md`.
    public static let hypervisorConcealmentPatches: Set<String> = [
        "kernel-exp-hv_vmm",
        "dyld-exp-hv_vmm",
        "system-watchdogd-exp-hv_vmm_cache",
    ]

    /// The preset a VM gets when nothing else is named.
    ///
    /// The shipped `standard.plist` must match this; `FirmwarePatchSetTests`
    /// checks that it does. This copy is what a dev build with no staged
    /// `patches_presets` directory falls back to, so `fw patch` works straight out
    /// of an Xcode build.
    public static let standardPreset = VPhonePatchPreset(
        identifier: VPhonePatchPreset.standardIdentifier,
        title: "Standard",
        summary: "The patches every vphone VM needs to boot, jailbroken, with a working display and camera.",
        patchSets: bundledReferences,
        selection: .block(manualOnlyPatches),
    )

    /// Everything the bundle declares, including the Frida relaxations, the
    /// hypervisor concealment and the iPhone17,3 identity. Each patch's own version
    /// gate still decides whether it lands.
    public static let extendedPreset = VPhonePatchPreset(
        identifier: "extended",
        title: "Extended",
        summary: """
        Every patch this bundle declares, including the Frida Stalker relaxations, \
        the iPhone17,3 identity rewrites, and the hv_vmm_present concealment that a \
        freshly restored 26.4 guest does not survive.
        """,
        patchSets: bundledReferences,
        selection: .all,
    )

    /// The presets the bundle ships.
    public static let builtInPresets: [VPhonePatchPreset] = [standardPreset, extendedPreset]
}
