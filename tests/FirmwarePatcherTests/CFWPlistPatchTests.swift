// CFWPlistPatchTests.swift — the three P1.4 CFW patchers, against the Python
// they replace.
//
// Unit tests cover the behaviour each patcher is supposed to have. The
// equivalence tests are the ones that matter: they run
// `scripts/patchers/<name>.py` and the Swift over the same real input and
// compare the outputs — semantically for the two plist patchers, byte for
// byte for the device tree.
//
// Real input, never a hand-made stand-in:
//   - the host's own /System/Library/CoreServices/SystemVersion.plist
//   - a real entitlements plist dumped from a signed system binary
//   - DeviceTree.vphone600ap.im4p, pulled out of the cloudOS IPSW
//
// Every equivalence test is gated on its input and on the project venv
// existing, and skips rather than fails when they do not — but a skip is not
// a pass, and the migration notes record which ones actually ran.

@testable import FirmwarePatcher
import Foundation
import Img4tool
import Testing

// MARK: - Fixtures and the Python reference

enum CFWPatchFixtures {
    /// tests/FirmwarePatcherTests/<this file> → repo root.
    static let repoRoot = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let python = repoRoot.appending(path: ".venv/bin/python3")
    static let patchers = repoRoot.appending(path: "scripts/patchers")

    /// A real Apple SystemVersion.plist, in XML, with a real ProductBuildVersion.
    static let systemVersionPlist = URL(filePath: "/System/Library/CoreServices/SystemVersion.plist")

    /// Signed host binaries to take a real entitlements plist from. Safari
    /// already carries a non-empty mach-lookup global-name exception array,
    /// so it exercises the merge; loginwindow does not carry the key at all,
    /// so it exercises the insert. Both paths matter — Campo can be either.
    static let entitlementsDonors = [
        URL(filePath: "/Applications/Safari.app"),
        URL(filePath: "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow"),
    ]

    static var availableEntitlementsDonors: [URL] {
        entitlementsDonors.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func pythonPatcherExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: patchers.appending(path: name).path)
    }

    static var venvAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: python.path)
    }

    static func canRun(_ patcher: String) -> Bool {
        venvAvailable && pythonPatcherExists(patcher)
    }

    static var systemVersionAvailable: Bool {
        FileManager.default.isReadableFile(atPath: systemVersionPlist.path)
    }

    static var entitlementsDonorAvailable: Bool {
        !availableEntitlementsDonors.isEmpty
    }

    /// Any IPSW in `ipsws/` that carries the vphone600 device tree.
    static let deviceTreeEntry = "Firmware/all_flash/DeviceTree.vphone600ap.im4p"

    static func ipswWithDeviceTree() -> URL? {
        let ipswDirectory = repoRoot.appending(path: "ipsws")
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: ipswDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        for candidate in candidates where candidate.pathExtension == "ipsw" {
            let listing = (try? run("/usr/bin/unzip", ["-l", candidate.path, deviceTreeEntry]))?.output ?? ""
            if listing.contains(deviceTreeEntry) { return candidate }
        }
        return nil
    }

    static var deviceTreeAvailable: Bool { ipswWithDeviceTree() != nil }

    /// Extract the device tree IM4P into `directory` and return its path.
    static func extractDeviceTree(into directory: URL) throws -> URL {
        guard let ipsw = ipswWithDeviceTree() else {
            throw CFWTestError.missingFixture("no IPSW in ipsws/ contains \(deviceTreeEntry)")
        }
        let result = try run("/usr/bin/unzip", ["-o", "-j", ipsw.path, deviceTreeEntry, "-d", directory.path])
        guard result.status == 0 else {
            throw CFWTestError.commandFailed("unzip exited \(result.status): \(result.output)")
        }
        return directory.appending(path: "DeviceTree.vphone600ap.im4p")
    }

    /// Dump a real entitlements plist the way `cfw_install_jb.sh` does with
    /// `ldid -e` — `codesign` is the host-side equivalent and needs no
    /// Homebrew.
    static func dumpEntitlements(of binary: URL, to url: URL) throws {
        let result = try run("/usr/bin/codesign", ["-d", "--entitlements", ":-", "--xml", binary.path])
        guard result.status == 0, !result.outputData.isEmpty else {
            throw CFWTestError.commandFailed("codesign exited \(result.status): \(result.combined)")
        }
        try result.outputData.write(to: url)
    }

    // MARK: Process plumbing

    /// stdout and stderr stay separate: `codesign -d --entitlements :-` puts
    /// the plist on stdout and its banner on stderr, and merging the two
    /// produces a file that is not a plist at all.
    struct CommandResult {
        let status: Int32
        let outputData: Data
        let errorData: Data
        var output: String { String(decoding: outputData, as: UTF8.self) }
        var combined: String { output + String(decoding: errorData, as: UTF8.self) }
    }

    @discardableResult
    static func run(_ launchPath: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(filePath: launchPath)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outputData = out.fileHandleForReading.readDataToEndOfFile()
        let errorData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            status: process.terminationStatus,
            outputData: outputData,
            errorData: errorData
        )
    }

    /// Copy a fixture's *contents*, not its file: the system plists this
    /// reads are mode 0444, and a `copyItem` carries that through and makes
    /// the copy unpatchable.
    static func copyContents(of source: URL, to destination: URL) throws {
        try Data(contentsOf: source).write(to: destination)
    }

    @discardableResult
    static func runPython(_ patcher: String, _ arguments: [String]) throws -> CommandResult {
        try run(python.path, [patchers.appending(path: patcher).path] + arguments)
    }

    static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "cfw-patch-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

enum CFWTestError: Error, CustomStringConvertible {
    case missingFixture(String)
    case commandFailed(String)

    var description: String {
        switch self {
        case let .missingFixture(message): "missing fixture: \(message)"
        case let .commandFailed(message): "command failed: \(message)"
        }
    }
}

// MARK: - Semantic plist comparison
//
// Migration plan §7.1: same key set, same array order, same value types,
// same Data bytes. Serialized key order and the XML-vs-binary encoding are
// deliberately not compared — neither is part of what a plist means.

enum PlistComparison {
    static func tag(_ value: Any) -> String {
        if CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() { return "bool" }
        switch value {
        case is [String: Any]: return "dict"
        case is [Any]: return "array"
        case is String: return "string"
        case is Data: return "data"
        case is Date: return "date"
        case let number as NSNumber: return CFNumberIsFloatType(number) ? "real" : "integer"
        default: return "unknown(\(type(of: value)))"
        }
    }

    /// Returns nil when the two are equivalent, or the path where they differ.
    static func difference(_ lhs: Any, _ rhs: Any, path: String = "<root>") -> String? {
        guard tag(lhs) == tag(rhs) else {
            return "\(path): type \(tag(lhs)) vs \(tag(rhs))"
        }
        switch tag(lhs) {
        case "dict":
            guard let left = lhs as? [String: Any], let right = rhs as? [String: Any] else {
                return "\(path): not a dictionary"
            }
            let leftKeys = Set(left.keys), rightKeys = Set(right.keys)
            guard leftKeys == rightKeys else {
                return "\(path): key set differs, only-left=\(leftKeys.subtracting(rightKeys).sorted()) only-right=\(rightKeys.subtracting(leftKeys).sorted())"
            }
            for key in leftKeys.sorted() {
                if let found = difference(left[key]!, right[key]!, path: "\(path).\(key)") {
                    return found
                }
            }
            return nil
        case "array":
            guard let left = lhs as? [Any], let right = rhs as? [Any] else {
                return "\(path): not an array"
            }
            guard left.count == right.count else {
                return "\(path): count \(left.count) vs \(right.count)"
            }
            for index in left.indices {
                if let found = difference(left[index], right[index], path: "\(path)[\(index)]") {
                    return found
                }
            }
            return nil
        case "data":
            guard let left = lhs as? Data, let right = rhs as? Data, left == right else {
                return "\(path): Data bytes differ"
            }
            return nil
        case "string":
            guard let left = lhs as? String, let right = rhs as? String, left == right else {
                return "\(path): '\(lhs)' vs '\(rhs)'"
            }
            return nil
        default:
            guard let left = lhs as? NSObject, let right = rhs as? NSObject, left.isEqual(right) else {
                return "\(path): \(lhs) vs \(rhs)"
            }
            return nil
        }
    }

    static func load(_ url: URL) throws -> Any {
        try PropertyListSerialization.propertyList(
            from: Data(contentsOf: url),
            options: [],
            format: nil
        )
    }
}

// MARK: - CFWBuildVersion

struct CFWBuildVersionTests {
    @Test func detectsXMLAndBinaryFormats() {
        #expect(CFWBuildVersion.detectFormat(Data("<?xml version=\"1.0\"?>".utf8)) == .xml)
        #expect(CFWBuildVersion.detectFormat(Data("\n\t <plist>".utf8)) == .xml)
        #expect(CFWBuildVersion.detectFormat(Data("bplist00".utf8)) == .binary)
        #expect(CFWBuildVersion.detectFormat(Data()) == .binary)
    }

    @Test func rewritesTheKeyAndLeavesEverythingElseAlone() throws {
        let directory = try CFWPatchFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "SystemVersion.plist")
        let original: [String: Any] = [
            "ProductBuildVersion": "23B85",
            "ProductVersion": "26.1",
            "ProductName": "iPhone OS",
        ]
        try PropertyListSerialization
            .data(fromPropertyList: original, format: .xml, options: 0)
            .write(to: url)

        let outcome = try CFWBuildVersion.patch(at: url, to: "23F77", verbose: false)
        #expect(outcome == .rewritten(from: "23B85", to: "23F77"))

        let patched = try PlistComparison.load(url) as? [String: Any]
        #expect(patched?["ProductBuildVersion"] as? String == "23F77")
        #expect(patched?["ProductVersion"] as? String == "26.1")
        #expect(patched?["ProductName"] as? String == "iPhone OS")
    }

    @Test func isIdempotentAndHonoursDryRun() throws {
        let directory = try CFWPatchFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "SystemVersion.plist")
        try PropertyListSerialization
            .data(fromPropertyList: ["ProductBuildVersion": "23F77"], format: .binary, options: 0)
            .write(to: url)

        let before = try Data(contentsOf: url)
        #expect(try CFWBuildVersion.patch(at: url, to: "23F77", verbose: false) == .alreadyTarget("23F77"))
        #expect(try Data(contentsOf: url) == before)

        let dry = try CFWBuildVersion.patch(at: url, to: "24A100", dryRun: true, verbose: false)
        #expect(dry == .dryRun(from: "23F77", to: "24A100"))
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func refusesAPlistWithoutTheKey() throws {
        let directory = try CFWPatchFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "SystemVersion.plist")
        try PropertyListSerialization
            .data(fromPropertyList: ["ProductVersion": "26.1"], format: .xml, options: 0)
            .write(to: url)
        #expect(throws: PatcherError.self) {
            try CFWBuildVersion.patch(at: url, to: "23F77", verbose: false)
        }
    }

    @Test func refusesANonDictionaryRoot() throws {
        let directory = try CFWPatchFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "root-array.plist")
        try PropertyListSerialization
            .data(fromPropertyList: ["a", "b"], format: .xml, options: 0)
            .write(to: url)
        #expect(throws: PatcherError.self) {
            try CFWBuildVersion.patch(at: url, to: "23F77", verbose: false)
        }
    }

    @Test(.enabled(if: CFWPatchFixtures.canRun("cfw_patch_build_version.py")
        && CFWPatchFixtures.systemVersionAvailable))
    func matchesPythonOnARealSystemVersionPlist() throws {
        let directory = try CFWPatchFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Both plist encodings of the same real file: the rootfs copy is XML,
        // the Cryptex copy on a device can be binary.
        for format in ["xml1", "binary1"] {
            let pythonOutput = directory.appending(path: "python-\(format).plist")
            let swiftOutput = directory.appending(path: "swift-\(format).plist")
            for destination in [pythonOutput, swiftOutput] {
                try CFWPatchFixtures.copyContents(of: CFWPatchFixtures.systemVersionPlist, to: destination)
                try CFWPatchFixtures.run("/usr/bin/plutil", ["-convert", format, destination.path])
            }

            let python = try CFWPatchFixtures.runPython(
                "cfw_patch_build_version.py",
                [pythonOutput.path, "23F77"]
            )
            #expect(python.status == 0, "python: \(python.combined)")
            try CFWBuildVersion.patch(at: swiftOutput, to: "23F77", verbose: false)

            let difference = PlistComparison.difference(
                try PlistComparison.load(pythonOutput),
                try PlistComparison.load(swiftOutput)
            )
            #expect(difference == nil, "\(format): \(difference ?? "")")

            // The format the file went in as is the format it comes back as.
            let swiftBytes = try Data(contentsOf: swiftOutput)
            #expect(CFWBuildVersion.detectFormat(swiftBytes) == (format == "xml1" ? .xml : .binary))
        }
    }
}

// MARK: - CFWMachLookupExceptions

struct CFWMachLookupExceptionTests {
    private func write(_ plist: [String: Any], to url: URL) throws {
        try PropertyListSerialization
            .data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: url)
    }

    @Test func addsEveryServiceWhenTheKeyIsAbsent() throws {
        let directory = try CFWPatchFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Campo.entitlements")
        try write(["platform-application": true], to: url)

        let outcome = try CFWMachLookupExceptions.merge(at: url, verbose: false)
        #expect(outcome.added == CFWMachLookupExceptions.services.count)
        #expect(outcome.total == CFWMachLookupExceptions.services.count)

        let patched = try PlistComparison.load(url) as? [String: Any]
        #expect(patched?[CFWMachLookupExceptions.exceptionKey] as? [String]
            == CFWMachLookupExceptions.services)
        #expect(patched?["platform-application"] as? Bool == true)
    }

    @Test func keepsExistingEntriesFirstAndDoesNotDuplicate() throws {
        let directory = try CFWPatchFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Campo.entitlements")
        let preexisting = ["com.apple.some.other.service", "com.apple.CARenderServer"]
        try write([CFWMachLookupExceptions.exceptionKey: preexisting], to: url)

        let outcome = try CFWMachLookupExceptions.merge(at: url, verbose: false)
        #expect(outcome.added == CFWMachLookupExceptions.services.count - 1)

        let patched = try PlistComparison.load(url) as? [String: Any]
        let merged = patched?[CFWMachLookupExceptions.exceptionKey] as? [String] ?? []
        #expect(Array(merged.prefix(2)) == preexisting)
        #expect(merged.filter { $0 == "com.apple.CARenderServer" }.count == 1)
        #expect(Set(merged).isSuperset(of: CFWMachLookupExceptions.services))
    }

    @Test func isIdempotent() throws {
        let directory = try CFWPatchFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Campo.entitlements")
        try write(["get-task-allow": true], to: url)

        try CFWMachLookupExceptions.merge(at: url, verbose: false)
        let once = try Data(contentsOf: url)
        let second = try CFWMachLookupExceptions.merge(at: url, verbose: false)
        #expect(second.added == 0)
        #expect(try Data(contentsOf: url) == once)
    }

    @Test func refusesAnExceptionKeyThatIsNotAnArray() throws {
        let directory = try CFWPatchFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Campo.entitlements")
        try write([CFWMachLookupExceptions.exceptionKey: "com.apple.CARenderServer"], to: url)
        #expect(throws: PatcherError.self) {
            try CFWMachLookupExceptions.merge(at: url, verbose: false)
        }
    }

    @Test(.enabled(if: CFWPatchFixtures.canRun("campo_mach_lookup_exceptions.py")
        && CFWPatchFixtures.entitlementsDonorAvailable))
    func matchesPythonOnRealEntitlements() throws {
        let directory = try CFWPatchFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for donor in CFWPatchFixtures.availableEntitlementsDonors {
            let name = donor.lastPathComponent
            let pythonOutput = directory.appending(path: "python-\(name).entitlements")
            let swiftOutput = directory.appending(path: "swift-\(name).entitlements")
            try CFWPatchFixtures.dumpEntitlements(of: donor, to: pythonOutput)
            try CFWPatchFixtures.copyContents(of: pythonOutput, to: swiftOutput)

            let python = try CFWPatchFixtures.runPython(
                "campo_mach_lookup_exceptions.py",
                [pythonOutput.path]
            )
            #expect(python.status == 0, "python: \(python.combined)")
            let outcome = try CFWMachLookupExceptions.merge(at: swiftOutput, verbose: false)
            #expect(python.output.contains("count: \(outcome.total) (+\(outcome.added) added)"))

            let difference = PlistComparison.difference(
                try PlistComparison.load(pythonOutput),
                try PlistComparison.load(swiftOutput)
            )
            #expect(difference == nil, "\(name): \(difference ?? "")")
        }
    }
}

// MARK: - Just enough DER to build and take apart a test IMG4

enum DERTestEncoder {
    static func length(_ count: Int) -> Data {
        if count < 0x80 { return Data([UInt8(count)]) }
        var bytes: [UInt8] = []
        var remaining = count
        while remaining > 0 {
            bytes.append(UInt8(remaining & 0xFF))
            remaining >>= 8
        }
        bytes.reverse()
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    static func element(tag: UInt8, value: Data) -> Data {
        var out = Data([tag])
        out.append(length(value.count))
        out.append(value)
        return out
    }

    static func sequence(_ elements: [Data]) -> Data {
        element(tag: 0x30, value: elements.reduce(into: Data()) { $0.append($1) })
    }

    static func ia5String(_ text: String) -> Data {
        element(tag: 0x16, value: Data(text.utf8))
    }

    /// Split a top-level SEQUENCE into its children's raw bytes.
    static func children(of data: Data) throws -> [Data] {
        var offset = 0
        func readHeader() throws -> (tag: UInt8, valueStart: Int, valueCount: Int) {
            guard offset + 2 <= data.count else { throw CFWTestError.commandFailed("short DER") }
            let tag = data[offset]
            let first = data[offset + 1]
            var cursor = offset + 2
            var count = Int(first)
            if first & 0x80 != 0 {
                let byteCount = Int(first & 0x7F)
                count = 0
                for index in 0 ..< byteCount { count = (count << 8) | Int(data[cursor + index]) }
                cursor += byteCount
            }
            return (tag, cursor, count)
        }
        let outer = try readHeader()
        var result: [Data] = []
        offset = outer.valueStart
        let end = outer.valueStart + outer.valueCount
        while offset < end {
            let child = try readHeader()
            result.append(data[offset ..< (child.valueStart + child.valueCount)])
            offset = child.valueStart + child.valueCount
        }
        return result
    }
}

// MARK: - CFWPostRestoreDeviceTree

struct CFWPostRestoreDeviceTreeTests {
    @Test(.enabled(if: CFWPatchFixtures.deviceTreeAvailable))
    func parseAndSerializeRoundTripsARealDeviceTree() throws {
        let directory = try CFWPatchFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let im4p = try CFWPatchFixtures.extractDeviceTree(into: directory)
        let blob = try IM4P(Data(contentsOf: im4p)).payload()

        // Patching to the values already there is a no-op, which is the only
        // way to see the parse/serialize pair on its own.
        let (patched, changes) = try CFWPostRestoreDeviceTree.patchedDeviceTree(blob)
        #expect(changes.count == 3)
        #expect(patched.count == blob.count)

        let (again, noChanges) = try CFWPostRestoreDeviceTree.patchedDeviceTree(patched)
        #expect(noChanges.isEmpty)
        #expect(again == patched)
    }

    @Test(.enabled(if: CFWPatchFixtures.deviceTreeAvailable))
    func rewritesExactlyTheThreeRestoreFatalProperties() throws {
        let directory = try CFWPatchFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let im4p = try CFWPatchFixtures.extractDeviceTree(into: directory)
        let blob = try IM4P(Data(contentsOf: im4p)).payload()
        let (patched, changes) = try CFWPostRestoreDeviceTree.patchedDeviceTree(blob)

        #expect(changes.map(\.property) == ["model", "target-type", "compatible"])
        #expect(changes[0].before == "iPhone99,11")
        #expect(changes[0].after == "iPhone17,3")
        #expect(changes[1].before == "VPHONE600")
        #expect(changes[1].after == "D47")
        #expect(changes[2].before == "[VPHONE600AP, iPhone99,11, AppleVirtualPlatformARM]")

        // Slot lengths are preserved, so every difference is inside one of the
        // three property values — 12 + 10 + 48 bytes at most.
        let differing = zip(blob, patched).filter { $0 != $1 }.count
        #expect(differing > 0 && differing <= 12 + 10 + 48)

        #expect(patched.range(of: Data("D47AP\0VPHONE600AP\0AppleVirtualPlatformARM\0".utf8)) != nil)
        #expect(patched.range(of: Data("iPhone17,3\0".utf8)) != nil)
    }

    @Test(.enabled(if: CFWPatchFixtures.canRun("cfw_patch_post_restore_dt.py")
        && CFWPatchFixtures.deviceTreeAvailable))
    func matchesPythonByteForByteOnARealDeviceTree() throws {
        let directory = try CFWPatchFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try CFWPatchFixtures.extractDeviceTree(into: directory)

        let pythonOutput = directory.appending(path: "python.im4p")
        let swiftOutput = directory.appending(path: "swift.im4p")
        try FileManager.default.copyItem(at: source, to: pythonOutput)
        try FileManager.default.copyItem(at: source, to: swiftOutput)

        let python = try CFWPatchFixtures.runPython("cfw_patch_post_restore_dt.py", [pythonOutput.path])
        #expect(python.status == 0, "python: \(python.combined)")
        let outcome = try CFWPostRestoreDeviceTree.patch(at: swiftOutput, verbose: false)
        #expect(outcome.wrote)
        #expect(outcome.changes.count == 3)

        let pythonBytes = try Data(contentsOf: pythonOutput)
        let swiftBytes = try Data(contentsOf: swiftOutput)
        #expect(pythonBytes == swiftBytes, "IM4P differs: \(pythonBytes.count)B vs \(swiftBytes.count)B")

        // And the re-run is a no-op on both sides.
        let pythonRerun = try CFWPatchFixtures.runPython("cfw_patch_post_restore_dt.py", [pythonOutput.path])
        #expect(pythonRerun.output.contains("no change"))
        let swiftRerun = try CFWPostRestoreDeviceTree.patch(at: swiftOutput, verbose: false)
        #expect(!swiftRerun.wrote)
        #expect(try Data(contentsOf: swiftOutput) == swiftBytes)
    }

    /// The IMG4 path, as far as it can be checked here.
    ///
    /// The real target is `/usr/standalone/firmware/devicetree.img4` on a
    /// restored rootfs, which is a signed IMG4 — and no signed IM4M is
    /// obtainable offline, so there is no Python-vs-Swift byte comparison for
    /// this shape. What is checkable without one is the part that is actually
    /// new: the IM4P inside must come out identical to the bare-IM4P run, and
    /// every element around it must come back byte for byte, because the
    /// manifest and restore info are carried, never re-encoded.
    @Test(.enabled(if: CFWPatchFixtures.deviceTreeAvailable))
    func preservesEverythingAroundTheIM4PInAnIMG4() throws {
        let directory = try CFWPatchFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try CFWPatchFixtures.extractDeviceTree(into: directory)
        let im4pBytes = try Data(contentsOf: source)

        // Stand-ins for the manifest and restore info: this test never looks
        // inside them, and neither does the patcher.
        let manifest = Data((0 ..< 96).map { UInt8(truncatingIfNeeded: $0 * 7 + 3) })
        let restoreInfo = Data((0 ..< 32).map { UInt8(truncatingIfNeeded: $0 * 11 + 5) })
        let img4 = DERTestEncoder.sequence([
            DERTestEncoder.ia5String("IMG4"),
            im4pBytes,
            DERTestEncoder.element(tag: 0xA0, value: manifest),
            DERTestEncoder.element(tag: 0xA1, value: restoreInfo),
        ])
        let img4URL = directory.appending(path: "devicetree.img4")
        try img4.write(to: img4URL)

        let outcome = try CFWPostRestoreDeviceTree.patch(at: img4URL, verbose: false)
        #expect(outcome.changes.count == 3)
        #expect(outcome.wrote)

        // The bare-IM4P run, for comparison.
        let bareURL = directory.appending(path: "bare.im4p")
        try im4pBytes.write(to: bareURL)
        try CFWPostRestoreDeviceTree.patch(at: bareURL, verbose: false)
        let patchedIM4P = try Data(contentsOf: bareURL)

        let children = try DERTestEncoder.children(of: Data(contentsOf: img4URL))
        #expect(children.count == 4)
        #expect(children[0] == DERTestEncoder.ia5String("IMG4"))
        #expect(children[1] == patchedIM4P)
        #expect(children[2] == DERTestEncoder.element(tag: 0xA0, value: manifest))
        #expect(children[3] == DERTestEncoder.element(tag: 0xA1, value: restoreInfo))
    }

    @Test(.enabled(if: CFWPatchFixtures.deviceTreeAvailable))
    func refusesAPayloadThatIsNotADeviceTree() throws {
        let directory = try CFWPatchFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "not-a-dt.im4p")
        try IM4P(fourcc: "krnl", description: "test", payload: Data(repeating: 0, count: 64))
            .data
            .write(to: url)
        #expect(throws: PatcherError.self) {
            try CFWPostRestoreDeviceTree.patch(at: url, verbose: false)
        }
    }
}
