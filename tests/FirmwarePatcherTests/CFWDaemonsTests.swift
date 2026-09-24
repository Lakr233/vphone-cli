import CryptoKit
@testable import FirmwarePatcher
import Foundation
import Testing

// MARK: - Plist semantics

/// Recursive semantic comparison of two property lists.
///
/// Byte equality is the wrong bar here and would fail on correct output: two XML
/// plist writers disagree on `<data>` line width, on `<real>` digits, and on
/// dictionary key order, none of which any consumer of these files can observe.
/// What *is* semantic — and what this checks — is the type of every value, the
/// order of every array, the key set of every dictionary and the bytes of every
/// `<data>`.
enum PlistSemantics {
    /// Every place the two differ, as readable key paths. Empty means equivalent.
    static func differences(_ lhs: Any, _ rhs: Any, at path: String = "<root>") -> [String] {
        // CFBoolean bridges to NSNumber, so `1` and `true` would compare equal
        // if the number branch saw them first. Type is semantic; check it first.
        if isBoolean(lhs) || isBoolean(rhs) {
            guard let left = lhs as? Bool, let right = rhs as? Bool, isBoolean(lhs), isBoolean(rhs) else {
                return ["\(path): boolean vs \(describe(isBoolean(lhs) ? rhs : lhs))"]
            }
            return left == right ? [] : ["\(path): \(left) != \(right)"]
        }

        switch (lhs, rhs) {
        case let (left as [String: Any], right as [String: Any]):
            var found: [String] = []
            let leftKeys = Set(left.keys)
            let rightKeys = Set(right.keys)
            for key in leftKeys.subtracting(rightKeys).sorted() {
                found.append("\(path).\(key): only on the left")
            }
            for key in rightKeys.subtracting(leftKeys).sorted() {
                found.append("\(path).\(key): only on the right")
            }
            for key in leftKeys.intersection(rightKeys).sorted() {
                found += differences(left[key]!, right[key]!, at: "\(path).\(key)")
            }
            return found

        case let (left as [Any], right as [Any]):
            guard left.count == right.count else {
                return ["\(path): array of \(left.count) vs \(right.count)"]
            }
            return (0 ..< left.count).flatMap {
                differences(left[$0], right[$0], at: "\(path)[\($0)]")
            }

        case let (left as String, right as String):
            return left == right ? [] : ["\(path): \"\(left)\" != \"\(right)\""]

        case let (left as Data, right as Data):
            return left == right ? [] : ["\(path): \(left.count) bytes != \(right.count) bytes"]

        case let (left as Date, right as Date):
            return left == right ? [] : ["\(path): \(left) != \(right)"]

        case let (left as NSNumber, right as NSNumber):
            let leftIsFloat = CFNumberIsFloatType(left as CFNumber)
            let rightIsFloat = CFNumberIsFloatType(right as CFNumber)
            if leftIsFloat != rightIsFloat {
                return ["\(path): \(leftIsFloat ? "real" : "integer") vs \(rightIsFloat ? "real" : "integer")"]
            }
            return left == right ? [] : ["\(path): \(left) != \(right)"]

        default:
            return ["\(path): \(describe(lhs)) vs \(describe(rhs))"]
        }
    }

    private static func isBoolean(_ value: Any) -> Bool {
        CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
    }

    private static func describe(_ value: Any) -> String {
        "\(type(of: value))(\(value))"
    }
}

// MARK: - Fixtures

enum CFWDaemonsFixtures {
    /// The repository root, from this file's own path.
    static let repositoryRoot = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let buildManifest = repositoryRoot.appending(path: "ipsws/ref_extract/iphone/BuildManifest.plist")
    static let cfwInputArchive = repositoryRoot.appending(path: "scripts/resources/cfw_input.tar.zst")
    static let jbSetupPlist = repositoryRoot.appending(path: "scripts/vphone_jb_setup.plist")

    /// A real `launchd.plist` of the shape the installer rewrites.
    ///
    /// The guest's copy lives on a volume that needs root to mount; the host's is
    /// the same file, produced by the same build system, and is world-readable.
    static let hostLaunchdPlist = URL(filePath: "/System/Library/xpc/launchd.plist")

    /// Whether the real inputs the frozen reference was recorded over are here.
    /// `BuildManifest.plist` comes out of an IPSW and is never in the repo.
    static var referenceInputsAvailable: Bool {
        [buildManifest, cfwInputArchive, hostLaunchdPlist]
            .allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func temporaryDirectory() throws -> URL {
        let url = URL(filePath: NSTemporaryDirectory())
            .appending(path: "CFWDaemonsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The installer's real LaunchDaemons staging directory, unpacked from the
    /// resource archive the installer itself consumes.
    static func unpackLaunchDaemons(into directory: URL) throws -> URL {
        try run("/usr/bin/tar", [
            "-xf", cfwInputArchive.path,
            "-C", directory.path,
            "cfw_input/jb/LaunchDaemons",
        ])
        return directory.appending(path: "cfw_input/jb/LaunchDaemons")
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(executable) \(arguments.joined(separator: " "))")
        return String(data: output, encoding: .utf8) ?? ""
    }

    static func loadPlist(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            as? [String: Any] ?? [:]
    }

    /// Copy a plist somewhere writable — the sources are all read-only originals.
    static func writableCopy(of source: URL, in directory: URL, named name: String) throws -> URL {
        let destination = directory.appending(path: name)
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
        return destination
    }
}

// MARK: - Unit tests

@Suite("CFW daemon plist rewrites")
struct CFWDaemonsTests {
    // MARK: - dropbear ProgramArguments

    //
    // Both cases below came over verbatim from tests/test_dropbear_plist.py,
    // which covered this exact rewrite and which no runner ever invoked.

    @Test
    func `-R is dropped and the seeded host keys are appended`() {
        var daemon: PlistDict = [
            "ProgramArguments": [
                "/iosbinpack64/usr/local/bin/dropbear",
                "--shell",
                "/iosbinpack64/bin/bash",
                "-R",
                "-E",
                "-F",
                "-p",
                "22222",
                "-a",
            ],
        ]

        CFWDaemons.patchDropbearDaemon(&daemon)

        let arguments = daemon["ProgramArguments"] as? [Any] ?? []
        let strings = arguments.compactMap { $0 as? String }
        #expect(!strings.contains("-R"))
        #expect(Array(strings.suffix(CFWDaemons.dropbearKeyArguments.count)) == CFWDaemons.dropbearKeyArguments)
    }

    @Test
    func `stale explicit -r key paths are replaced, not kept`() {
        var daemon: PlistDict = [
            "ProgramArguments": [
                "dropbear",
                "-r",
                "/etc/dropbear/dropbear_rsa_host_key",
                "-E",
                "-r",
                "/tmp/old_ecdsa_key",
                "-p",
                "22222",
            ],
        ]

        CFWDaemons.patchDropbearDaemon(&daemon)

        let strings = (daemon["ProgramArguments"] as? [Any] ?? []).compactMap { $0 as? String }
        #expect(!strings.contains("/etc/dropbear/dropbear_rsa_host_key"))
        #expect(!strings.contains("/tmp/old_ecdsa_key"))
        #expect(strings == ["dropbear", "-E", "-p", "22222"] + CFWDaemons.dropbearKeyArguments)
    }

    @Test
    func `an empty argument list is left alone — there is nothing to point at a key`() {
        var daemon: PlistDict = ["ProgramArguments": [String]()]
        CFWDaemons.patchDropbearDaemon(&daemon)
        #expect((daemon["ProgramArguments"] as? [Any])?.isEmpty == true)
    }

    @Test
    func `a trailing -r with no path does not read past the end`() {
        #expect(
            CFWDaemons.patchedDropbearArguments(["dropbear", "-r"]).compactMap { $0 as? String }
                == ["dropbear"] + CFWDaemons.dropbearKeyArguments,
        )
    }

    // MARK: - Cryptex paths

    @Test
    func `Cryptex paths are found in a later identity, not just the first`() throws {
        let directory = try CFWDaemonsFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // vResearch IPSWs put the Cryptex entries somewhere other than identity 0,
        // and a real manifest's last identity has neither.
        let manifest: PlistDict = [
            "BuildIdentities": [
                ["Manifest": PlistDict()],
                ["Manifest": [
                    "Cryptex1,SystemOS": ["Info": ["Path": "043-70113-702.dmg.aea"]],
                    "Cryptex1,AppOS": ["Info": ["Path": "043-69297-784.dmg"]],
                ] as PlistDict],
            ],
        ]
        let url = directory.appending(path: "BuildManifest.plist")
        try CFWDaemons.savePlist(manifest, to: url)

        let paths = try CFWDaemons.cryptexPaths(buildManifest: url)
        #expect(paths.systemOS == "043-70113-702.dmg.aea")
        #expect(paths.appOS == "043-69297-784.dmg")
    }

    @Test
    func `an identity carrying only one of the two is not a match`() throws {
        let directory = try CFWDaemonsFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifest: PlistDict = [
            "BuildIdentities": [
                ["Manifest": ["Cryptex1,SystemOS": ["Info": ["Path": "sys.dmg"]]] as PlistDict],
            ],
        ]
        let url = directory.appending(path: "BuildManifest.plist")
        try CFWDaemons.savePlist(manifest, to: url)

        #expect(throws: CFWDaemons.DaemonError.self) {
            try CFWDaemons.cryptexPaths(buildManifest: url)
        }
    }

    // MARK: - launchd.plist injection

    @Test
    func `injection creates LaunchDaemons when the target has none`() throws {
        let directory = try CFWDaemonsFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let launchd = directory.appending(path: "launchd.plist")
        try CFWDaemons.savePlist(["VersionNumber": 1], to: launchd)

        try CFWDaemons.inject(
            [CFWDaemons.Daemon(name: "vphoned", contents: ["Label": "vphoned"])],
            into: launchd,
        )

        let result = try CFWDaemons.loadPlist(launchd)
        let daemons = result["LaunchDaemons"] as? PlistDict
        #expect(daemons?["/System/Library/LaunchDaemons/vphoned.plist"] != nil)
        #expect(result["VersionNumber"] as? Int == 1)
    }

    @Test
    func `injecting twice replaces rather than duplicates, so a re-run is safe`() throws {
        let directory = try CFWDaemonsFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let launchd = directory.appending(path: "launchd.plist")
        try CFWDaemons.savePlist(["LaunchDaemons": PlistDict()], to: launchd)

        let daemon = CFWDaemons.Daemon(name: "bash", contents: ["Label": "bash"])
        try CFWDaemons.inject([daemon], into: launchd)
        let first = try CFWDaemonsFixtures.loadPlist(launchd)
        try CFWDaemons.inject([daemon], into: launchd)
        let second = try CFWDaemonsFixtures.loadPlist(launchd)

        #expect(PlistSemantics.differences(first, second).isEmpty)
        #expect((second["LaunchDaemons"] as? PlistDict)?.count == 1)
    }

    @Test
    func `a daemon absent from the staging directory is reported, not fatal`() throws {
        let directory = try CFWDaemonsFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let staging = directory.appending(path: "LaunchDaemons")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try CFWDaemons.savePlist(["Label": "bash"], to: staging.appending(path: "bash.plist"))

        let launchd = directory.appending(path: "launchd.plist")
        try CFWDaemons.savePlist(PlistDict(), to: launchd)

        let staged = try CFWDaemons.injectDaemons(into: launchd, fromDirectory: staging)
        #expect(staged.injectedNames == ["bash"])
        #expect(staged.missingSources.count == CFWDaemons.defaultDaemonNames.count - 1)
        // Scan order, not injected-then-missing: the caller logs one line each,
        // and those lines have always come out in the order the names are tried.
        #expect(staged.count == CFWDaemons.defaultDaemonNames.count)
        if case .present = staged[0] {} else {
            Issue.record("bash should be first in scan order")
        }
    }

    @Test
    func `the directory loader applies the dropbear rewrite on its way through`() throws {
        let directory = try CFWDaemonsFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let staging = directory.appending(path: "LaunchDaemons")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try CFWDaemons.savePlist(
            ["ProgramArguments": ["dropbear", "-R"]],
            to: staging.appending(path: "dropbear.plist"),
        )

        let staged = try CFWDaemons.loadDaemons(inDirectory: staging, names: ["dropbear"])
        let arguments = (staged.present[0].contents["ProgramArguments"] as? [Any] ?? [])
            .compactMap { $0 as? String }
        #expect(arguments == ["dropbear"] + CFWDaemons.dropbearKeyArguments)
    }

    @Test
    func `the installed label, not the source filename, is what launchd keys on`() {
        let daemon = CFWDaemons.Daemon(name: "com.vphone.jb-setup", contents: [:])
        #expect(daemon.launchdKey == "/System/Library/LaunchDaemons/com.vphone.jb-setup.plist")
    }

    // MARK: - The comparator itself

    //
    // The equivalence tests below are only worth their run time if the thing
    // judging them can fail. These are what say it can.

    @Test
    func `the comparator catches a reordered array`() {
        let differences = PlistSemantics.differences(
            ["ProgramArguments": ["-r", "/a", "-r", "/b"]],
            ["ProgramArguments": ["-r", "/b", "-r", "/a"]],
        )
        #expect(differences.count == 2)
    }

    @Test
    func `the comparator catches true standing in for 1, and a missing key`() {
        #expect(!PlistSemantics.differences(["RunAtLoad": true], ["RunAtLoad": 1]).isEmpty)
        #expect(!PlistSemantics.differences(["Umask": 0], ["Umask": 0, "Extra": 1]).isEmpty)
        #expect(!PlistSemantics.differences(["Version": 1], ["Version": 1.0]).isEmpty)
    }

    @Test
    func `the comparator catches differing Data bytes of equal length`() {
        #expect(!PlistSemantics.differences(
            ["Blob": Data([0x01, 0x02])],
            ["Blob": Data([0x01, 0x03])],
        ).isEmpty)
    }
}

// MARK: - The frozen reference

/// What `scripts/patchers/` produced on these inputs, recorded before it was
/// deleted.
///
/// Measured at repo commit `78cbeea` with `.venv/bin/python3`. Two of the three
/// rewrites take an input that is not fixed — the host's own
/// `/System/Library/xpc/launchd.plist` is 2.6 MB and differs with every macOS
/// build — so for those the frozen value is the *transform*, read off the
/// Python's output by diffing it against its own input. Each constant says
/// which command it came from, and the transform assertions below are exactly
/// the ones that diff reported.
enum CFWDaemonsGolden {
    /// `.venv/bin/python3 scripts/patchers/cfw.py cryptex-paths \
    ///  ipsws/ref_extract/iphone/BuildManifest.plist`
    /// printed these two lines, in this order.
    static let cryptexSystemOS = "043-70113-702.dmg.aea"
    static let cryptexAppOS = "043-69297-784.dmg"

    /// `.venv/bin/python3 scripts/patchers/cfw.py patch-dropbear-plist <copy of
    /// cfw_input/jb/LaunchDaemons/dropbear.plist>` — over the file whose digest
    /// is ``dropbearSource`` — left exactly this `ProgramArguments` array and
    /// changed no other key. `-R` dropped, the two `-r` key paths appended.
    static let dropbearSource =
        "2f6b05e7eeeb98559a3eb389a9c8fcb6083c2ccb9f2c105d6b132c76eece78a5"
    static let dropbearProgramArguments = [
        "/iosbinpack64/usr/local/bin/dropbear",
        "--shell",
        "/iosbinpack64/bin/bash",
        "-E",
        "-F",
        "-p",
        "22222",
        "-a",
        "-r",
        "/var/dropbear/dropbear_rsa_host_key",
        "-r",
        "/var/dropbear/dropbear_ecdsa_host_key",
    ]

    /// `.venv/bin/python3 scripts/patchers/cfw.py inject-daemons <copy of
    /// /System/Library/xpc/launchd.plist> <cfw_input/jb/LaunchDaemons>`.
    ///
    /// Diffing its output against its input: the top-level key set was
    /// unchanged, every key but `LaunchDaemons` was untouched, no existing
    /// `LaunchDaemons` entry moved, and exactly these four keys were added —
    /// each one carrying the staged plist verbatim, dropbear with the rewrite
    /// above already applied. It also printed
    /// `[!] Missing …/vphoned.plist, skipping`.
    static let injectedDaemonNames = ["bash", "dropbear", "trollvnc", "rpcserver_ios"]
    static let missingDaemonCount = 1

    /// The inline `plistlib` snippet at `cfw_install_jb.sh:460-469` and
    /// `cfw_install_exp.sh:702-711`, run verbatim over the same input.
    ///
    /// The same diff: one key added, carrying `scripts/vphone_jb_setup.plist`
    /// verbatim (digest ``jbSetupSource``), nothing else changed.
    static let jbSetupKey = "/System/Library/LaunchDaemons/com.vphone.jb-setup.plist"
    static let jbSetupSource =
        "80ff5a830b81012c1ecfdc596bfb05557ace23ae747002233b2b88b464de9efc"

    static func launchdKey(_ name: String) -> String {
        "/System/Library/LaunchDaemons/\(name).plist"
    }

    /// SHA-256 as `shasum -a 256` prints it.
    static func digest(of url: URL) throws -> String {
        try Data(SHA256.hash(data: Data(contentsOf: url))).hex
    }
}

// MARK: - Equivalence against the frozen reference

/// The verification bar for this port: same real input through the Python and
/// through the Swift, compared semantically.
///
/// These run only while the real inputs are here — `BuildManifest.plist` comes
/// out of an IPSW, and `ipsws/` is not in the repo.
@Suite(
    "CFW daemon rewrites match the Python they replaced",
    .enabled(if: CFWDaemonsFixtures.referenceInputsAvailable),
)
struct CFWDaemonsReferenceEquivalenceTests {
    @Test
    func `cryptex-paths on a real BuildManifest`() throws {
        let swift = try CFWDaemons.cryptexPaths(buildManifest: CFWDaemonsFixtures.buildManifest)
        #expect(swift.systemOS == CFWDaemonsGolden.cryptexSystemOS)
        #expect(swift.appOS == CFWDaemonsGolden.cryptexAppOS)
    }

    @Test
    func `patch-dropbear-plist on the installer's real dropbear.plist`() throws {
        let directory = try CFWDaemonsFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let staging = try CFWDaemonsFixtures.unpackLaunchDaemons(into: directory)
        let source = staging.appending(path: "dropbear.plist")
        try #require(
            try CFWDaemonsGolden.digest(of: source) == CFWDaemonsGolden.dropbearSource,
            "the archive's dropbear.plist is not the one the golden was recorded over",
        )
        let before = try CFWDaemonsFixtures.loadPlist(source)

        let swiftCopy = try CFWDaemonsFixtures.writableCopy(of: source, in: directory, named: "swift.plist")
        try CFWDaemons.patchDropbearPlist(at: swiftCopy)
        let after = try CFWDaemonsFixtures.loadPlist(swiftCopy)

        #expect(
            (after["ProgramArguments"] as? [Any])?.compactMap { $0 as? String }
                == CFWDaemonsGolden.dropbearProgramArguments,
        )
        // …and nothing but that key moved, which is the other half of what the
        // Python's own output diff said.
        var expected = after
        expected["ProgramArguments"] = before["ProgramArguments"]
        let differences = PlistSemantics.differences(before, expected)
        #expect(differences.isEmpty, "\(differences)")
    }

    @Test
    func `inject-daemons on a real launchd.plist and the real staging directory`() throws {
        let directory = try CFWDaemonsFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let staging = try CFWDaemonsFixtures.unpackLaunchDaemons(into: directory)
        let swiftCopy = try CFWDaemonsFixtures.writableCopy(
            of: CFWDaemonsFixtures.hostLaunchdPlist, in: directory, named: "swift-launchd.plist",
        )
        let before = try CFWDaemonsFixtures.loadPlist(swiftCopy)

        let staged = try CFWDaemons.injectDaemons(into: swiftCopy, fromDirectory: staging)
        #expect(staged.injectedNames == CFWDaemonsGolden.injectedDaemonNames)
        // vphoned is staged separately by the Swift installer, so the archive's
        // directory really is missing it — the skip path is exercised for free.
        #expect(staged.missingSources.count == CFWDaemonsGolden.missingDaemonCount)

        let after = try CFWDaemonsFixtures.loadPlist(swiftCopy)
        try assertOnlyAdded(
            CFWDaemonsGolden.injectedDaemonNames.map(CFWDaemonsGolden.launchdKey),
            to: before, in: after,
        )

        // Each added value is the staged plist verbatim — dropbear with the
        // rewrite applied — which is what the reference's output diff showed.
        let daemons = try #require(after["LaunchDaemons"] as? [String: Any])
        for name in CFWDaemonsGolden.injectedDaemonNames {
            var source = try CFWDaemonsFixtures.loadPlist(staging.appending(path: "\(name).plist"))
            if name == "dropbear" {
                var patched: PlistDict = source
                CFWDaemons.patchDropbearDaemon(&patched)
                source = patched
            }
            let injected = try #require(daemons[CFWDaemonsGolden.launchdKey(name)])
            let differences = PlistSemantics.differences(source, injected)
            #expect(differences.isEmpty, "\(name): \(differences.prefix(10))")
        }
    }

    /// The inline `plistlib` snippet at `cfw_install_jb.sh:460-469` and
    /// `cfw_install_exp.sh:702-711`, measured against the same input as the
    /// Swift single-daemon form. This is what "one implementation, three call
    /// sites" has to mean: the inline snippet was not a second behaviour.
    @Test
    func `the installers' inline jb-setup merge is the same merge`() throws {
        let directory = try CFWDaemonsFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try #require(
            try CFWDaemonsGolden.digest(of: CFWDaemonsFixtures.jbSetupPlist)
                == CFWDaemonsGolden.jbSetupSource,
            "vphone_jb_setup.plist is not the one the golden was recorded over",
        )

        let swiftCopy = try CFWDaemonsFixtures.writableCopy(
            of: CFWDaemonsFixtures.hostLaunchdPlist, in: directory, named: "swift-launchd.plist",
        )
        let before = try CFWDaemonsFixtures.loadPlist(swiftCopy)

        try CFWDaemons.injectDaemon(
            into: swiftCopy,
            name: "com.vphone.jb-setup",
            from: CFWDaemonsFixtures.jbSetupPlist,
        )

        let after = try CFWDaemonsFixtures.loadPlist(swiftCopy)
        try assertOnlyAdded([CFWDaemonsGolden.jbSetupKey], to: before, in: after)

        let daemons = try #require(after["LaunchDaemons"] as? [String: Any])
        let injected = try #require(daemons[CFWDaemonsGolden.jbSetupKey])
        let source = try CFWDaemonsFixtures.loadPlist(CFWDaemonsFixtures.jbSetupPlist)
        let differences = PlistSemantics.differences(source, injected)
        #expect(differences.isEmpty, "\(differences.prefix(10))")
    }

    /// The shape the reference's output diff reported, for both merges: the
    /// top-level key set unchanged, every key but `LaunchDaemons` untouched, no
    /// existing `LaunchDaemons` entry moved or removed, and exactly `keys`
    /// added.
    private func assertOnlyAdded(
        _ keys: [String],
        to before: [String: Any],
        in after: [String: Any],
    ) throws {
        #expect(Set(before.keys).union(["LaunchDaemons"]) == Set(after.keys))
        for key in before.keys where key != "LaunchDaemons" {
            let differences = PlistSemantics.differences(before[key]!, after[key]!, at: key)
            #expect(differences.isEmpty, "\(differences)")
        }

        let old = (before["LaunchDaemons"] as? [String: Any]) ?? [:]
        let new = try #require(after["LaunchDaemons"] as? [String: Any])
        #expect(Set(new.keys).subtracting(old.keys) == Set(keys))
        #expect(Set(old.keys).subtracting(new.keys).isEmpty)
        for key in old.keys where !keys.contains(key) {
            let differences = PlistSemantics.differences(old[key]!, new[key]!, at: key)
            #expect(differences.isEmpty, "\(differences)")
        }
    }
}
