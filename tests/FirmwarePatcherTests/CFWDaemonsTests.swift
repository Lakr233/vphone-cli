import Foundation
import Testing
@testable import FirmwarePatcher

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

    static let python = repositoryRoot.appending(path: ".venv/bin/python3")
    static let cfwPy = repositoryRoot.appending(path: "scripts/patchers/cfw.py")
    static let buildManifest = repositoryRoot.appending(path: "ipsws/ref_extract/iphone/BuildManifest.plist")
    static let cfwInputArchive = repositoryRoot.appending(path: "scripts/resources/cfw_input.tar.zst")
    static let jbSetupPlist = repositoryRoot.appending(path: "scripts/vphone_jb_setup.plist")

    /// A real `launchd.plist` of the shape the installer rewrites.
    ///
    /// The guest's copy lives on a volume that needs root to mount; the host's is
    /// the same file, produced by the same build system, and is world-readable.
    static let hostLaunchdPlist = URL(filePath: "/System/Library/xpc/launchd.plist")

    /// Whether the Python this ports is still in the tree to compare against.
    /// It is deleted at the end of P1, and these comparisons go with it.
    static var pythonReferenceAvailable: Bool {
        [python, cfwPy, buildManifest, cfwInputArchive, hostLaunchdPlist]
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

    @Test("-R is dropped and the seeded host keys are appended")
    func rewritesReadOnlyRootKeyGeneration() {
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

    @Test("stale explicit -r key paths are replaced, not kept")
    func replacesStaleExplicitKeyPaths() {
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

    @Test("an empty argument list is left alone — there is nothing to point at a key")
    func leavesEmptyArgumentsAlone() {
        var daemon: PlistDict = ["ProgramArguments": [String]()]
        CFWDaemons.patchDropbearDaemon(&daemon)
        #expect((daemon["ProgramArguments"] as? [Any])?.isEmpty == true)
    }

    @Test("a trailing -r with no path does not read past the end")
    func toleratesTrailingKeyFlag() {
        #expect(
            CFWDaemons.patchedDropbearArguments(["dropbear", "-r"]).compactMap { $0 as? String }
                == ["dropbear"] + CFWDaemons.dropbearKeyArguments
        )
    }

    // MARK: - Cryptex paths

    @Test("Cryptex paths are found in a later identity, not just the first")
    func cryptexPathsSearchesEveryIdentity() throws {
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

    @Test("an identity carrying only one of the two is not a match")
    func cryptexPathsNeedsBoth() throws {
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

    @Test("injection creates LaunchDaemons when the target has none")
    func injectionCreatesLaunchDaemonsDictionary() throws {
        let directory = try CFWDaemonsFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let launchd = directory.appending(path: "launchd.plist")
        try CFWDaemons.savePlist(["VersionNumber": 1], to: launchd)

        try CFWDaemons.inject(
            [CFWDaemons.Daemon(name: "vphoned", contents: ["Label": "vphoned"])],
            into: launchd
        )

        let result = try CFWDaemons.loadPlist(launchd)
        let daemons = result["LaunchDaemons"] as? PlistDict
        #expect(daemons?["/System/Library/LaunchDaemons/vphoned.plist"] != nil)
        #expect(result["VersionNumber"] as? Int == 1)
    }

    @Test("injecting twice replaces rather than duplicates, so a re-run is safe")
    func injectionIsIdempotent() throws {
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

    @Test("a daemon absent from the staging directory is reported, not fatal")
    func missingDaemonsAreReported() throws {
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
        if case .present = staged[0] {} else { Issue.record("bash should be first in scan order") }
    }

    @Test("the directory loader applies the dropbear rewrite on its way through")
    func directoryLoaderPatchesDropbear() throws {
        let directory = try CFWDaemonsFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let staging = directory.appending(path: "LaunchDaemons")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try CFWDaemons.savePlist(
            ["ProgramArguments": ["dropbear", "-R"]],
            to: staging.appending(path: "dropbear.plist")
        )

        let staged = try CFWDaemons.loadDaemons(inDirectory: staging, names: ["dropbear"])
        let arguments = (staged.present[0].contents["ProgramArguments"] as? [Any] ?? [])
            .compactMap { $0 as? String }
        #expect(arguments == ["dropbear"] + CFWDaemons.dropbearKeyArguments)
    }

    @Test("the installed label, not the source filename, is what launchd keys on")
    func launchdKeyComesFromTheInstalledLabel() {
        let daemon = CFWDaemons.Daemon(name: "com.vphone.jb-setup", contents: [:])
        #expect(daemon.launchdKey == "/System/Library/LaunchDaemons/com.vphone.jb-setup.plist")
    }

    // MARK: - The comparator itself
    //
    // The equivalence tests below are only worth their run time if the thing
    // judging them can fail. These are what say it can.

    @Test("the comparator catches a reordered array")
    func comparatorCatchesArrayOrder() {
        let differences = PlistSemantics.differences(
            ["ProgramArguments": ["-r", "/a", "-r", "/b"]],
            ["ProgramArguments": ["-r", "/b", "-r", "/a"]]
        )
        #expect(differences.count == 2)
    }

    @Test("the comparator catches true standing in for 1, and a missing key")
    func comparatorCatchesTypeAndKeySet() {
        #expect(!PlistSemantics.differences(["RunAtLoad": true], ["RunAtLoad": 1]).isEmpty)
        #expect(!PlistSemantics.differences(["Umask": 0], ["Umask": 0, "Extra": 1]).isEmpty)
        #expect(!PlistSemantics.differences(["Version": 1], ["Version": 1.0]).isEmpty)
    }

    @Test("the comparator catches differing Data bytes of equal length")
    func comparatorCatchesDataBytes() {
        #expect(!PlistSemantics.differences(
            ["Blob": Data([0x01, 0x02])],
            ["Blob": Data([0x01, 0x03])]
        ).isEmpty)
    }
}

// MARK: - Equivalence against the Python

/// The verification bar for this port: same real input through the Python and
/// through the Swift, compared semantically.
///
/// These run only while `scripts/patchers/` and the venv are still in the tree.
/// When P1 finishes deleting them the suite disables itself and the unit tests
/// above are what remains.
@Suite(
    "CFW daemon rewrites match the Python they replace",
    .enabled(if: CFWDaemonsFixtures.pythonReferenceAvailable)
)
struct CFWDaemonsPythonEquivalenceTests {
    @Test("cryptex-paths on a real BuildManifest")
    func cryptexPathsMatchPython() throws {
        let output = try CFWDaemonsFixtures.run(CFWDaemonsFixtures.python.path, [
            CFWDaemonsFixtures.cfwPy.path,
            "cryptex-paths",
            CFWDaemonsFixtures.buildManifest.path,
        ])
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        try #require(lines.count == 2)

        let swift = try CFWDaemons.cryptexPaths(buildManifest: CFWDaemonsFixtures.buildManifest)
        #expect(swift.systemOS == lines[0])
        #expect(swift.appOS == lines[1])
    }

    @Test("patch-dropbear-plist on the installer's real dropbear.plist")
    func dropbearPlistMatchesPython() throws {
        let directory = try CFWDaemonsFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let staging = try CFWDaemonsFixtures.unpackLaunchDaemons(into: directory)
        let source = staging.appending(path: "dropbear.plist")

        let pythonCopy = try CFWDaemonsFixtures.writableCopy(of: source, in: directory, named: "py.plist")
        let swiftCopy = try CFWDaemonsFixtures.writableCopy(of: source, in: directory, named: "swift.plist")

        try CFWDaemonsFixtures.run(CFWDaemonsFixtures.python.path, [
            CFWDaemonsFixtures.cfwPy.path, "patch-dropbear-plist", pythonCopy.path,
        ])
        try CFWDaemons.patchDropbearPlist(at: swiftCopy)

        let differences = try PlistSemantics.differences(
            CFWDaemonsFixtures.loadPlist(pythonCopy),
            CFWDaemonsFixtures.loadPlist(swiftCopy)
        )
        #expect(differences.isEmpty, "\(differences)")
    }

    @Test("inject-daemons on a real launchd.plist and the real staging directory")
    func injectDaemonsMatchesPython() throws {
        let directory = try CFWDaemonsFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let staging = try CFWDaemonsFixtures.unpackLaunchDaemons(into: directory)
        let pythonCopy = try CFWDaemonsFixtures.writableCopy(
            of: CFWDaemonsFixtures.hostLaunchdPlist, in: directory, named: "py-launchd.plist"
        )
        let swiftCopy = try CFWDaemonsFixtures.writableCopy(
            of: CFWDaemonsFixtures.hostLaunchdPlist, in: directory, named: "swift-launchd.plist"
        )

        try CFWDaemonsFixtures.run(CFWDaemonsFixtures.python.path, [
            CFWDaemonsFixtures.cfwPy.path, "inject-daemons", pythonCopy.path, staging.path,
        ])
        let staged = try CFWDaemons.injectDaemons(into: swiftCopy, fromDirectory: staging)
        #expect(staged.injectedNames == ["bash", "dropbear", "trollvnc", "rpcserver_ios"])
        // vphoned is staged separately by the Swift installer, so the archive's
        // directory really is missing it — the skip path is exercised for free.
        #expect(staged.missingSources.count == 1)

        let differences = try PlistSemantics.differences(
            CFWDaemonsFixtures.loadPlist(pythonCopy),
            CFWDaemonsFixtures.loadPlist(swiftCopy)
        )
        #expect(differences.isEmpty, "\(differences.prefix(10))")
    }

    /// The inline `plistlib` snippet at `cfw_install_jb.sh:460-469` and
    /// `cfw_install_exp.sh:702-711`, run verbatim against the same input as the
    /// Swift single-daemon form. This is what "one implementation, three call
    /// sites" has to mean: the inline snippet is not a second behaviour.
    @Test("the installers' inline jb-setup merge is the same merge")
    func inlineInstallerSnippetMatchesSwift() throws {
        let directory = try CFWDaemonsFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let pythonCopy = try CFWDaemonsFixtures.writableCopy(
            of: CFWDaemonsFixtures.hostLaunchdPlist, in: directory, named: "py-launchd.plist"
        )
        let swiftCopy = try CFWDaemonsFixtures.writableCopy(
            of: CFWDaemonsFixtures.hostLaunchdPlist, in: directory, named: "swift-launchd.plist"
        )

        let inlineSnippet = """
        import plistlib, sys
        with open(sys.argv[1], 'rb') as f:
            target = plistlib.load(f)
        with open(sys.argv[2], 'rb') as f:
            daemon = plistlib.load(f)
        target.setdefault('LaunchDaemons', {})\
        ['/System/Library/LaunchDaemons/com.vphone.jb-setup.plist'] = daemon
        with open(sys.argv[1], 'wb') as f:
            plistlib.dump(target, f, sort_keys=False)
        """
        try CFWDaemonsFixtures.run(CFWDaemonsFixtures.python.path, [
            "-c", inlineSnippet, pythonCopy.path, CFWDaemonsFixtures.jbSetupPlist.path,
        ])
        try CFWDaemons.injectDaemon(
            into: swiftCopy,
            name: "com.vphone.jb-setup",
            from: CFWDaemonsFixtures.jbSetupPlist
        )

        let differences = try PlistSemantics.differences(
            CFWDaemonsFixtures.loadPlist(pythonCopy),
            CFWDaemonsFixtures.loadPlist(swiftCopy)
        )
        #expect(differences.isEmpty, "\(differences.prefix(10))")
    }
}
