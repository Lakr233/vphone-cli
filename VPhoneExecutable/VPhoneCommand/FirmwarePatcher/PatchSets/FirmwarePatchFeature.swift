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
    /// The patches the feature turns on, by identifier.
    public let patches: Set<String>

    public var id: String {
        identifier
    }

    /// Whether `preset` can carry this feature: it names every set that
    /// declares one of its patches, so `--allow` for each resolves. A preset
    /// without one of those sets cannot turn the feature on at all.
    public func isAvailable(in preset: VPhonePatchPreset) -> Bool {
        let named = Set(preset.patchSets.map(\.identifier))
        return patches.allSatisfy { patch in
            FirmwarePatchSetCatalog.bundled.contains { set in
                named.contains(set.identifier) && set.patches.contains { $0.identifier == patch }
            }
        }
    }
}

extension FirmwarePatchSetCatalog {
    /// Everything a debugger needs to attach to a process in a ``minimalPreset``
    /// guest and read its memory, and no more. `minimal` restores a resealed
    /// system onto a stock kernel and TXM; this adds:
    ///
    /// - `filesystem-exp-debugserver`: re-signs the guest's debugserver with
    ///   `task_for_pid-allow` and no sandbox profile, before the reseal, so its
    ///   new hash lands in the regenerated trust cache.
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
    /// - `kernel-boot-amfi_trustcache` and `kernel-boot-amfi_execve` admit the
    ///   re-signed debugserver should it run outside the image's trust cache.
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
    /// off: the resealed image's own trust cache admits everything it runs.
    /// `standard` and its relatives install their debugserver with
    /// `cfw install` instead and already carry these kernel and TXM patches.
    public static let userspaceDebugging = FirmwarePatchFeature(
        identifier: "userspace-debugging",
        title: "Userspace debugging",
        summary: "A re-signed debugserver, and the kernel and TXM patches it needs to attach to any process in the guest and read its memory. The kernel and TXM stay otherwise stock.",
        patches: [
            FirmwareRestoreImagePatchSet.debugserver,
            "kernel-cfw-task_for_pid",
            "kernel-boot-task_conversion_eval",
            "kernel-cfw-debugger",
            "kernel-boot-port_to_map",
            "kernel-boot-proc_security_policy",
            "kernel-boot-cred_label_update_execve",
            "kernel-boot-hook_cred_label",
            "kernel-boot-amfi_trustcache",
            "kernel-boot-amfi_execve",
            "txm-boot-developer_mode_bypass",
            "txm-cfw-debugger_entitlement",
            "txm-boot-sel42_29",
            "txm-cfw-get_task_allow",
        ],
    )

    /// The features the bundle offers.
    public static let features: [FirmwarePatchFeature] = [userspaceDebugging]
}
