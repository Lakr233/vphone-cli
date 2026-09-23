// CFWDaemonsLaunchd.swift — LaunchDaemon injection into /System/Library/xpc/launchd.plist.
//
// Translated from: scripts/patchers/cfw_daemons.py (inject_daemons), and from the
// inline plistlib snippets at cfw_install_jb.sh:460-469 and cfw_install_exp.sh:702-711.
//
// Those three were the same merge written twice, once as a command taking a
// directory of daemon plists and once inline taking a single file. They converge
// here: `inject` is the merge, and the two loaders below are the only difference
// between the call sites.

import Foundation

extension CFWDaemons {
    // MARK: - Daemon

    /// One LaunchDaemon to merge, already loaded and already rewritten.
    public struct Daemon {
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
    public static let defaultDaemonNames: [String] = [
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
    public enum StagedDaemon {
        case present(Daemon)
        case absent(source: String)
    }

    /// Load one daemon plist by the name it will be installed under.
    ///
    /// The dropbear rewrite lives here rather than in the directory loader so it
    /// holds however the daemon reaches the merge.
    public static func loadDaemon(name: String, from url: URL) throws -> Daemon {
        var contents = try loadPlist(url)
        if name == "dropbear" {
            patchDropbearDaemon(&contents)
        }
        return Daemon(name: name, contents: contents)
    }

    /// Scan a staging directory for the named daemons, in the order given.
    public static func loadDaemons(
        inDirectory directory: URL,
        names: [String] = defaultDaemonNames
    ) throws -> [StagedDaemon] {
        try names.map { name in
            let source = directory.appendingPathComponent("\(name).plist")
            guard FileManager.default.fileExists(atPath: source.path) else {
                return .absent(source: source.path)
            }
            return .present(try loadDaemon(name: name, from: source))
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
    public static func inject(_ daemons: [Daemon], into launchdPlist: URL) throws -> [String] {
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
    public static func injectDaemons(
        into launchdPlist: URL,
        fromDirectory directory: URL,
        names: [String] = defaultDaemonNames
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
    public static func injectDaemon(
        into launchdPlist: URL,
        name: String,
        from source: URL
    ) throws {
        try inject([loadDaemon(name: name, from: source)], into: launchdPlist)
    }
}

// MARK: - Scan convenience

public extension [CFWDaemons.StagedDaemon] {
    var present: [CFWDaemons.Daemon] {
        compactMap { if case let .present(daemon) = $0 { daemon } else { nil } }
    }

    var injectedNames: [String] {
        present.map(\.name)
    }

    var missingSources: [String] {
        compactMap { if case let .absent(source) = $0 { source } else { nil } }
    }
}
