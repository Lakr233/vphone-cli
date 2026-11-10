// FirmwarePatchFeature.swift — Patches a machine turns on or off together.
//
// A feature is not a patch set and not a preset: it names patches that already
// belong to sets, and is only useful as a group. Turning it on is the same as
// `--allow` for each of its patches, so the selection on disk stays a list of
// patch identifiers and nothing new has to be resolved. `fw patches --json`
// reports the features, so Launchpad can offer one checkbox for the group
// without declaring any patch of its own.

import Foundation
import VPhonePatchKit

public struct FirmwarePatchFeature: Sendable, Hashable, Identifiable {
    public let identifier: String
    public let title: String
    public let summary: String
    /// What the feature turns on, one entry per part. Most parts are one patch;
    /// a part that presets deliver in different ways lists each patch that does
    /// it, and a preset takes the first one its sets declare.
    public let parts: [[String]]

    public var id: String {
        identifier
    }

    /// Every patch any preset could take for the feature.
    public var allPatches: Set<String> {
        Set(parts.flatMap(\.self))
    }

    /// The patches `preset` turns on for the feature, or nil when it cannot
    /// carry it: some part has no patch in a set the preset names, so `--allow`
    /// would not resolve, or `cfw install` would refuse one of them on the
    /// preset's tvOS-family guest (``FirmwareGuestPatchResolution``).
    public func patches(in preset: VPhonePatchPreset) -> Set<String>? {
        let named = Set(preset.patchSets.map(\.identifier))
        let declared = Set(FirmwarePatchSetCatalog.bundled.filter { named.contains($0.identifier) }
            .flatMap(\.patches).map(\.identifier))
        var result: Set<String> = []
        for part in parts {
            guard let patch = part.first(where: declared.contains) else { return nil }
            result.insert(patch)
        }
        let refused: [String] = switch preset.identifier {
        case VPhonePatchPreset.homePodMiniIdentifier:
            FirmwareGuestPatchResolution.unvalidatedHomePodGuestPatches(enabled: result)
        case VPhonePatchPreset.homeViewIdentifier:
            FirmwareGuestPatchResolution.unvalidatedHomeViewGuestPatches(enabled: result)
        case VPhonePatchPreset.tvOSIdentifier:
            FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: result)
        case VPhonePatchPreset.tvOS4KIdentifier:
            FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: result, arm64eUserland: true)
        case VPhonePatchPreset.watchOSIdentifier:
            // The restore image skips trusted darwinOS on a watch.
            result.contains(FirmwareRestoreImagePatchSet.trustedDarwinOS) ? [FirmwareRestoreImagePatchSet.trustedDarwinOS] : []
        default:
            []
        }
        return refused.isEmpty ? result : nil
    }

    public func isAvailable(in preset: VPhonePatchPreset) -> Bool {
        patches(in: preset) != nil
    }
}

extension FirmwarePatchSetCatalog {
    /// Everything a debugger needs to attach to a process in a ``minimalPreset``
    /// guest and read its memory, and no more. `minimal` restores a resealed
    /// system onto a stock kernel and TXM; this adds:
    ///
    /// - A debugserver re-signed with `task_for_pid-allow` and no sandbox
    ///   profile: `filesystem-exp-debugserver` re-signs it before the reseal,
    ///   so its new hash lands in the regenerated trust cache; a preset that
    ///   installs the guest with `cfw install` takes
    ///   `system-debugserver-cfw-install` instead (HomePod and the Apple TV
    ///   presets leave it off).
    /// - launchd's jetsam panic guard, bypassed (`filesystem-exp-launchd_jetsam_panic_guard`
    ///   before the reseal, `system-launchd-boot-jetsam_panic_guard_bypass` with
    ///   `cfw install`). With developer mode on, MobileStorageMounter mounts the
    ///   Developer disk image, and launchd kills init over its daemons
    ///   ("jetsam property category (Daemon) is not initialized").
    /// - `kernel-cfw-task_for_pid` returns a task port for a process the caller
    ///   does not own, and `kernel-boot-task_conversion_eval` lets that port be
    ///   converted.
    /// - `kernel-cfw-debugger` reports the kernel debuggable, which
    ///   `task_for_pid` is gated on.
    /// - `kernel-boot-port_to_map` stops the panic when debugserver converts the
    ///   target's task port to a vm_map to read or write its memory.
    /// - `kernel-boot-proc_security_policy` lets the per-process policy check pass.
    /// - `kernel-boot-cred_label_update_execve` grants the platform label and
    ///   `kernel-boot-hook_cred_label` retargets the MACF hook to that handler;
    ///   the handler is dead code without the hook.
    /// - `txm-boot-developer_mode_bypass` reports developer mode on. On a TXM
    ///   device AMFI asks TXM, and kills the re-signed debugserver without it
    ///   ("Developer mode is disabled, task_for_pid-allow is disallowed");
    ///   enrolling from the guest does not survive a forced reboot.
    /// - `txm-cfw-debugger_entitlement` passes selector 42's (debug memory
    ///   mapping) debugger entitlement check, and `txm-boot-sel42_29` and
    ///   `txm-cfw-get_task_allow` set the target's get-task-allow byte where
    ///   selectors 42 and 41 read it, so a daemon without get-task-allow can be
    ///   debugged (Research/Firmware/txm_jb_patches.md).
    ///
    /// The rest of the kernel sets, and TXM's signature-admission patches, stay
    /// off: the resealed image's own trust cache admits everything it runs,
    /// the re-signed debugserver included, so AMFI's trust cache and execve
    /// patches are not needed (an iPhone17,3 26.5 guest attached without them).
    /// `standard` and its relatives turn every part on already, so the editor
    /// offers no box there.
    public static let userspaceDebugging = FirmwarePatchFeature(
        identifier: "userspace-debugging",
        title: "Userspace debugging",
        summary: "A re-signed debugserver, and the kernel and TXM patches it needs to attach to any process in the guest and read its memory. The kernel and TXM stay otherwise stock.",
        parts: [
            [FirmwareRestoreImagePatchSet.debugserver, "system-debugserver-cfw-install"],
            [FirmwareRestoreImagePatchSet.launchdJetsam, "system-launchd-boot-jetsam_panic_guard_bypass"],
            ["kernel-cfw-task_for_pid"],
            ["kernel-boot-task_conversion_eval"],
            ["kernel-cfw-debugger"],
            ["kernel-boot-port_to_map"],
            ["kernel-boot-proc_security_policy"],
            ["kernel-boot-cred_label_update_execve"],
            ["kernel-boot-hook_cred_label"],
            ["txm-boot-developer_mode_bypass"],
            ["txm-cfw-debugger_entitlement"],
            ["txm-boot-sel42_29"],
            ["txm-cfw-get_task_allow"],
        ],
    )

    /// A ``minimalPreset`` iPhone or iPad guest restored as trusted darwinOS,
    /// the environment cloudOS runs in, with cloudOS's cryptexctl: a cryptex
    /// can then be personalized and installed while the guest runs, instead of
    /// a restore for every change to the sealed system. It is one patch,
    /// `filesystem-exp-trusted_darwinos`; a feature so the editor offers it as
    /// a box beside the preset.
    /// No preset but `minimal` names the restore image set, so no other shows
    /// it. Research/Firmware/trusted_darwinos_cryptexes.md has the details.
    public static let trustedDarwinOS = FirmwarePatchFeature(
        identifier: "trusted-darwinos",
        title: "Trusted darwinOS environment",
        summary: "Restores the guest in the environment cloudOS runs in, which lets cryptexes be installed and mounted while it runs instead of restoring for every change to the system. Developer Mode is unavailable on research-board guests.",
        parts: [[FirmwareRestoreImagePatchSet.trustedDarwinOS]],
    )

    /// The features the bundle offers.
    public static let features: [FirmwarePatchFeature] = [userspaceDebugging, trustedDarwinOS]
}
