// FirmwarePatchDrift.swift — Where a VM's patches stand, and what a change still needs.
//
// A VM carries three patch records: the selection (what the owner wants), the
// plan (what the last `fw patch` built) and the receipt (what is live in the
// guest, part by part). This file compares them. It reads no file and writes
// none: `fw patches`, `fw set-patches` and `restore` hand it the records they
// already loaded, so the comparison is one pure rule the tests can pin.
//
// Parts are named by the caller's rule (`VPhoneVirtualMachinePatchReceipt.part(for:)`
// in `vphone-cli`), passed in as a closure so the receipt stays the one place
// that spells a part key.

import Foundation
import VPhonePatchKit

// MARK: - Delivery

/// The step that carries a change to one patch into a guest that is already
/// installed. Which one depends on where the patch lands, and for the
/// kernelcache on whether the restore installed a customised system.
public enum FirmwarePatchDelivery: String, Sendable, Hashable, CaseIterable, Codable {
    /// AVPBooter sits in the VM folder and is read at every boot, so
    /// `fw patch` alone delivers it. `fw patch` still needs the VM's restore
    /// tree, which is kept only with `--keep-artifacts`.
    case firmwarePatch = "fw-patch"
    /// The kernelcache lives in Preboot as an IMG4; `cfw update-kernel`
    /// re-patches it from the VM's FirmwareOriginals and swaps its IM4P into
    /// Preboot under the signed manifest, with no restore and no erase.
    case updateKernel = "update-kernel"
    /// iBSS and iBEC are used only while restoring, LLB lives in NOR, and TXM
    /// and DeviceTree are personalized into Preboot by the restore, which
    /// erases. Nothing else writes them.
    case restore
    /// Everything `cfw install` writes into the guest volumes.
    case updateEnvironment = "update-environment"

    /// - Parameter restoredCustomisedSystem: Whether the guest's restore
    ///   installed a system `fw patch` customised (``FirmwareRestoreImagePatchSet``).
    ///   `cfw update-kernel` refuses such a guest, so its kernelcache, like
    ///   the rest of its boot chain, changes only with a restore.
    public init(target: VPhonePatchTarget, restoredCustomisedSystem: Bool = false) {
        switch target {
        case .firmware(.avpBooter):
            self = .firmwarePatch
        case .firmware(.kernelcache):
            self = restoredCustomisedSystem ? .restore : .updateKernel
        case .firmware:
            // iBSS, iBEC, LLB, TXM, DeviceTree, SEP, and the restore-only
            // Filesystem/Manifest.
            self = .restore
        case .dyldSharedCache, .guestExecutable, .guestEntitlements, .guestFile, .prebootDeviceTree:
            self = .updateEnvironment
        @unknown default:
            // A target this build does not know is written by the guest install.
            self = .updateEnvironment
        }
    }
}

// MARK: - Drift

public enum FirmwarePatchDrift {
    /// The boot-chain components a successful restore writes into the guest,
    /// in boot order. AVPBooter is not among them: it never leaves the VM
    /// folder, and `fw patch` records it itself.
    public static let restoredComponents: [VPhoneFirmwareComponent] = [
        .iBSS, .iBEC, .llb, .txm, .restoreRamDisk, .kernelcache, .deviceTree, .sep,
    ]

    /// What a restore put into each component it wrote: the plan's enabled
    /// patches that target that component.
    ///
    /// Every component in ``restoredComponents`` is present, empty when the plan
    /// turned all of its patches off, so a receipt records "nothing" rather than
    /// leaving the part unknown.
    public static func restoredParts(
        enabledPatches: Set<String>,
        declarations: [VPhonePatchDeclaration] = FirmwarePatchSetCatalog.allDeclarations,
    ) -> [VPhoneFirmwareComponent: [String]] {
        var result: [VPhoneFirmwareComponent: [String]] = [:]
        for component in restoredComponents {
            result[component] = declarations
                .filter { $0.target == .firmware(component) && enabledPatches.contains($0.identifier) }
                .map(\.identifier)
                .sorted()
        }
        return result
    }

    /// The patches the selection turns on that also pass their version gate.
    ///
    /// `selected` is the selection before any gate (a preset plus the VM's
    /// boxes). A patch pinned to another OS release is not wanted on this VM,
    /// however it was selected, so it never counts as drift. With neither
    /// version known there is nothing to gate against and the selection stands.
    public static func wantedPatches(
        selected: Set<String>,
        declarations: [VPhonePatchDeclaration],
        iOSBase: VPhoneVersion?,
        cloudOS: VPhoneVersion?,
    ) -> Set<String> {
        guard iOSBase != nil || cloudOS != nil else { return selected }
        return Set(declarations.lazy
            .filter { selected.contains($0.identifier) }
            .filter { $0.applicability.matches(iOSBase: iOSBase, cloudOS: cloudOS) }
            .map(\.identifier))
    }

    /// One patch, compared across the three records.
    public struct PatchState: Sendable, Hashable {
        public let identifier: String
        public let target: VPhonePatchTarget
        /// The receipt part the patch lives in.
        public let part: String
        /// Whether the current selection wants it, after the version gate.
        public let wanted: Bool
        /// Whether the last `fw patch` turned it on; nil with no plan.
        public let planned: Bool?
        /// Whether it is live in the guest; nil when the receipt does not
        /// record its part.
        public let applied: Bool?
        /// Whether the guest's restore installed a customised system, which
        /// changes what delivers a kernelcache patch.
        public let restoredCustomisedSystem: Bool

        /// What the guest is believed to run: the receipt where it records the
        /// part, else the plan, which is what the next restore or install
        /// would write. Nil when neither says.
        public var reference: Bool? {
            applied ?? planned
        }

        /// Whether the wanted state still has to reach the guest. Nil when
        /// nothing records what the guest has.
        public var isPending: Bool? {
            reference.map { $0 != wanted }
        }

        public var delivery: FirmwarePatchDelivery {
            FirmwarePatchDelivery(target: target, restoredCustomisedSystem: restoredCustomisedSystem)
        }
    }

    /// Every declaration, compared.
    ///
    /// - Parameters:
    ///   - wanted: ``wantedPatches(selected:declarations:iOSBase:cloudOS:)``.
    ///   - planned: The plan's enabled patches, or nil with no plan.
    ///   - applied: The receipt's patches by part, or nil with no receipt. A
    ///     part missing from it leaves its patches' `applied` nil.
    ///   - standIns: A patch and the patch that puts the same change into
    ///     the guest another way, such as a boot-chain DeviceTree patch and the
    ///     Preboot repair for a VM restored before it
    ///     (`FirmwareGuestSystemPatchSet.prebootRepairs`). When the stand-in is
    ///     live, the patch reads as applied, whatever its own part records.
    ///   - restoredCustomisedSystem: Whether the guest's restore installed a
    ///     customised system; see ``FirmwarePatchDelivery/init(target:restoredCustomisedSystem:)``.
    ///   - part: The receipt's rule for naming a target's part.
    public static func states(
        declarations: [VPhonePatchDeclaration],
        wanted: Set<String>,
        planned: Set<String>?,
        applied: [String: Set<String>]?,
        notApplicable: Set<String> = [],
        standIns: [String: String] = [:],
        restoredCustomisedSystem: Bool = false,
        part: (VPhonePatchTarget) -> String,
    ) -> [PatchState] {
        let partOf = part
        let targets = Dictionary(declarations.map { ($0.identifier, $0.target) }, uniquingKeysWith: { first, _ in first })
        return declarations.map { declaration in
            let part = partOf(declaration.target)
            let isWanted = wanted.contains(declaration.identifier)
            // A patch the guest has nothing for reads as whatever is wanted,
            // so turning it on or off is never reported as pending.
            var isApplied = applied?[part].map {
                notApplicable.contains(declaration.identifier) ? isWanted : $0.contains(declaration.identifier)
            }
            if let standIn = standIns[declaration.identifier],
               let standInTarget = targets[standIn],
               applied?[partOf(standInTarget)]?.contains(standIn) == true
            {
                isApplied = true
            }
            return PatchState(
                identifier: declaration.identifier,
                target: declaration.target,
                part: part,
                wanted: isWanted,
                planned: planned.map { $0.contains(declaration.identifier) },
                applied: isApplied,
                restoredCustomisedSystem: restoredCustomisedSystem,
            )
        }
    }
}
