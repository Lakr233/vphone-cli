// VPhonePatchCatalogReport.swift — The full patch set, as text or as JSON.
//
// One report serves two readers. `vphone-cli fw patches` prints it for a person,
// and `--json` hands the same content to the Launchpad's patch editor, which
// renders it as the checkmark list. The UI is therefore never a second copy of
// the catalogue: it shows whatever this bundle declares, including patches from a
// set the app has never heard of.
//
// The report says what each patch *is*, not whether it would land on some VM: a
// version gate is evaluated at patch time against the two OS versions, which the
// editor does not know. `applicability` is carried through so the UI can say
// "iOS 27 only" beside the box.
//
// With a VM named, the report also compares the VM's selection against its plan
// and receipt (`FirmwarePatchDrift`), so a change that has not reached the guest
// yet is visible. Those fields are additive and appear only with a VM: a
// Launchpad that predates them ignores them, and a newer one reading an older
// bundle finds them absent.

import FirmwarePatcher
import Foundation
import VPhoneCoreKit
import VPhonePatchKit

public struct VPhonePatchCatalogReport: Sendable {
    public let vmName: String?
    public let selection: VPhoneVirtualMachinePatchSelection
    public let activePreset: VPhonePatchPreset
    public let presets: [VPhonePatchPreset]
    /// The named VM's other records, or nil when no VM was named.
    public let machine: MachineRecords?

    public init(
        vmName: String?,
        selection: VPhoneVirtualMachinePatchSelection,
        activePreset: VPhonePatchPreset,
        presets: [VPhonePatchPreset],
        machine: MachineRecords? = nil,
    ) {
        self.vmName = vmName
        self.selection = selection
        self.activePreset = activePreset
        self.presets = presets
        self.machine = machine
    }

    // MARK: - Machine Records

    /// What a VM records beside its selection: the plan, the receipt, whether
    /// `cfw install` finished, and the OS pairing the version gates run against.
    public struct MachineRecords: Sendable {
        public let plan: VPhoneVirtualMachinePatchPlan?
        public let receipt: VPhoneVirtualMachinePatchReceipt?
        /// Whether `cfw install` finished (`restore-info.json` has a variant);
        /// nil when the VM has no snapshot to tell.
        public let installed: Bool?
        public let iOSBase: VPhoneVersion?
        public let cloudOS: VPhoneVersion?

        public init(
            plan: VPhoneVirtualMachinePatchPlan?,
            receipt: VPhoneVirtualMachinePatchReceipt?,
            installed: Bool?,
            iOSBase: VPhoneVersion?,
            cloudOS: VPhoneVersion?,
        ) {
            self.plan = plan
            self.receipt = receipt
            self.installed = installed
            self.iOSBase = iOSBase
            self.cloudOS = cloudOS
        }

        /// Reads every record from the VM folder. The versions come from the
        /// plan, which is what `fw patch` gated against, else from the restore.
        public static func read(_ bundle: VPhoneBundle) -> MachineRecords {
            let plan = VPhonePatchPresetStore.plan(forVM: bundle.url)
            let restored = VPhoneRestoreInfo.load(fromBundle: bundle)
            return MachineRecords(
                plan: plan,
                receipt: VPhonePatchPresetStore.receipt(forVM: bundle.url),
                installed: VPhoneRestoreInfo.customFirmwareInstalled(inBundle: bundle),
                iOSBase: VPhoneVersion(plan?.iOSBaseVersion ?? restored?.ios.version),
                cloudOS: VPhoneVersion(plan?.cloudOSVersion ?? restored?.cloudOS.version),
            )
        }

        /// Each declaration compared across selection, plan and receipt.
        func states(selected: Set<String>) -> [FirmwarePatchDrift.PatchState] {
            let declarations = FirmwarePatchSetCatalog.allDeclarations
            return FirmwarePatchDrift.states(
                declarations: declarations,
                wanted: FirmwarePatchDrift.wantedPatches(
                    selected: selected,
                    declarations: declarations,
                    iOSBase: iOSBase,
                    cloudOS: cloudOS,
                ).subtracting(plan?.notApplicablePatches ?? []),
                planned: plan.map { Set($0.enabledPatches) },
                applied: receipt.map { $0.parts.mapValues { Set($0.patches) } },
                notApplicable: Set(receipt?.parts.values.flatMap(\.notApplicable) ?? []),
                standIns: FirmwareGuestSystemPatchSet.prebootRepairs,
                restoredCustomisedSystem: VPhoneCustomFirmwareInstaller.restoredCustomisedSystem(plan),
                part: VPhoneVirtualMachinePatchReceipt.part(for:),
            )
        }
    }

    // MARK: - JSON

    /// One patch as the editor sees it.
    struct PatchEntry: Encodable, Sendable {
        let identifier: String
        let title: String
        let summary: String
        let patchSet: String
        let patchSetName: String
        let target: String
        let applicability: String
        let bootEssential: Bool
        /// Whether the preset turns it on, before any version gate.
        let inPreset: Bool
        /// Whether this VM's own choice leaves it on.
        let enabled: Bool
        /// Set only when a VM is named.
        var state: FirmwarePatchDrift.PatchState?

        private enum CodingKeys: String, CodingKey {
            case identifier, title, summary, patchSet, patchSetName, target, applicability
            case bootEssential, inPreset, enabled
            case part, wanted, planned, applied, pending, delivery
        }

        /// The machine fields are written as `null` rather than left out when
        /// a VM is named but the record is missing, so a reader can tell "no
        /// plan" from "no VM".
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(identifier, forKey: .identifier)
            try container.encode(title, forKey: .title)
            try container.encode(summary, forKey: .summary)
            try container.encode(patchSet, forKey: .patchSet)
            try container.encode(patchSetName, forKey: .patchSetName)
            try container.encode(target, forKey: .target)
            try container.encode(applicability, forKey: .applicability)
            try container.encode(bootEssential, forKey: .bootEssential)
            try container.encode(inPreset, forKey: .inPreset)
            try container.encode(enabled, forKey: .enabled)
            guard let state else { return }
            try container.encode(state.part, forKey: .part)
            try container.encode(state.wanted, forKey: .wanted)
            try container.encode(state.planned, forKey: .planned)
            try container.encode(state.applied, forKey: .applied)
            try container.encode(state.isPending, forKey: .pending)
            try container.encode(state.isPending == true ? state.delivery.rawValue : nil, forKey: .delivery)
        }
    }

    struct PresetEntry: Encodable, Sendable {
        let identifier: String
        let title: String
        let summary: String
        let patchSets: [String]
    }

    /// A group of patches the editor turns on or off with one box
    /// (``FirmwarePatchFeature``).
    struct FeatureEntry: Encodable, Sendable {
        let identifier: String
        let title: String
        let summary: String
        let patches: [String]
        /// Whether the active preset names every set the feature draws on, so
        /// allowing its patches resolves.
        let available: Bool
    }

    struct Payload: Encodable, Sendable {
        let vmName: String?
        let activePreset: String
        let blockedPatches: [String]
        let allowedPatches: [String]
        let presets: [PresetEntry]
        let patches: [PatchEntry]
        let features: [FeatureEntry]
        /// Set only when a VM is named.
        let machine: MachineRecords?

        private enum CodingKeys: String, CodingKey {
            case vmName, activePreset, blockedPatches, allowedPatches, presets, patches, features
            case planRecorded, receiptRecorded, receiptParts, installed, pendingPatches
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(vmName, forKey: .vmName)
            try container.encode(activePreset, forKey: .activePreset)
            try container.encode(blockedPatches, forKey: .blockedPatches)
            try container.encode(allowedPatches, forKey: .allowedPatches)
            try container.encode(presets, forKey: .presets)
            try container.encode(patches, forKey: .patches)
            try container.encode(features, forKey: .features)
            guard let machine else { return }
            try container.encode(machine.plan != nil, forKey: .planRecorded)
            try container.encode(machine.receipt != nil, forKey: .receiptRecorded)
            try container.encode(machine.receipt.map { $0.parts.keys.sorted() }, forKey: .receiptParts)
            try container.encode(machine.installed, forKey: .installed)
            let known = patches.compactMap { $0.state?.isPending }
            try container.encode(
                known.isEmpty ? nil : known.count(where: { $0 }),
                forKey: .pendingPatches,
            )
        }
    }

    /// The patches a preset turns on, before any version gate.
    ///
    /// `fw set-patches` normalises a VM's record against this, so both readers of
    /// "is this patch in the preset" answer from one rule.
    public static func patchesInPreset(_ preset: VPhonePatchPreset) -> Set<String> {
        let presetSets = Set(preset.patchSets.map(\.identifier))
        var result: Set<String> = []
        for set in FirmwarePatchSetCatalog.bundled where presetSets.contains(set.identifier) {
            for patch in set.patches where preset.selection.includes(patch.identifier) {
                result.insert(patch.identifier)
            }
        }
        return result
    }

    /// The patches this VM's choice leaves on, before any version gate.
    public func selectedPatches() -> Set<String> {
        let presetSets = Set(activePreset.patchSets.map(\.identifier))
        let included = Self.patchesInPreset(activePreset)
        let allowed = Set(selection.allowedPatches)
        let blocked = Set(selection.blockedPatches)
        var result: Set<String> = []
        for set in FirmwarePatchSetCatalog.bundled where presetSets.contains(set.identifier) {
            for patch in set.patches
                where (included.contains(patch.identifier) || allowed.contains(patch.identifier))
                && !blocked.contains(patch.identifier)
            {
                result.insert(patch.identifier)
            }
        }
        return result
    }

    /// Each patch compared across the VM's records, or nil with no VM.
    public func states() -> [FirmwarePatchDrift.PatchState]? {
        machine?.states(selected: selectedPatches())
    }

    /// Every patch every bundled set declares, not just the active preset's.
    ///
    /// The editor needs the whole catalogue to show a patch that switching preset
    /// would bring in, so `inPreset` carries the distinction rather than the list
    /// being filtered.
    func entries() -> [PatchEntry] {
        let included = Self.patchesInPreset(activePreset)
        let selected = selectedPatches()
        let states = Dictionary(
            (states() ?? []).map { ($0.identifier, $0) },
            uniquingKeysWith: { first, _ in first },
        )
        var result: [PatchEntry] = []
        for set in FirmwarePatchSetCatalog.bundled {
            for patch in set.patches {
                result.append(PatchEntry(
                    identifier: patch.identifier,
                    title: patch.title,
                    summary: patch.summary,
                    patchSet: set.identifier,
                    patchSetName: set.name,
                    target: patch.target.description,
                    applicability: patch.applicability.description,
                    bootEssential: patch.bootEssential,
                    inPreset: included.contains(patch.identifier),
                    enabled: selected.contains(patch.identifier),
                    state: states[patch.identifier],
                ))
            }
        }
        return result
    }

    public func jsonText() throws -> String {
        let payload = Payload(
            vmName: vmName,
            activePreset: activePreset.identifier,
            blockedPatches: selection.blockedPatches.sorted(),
            allowedPatches: selection.allowedPatches.sorted(),
            presets: presets.map {
                PresetEntry(
                    identifier: $0.identifier,
                    title: $0.title,
                    summary: $0.summary,
                    patchSets: $0.patchSets.map(\.identifier),
                )
            },
            patches: entries(),
            features: FirmwarePatchSetCatalog.features.map {
                FeatureEntry(
                    identifier: $0.identifier,
                    title: $0.title,
                    summary: $0.summary,
                    patches: $0.patches.sorted(),
                    available: $0.isAvailable(in: activePreset),
                )
            },
            machine: machine,
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Text

    public func text(libraryArguments: String = "") -> String {
        var lines: [String] = []
        if let vmName {
            lines.append("VM:     \(vmName)")
        }
        lines.append("Preset: \(activePreset.identifier) — \(activePreset.title)")
        if !activePreset.summary.isEmpty {
            lines.append("        \(activePreset.summary)")
        }
        if !selection.blockedPatches.isEmpty {
            lines.append("Off:    \(selection.blockedPatches.sorted().joined(separator: ", "))")
        }
        if !selection.allowedPatches.isEmpty {
            lines.append("On:     \(selection.allowedPatches.sorted().joined(separator: ", "))")
        }
        if let machine {
            lines.append("Plan:   " + (machine.plan.map {
                "preset \($0.presetIdentifier), \($0.enabledPatches.count) patches (last fw patch)"
            } ?? "none — fw patch has not run"))
            lines.append("Applied: " + (machine.receipt.map {
                "parts recorded: \($0.parts.keys.sorted { Self.partOrder($0) < Self.partOrder($1) }.joined(separator: ", "))"
            } ?? "no receipt — what the guest runs is not recorded"))
            let installed = switch machine.installed {
            case true?: "yes"
            case false?: "no (cfw install has not finished)"
            case nil: "unknown"
            }
            lines.append("Installed: \(installed)")
        }

        lines.append("")
        lines.append("Presets:")
        for preset in presets {
            let marker = preset.identifier == activePreset.identifier ? "*" : " "
            lines.append("  \(marker) \(preset.identifier.padding(toLength: 12, withPad: " ", startingAt: 0))"
                + " \(preset.title)")
        }

        let entries = entries()
        lines.append("")
        lines.append("Patches (\(entries.filter(\.enabled).count) of \(entries.count) on):")
        var lastSet = ""
        for entry in entries {
            if entry.patchSet != lastSet {
                lines.append("")
                lines.append("  \(entry.patchSetName)  [\(entry.patchSet)]")
                lastSet = entry.patchSet
            }
            let box = entry.enabled ? "[x]" : "[ ]"
            var notes: [String] = []
            if entry.applicability != "any" {
                notes.append(entry.applicability)
            }
            if entry.bootEssential {
                notes.append("boot-essential")
            }
            if let state = entry.state, state.isPending == true {
                notes.append(state.wanted ? "not applied yet" : "still applied")
            }
            let suffix = notes.isEmpty ? "" : "  (\(notes.joined(separator: ", ")))"
            lines.append("    \(box) \(entry.identifier)\(suffix)")
        }

        let selected = selectedPatches()
        let features = FirmwarePatchSetCatalog.features.filter { $0.isAvailable(in: activePreset) }
        if !features.isEmpty {
            lines.append("")
            lines.append("Features (turn one on by allowing each of its patches with `fw set-patches`):")
            for feature in features {
                let on = feature.patches.intersection(selected).count
                let state = on == feature.patches.count ? "on" : on == 0 ? "off" : "\(on) of \(feature.patches.count) on"
                lines.append("  \(feature.identifier) — \(feature.title) (\(state))")
                lines.append("    " + feature.patches.sorted().map { "--allow \($0)" }.joined(separator: " "))
            }
        }

        if let vmName, let machine, let states = states() {
            let pending = states.filter { $0.isPending == true }
            if pending.isEmpty {
                if states.contains(where: { $0.isPending != nil }) {
                    lines.append("")
                    lines.append("Every patch matches what is recorded for this machine.")
                }
            } else if machine.installed == true {
                lines.append("")
                lines.append("\(pending.count) patch(es) differ from what the guest has. To apply them:")
                lines += Self.pendingSteps(pending, vmName: vmName, libraryArguments: libraryArguments)
            } else {
                lines.append("")
                lines.append("\(pending.count) patch(es) differ from the last fw patch. The next fw patch,"
                    + " restore and cfw install build the machine with this selection.")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Pending Steps

    /// A part's position: boot-chain components in boot order, then the guest.
    static func partOrder(_ part: String) -> Int {
        let order = VPhoneFirmwareComponent.allCases.map(\.rawValue) + [VPhoneVirtualMachinePatchReceipt.guestPart]
        return order.firstIndex(of: part) ?? order.count
    }

    /// What each part still needs on an installed VM, grouped by part: the
    /// step that delivers it, then each patch with the state it is changing to.
    ///
    /// `libraryArguments` is appended to every command shown, so a VM outside
    /// the default library gets a command that finds it.
    public static func pendingSteps(
        _ pending: [FirmwarePatchDrift.PatchState],
        vmName: String,
        libraryArguments: String = "",
    ) -> [String] {
        let vm = vmName + libraryArguments
        let byPart = Dictionary(grouping: pending, by: \.part)
        var lines: [String] = []
        for part in byPart.keys.sorted(by: { partOrder($0) < partOrder($1) }) {
            let states = byPart[part] ?? []
            guard let delivery = states.first?.delivery else { continue }
            let step = switch delivery {
            case .firmwarePatch:
                "run `vphone-cli fw patch \(vm)`; it takes effect at the next boot."
                    + " It needs the VM's restore tree (kept with `--keep-artifacts`)."
            case .updateKernel:
                "run `sudo vphone-cli cfw update-kernel \(vm)` with the machine off;"
                    + " it re-patches the kernelcache and keeps the guest's data (no restore)."
            case .restore where part == VPhoneFirmwareComponent.iBSS.rawValue
                || part == VPhoneFirmwareComponent.iBEC.rawValue:
                "used only while restoring, so the change matters at the next restore and not to this guest."
            case .restore:
                "only a restore writes \(part), and a restore erases the guest's data: there is no in-place one."
            case .updateEnvironment:
                "run `sudo vphone-cli cfw update-environment \(vm)`"
                    + " (in Launchpad: Update Guest Environment), with the machine off."
            }
            lines.append("  \(part): \(step)")
            for state in states.sorted(by: { $0.identifier < $1.identifier }) {
                lines.append("    \(state.wanted ? "on " : "off") \(state.identifier)")
            }
        }
        return lines
    }
}
