// CustomFirmwareDaemonsLaunchd.swift — LaunchDaemon injection into /System/Library/xpc/launchd.plist.
//
// Translated from: scripts/patchers/cfw_daemons.py (inject_daemons), and from the
// inline plistlib snippets at cfw_install_jb.sh:460-469 and cfw_install_exp.sh:702-711.
//
// Those three were the same merge written twice, once as a command taking a
// directory of daemon plists and once inline taking a single file. They converge
// here: `inject` is the merge, and the two loaders below are the only difference
// between the call sites.

import Foundation

public extension CustomFirmwareDaemons {
    /// Expose native environment assets on a virtual headset. Own only Enabled
    /// and remember whether this optional entry existed before the first write.
    static func visionOSEnvironmentFeatures(
        domain: inout PlistDict, journal: inout PlistDict, enabled: Bool
    ) throws -> [String] {
        let feature = "ShowEnvironmentsOnSimulator"
        let wasPresent = domain[feature] != nil
        guard !wasPresent || domain[feature] is PlistDict else {
            throw DaemonError.invalidPlist(feature)
        }
        var entry = domain[feature] as? PlistDict ?? [:]
        if let value = entry["Enabled"], CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID() {
            throw DaemonError.invalidPlist("\(feature).Enabled")
        }
        // The native 26.4 parser does not allow both fields. This experiment
        // does not own DevelopmentPhase, so refuse instead of changing it.
        guard entry["DevelopmentPhase"] == nil else {
            throw DaemonError.invalidPlist("\(feature).DevelopmentPhase")
        }
        guard Set(journal.keys).isSubset(of: [feature]) else {
            throw DaemonError.invalidPlist("environment feature journal")
        }
        var original: PlistDict?
        if let saved = journal[feature] {
            guard let fields = saved as? PlistDict,
                  Set(fields.keys).isSubset(of: ["EntryWasPresent", "Enabled"]),
                  let present = fields["EntryWasPresent"],
                  CFGetTypeID(present as CFTypeRef) == CFBooleanGetTypeID(),
                  (present as? Bool == true || fields["Enabled"] == nil)
            else { throw DaemonError.invalidPlist("journal.\(feature)") }
            if let value = fields["Enabled"], CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID() {
                throw DaemonError.invalidPlist("journal.\(feature).Enabled")
            }
            original = fields
        }

        var updatedDomain = domain, updatedJournal = journal
        if enabled {
            if original == nil {
                var fields: PlistDict = ["EntryWasPresent": wasPresent]
                if let value = entry["Enabled"] { fields["Enabled"] = value }
                updatedJournal[feature] = fields
            }
            entry["Enabled"] = true
            updatedDomain[feature] = entry
        } else if let original {
            entry.removeValue(forKey: "Enabled")
            if let value = original["Enabled"] { entry["Enabled"] = value }
            if original["EntryWasPresent"] as? Bool == false && entry.isEmpty {
                updatedDomain.removeValue(forKey: feature)
            } else {
                updatedDomain[feature] = entry
            }
        }
        let changed = !NSDictionary(dictionary: domain).isEqual(to: updatedDomain)
        domain = updatedDomain
        journal = updatedJournal
        return changed ? [feature] : []
    }

    /// Select UXM's legacy blackboard without changing unrelated feature flags.
    /// The 26.4 native parser rejects an entry containing both Enabled and
    /// DevelopmentPhase, so the two owned fields are journaled and restored together.
    static func visionOSLegacyUXMFeatures(
        domain: inout PlistDict, journal: inout PlistDict, enabled: Bool
    ) throws -> [String] {
        let features = ["UXMSharedMemoryBlackboard", "UXMShim"]
        let fields: Set<String> = ["Enabled", "DevelopmentPhase"]

        func validatedEntry(_ value: Any?, path: String, isJournal: Bool = false) throws -> PlistDict {
            guard let entry = value as? PlistDict,
                  !isJournal || Set(entry.keys).isSubset(of: fields)
            else { throw DaemonError.invalidPlist(path) }
            if let value = entry["Enabled"], CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID() {
                throw DaemonError.invalidPlist("\(path).Enabled")
            }
            if let value = entry["DevelopmentPhase"], !(value is String) {
                throw DaemonError.invalidPlist("\(path).DevelopmentPhase")
            }
            return entry
        }

        // Validate both entries and any saved fields before committing either
        // dictionary, including when restoring a partially populated journal.
        var entries: [String: PlistDict] = [:]
        var originals: [String: PlistDict] = [:]
        for feature in features {
            entries[feature] = try validatedEntry(domain[feature], path: feature)
            if let value = journal[feature] {
                originals[feature] = try validatedEntry(value, path: "journal.\(feature)", isJournal: true)
            }
        }

        var updatedDomain = domain, updatedJournal = journal
        var changed: [String] = []
        for feature in features {
            var entry = entries[feature]!
            let previous = entry.filter { fields.contains($0.key) }
            if enabled {
                if originals[feature] == nil { updatedJournal[feature] = previous }
                entry["Enabled"] = false
                entry.removeValue(forKey: "DevelopmentPhase")
            } else if let original = originals[feature] {
                for field in fields {
                    entry.removeValue(forKey: field)
                    if let value = original[field] { entry[field] = value }
                }
            }
            if !NSDictionary(dictionary: previous).isEqual(to: entry.filter { fields.contains($0.key) }) {
                changed.append(feature)
            }
            updatedDomain[feature] = entry
        }
        domain = updatedDomain
        journal = updatedJournal
        return changed
    }

    /// Preserve every job and unrelated policy. Journal only the two flags
    /// owned by this experimental port so disabling it is an exact inverse.
    static func visionOSNonfatalServices(
        cache: inout PlistDict, journal: inout PlistDict, enabled: Bool
    ) throws -> [String] {
        guard var jobs = cache["LaunchDaemons"] as? PlistDict else {
            throw DaemonError.invalidPlist("LaunchDaemons")
        }
        let labels = ["com.apple.polarisd", "com.apple.realitycamerad",
                      "com.apple.realitycoprocessorloaderd", "com.apple.arkitd"]
        let keys = ["_PanicOnCrash", "com.apple.private.spawn-panic-crash-behavior"]
        var changed: [String] = []
        for label in labels {
            let path = "/System/Library/LaunchDaemons/\(label).plist"
            guard var job = jobs[path] as? PlistDict else { continue }
            if enabled {
                if journal[path] == nil {
                    journal[path] = job.filter { keys.contains($0.key) }
                }
                let hasPolicy = keys.contains { job[$0] != nil }
                for key in keys { job.removeValue(forKey: key) }
                if hasPolicy { changed.append(label) }
            } else if let original = journal[path] as? PlistDict {
                for key in keys {
                    job.removeValue(forKey: key)
                    if let value = original[key] { job[key] = value }
                }
                changed.append(label)
            }
            jobs[path] = job
        }
        cache["LaunchDaemons"] = jobs
        return changed
    }

    // MARK: - Daemon

    /// One LaunchDaemon to merge, already loaded and already rewritten.
    struct Daemon {
        /// Label as installed, without `.plist` — e.g. `dropbear`, `com.vphone.jb-setup`.
        public let name: String
        public let contents: PlistDict

        public init(name: String, contents: PlistDict) {
            self.name = name
            self.contents = contents
        }

        /// The `LaunchDaemons` key launchd looks this daemon up under.
        public var launchdKey: String {
            "/System/Library/LaunchDaemons/\(name).plist"
        }
    }

    /// The daemons `inject-daemons` looks for in a directory, in this order.
    ///
    /// A fixed list rather than a directory listing, so what gets injected does
    /// not depend on what else a variant happens to leave in the staging
    /// directory, and so the order stays the order the log lines come out in.
    static let defaultDaemonNames: [String] = [
        "bash",
        "dropbear",
        "trollvnc",
        "vphoned",
        "rpcserver_ios",
    ]

    // MARK: - Loading

    /// One entry of a staging-directory scan.
    ///
    /// A daemon that is not there is not an error — a variant that does not ship
    /// `rpcserver_ios` still installs — so absence is a result, not a throw. The
    /// scan is returned in order because the caller logs it line by line.
    enum StagedDaemon {
        case present(Daemon)
        case absent(source: String)
    }

    /// Load one daemon plist by the name it will be installed under.
    ///
    /// The dropbear rewrite lives here rather than in the directory loader so it
    /// holds however the daemon reaches the merge.
    static func loadDaemon(name: String, from url: URL) throws -> Daemon {
        var contents = try loadPlist(url)
        if name == "dropbear" {
            patchDropbearDaemon(&contents)
        }
        return Daemon(name: name, contents: contents)
    }

    /// Scan a staging directory for the named daemons, in the order given.
    static func loadDaemons(
        inDirectory directory: URL,
        names: [String] = defaultDaemonNames,
    ) throws -> [StagedDaemon] {
        try names.map { name in
            let source = directory.appendingPathComponent("\(name).plist")
            guard FileManager.default.fileExists(atPath: source.path) else {
                return .absent(source: source.path)
            }
            return try .present(loadDaemon(name: name, from: source))
        }
    }

    // MARK: - Injection

    /// Merge daemons into a `launchd.plist`'s `LaunchDaemons` dictionary, in place.
    ///
    /// This is the single merge behind `cfw inject-daemons`, the jb-setup
    /// injection in `cfw_install_jb.sh` and the one in `cfw_install_exp.sh`.
    /// An entry already present is replaced, which is what makes re-running an
    /// install over an already-patched volume safe.
    ///
    /// - Returns: the names injected, in the order given.
    @discardableResult
    static func inject(_ daemons: [Daemon], into launchdPlist: URL) throws -> [String] {
        var target = try loadPlist(launchdPlist)
        var launchDaemons = target["LaunchDaemons"] as? PlistDict ?? [:]

        for daemon in daemons {
            launchDaemons[daemon.launchdKey] = daemon.contents
        }

        target["LaunchDaemons"] = launchDaemons
        try savePlist(target, to: launchdPlist)
        return daemons.map(\.name)
    }

    /// `cfw.py inject-daemons <launchd.plist> <daemon_dir>`, whole.
    ///
    /// - Returns: the scan, in scan order, so the caller can log one line each.
    @discardableResult
    static func injectDaemons(
        into launchdPlist: URL,
        fromDirectory directory: URL,
        names: [String] = defaultDaemonNames,
    ) throws -> [StagedDaemon] {
        let staged = try loadDaemons(inDirectory: directory, names: names)
        try inject(staged.present, into: launchdPlist)
        return staged
    }

    /// The single-file form the two installer scripts inline.
    ///
    /// `name` is the installed label, which is not the source filename: the jb
    /// setup daemon ships as `vphone_jb_setup.plist` and installs as
    /// `com.vphone.jb-setup.plist`.
    static func injectDaemon(
        into launchdPlist: URL,
        name: String,
        from source: URL,
    ) throws {
        try inject([loadDaemon(name: name, from: source)], into: launchdPlist)
    }
}

// MARK: - Scan convenience

public extension [CustomFirmwareDaemons.StagedDaemon] {
    var present: [CustomFirmwareDaemons.Daemon] {
        compactMap {
            if case let .present(daemon) = $0 {
                daemon
            } else {
                nil
            }
        }
    }

    var injectedNames: [String] {
        present.map(\.name)
    }

    var missingSources: [String] {
        compactMap {
            if case let .absent(source) = $0 {
                source
            } else {
                nil
            }
        }
    }
}
