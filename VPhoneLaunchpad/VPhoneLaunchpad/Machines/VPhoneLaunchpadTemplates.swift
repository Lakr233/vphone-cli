import Foundation

// MARK: - Slimming switches

/// New Machine's system slimming switches, as `vphone-cli vm create`,
/// `vm template find`, `vm template trim` and `vm template setup` take them
/// (`VPhoneTemplateSlimmingRequest` in the bundle). Only switches that differ
/// from the CLI's defaults are passed, so the CLI's own defaults stay the one
/// source of them.
///
/// The template key holds the trim tier and the removed apps; the service
/// profile can be switched on the machine later (Guest System).
nonisolated struct VPhoneLaunchpadSlimming: Hashable, Sendable {
    enum TrimTier: String, CaseIterable, Identifiable, Sendable {
        case none
        case conservative
        case standard

        var id: Self {
            self
        }

        var title: String {
            switch self {
            case .none: String(localized: "None")
            case .conservative: String(localized: "Conservative")
            case .standard: String(localized: "Standard")
            }
        }
    }

    /// One app the setup boot removes unless it is kept.
    struct App: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
    }

    /// Master switch. Off is `--slim off`: nothing trimmed, every service
    /// and app kept. Setup is skipped either way.
    var slim = true
    var trim = TrimTier.standard
    /// The languages the standard tier keeps the linguistic data of, comma
    /// separated; empty keeps ``defaultLanguages``.
    var keptLanguages = ""
    /// The trimmed service profile; off is `--service-profile none`.
    var trimsServices = true
    /// Off by default: the system apps stay unless New Machine picks them.
    var removesApps = false
    /// Apps of ``removableApps`` to keep.
    var keptApps: Set<String> = []
    /// Also turns off the Apple Account daemons, which counts only with the
    /// trimmed profile. On by default and not offered in New Machine: the
    /// guest refuses Apple Account sign-in and its services either way.
    var accountsOff = true

    static let defaultLanguages = "en,zh-Hans,zh"

    /// List C of the template plan, the CLI's `defaultRemovedApps`. Camera
    /// and Phone are never removed.
    static var removableApps: [App] {
        [
            App(id: "com.apple.AppStore", name: String(localized: "App Store")),
            App(id: "com.apple.Home", name: String(localized: "Home")),
            App(id: "com.apple.tv", name: String(localized: "TV")),
            App(id: "com.apple.news", name: String(localized: "News")),
            App(id: "com.apple.facetime", name: String(localized: "FaceTime")),
            App(id: "com.apple.MobileStore", name: String(localized: "iTunes Store")),
            App(id: "com.apple.MobileSMS", name: String(localized: "Messages")),
            App(id: "com.apple.games", name: String(localized: "Games")),
            App(id: "com.apple.findmy", name: String(localized: "Find My")),
            App(id: "com.apple.Passbook", name: String(localized: "Wallet")),
        ]
    }

    static func appName(_ bundleID: String) -> String {
        removableApps.first { $0.id == bundleID }?.name ?? bundleID
    }

    // MARK: Effective values

    /// The kept languages as the CLI takes them, or nil for the default (or
    /// when no tier removes language data).
    var languagesArgument: String? {
        guard slim, trim == .standard else {
            return nil
        }
        let list = Self.languageList(keptLanguages)
        guard !list.isEmpty, list.joined(separator: ",") != Self.defaultLanguages else {
            return nil
        }
        return list.joined(separator: ",")
    }

    static func languageList(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Why Create cannot go ahead with these switches, or nil. The CLI
    /// refuses the rest; the controls do not offer them.
    var problem: String? {
        guard let languages = languagesArgument else {
            return nil
        }
        let bad = Self.languageList(languages).filter { $0.wholeMatch(of: /[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*/) == nil }
        guard bad.isEmpty else {
            return String(localized: "\(bad.joined(separator: ", ")) is not a language code such as ja or zh-Hant.")
        }
        return nil
    }

    /// The apps the template removes.
    var removedApps: [String] {
        guard slim, removesApps else {
            return []
        }
        return Self.removableApps.map(\.id).filter { !keptApps.contains($0) }
    }

    // MARK: Arguments

    /// For `vm template find` and `vm create`.
    var arguments: [String] {
        guard slim else {
            return ["--slim", "off"]
        }
        var arguments: [String] = []
        if trim != .standard {
            arguments += ["--trim", trim.rawValue]
        }
        if let languagesArgument {
            arguments += ["--keep-languages", languagesArgument]
        }
        arguments += profileArguments
        if !removesApps {
            arguments += ["--remove-apps", "off"]
        } else {
            let kept = Self.removableApps.map(\.id).filter(keptApps.contains)
            if !kept.isEmpty {
                arguments += ["--keep-apps", kept.joined(separator: ",")]
            }
        }
        return arguments
    }

    private var profileArguments: [String] {
        if !trimsServices {
            return ["--service-profile", "none"]
        }
        return accountsOff ? ["--accounts-off"] : []
    }

    /// For `vm template setup`: the same without the trim, which the setup
    /// boot takes from what `vm template trim` recorded.
    var setupArguments: [String] {
        guard slim else {
            return ["--slim", "off"]
        }
        var arguments: [String] = []
        var index = self.arguments.startIndex
        let all = self.arguments
        while index < all.endIndex {
            let argument = all[index]
            if argument == "--trim" || argument == "--keep-languages" {
                index += 2
                continue
            }
            arguments.append(argument)
            index += 1
        }
        return arguments
    }

    /// `vm template trim`'s options, or nil when nothing is trimmed and the
    /// step is left out.
    var trimArguments: [String]? {
        guard slim, trim != .none else {
            return nil
        }
        return ["--tier", trim.rawValue] + (languagesArgument.map { ["--keep-languages", $0] } ?? [])
    }
}

// MARK: - Commands

/// The `vphone-cli` arguments of a template-backed creation and of the
/// Templates page, without `--library-root`. One place, so the command a
/// step shows cannot drift from the one it runs.
nonisolated enum VPhoneLaunchpadTemplateCommands {
    struct Request: Hashable, Sendable {
        var iphoneSource: String
        var cloudOSSource: String
        var device: String?
        var preset: String
        var blocked: Set<String> = []
        var allowed: Set<String> = []
        var diskSizeGB: Int
        var slimming: VPhoneLaunchpadSlimming
    }

    static func find(_ request: Request) -> [String] {
        var arguments = ["vm", "template", "find", "--json",
                         "--iphone-source", request.iphoneSource, "--cloudos-source", request.cloudOSSource]
        if let device = request.device {
            arguments += ["--device", device]
        }
        arguments += ["--preset", request.preset, "--disk-size", String(request.diskSizeGB)]
        arguments += request.blocked.sorted().flatMap { ["--block", $0] }
        arguments += request.allowed.sorted().flatMap { ["--allow", $0] }
        return arguments + request.slimming.arguments
    }

    static func trim(_ machine: String, _ slimming: VPhoneLaunchpadSlimming) -> [String]? {
        slimming.trimArguments.map { ["vm", "template", "trim", machine] + $0 }
    }

    /// `--strict`: the setup boot fails when an app it should remove stays.
    /// Without it the app only drops out of the key, the adopted template
    /// gets another id than Find Template computed, and every later create
    /// with these options builds a template again.
    static func setup(_ machine: String, _ slimming: VPhoneLaunchpadSlimming) -> [String] {
        ["vm", "template", "setup", machine, "--strict"] + slimming.setupArguments
    }

    /// `--expect`: the id Find Template computed for this creation. The adopt
    /// fails, saying which part of the key differs, rather than save the
    /// build under another id.
    static func adopt(_ machine: String, iphoneSource: String, cloudOSSource: String, expect: String?) -> [String] {
        ["vm", "template", "adopt", machine, "--json", "--iphone-source", iphoneSource, "--cloudos-source", cloudOSSource]
            + (expect.map { ["--expect", $0] } ?? [])
    }

    /// `fw set-patches`: the template build's boot-chain overrides, or every
    /// override for a machine of its own (`includingGuest`).
    static func setPatches(_ machine: String, _ overrides: VPhoneLaunchpadPatchOverrides, includingGuest: Bool) -> [String] {
        ["fw", "set-patches", machine] + overrides.setPatchesArguments(includingGuest: includingGuest)
    }

    /// The new machine, cloned with the settings a template does not fix.
    /// Its first boot is Launchpad's own.
    static func clone(_ machine: String, template: String, cpuCount: Int, memoryMB: Int, network: String) -> [String] {
        ["vm", "create", machine, "--template", template, "--skip-first-boot",
         "--cpu", String(cpuCount), "--memory", String(memoryMB), "--network", network]
    }

    static let list = ["vm", "template", "list", "--json"]

    static func delete(_ identifier: String) -> [String] {
        ["vm", "template", "delete", identifier, "--force"]
    }

    /// The line a failed `vphone-cli` ends with (`Error: …`), the reason a
    /// step failed in a sentence; nil when there is none.
    static func failureLine(_ lines: [String]) -> String? {
        lines.last { $0.hasPrefix("Error: ") }.map { String($0.dropFirst("Error: ".count)) }
    }
}

// MARK: - Patch overrides

/// New Machine's per-patch overrides, split where the template key splits
/// them. A boot-chain patch is built into the template by `fw patch`, so its
/// overrides are part of the key and go to the build. A guest patch is
/// written by the guest half of an install, which `cfw update-environment`
/// runs again on a clone, so its overrides stay out of the template and go
/// to the clone: a template never passes them on to a creation that did not
/// ask for them, and `vm template find` does not key on them.
nonisolated struct VPhoneLaunchpadPatchOverrides: Hashable, Sendable {
    var preset: String
    var blocked: Set<String> = []
    var allowed: Set<String> = []
    /// The overridden patches the bundle's catalog places in the guest
    /// (`VPhoneLaunchpadPatchCatalog.guestOverrides`). A patch it does not
    /// list counts as boot chain, as the template key counts it.
    var guestPatches: Set<String> = []

    var bootChainBlocked: Set<String> {
        blocked.subtracting(guestPatches)
    }

    var bootChainAllowed: Set<String> {
        allowed.subtracting(guestPatches)
    }

    var hasBootChainOverrides: Bool {
        !bootChainBlocked.isEmpty || !bootChainAllowed.isEmpty
    }

    var hasGuestOverrides: Bool {
        !blocked.isDisjoint(with: guestPatches) || !allowed.isDisjoint(with: guestPatches)
    }

    /// Overrides asked for by name (`vphone-launchpad-cli vm create --block
    /// … --allow …`), checked and reduced as `vphone-cli fw set-patches`
    /// does: a patch no set declares, or one both blocked and allowed, is
    /// refused, and only differences from the preset are kept. `declared`,
    /// `inPreset` and `guest` (the patches outside the boot chain) come from
    /// the bundle's catalog for `preset`.
    static func requested(
        preset: String,
        block: [String],
        allow: [String],
        declared: Set<String>,
        inPreset: Set<String>,
        guest: Set<String>,
    ) throws(RequestError) -> Self {
        let unknown = Set(block + allow).subtracting(declared)
        guard unknown.isEmpty else {
            throw .unknown(unknown.sorted())
        }
        let contradictory = Set(block).intersection(allow)
        guard contradictory.isEmpty else {
            throw .contradictory(contradictory.sorted())
        }
        let blocked = Set(block).intersection(inPreset)
        let allowed = Set(allow).subtracting(inPreset)
        return Self(preset: preset, blocked: blocked, allowed: allowed, guestPatches: blocked.union(allowed).intersection(guest))
    }

    nonisolated enum RequestError: Error, Equatable {
        case unknown([String])
        case contradictory([String])

        var message: String {
            switch self {
            case let .unknown(patches):
                "No patch declares \(patches.joined(separator: ", ")). Run exec fw patches for the identifiers."
            case let .contradictory(patches):
                "\(patches.joined(separator: ", ")) cannot be both blocked and allowed."
            }
        }
    }

    /// `fw set-patches` arguments without the machine. Each run writes the
    /// whole record, so the clone's run repeats the boot-chain overrides it
    /// already has from its template.
    func setPatchesArguments(includingGuest: Bool) -> [String] {
        let blocked = includingGuest ? blocked : bootChainBlocked
        let allowed = includingGuest ? allowed : bootChainAllowed
        return ["--preset", preset]
            + blocked.sorted().flatMap { ["--block", $0] }
            + allowed.sorted().flatMap { ["--allow", $0] }
    }
}

// MARK: - vm template list / show / find / adopt --json

/// One template as `vm template list --json`, `show --json` and `adopt
/// --json` print it (`VPhoneMachineTemplateReport`).
nonisolated struct VPhoneLaunchpadTemplate: Decodable, Identifiable, Hashable, Sendable {
    struct Slimming: Decodable, Hashable, Sendable {
        let trimTier: String
        let setupBoot: Bool
        let serviceProfile: String
        let serviceGroups: [String]
        let removedApps: [String]

        private enum CodingKeys: String, CodingKey {
            case trimTier = "TrimTier"
            case setupBoot = "SetupBoot"
            case serviceProfile = "ServiceProfile"
            case serviceGroups = "ServiceGroups"
            case removedApps = "RemovedApps"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            trimTier = try container.decode(String.self, forKey: .trimTier)
            setupBoot = try container.decode(Bool.self, forKey: .setupBoot)
            serviceProfile = try container.decode(String.self, forKey: .serviceProfile)
            serviceGroups = try container.decodeIfPresent([String].self, forKey: .serviceGroups) ?? []
            removedApps = try container.decode([String].self, forKey: .removedApps)
        }

        /// The tier without its list version and languages:
        /// `standard/1/en,zh` is `standard`.
        var tier: String {
            String(trimTier.split(separator: "/").first ?? "none")
        }

        /// The languages a standard trim kept, from `standard/1/en,zh`.
        var keptLanguages: String? {
            let parts = trimTier.split(separator: "/")
            return parts.count >= 3 ? String(parts[2]) : nil
        }

        var isSlimmed: Bool {
            tier != "none" || serviceProfile != "none" || !removedApps.isEmpty
        }

        /// `Standard trim · Services trimmed · 10 apps removed`, or Not
        /// slimmed.
        var summary: String {
            guard isSlimmed else {
                return String(localized: "Not slimmed")
            }
            var parts: [String] = []
            switch tier {
            case "standard": parts.append(String(localized: "Standard trim"))
            case "conservative": parts.append(String(localized: "Conservative trim"))
            case "none": parts.append(String(localized: "No trim"))
            default: parts.append(tier)
            }
            if serviceProfile == "trimmed" {
                parts.append(serviceGroups.contains("accounts")
                    ? String(localized: "Services and accounts off")
                    : String(localized: "Services trimmed"))
            }
            if !removedApps.isEmpty {
                parts.append(String(localized: "^[\(removedApps.count) app](inflect: true) removed"))
            }
            return parts.joined(separator: " · ")
        }
    }

    struct Key: Decodable, Hashable, Sendable {
        let device: String
        let iOSVersion: String
        let iOSBuild: String
        let cloudOSVersion: String
        let cloudOSBuild: String
        let patchPreset: String
        let bundleSeries: String
        let diskSizeGB: Int
        let slimming: Slimming

        private enum CodingKeys: String, CodingKey {
            case device = "Device"
            case iOSVersion = "IOSVersion"
            case iOSBuild = "IOSBuild"
            case cloudOSVersion = "CloudOSVersion"
            case cloudOSBuild = "CloudOSBuild"
            case patchPreset = "PatchPreset"
            case bundleSeries = "BundleSeries"
            case diskSizeGB = "DiskSizeGB"
            case slimming = "Slimming"
        }

        var osName: String {
            device.hasPrefix("iPad") ? "iPadOS" : "iOS"
        }
    }

    struct Sources: Decodable, Hashable, Sendable {
        let iPhone: String
        let cloudOS: String

        private enum CodingKeys: String, CodingKey {
            case iPhone = "IPhone"
            case cloudOS = "CloudOS"
        }
    }

    let id: String
    let path: String
    let key: Key
    let created: Date
    let builtWithBundleVersion: String?
    let bootChainBundleVersion: String?
    let sourceMachine: String?
    let allocatedBytes: Int64
    let machines: [String]
    let stale: Bool
    let staleReasons: [String]
    let sources: Sources?
    /// The library it was listed from. Not part of the JSON.
    var libraryRoot = ""

    private enum CodingKeys: String, CodingKey {
        case id, path, key, created, builtWithBundleVersion, bootChainBundleVersion, sourceMachine, allocatedBytes,
             machines, stale, staleReasons, sources
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    var url: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }
}

/// `vm template list --json`.
nonisolated struct VPhoneLaunchpadTemplateList: Decodable, Sendable {
    /// A create building a template, or a build that stopped.
    struct Building: Decodable, Hashable, Sendable {
        let name: String
        let path: String
        let id: String?
        let active: Bool
    }

    var templates: [VPhoneLaunchpadTemplate]
    var building: [Building]
    var damaged: [[String: String]]

    static func decode(_ data: Data, libraryRoot: String) throws -> Self {
        var list = try VPhoneLaunchpadTemplate.decoder().decode(Self.self, from: data)
        for index in list.templates.indices {
            list.templates[index].libraryRoot = libraryRoot
        }
        return list
    }
}

/// `vm template find --json`.
nonisolated struct VPhoneLaunchpadTemplateFind: Decodable, Sendable {
    let resolved: Bool
    let resolvedBy: String?
    let id: String?
    let summary: String?
    let template: VPhoneLaunchpadTemplate?
    let usable: Bool
    let building: Bool
    let reason: String?

    static func decode(_ data: Data) throws -> Self {
        try VPhoneLaunchpadTemplate.decoder().decode(Self.self, from: data)
    }
}

// MARK: - Last machine of a template

/// What `vm delete` notes when the machine was the last one cloned from a
/// template that is still there: the template, and what it takes.
nonisolated struct VPhoneLaunchpadTemplateNotice: Identifiable, Hashable, Sendable {
    let id: String
    /// As the CLI wrote it, `17.58 GB`.
    let size: String
    let libraryRoot: String

    /// `note: template 52b1fcc75e0c (~17.58 GB) is no longer used by any machine; …`
    static func parse(_ lines: [String], libraryRoot: String) -> Self? {
        for line in lines.reversed() {
            if let match = line.firstMatch(of: /^note: template ([0-9a-f]{12}) \(~([^)]+)\) is no longer used by any machine/) {
                return Self(id: String(match.1), size: String(match.2), libraryRoot: libraryRoot)
            }
        }
        return nil
    }
}

// MARK: - Guest System

/// `services.profile`, as much of it as the Guest System sheet shows.
nonisolated struct VPhoneLaunchpadServiceProfile: Equatable, Sendable {
    var profile: String
    var supported: Bool
    /// The groups and allowed labels the guest's record holds, passed back
    /// when the profile is applied again so `--accounts-off` stays.
    var groups: [String]
    var allow: [String]
    /// Labels the profile turned off that still run until the guest restarts.
    var running: Int
    var rebootRequired: Bool

    init(_ result: [String: Any]) {
        profile = result["profile"] as? String ?? "none"
        supported = result["supported"] as? Bool ?? false
        let record = result["record"] as? [String: Any]
        groups = record?["groups"] as? [String] ?? []
        allow = record?["allow"] as? [String] ?? []
        running = (result["running"] as? [Any])?.count ?? 0
        rebootRequired = result["reboot_required"] as? Bool ?? false
    }
}

/// A service profile change waiting for its guest to restart.
///
/// `services.profile` cannot say this for every change: switching to None
/// clears the guest's record, and with it the labels `reboot_required` is
/// counted from, while the services it turned back on start only with the
/// next boot. So the apply's own answer is kept until the guest has booted
/// again, which shows as a new start time of launchd (pid 1).
nonisolated struct VPhoneLaunchpadPendingRestart: Hashable, Sendable {
    /// When launchd started in the boot the change was made in; nil when the
    /// guest did not say. Without it, only the machine stopping clears this.
    let boot: Double?

    /// The guest's boot from `processes.list`: launchd's start time.
    static func boot(fromProcesses result: [String: Any]) -> Double? {
        let rows = result["processes"] as? [[String: Any]] ?? []
        return rows.first { $0["pid"] as? Int == 1 }?["start_time"] as? Double
    }

    /// What is pending after `services.profile.apply` answered `result`. A
    /// change still waiting keeps the boot it was made in; an apply that
    /// needs no restart, such as one undoing a change that never ran, leaves
    /// nothing pending.
    static func afterApply(_ result: [String: Any], pending: Self?, boot: Double?) -> Self? {
        guard result["reboot_required"] as? Bool == true else {
            return nil
        }
        return pending ?? Self(boot: boot)
    }

    /// Whether the guest has booted since the change: both boots known, and
    /// a second or more apart.
    func hasRestarted(currentBoot: Double?) -> Bool {
        guard let boot, let currentBoot else {
            return false
        }
        return abs(currentBoot - boot) >= 1
    }
}
