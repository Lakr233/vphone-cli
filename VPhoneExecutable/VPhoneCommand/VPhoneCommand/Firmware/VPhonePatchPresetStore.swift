// VPhonePatchPresetStore.swift — Finding presets, and remembering a VM's choice.
//
// Four files matter here.
//
// `VPhone.bundle/Contents/Resources/patches_presets/*.plist` are the presets the
// bundle ships. They are prewritten and reviewed; nothing in the tool writes one.
//
// `<vm>/PatchSelection.plist` is the VM's choice: which preset, and which patches
// the user unchecked. It is written when the VM is created or edited, and read by
// `fw patch`.
//
// `<vm>/PatchPlan.plist` is what `fw patch` actually resolved, written after the
// boot chain is patched. `cfw install` reads it so the guest half of the install
// applies the same selection the boot chain was built with, without resolving the
// preset a second time against versions that may since have changed.
//
// `<vm>/PatchPreset.plist` is a preset given to `--preset` as a file, kept so
// later steps, root ones included, resolve it without the original.

import ArgumentParser
import FirmwarePatcher
import Foundation
import VPhoneCoreKit
import VPhonePatchKit

// MARK: - VM Records

/// A VM's patch choice: a preset, plus the boxes the user changed.
///
/// Only the differences from the preset are stored. A patch nobody touched follows
/// whatever the preset says, so a later preset revision reaches VMs that never
/// overrode it.
public struct VPhoneVirtualMachinePatchSelection: Codable, Sendable, Hashable {
    public var presetIdentifier: String
    /// Patches the user unchecked.
    public var blockedPatches: [String]
    /// Patches the user checked that the preset leaves off. Each still has to pass
    /// its own version gate, so checking a box cannot put a patch on an OS it was
    /// never meant for.
    public var allowedPatches: [String]

    public init(
        presetIdentifier: String = VPhonePatchPreset.standardIdentifier,
        blockedPatches: [String] = [],
        allowedPatches: [String] = [],
    ) {
        self.presetIdentifier = presetIdentifier
        self.blockedPatches = blockedPatches
        self.allowedPatches = allowedPatches
    }

    private enum CodingKeys: String, CodingKey {
        case presetIdentifier = "Preset"
        case blockedPatches = "BlockedPatches"
        case allowedPatches = "AllowedPatches"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        presetIdentifier = try container.decodeIfPresent(String.self, forKey: .presetIdentifier)
            ?? VPhonePatchPreset.standardIdentifier
        // A record outlives the bundle that wrote it, so a renamed patch is read
        // under the name this bundle declares.
        blockedPatches = try FirmwarePatchSetCatalog.currentIdentifiers(
            container.decodeIfPresent([String].self, forKey: .blockedPatches) ?? [],
        )
        allowedPatches = try FirmwarePatchSetCatalog.currentIdentifiers(
            container.decodeIfPresent([String].self, forKey: .allowedPatches) ?? [],
        )
    }
}

/// What `fw patch` resolved, recorded for `cfw install`.
public struct VPhoneVirtualMachinePatchPlan: Codable, Sendable, Hashable {
    public var presetIdentifier: String
    public var patchSets: [String]
    public var enabledPatches: [String]
    public var notApplicablePatches: [String]
    public var iOSBaseVersion: String?
    public var cloudOSVersion: String?
    /// The preset's knobs, carried through so `cfw install` reads the same values
    /// the boot chain was built with rather than resolving the preset again.
    public var parameters: [String: String]

    public init(
        plan: VPhonePatchPlan,
        iOSBase: VPhoneVersion?,
        cloudOS: VPhoneVersion?,
        notApplicablePatches: Set<String> = [],
    ) {
        presetIdentifier = plan.presetIdentifier
        patchSets = plan.patchSets.map(\.identifier)
        let notApplicable = notApplicablePatches.intersection(plan.enabled)
        enabledPatches = plan.enabled.subtracting(notApplicable).sorted()
        self.notApplicablePatches = notApplicable.sorted()
        iOSBaseVersion = iOSBase?.description
        cloudOSVersion = cloudOS?.description
        parameters = plan.parameters
    }

    /// Whether the patch declaring `identifier` was turned on for this VM.
    public func isEnabled(_ identifier: String) -> Bool {
        enabledPatches.contains(identifier)
    }

    public var selectedPatches: Set<String> {
        Set(enabledPatches).union(notApplicablePatches)
    }

    private enum CodingKeys: String, CodingKey {
        case presetIdentifier = "Preset"
        case patchSets = "PatchSets"
        case enabledPatches = "EnabledPatches"
        case notApplicablePatches = "NotApplicablePatches"
        case iOSBaseVersion = "IOSBaseVersion"
        case cloudOSVersion = "CloudOSVersion"
        case parameters = "Parameters"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        presetIdentifier = try container.decode(String.self, forKey: .presetIdentifier)
        patchSets = try container.decodeIfPresent([String].self, forKey: .patchSets) ?? []
        enabledPatches = try FirmwarePatchSetCatalog.currentIdentifiers(
            container.decodeIfPresent([String].self, forKey: .enabledPatches) ?? [],
        )
        notApplicablePatches = try FirmwarePatchSetCatalog.currentIdentifiers(
            container.decodeIfPresent([String].self, forKey: .notApplicablePatches) ?? [],
        )
        iOSBaseVersion = try container.decodeIfPresent(String.self, forKey: .iOSBaseVersion)
        cloudOSVersion = try container.decodeIfPresent(String.self, forKey: .cloudOSVersion)
        parameters = try container.decodeIfPresent([String: String].self, forKey: .parameters) ?? [:]
    }
}

/// What is live in the guest now, part by part.
///
/// `PatchSelection.plist` is what the owner wants and `PatchPlan.plist` is what
/// the last `fw patch` built; neither says what the guest actually runs. A
/// boot-chain file patched in the restore tree reaches the guest only when a
/// restore flashes it, and a guest patch only when `cfw install` writes it. Each
/// step that puts bytes into the guest replaces its own part here, so the
/// difference between this and the plan is exactly what a change still has to
/// reach.
///
/// Parts are keyed by ``part(for:)``: a boot-chain component's raw value for a
/// `.firmware` target, ``guestPart`` for everything `cfw install` writes.
public struct VPhoneVirtualMachinePatchReceipt: Codable, Sendable, Hashable {
    public struct Entry: Codable, Sendable, Hashable {
        /// The enabled patch identifiers whose bytes are in this part, sorted.
        public var patches: [String]
        /// The verb that wrote the part: `fw patch`, `restore`, `cfw install`, …
        public var writer: String
        /// The `VPhone.bundle` version that wrote it, when known.
        public var bundleVersion: String?
        public var date: Date
        /// Selected patches the writer found nothing to do for on this guest:
        /// a repair for hardware it does not have, a spoof with no value set.
        /// They are neither live nor missing, so they never count as drift.
        public var notApplicable: [String]

        public init(
            patches: some Sequence<String>,
            writer: String,
            bundleVersion: String?,
            date: Date = Date(),
            notApplicable: some Sequence<String> = [String](),
        ) {
            self.patches = Array(Set(patches)).sorted()
            self.writer = writer
            self.bundleVersion = bundleVersion
            self.date = date
            self.notApplicable = Array(Set(notApplicable)).sorted()
        }

        private enum CodingKeys: String, CodingKey {
            case patches = "Patches"
            case writer = "Writer"
            case bundleVersion = "BundleVersion"
            case date = "Date"
            case notApplicable = "NotApplicable"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            patches = try FirmwarePatchSetCatalog.currentIdentifiers(
                container.decode([String].self, forKey: .patches),
            ).sorted()
            writer = try container.decode(String.self, forKey: .writer)
            bundleVersion = try container.decodeIfPresent(String.self, forKey: .bundleVersion)
            date = try container.decode(Date.self, forKey: .date)
            notApplicable = try FirmwarePatchSetCatalog.currentIdentifiers(
                container.decodeIfPresent([String].self, forKey: .notApplicable) ?? [],
            ).sorted()
        }
    }

    public static let guestPart = "Guest"

    public var parts: [String: Entry]

    public init(parts: [String: Entry] = [:]) {
        self.parts = parts
    }

    /// The part a patch with this target lives in.
    public static func part(for target: VPhonePatchTarget) -> String {
        if case let .firmware(component) = target {
            return component.rawValue
        }
        return guestPart
    }

    /// Every patch identifier live in some part.
    public var appliedPatches: Set<String> {
        Set(parts.values.flatMap(\.patches))
    }

    /// Replaces one part. A writer records every part it wrote, including one
    /// it left with no patches, so a part that was reverted reads as empty
    /// rather than as unknown.
    public mutating func record(
        _ part: String,
        patches: some Sequence<String>,
        writer: String,
        bundleVersion: String?,
        notApplicable: some Sequence<String> = [String](),
    ) {
        parts[part] = Entry(patches: patches, writer: writer, bundleVersion: bundleVersion, notApplicable: notApplicable)
    }

    private enum CodingKeys: String, CodingKey {
        case parts = "Parts"
    }

    public func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> Self {
        try PropertyListDecoder().decode(Self.self, from: data)
    }
}

// MARK: - Store

public enum VPhonePatchPresetStore {
    public static let selectionFileName = "PatchSelection.plist"
    public static let planFileName = "PatchPlan.plist"
    /// Written by whatever puts patched bytes into the guest; see
    /// ``VPhoneVirtualMachinePatchReceipt``. Root writers (`cfw install`) go
    /// through the VM's confined directory with ``VPhoneVirtualMachinePatchReceipt/encoded()``
    /// rather than ``write(_:forVM:)``, and leave the file mode `0777` like
    /// every other host VM artifact.
    public static let receiptFileName = "PatchReceipt.plist"

    // MARK: Presets

    /// Every preset available, shipped ones first.
    ///
    /// A staged bundle has `Contents/Resources/patches_presets` beside the
    /// executable. A plain Xcode build of `vphone-cli` has no such directory, so
    /// the built-in copies stand in and `fw patch` still runs.
    ///
    /// `~/.vphone/patches_presets` is added after those. It is the only place a
    /// preset naming an external `.vphonepatchset` can live: the shipped directory
    /// is inside a sealed bundle, and a shipped preset never references a set from
    /// outside it. A user preset cannot shadow a shipped one — an identifier
    /// already claimed is ignored, so nothing can redefine `standard`.
    public static func availablePresets() -> [VPhonePatchPreset] {
        var presets = shippedPresets()
        let claimed = Set(presets.map(\.identifier))
        if let user = try? VPhonePatchPreset.readAll(fromDirectory: userPresetsDirectory()) {
            presets.append(contentsOf: user.filter { !claimed.contains($0.identifier) })
        }
        return presets
    }

    /// `~/.vphone/patches_presets`, where a researcher's own presets go.
    public static func userPresetsDirectory() -> URL {
        VPhoneResources.userDataRoot()
            .appendingPathComponent(VPhonePatchPreset.resourceDirectoryName, isDirectory: true)
    }

    static func shippedPresets() -> [VPhonePatchPreset] {
        if let directory = presetsDirectory(),
           let shipped = try? VPhonePatchPreset.readAll(fromDirectory: directory),
           !shipped.isEmpty
        {
            return shipped
        }
        return FirmwarePatchSetCatalog.builtInPresets
    }

    /// Whether the bundle ships a preset with this identifier. Only then does
    /// the identifier alone say what the preset turns on: a user's preset or
    /// a preset file can change under the same one.
    static func isShipped(_ identifier: String) -> Bool {
        shippedPresets().contains { $0.identifier == identifier }
    }

    /// The preset with this identifier, or nil.
    public static func preset(named identifier: String) -> VPhonePatchPreset? {
        availablePresets().first { $0.identifier == identifier }
    }

    /// The preset with this identifier for one VM: its own copy
    /// (``vmPresetFileName``) when that is the one named, else ``preset(named:)``.
    public static func preset(named identifier: String, forVM directory: URL) -> VPhonePatchPreset? {
        preset(named: identifier, vmCopy: vmCopyData(forVM: directory))
    }

    /// As ``preset(named:forVM:)``, from the VM copy's bytes, for a reader
    /// that opens the VM folder itself.
    public static func preset(named identifier: String, vmCopy data: Data?) -> VPhonePatchPreset? {
        vmCopy(named: identifier, data: data) ?? preset(named: identifier)
    }

    private static func vmCopyData(forVM directory: URL) -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent(vmPresetFileName))
    }

    /// The VM's copy, when it is the preset named. Never a shipped identifier.
    private static func vmCopy(named identifier: String, data: Data?) -> VPhonePatchPreset? {
        guard let data, let copy = try? VPhonePatchPreset.decode(data), copy.identifier == identifier,
              !isShipped(identifier)
        else { return nil }
        return copy
    }

    // MARK: Preset Files

    /// A preset given to `--preset` as a file, kept in the VM so every later
    /// step resolves the same preset without the original file.
    public static let vmPresetFileName = FirmwarePatchWorkspace.presetFileName

    /// `--preset` names a file when it has a path separator or a `.plist` suffix.
    public static func isPresetFile(_ argument: String) -> Bool {
        argument.contains("/") || argument.hasSuffix(".plist")
    }

    /// A `--preset` value: a preset file, or a name resolved for `directory`
    /// when given. `file` is the preset the VM keeps a copy of: one read from a
    /// file, or the VM's existing copy when the name is its identifier.
    public static func resolve(
        _ argument: String,
        forVM directory: URL? = nil,
    ) throws -> (preset: VPhonePatchPreset, file: VPhonePatchPreset?) {
        if isPresetFile(argument) {
            let preset = try readPresetFile(argument)
            return (preset, preset)
        }
        if let directory, let copy = vmCopy(named: argument, data: vmCopyData(forVM: directory)) {
            return (copy, copy)
        }
        guard let found = preset(named: argument) else {
            let available = availablePresets().map(\.identifier)
            throw ValidationError("Unknown patch preset '\(argument)'. Available: \(available.joined(separator: ", "))")
        }
        return (found, nil)
    }

    /// Reads a preset file, as ``VPhoneInvokingUserFile`` allows under root.
    static func readPresetFile(_ path: String) throws -> VPhonePatchPreset {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let data = try VPhoneInvokingUserFile.read(url, kind: "preset file")
        let preset: VPhonePatchPreset
        do {
            preset = try VPhonePatchPreset.decode(data)
        } catch {
            throw ValidationError("Preset file \(url.path) is not a valid preset: \(error)")
        }
        // The VM records the identifier, and reading it back must not take it for a path.
        if isPresetFile(preset.identifier) {
            throw ValidationError("Preset file \(url.path) has the identifier '\(preset.identifier)'; an identifier has no '/' and no .plist suffix.")
        }
        // As for ~/.vphone/patches_presets: nothing can redefine a shipped preset.
        if isShipped(preset.identifier) {
            throw ValidationError("Preset file \(url.path) uses the identifier '\(preset.identifier)' of a shipped preset; give it its own.")
        }
        return preset
    }

    /// Keeps `file` as the VM's preset copy, or removes the copy when nil.
    public static func writePresetFile(_ file: VPhonePatchPreset?, forVM directory: URL) throws {
        let url = directory.appendingPathComponent(vmPresetFileName)
        guard let file else {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        try file.encodedPlist().write(to: url, options: .atomic)
    }

    /// `Contents/Resources/patches_presets` beside the running executable.
    static func presetsDirectory() -> URL? {
        // Not argv[0]: a `vphone-cli` found on PATH gets a bare name there, which
        // would resolve the presets directory against the working directory.
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            return nil
        }
        let resources = executable
            .deletingLastPathComponent() // Contents/MacOS
            .deletingLastPathComponent() // Contents
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(VPhonePatchPreset.resourceDirectoryName, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resources.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return nil
        }
        return resources
    }

    // MARK: VM Selection

    /// The VM's recorded choice, or the standard preset when it has none.
    ///
    /// A VM created before presets existed reads as standard, which is what it was
    /// built with.
    public static func selection(forVM directory: URL) -> VPhoneVirtualMachinePatchSelection {
        let url = directory.appendingPathComponent(selectionFileName)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? PropertyListDecoder().decode(
                  VPhoneVirtualMachinePatchSelection.self,
                  from: data,
              )
        else {
            return VPhoneVirtualMachinePatchSelection()
        }
        return decoded
    }

    public static func write(
        _ selection: VPhoneVirtualMachinePatchSelection,
        forVM directory: URL,
    ) throws {
        try write(selection, to: directory.appendingPathComponent(selectionFileName))
    }

    // MARK: VM Plan

    /// What the last `fw patch` resolved for this VM, or nil if it never ran with
    /// a preset.
    public static func plan(forVM directory: URL) -> VPhoneVirtualMachinePatchPlan? {
        let url = directory.appendingPathComponent(planFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(VPhoneVirtualMachinePatchPlan.self, from: data)
    }

    public static func write(_ plan: VPhoneVirtualMachinePatchPlan, forVM directory: URL) throws {
        try write(plan, to: directory.appendingPathComponent(planFileName))
    }

    // MARK: VM Receipt

    /// What is live in the guest, or nil for a VM no receipt-writing build has
    /// touched — that VM's state is unknown, not empty.
    public static func receipt(forVM directory: URL) -> VPhoneVirtualMachinePatchReceipt? {
        let url = directory.appendingPathComponent(receiptFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? VPhoneVirtualMachinePatchReceipt.decode(data)
    }

    /// Reads, changes and writes the receipt in one step, starting from an
    /// empty one when the VM has none.
    public static func updateReceipt(
        forVM directory: URL,
        _ body: (inout VPhoneVirtualMachinePatchReceipt) -> Void,
    ) throws {
        var receipt = receipt(forVM: directory) ?? VPhoneVirtualMachinePatchReceipt()
        body(&receipt)
        let url = directory.appendingPathComponent(receiptFileName)
        try receipt.encoded().write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: url.path)
    }

    private static func write(_ value: some Encodable, to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
