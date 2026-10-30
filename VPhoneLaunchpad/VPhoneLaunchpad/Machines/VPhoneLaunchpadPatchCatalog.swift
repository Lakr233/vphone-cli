import Foundation

// MARK: - fw patches --json

/// Mirrors the payload `vphone-cli fw patches --json` prints.
///
/// The app declares no patch of its own. Everything the editor lists comes from
/// the Core Bundle it is read from, so a patch set this build of Launchpad has
/// never heard of still appears, with its own patches and version gates.
nonisolated struct VPhoneLaunchpadPatchCatalog: Decodable, Sendable {
    struct Preset: Decodable, Hashable, Identifiable, Sendable {
        let identifier: String
        let title: String
        let summary: String
        let patchSets: [String]?

        var id: String {
            identifier
        }

        /// Whether it merges the restore image, which only a root `fw patch`
        /// before the restore does (`com.vphone.patchset.restore.image`).
        var customisesRestoredSystem: Bool {
            patchSets?.contains("com.vphone.patchset.restore.image") == true
        }

        /// The bundle writes its built-in presets in English. Launchpad
        /// translates those two; any other preset shows its own text.
        var displayTitle: String {
            switch identifier {
            case "standard": String(localized: "Standard", comment: "The built-in patch preset")
            case "experimental": String(localized: "Experimental", comment: "The built-in patch preset")
            default: title
            }
        }

        var displaySummary: String {
            switch identifier {
            case "standard": String(localized: "Patches every machine needs to start, with a working display and camera.")
            case "experimental": String(localized: "Every patch in this bundle, including advanced ones that may stop a newly restored 26.4 machine from starting.")
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
        /// Whether the machine's wanted state for this patch has not reached its
        /// guest yet. Reported only for a named machine, by a bundle that
        /// compares its records; nil otherwise.
        let pending: Bool?
        /// Where the patch lives in a machine: a boot-chain component's name,
        /// or `Guest`. Reported only for a named machine; nil otherwise.
        let part: String?
        /// The step that delivers this patch to an installed guest, reported by
        /// the machine's own bundle only for a pending patch:
        /// `update-environment`, `update-kernel`, `fw-patch` or
        /// `restore`. A bundle without `cfw update-kernel` never reports
        /// `update-kernel`, so the kernel button keyed on it simply
        /// does not appear there. Nil when not pending or not reported.
        let delivery: String?

        var id: String {
            identifier
        }

        /// Whether the patch is in the boot chain, which only a restore
        /// changes on a machine that exists. Read from `part` when the bundle
        /// reports it, else from `target`, which names the component the same
        /// way for a boot-chain patch. Every `.firmware` component counts, as
        /// it does for `fw patch` and the template key.
        var isBootChain: Bool {
            Self.bootChainParts.contains(part ?? target)
        }

        /// The kernelcache, which `cfw update-kernel` changes without a restore.
        var isKernel: Bool {
            (part ?? target) == "kernelcache"
        }

        private static let bootChainParts: Set<String> = [
            "AVPBooter", "iBSS", "iBEC", "LLB", "TXM", "kernelcache", "DeviceTree", "SEP", "Filesystem", "Manifest",
        ]

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

    // Reported only for a named machine, and only by a bundle that compares a
    // machine's records. An older bundle leaves them out, and every reader
    // treats their absence as "not known".

    /// Whether `cfw install` finished on the machine; nil when unknown.
    let installed: Bool?
    /// Whether the machine has a receipt saying what its guest runs.
    let receiptRecorded: Bool?
    /// How many patches differ from what the machine's guest has, or nil when
    /// nothing records what it has.
    let pendingPatches: Int?

    /// The overrides the machine's choice makes on its preset.
    var overrideCount: Int {
        blockedPatches.count + allowedPatches.count
    }

    /// The machine's own choice, as the editor starts from it.
    var selection: VPhoneLaunchpadPatchSelection {
        VPhoneLaunchpadPatchSelection(
            preset: activePreset,
            blocked: Set(blockedPatches),
            allowed: Set(allowedPatches),
        )
    }

    /// Pending patches `cfw update-environment` brings in line (the bundle's
    /// own classification; falls back to the part for a bundle that does not
    /// report delivery).
    var pendingGuestPatches: Int {
        patches.count { $0.pending == true && ($0.delivery ?? (!$0.isBootChain ? "update-environment" : "")) == "update-environment" }
    }

    /// Pending kernelcache patches `cfw update-kernel` applies without a
    /// restore. Keyed on the delivery the machine's bundle reports, so a bundle
    /// without the verb never counts any here and the button stays hidden.
    var pendingKernelPatches: Int {
        patches.count { $0.pending == true && $0.delivery == "update-kernel" }
    }

    /// Pending boot-chain patches that only an erasing restore applies.
    var pendingRestorePatches: Int {
        patches.count { $0.pending == true && ($0.delivery ?? (($0.isBootChain && !$0.isKernel) ? "restore" : "")) == "restore" }
    }

    /// The overrides of `selection` the guest half of an install writes. One
    /// naming a patch this catalog does not list counts as boot chain, as the
    /// template key counts it.
    func guestOverrides(_ selection: VPhoneLaunchpadPatchSelection) -> Set<String> {
        let guest = Set(patches.filter { !$0.isBootChain }.map(\.identifier))
        return selection.blocked.union(selection.allowed).intersection(guest)
    }

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
    /// Reads the catalogue with one Core Bundle version's `vphone-cli`.
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
                guard let catalog = VPhoneLaunchpadPreview.patchCatalog(preset: preset, machine: machine != nil) else {
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

    /// The preset an Apple TV guest gets, mirroring
    /// `VPhonePatchPreset.tvOSIdentifier`.
    static let tvOSPreset = "tvos"

    /// The preset an Apple TV 4K guest gets, mirroring
    /// `VPhonePatchPreset.tvOS4KIdentifier`: its arm64e userland comes from
    /// the OTA, with the paravirtual GPU driver.
    static let tvOS4KPreset = "tvos-4k"
    /// The preset that customises the system before the restore and patches
    /// no boot chain: `fw patch` runs as root, and nothing writes the system
    /// afterwards, so there is no template and no slimming.
    static let minimalPreset = "minimal"
    /// The preset an Apple Watch guest gets, mirroring
    /// `VPhonePatchPreset.watchOSIdentifier`: `minimal` for the watch board.
    static let watchOSPreset = "watchos"

    /// The HomePod mini's arm64e userland has a preset of its own.
    static let homePodMiniPreset = "homepod-mini"

    /// The preset a new machine of `productType` starts from.
    static func defaultPreset(forDevice productType: String?) -> String {
        switch productType {
        case "HomeAccessory17,1", "HomeAccessory17,2": "homeview"
        case "AudioAccessory5,1": homePodMiniPreset
        case "AppleTV14,1", "AppleTV18,1": tvOS4KPreset
        case let type? where type.hasPrefix("AppleTV"): tvOSPreset
        case let type? where type.hasPrefix("Watch"): watchOSPreset
        // The iOS 18 research board kernels boot no other preset.
        case "iPhone11,6", "iPhone11,4": minimalPreset
        default: defaultPreset
        }
    }

    var preset = defaultPreset
    /// A preset plist chosen with Other…, passed to `--preset` in place of
    /// `preset`; `vphone-cli` keeps a copy in the machine. Once the bundle has
    /// read it, `preset` is the identifier it declares (``adoptFile(from:)``).
    var presetFile: String?
    /// Patches the preset turns on that this VM leaves off.
    var blocked: Set<String> = []
    /// Patches the preset leaves off that this VM turns on.
    var allowed: Set<String> = []
    /// Whether the file's preset customises the system before the restore,
    /// from the bundle's catalog.
    var fileCustomisesRestoredSystem = false

    /// `--preset <file>` for `vphone-cli` 2.14 and later.
    static func isPresetFile(_ value: String) -> Bool {
        value.contains("/") || value.hasSuffix(".plist")
    }

    var hasOverrides: Bool {
        !blocked.isEmpty || !allowed.isEmpty
    }

    var isDefault: Bool {
        presetFile == nil && preset == Self.defaultPreset && !hasOverrides
    }

    /// What `--preset` is given: the file, else the preset's identifier.
    var presetArgument: String {
        presetFile ?? preset
    }

    /// `fw set-patches` arguments, without the VM name or library root. Each run
    /// writes the whole record, so an empty list clears that half of it.
    var setPatchesArguments: [String] {
        ["--preset", presetArgument]
            + blocked.sorted().flatMap { ["--block", $0] }
            + allowed.sorted().flatMap { ["--allow", $0] }
    }

    var customisesRestoredSystem: Bool {
        presetFile != nil ? fileCustomisesRestoredSystem : preset == Self.minimalPreset || preset == Self.watchOSPreset
    }

    /// The `--preset` flag `fw patch` and `fw patches` carry, if any.
    var presetArguments: [String] {
        presetFile == nil && preset == Self.defaultPreset ? [] : ["--preset", presetArgument]
    }

    /// The `--preset` flag for a step on a machine that already keeps the
    /// preset: `fw set-patches` before `fw prepare` copies a file into it
    /// with ``presetArguments``, and a clone has its template's copy. Once the
    /// bundle has read the file, `preset` is its identifier, so a later step
    /// or a retry does not need the file again.
    var machinePresetArguments: [String] {
        preset == Self.defaultPreset ? [] : ["--preset", preset]
    }

    /// Takes what the bundle read from ``presetFile``: the identifier it
    /// declares, and whether it customises the system before the restore.
    mutating func adoptFile(from catalog: VPhoneLaunchpadPatchCatalog) {
        guard presetFile != nil else { return }
        preset = catalog.activePreset
        fileCustomisesRestoredSystem = catalog.preset(catalog.activePreset)?.customisesRestoredSystem ?? false
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

/// So the inspector can present the editor with the choice it opens on.
extension VPhoneLaunchpadPatchSelection {
    /// The preset pickers' Other… item, which chooses a preset plist.
    static let otherPresetTag = "\u{1}other"

    /// A preset plist, with no overrides. `preset` holds the path until the
    /// bundle has read the file.
    init(presetFile: String) {
        self.init(preset: presetFile, presetFile: presetFile)
    }
}

extension VPhoneLaunchpadPatchSelection: Identifiable {
    var id: Self {
        self
    }
}
