import Foundation

// MARK: - fw patches --json

/// Mirrors the payload `vphone-cli fw patches --json` prints.
///
/// The app declares no patch of its own. Everything the editor lists comes from
/// the active bundle, so a patch set this build of Launchpad has never heard of
/// still appears, with its own patches and version gates.
nonisolated struct VPhoneLaunchpadPatchCatalog: Decodable, Sendable {
    struct Preset: Decodable, Hashable, Identifiable, Sendable {
        let identifier: String
        let title: String
        let summary: String

        var id: String {
            identifier
        }

        /// The bundle writes its built-in presets in English. Launchpad
        /// translates those two; any other preset shows its own text.
        var displayTitle: String {
            switch identifier {
            case "standard": String(localized: "Standard", comment: "The built-in patch preset")
            case "extended": String(localized: "Extended", comment: "The built-in patch preset")
            default: title
            }
        }

        var displaySummary: String {
            switch identifier {
            case "standard": String(localized: "Patches every machine needs to start, with a working display and camera.")
            case "extended": String(localized: "Every patch in this bundle, including advanced ones that may stop a newly restored 26.4 machine from starting.")
            default: summary
            }
        }
    }

    struct Patch: Decodable, Hashable, Identifiable, Sendable {
        let identifier: String
        let title: String
        let summary: String
        let patchSet: String
        let patchSetName: String
        let target: String
        /// The OS versions the patch is declared for, or `any`.
        let applicability: String
        let bootEssential: Bool
        /// Whether the preset the report was made against turns it on. What the
        /// checkmarks are a difference from.
        let inPreset: Bool

        var id: String {
            identifier
        }

        /// False when the patch applies to every version, which is not worth a
        /// column entry.
        var isVersionGated: Bool {
            applicability != "any"
        }

        /// What the patch changes: `kernel`, `dyld`, `system-seputil`.
        var component: String {
            parts.component
        }

        /// Why it is there: `boot`, `cfw` or `exp`.
        var effect: String {
            parts.effect
        }

        /// The patch's own name within its component and effect.
        var name: String {
            parts.name
        }

        /// Splits `{component}-{effect}-{name}`, read from the right: the name
        /// holds no hyphen, and a component may (`system-seputil`). Every
        /// bundled patch follows this; an outside set that names its patches
        /// another way keeps its identifier whole as the name.
        private var parts: (component: String, effect: String, name: String) {
            let segments = identifier.split(separator: "-", omittingEmptySubsequences: false)
            guard segments.count >= 3,
                  Self.effects.contains(String(segments[segments.count - 2]))
            else {
                return ("", "", identifier)
            }
            return (
                segments.dropLast(2).joined(separator: "-"),
                String(segments[segments.count - 2]),
                String(segments[segments.count - 1]),
            )
        }

        private static let effects: Set<String> = ["boot", "cfw", "exp"]
    }

    /// The preset this report was made against: the VM's own, or the one `--preset`
    /// asked for.
    let activePreset: String
    let blockedPatches: [String]
    let allowedPatches: [String]
    let presets: [Preset]
    let patches: [Patch]

    func preset(_ identifier: String) -> Preset? {
        presets.first { $0.identifier == identifier }
    }

    func patch(_ identifier: String?) -> Patch? {
        identifier.flatMap { needle in patches.first { $0.identifier == needle } }
    }

    /// The patches matching `filter`, in the order the bundle applies them, which
    /// already runs one set after another.
    func patches(matching filter: String) -> [Patch] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else {
            return patches
        }
        return patches.filter { Self.matches($0, needle) }
    }

    private static func matches(_ patch: Patch, _ needle: String) -> Bool {
        [patch.title, patch.identifier, patch.summary, patch.patchSetName, patch.target]
            .contains { $0.localizedCaseInsensitiveContains(needle) }
    }
}

// MARK: - Reading

extension VPhoneLaunchpadPatchCatalog {
    /// Reads the catalogue from the active bundle's `vphone-cli`.
    ///
    /// `preset` reports against that preset instead of the machine's own record,
    /// which is how the picker re-bases what `inPreset` means. Passing neither a
    /// machine nor a preset reports what the bundle does by default.
    @MainActor
    static func read(
        using commandLine: VPhoneLaunchpadCommandLine?,
        machine: VPhoneLaunchpadMachinePath?,
        preset: String?,
    ) async throws -> VPhoneLaunchpadPatchCatalog {
        #if DEBUG
            if VPhoneLaunchpadPreview.isActive {
                guard let catalog = VPhoneLaunchpadPreview.patchCatalog(preset: preset) else {
                    throw VPhoneLaunchpadError(String(localized: "Unable to list the bundle's patches."))
                }
                return catalog
            }
        #endif
        guard let commandLine else {
            throw VPhoneLaunchpadError(
                String(localized: "No Core Bundle version is in use. Choose a version in Core Bundle."),
            )
        }
        var arguments = ["fw", "patches"]
        if let machine {
            arguments.append(machine.name)
        }
        if let preset {
            arguments += ["--preset", preset]
        }
        arguments.append("--json")
        if let machine {
            arguments += machine.libraryArguments
        }
        let result = try await commandLine.run(arguments, recordInHistory: false)
        guard result.succeeded, let data = result.jsonData else {
            throw VPhoneLaunchpadError(
                String(localized: "Unable to list the bundle's patches."),
                detail: result.tail,
            )
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

// MARK: - Selection

/// A VM's patch choice: a preset, plus only the boxes that differ from it.
///
/// This is what `vphone-cli fw set-patches` stores in `<vm>/PatchSelection.plist`.
/// Storing differences rather than a full list is what lets a later preset
/// revision reach a VM whose boxes were never touched.
nonisolated struct VPhoneLaunchpadPatchSelection: Hashable, Sendable {
    /// The preset `vphone-cli` uses when `--preset` is absent, mirroring
    /// `VPhonePatchPreset.standardIdentifier`. Naming it on the command line would
    /// only add noise, so the pipeline omits the flag for this one value.
    static let defaultPreset = "standard"

    var preset = defaultPreset
    /// Patches the preset turns on that this VM leaves off.
    var blocked: Set<String> = []
    /// Patches the preset leaves off that this VM turns on.
    var allowed: Set<String> = []

    var hasOverrides: Bool {
        !blocked.isEmpty || !allowed.isEmpty
    }

    var isDefault: Bool {
        preset == Self.defaultPreset && !hasOverrides
    }

    /// `fw set-patches` arguments, without the VM name or library root. Each run
    /// writes the whole record, so an empty list clears that half of it.
    var setPatchesArguments: [String] {
        ["--preset", preset]
            + blocked.sorted().flatMap { ["--block", $0] }
            + allowed.sorted().flatMap { ["--allow", $0] }
    }

    /// The `--preset` flag `fw patch` and `fw patches` carry, if any.
    var presetArguments: [String] {
        preset == Self.defaultPreset ? [] : ["--preset", preset]
    }

    func isOn(_ patch: VPhoneLaunchpadPatchCatalog.Patch) -> Bool {
        patch.inPreset ? !blocked.contains(patch.identifier) : allowed.contains(patch.identifier)
    }

    /// Records a box the way it differs from the preset, so a patch that agrees
    /// with the preset again lands in neither list.
    mutating func set(_ patch: VPhoneLaunchpadPatchCatalog.Patch, on: Bool) {
        let identifier = patch.identifier
        blocked.remove(identifier)
        allowed.remove(identifier)
        switch (patch.inPreset, on) {
        case (true, false): blocked.insert(identifier)
        case (false, true): allowed.insert(identifier)
        default: break
        }
    }

    /// Drops overrides this catalogue makes meaningless: one the preset already
    /// agrees with, and one naming a patch the bundle no longer declares. A
    /// hand-edited plist, or a bundle whose presets have since changed, would
    /// otherwise show a checkmark that stores nothing.
    mutating func normalize(against catalog: VPhoneLaunchpadPatchCatalog) {
        let inPreset = Set(catalog.patches.filter(\.inPreset).map(\.identifier))
        let declared = Set(catalog.patches.map(\.identifier))
        blocked = blocked.intersection(inPreset)
        allowed = allowed.intersection(declared).subtracting(inPreset)
    }

    /// The boot-essential patches this choice turns off, in catalogue order.
    func bootEssentialOff(in catalog: VPhoneLaunchpadPatchCatalog) -> [VPhoneLaunchpadPatchCatalog.Patch] {
        catalog.patches.filter { $0.bootEssential && !isOn($0) }
    }
}
