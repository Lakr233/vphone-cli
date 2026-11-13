import Foundation
import XCTest
@testable import ResultSchemaKit

/// Drift scenarios (REQ-RPC-008): each copies Fixtures/drift to a temp dir and mutates it.
/// The NFR-RPC-002 timing test (built binary, real tree, under 60 s) waits for Phase 4, when
/// every catalog row has a `result` cell.
final class DriftTests: XCTestCase {
    static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/drift")

    var temp: URL!
    var repo: URL { temp.appendingPathComponent("repo") }
    var icli: URL { temp.appendingPathComponent("icli") }

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("drift-" + UUID().uuidString)
        try FileManager.default.copyItem(at: Self.fixture, to: temp)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    /// Replaces `old` with `new` in a file of the temp tree; fails when `old` is absent.
    func mutate(_ path: String, _ old: String, _ new: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let url = temp.appendingPathComponent(path)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains(old), "\(old) not in \(path)", file: file, line: line)
        try text.replacingOccurrences(of: old, with: new).write(to: url, atomically: true, encoding: .utf8)
    }

    func check(method: String? = nil) -> DriftReport { DriftCheck.run(repo: repo, icli: icli, method: method) }

    static let clip = "clipboard.get: icli IcliKit/Clipboard.swift#clipboardInfo"
    static let clipPlace = "ClipboardMethod.clipboardGet"
    static let clipPath = "icli/Sources/IcliKit/Clipboard.swift"
    static let devicePath = "icli/Sources/IcliKit/Device.swift"
    static let catalog = "repo/VPhoneDaemon/Tests/methods-catalog.tsv"

    // MARK: kinds

    func testUnmodifiedTreeIsClean() {
        let report = check()
        XCTAssertEqual(report, DriftReport())
    }

    func testAddedKey() throws {
        try mutate(Self.clipPath, "\"count\": count]", "\"count\": count, \"x\": \"v\"]")
        let report = check()
        XCTAssertEqual(report.stdout, [
            "\(Self.clip) added key \"x\" (string); add .required(\"x\", .string) or .optional(\"x\", .string) to \(Self.clipPlace)"
        ])
        XCTAssertEqual(report.stderr, [])
        XCTAssertEqual(report.exitCode, 1)
    }

    static let pagedCells = "count:integer,next_cursor:string?,text:string,total:integer,truncated:boolean"

    func testPagedMethodMayDeclareDispatchKeys() throws {
        try mutate("repo/VPhoneDaemon/Daemon/GuestAPI.swift", "    case clipboardGet = \"clipboard.get\"\n}",
                   "    case clipboardGet = \"clipboard.get\"\n    var spec: MethodSpec {\n        switch self {\n"
                       + "        case .clipboardGet: MethodSpec(result: [], paged: MethodSpec.Paged(key: \"text\", order: .keep))\n        }\n    }\n}")
        try mutate(Self.catalog, "count:integer,text:string", Self.pagedCells)
        XCTAssertEqual(check(), DriftReport())
    }

    func testNonPagedMethodListingDispatchKeysFails() throws {
        try mutate(Self.catalog, "count:integer,text:string", Self.pagedCells)
        let report = check()
        XCTAssertEqual(report.stdout, ["next_cursor", "total", "truncated"].map {
            "\(Self.clip) removed key \"\($0)\"; remove \"\($0)\" from \(Self.clipPlace)"
        })
        XCTAssertEqual(report.exitCode, 1)
    }

    func testRemovedKey() throws {
        try mutate(Self.clipPath, "\"text\": text, ", "")
        let report = check()
        XCTAssertEqual(report.stdout, ["\(Self.clip) removed key \"text\"; remove \"text\" from \(Self.clipPlace)"])
        XCTAssertEqual(report.exitCode, 1)
    }

    func testTypeChanged() throws {
        try mutate(Self.clipPath, "let count: Int = 3", "let count: Double = 3")
        let report = check()
        XCTAssertEqual(report.stdout, [
            "\(Self.clip) key \"count\" type changed integer -> number; declare \"count\" as .number in \(Self.clipPlace)"
        ])
        XCTAssertEqual(report.exitCode, 1)
    }

    func testAnyAgainstConcreteIsDrift() throws {
        try mutate(Self.clipPath, "\"count\": count]", "\"count\": externalCount]")
        XCTAssertEqual(check().stdout, [
            "\(Self.clip) key \"count\" type changed integer -> any; declare \"count\" as .any in \(Self.clipPlace)"
        ])
    }

    func testNullabilityChangedIsItsOwnFinding() throws {
        try mutate(Self.catalog, "count:integer,", "count:integer:null,")
        let report = check()
        XCTAssertEqual(report.stdout, [
            "\(Self.clip) key \"count\" nullability changed nullable -> non-null; "
                + "remove .nullable() from \"count\" in \(Self.clipPlace)"
        ])
        XCTAssertEqual(report.exitCode, 1)
    }

    func testNullableDeclarationReportsTypeAndNullabilityFindings() throws {
        // A declared `:null` key keeps its type and presence comparison independent of nullability.
        try mutate(Self.catalog, "count:integer,", "count:number:null,")
        XCTAssertEqual(check().stdout, [
            "\(Self.clip) key \"count\" type changed number -> integer; declare \"count\" as .integer in \(Self.clipPlace)",
            "\(Self.clip) key \"count\" nullability changed nullable -> non-null; "
                + "remove .nullable() from \"count\" in \(Self.clipPlace)",
        ])
    }

    func testNullOnlyDeclarationAgainstConcreteIsTypeDrift() throws {
        try mutate(Self.catalog, "count:integer,", "count:null,")
        XCTAssertEqual(check().stdout, [
            "\(Self.clip) key \"count\" type changed null -> integer; declare \"count\" as .integer in \(Self.clipPlace)"
        ])
    }

    func testNullableIntegerExtractionAgainstIntegerCatalogIsNullabilityDrift() throws {
        try mutate(Self.clipPath, "\"count\": count]", "\"count\": Bool.random() ? nil : count]")
        XCTAssertEqual(check().stdout, [
            "\(Self.clip) key \"count\" nullability changed non-null -> nullable; add .nullable() to \"count\" in \(Self.clipPlace)"
        ])
    }

    func testNullOnlyExtractionAgainstStringCatalogIsTypeDrift() throws {
        try mutate(Self.clipPath, "\"text\": text, ", "\"text\": NSNull(), ")
        XCTAssertEqual(check().stdout, [
            "\(Self.clip) key \"text\" type changed string -> null; declare \"text\" as .null in \(Self.clipPlace)"
        ])
    }

    func testNullOnlyExtractionAgainstAnyCatalogIsTypeDrift() throws {
        try mutate(Self.catalog, "text:string", "text:any")
        try mutate(Self.clipPath, "\"text\": text, ", "\"text\": NSNull(), ")
        XCTAssertEqual(check().stdout, [
            "\(Self.clip) key \"text\" type changed any -> null; declare \"text\" as .null in \(Self.clipPlace)"
        ])
    }

    func testPresenceRequiredToOptional() throws {
        try mutate(Self.devicePath, ", \"model\": \"iPhone\"]", "]")
        try mutate(Self.devicePath, "result[\"serial\"] = \"S1\"", "result[\"serial\"] = \"S1\"\n        result[\"model\"] = \"iPhone\"")
        let report = check()
        XCTAssertEqual(report.stdout, [
            "device.info: icli IcliKit/Device.swift#deviceInfo key \"model\" presence changed required -> optional; "
                + "declare \"model\" as optional in DeviceMethod.deviceInfo"
        ])
        XCTAssertEqual(report.exitCode, 1)
    }

    func testPresenceOptionalToRequired() throws {
        try mutate(Self.devicePath, "    if detailed {\n        result[\"serial\"] = \"S1\"\n    }\n", "    result[\"serial\"] = \"S1\"\n")
        XCTAssertEqual(check().stdout, [
            "device.info: icli IcliKit/Device.swift#deviceInfo key \"serial\" presence changed optional -> required; "
                + "declare \"serial\" as required in DeviceMethod.deviceInfo"
        ])
    }

    func testRepoSideProducerLine() throws {
        try mutate("repo/VPhoneDaemon/Daemon/GuestAPI+Device.swift", "[\"level\": 80]", "[\"level\": 80, \"volts\": 1.5]")
        XCTAssertEqual(check().stdout, [
            "device.battery: repo VPhoneDaemon/Daemon/GuestAPI+Device.swift#batteryInfo added key \"volts\" (number); "
                + "add .required(\"volts\", .number) or .optional(\"volts\", .number) to DeviceMethod.deviceBattery"
        ])
    }

    func testSinkProducerLine() throws {
        try mutate("repo/VPhoneDaemon/Daemon/Progress.swift", "\"layout\": layout, \"tag\": \"t\"]", "\"layout\": layout, \"tag\": \"t\", \"extra\": 1]")
        XCTAssertEqual(check().stdout, [
            "progress.status: repo VPhoneDaemon/Daemon/Progress.swift#setProgress added key \"extra\" (integer); "
                + "add .required(\"extra\", .integer) or .optional(\"extra\", .integer) to ProgressMethod.progressStatus"
        ])
    }

    // MARK: hidden and open

    func testHiddenKeyComparedByNameAndTypeOnly() throws {
        // Presence is not compared: optional in source, declared plain hidden.
        try mutate(Self.devicePath, "return [\"plane\": \"IOService\", \"path\": \"/\"]",
                   "var r: [String: Any] = [\"plane\": \"IOService\"]\n    if flag { r[\"path\"] = \"/\" }\n    return r")
        XCTAssertEqual(check(), DriftReport())
        // Type is compared.
        try mutate(Self.devicePath, "r[\"path\"] = \"/\"", "r[\"path\"] = 1")
        XCTAssertEqual(check().stdout, [
            "device.ioreg: icli IcliKit/Device.swift#ioregInfo key \"path\" type changed string -> integer; "
                + "declare \"path\" as .integer in DeviceMethod.deviceIoreg"
        ])
    }

    func testHiddenKeyRemovedByName() throws {
        try mutate(Self.devicePath, ", \"path\": \"/\"]", "]")
        XCTAssertEqual(check().stdout, [
            "device.ioreg: icli IcliKit/Device.swift#ioregInfo removed key \"path\"; remove \"path\" from DeviceMethod.deviceIoreg"
        ])
    }

    func testOpenFlagIsNotCompared() throws {
        try mutate(Self.catalog, "path:string~", "path:string~*")
        XCTAssertEqual(check(), DriftReport())
        try mutate(Self.catalog, "level:integer", "level:integer*")
        XCTAssertEqual(check(), DriftReport())
    }

    // MARK: ordering, combination, filtering

    func testSortedByMethodThenKey() throws {
        try mutate("repo/VPhoneDaemon/Daemon/GuestAPI+Device.swift", "[\"level\": 80]", "[\"level\": 80, \"zeta\": 1]")
        try mutate(Self.clipPath, "\"count\": count]", "\"count\": count, \"b\": 1, \"a\": 2]")
        let report = check()
        let heads = report.stdout.map { line -> String in
            let method = line.components(separatedBy: ":")[0]
            let key = line.components(separatedBy: "added key \"")[1].prefix { $0 != "\"" }
            return "\(method) \(key)"
        }
        XCTAssertEqual(heads, ["clipboard.get a", "clipboard.get b", "device.battery zeta"])
        XCTAssertEqual(report.exitCode, 1)
    }

    func testDriftAndUnresolvableInOneRunBothPrintAndExitIsTwo() throws {
        try mutate(Self.clipPath, "\"count\": count]", "\"count\": count, \"x\": \"v\"]")
        try mutate(Self.devicePath, "func ioregInfo", "func ioregRenamed")
        let report = check()
        XCTAssertEqual(report.stdout.count, 1)
        XCTAssertTrue(report.stdout[0].hasPrefix("\(Self.clip) added key \"x\""))
        XCTAssertEqual(report.stderr, [
            "producer not found: device.ioreg -> icli:IcliKit/Device.swift#ioregInfo; fix the entry in result-producers.tsv"
        ])
        XCTAssertEqual(report.exitCode, 2)
    }

    func testMethodPrefixChecksOnlyThatFamily() throws {
        try mutate(Self.clipPath, "\"count\": count]", "\"count\": count, \"x\": 1]")
        try mutate("repo/VPhoneDaemon/Daemon/GuestAPI+Device.swift", "[\"level\": 80]", "[\"level\": 80, \"volts\": 1.5]")
        let device = check(method: "device.")
        XCTAssertEqual(device.stdout.count, 1)
        XCTAssertTrue(device.stdout[0].hasPrefix("device.battery:"))
        let clip = check(method: "clipboard.get")
        XCTAssertEqual(clip.stdout.count, 1)
        XCTAssertTrue(clip.stdout[0].hasPrefix("clipboard.get:"))
        // The unmodified family is clean even though another one drifts.
        XCTAssertEqual(check(method: "progress."), DriftReport())
    }

    func testPrefixMatchingNothingExitsTwo() {
        let report = check(method: "nosuch.")
        XCTAssertEqual(report.stdout, [])
        XCTAssertEqual(report.stderr, ["no methods match nosuch.; see methods-catalog.tsv for names"])
        XCTAssertEqual(report.exitCode, 2)
    }

    // MARK: unresolvable inputs

    func testMissingOrAmbiguousEnumCase() throws {
        try mutate("repo/VPhoneDaemon/Daemon/GuestAPI.swift", "    case clipboardGet = \"clipboard.get\"\n", "")
        try mutate(Self.devicePath, ", \"model\": \"iPhone\"]", ", \"model\": \"iPhone\", \"q\": 1]")
        var report = check()
        XCTAssertEqual(report.stderr, ["no enum case: clipboard.get; add case x = \"clipboard.get\" in GuestAPI*.swift"])
        XCTAssertEqual(report.stdout.count, 1, "other methods still report")
        XCTAssertEqual(report.exitCode, 2)

        try mutate("repo/VPhoneDaemon/Daemon/GuestAPI.swift", "enum ProgressMethod", "enum Twice: String {\n    case a = \"device.battery\"\n}\nenum ProgressMethod")
        report = check(method: "device.battery")
        XCTAssertEqual(report.stderr, ["no enum case: device.battery; add case x = \"device.battery\" in GuestAPI*.swift"])
        XCTAssertEqual(report.exitCode, 2)
    }

    func testBadDeclarationCells() throws {
        for (bad, line) in [("count:bogus,text:string", 1), ("count:integer,count:integer,text:string", 1), ("count:integer*?,text:string", 1),
                            ("", 1), ("count,text:string", 1)] {
            try mutate(Self.catalog, "count:integer,text:string", bad)
            try mutate("repo/VPhoneDaemon/Daemon/GuestAPI+Device.swift", "[\"level\": 80", "[\"level\": 80, \"v\": 1")
            let report = check()
            XCTAssertEqual(report.stderr, ["unresolvable declaration: clipboard.get methods-catalog.tsv line \(line)"], bad)
            XCTAssertEqual(report.exitCode, 2, bad)
            XCTAssertEqual(report.stdout.count, 1, "the other method's drift still prints: \(bad)")
            try FileManager.default.removeItem(at: temp)
            try FileManager.default.copyItem(at: Self.fixture, to: temp)
        }
    }

    func testCatalogWithoutResultColumn() throws {
        try "clipboard.get\tnever\t-\t-\n".write(
            to: temp.appendingPathComponent(Self.catalog), atomically: true, encoding: .utf8)
        try "clipboard.get\ticli:IcliKit/Clipboard.swift#clipboardInfo\n".write(
            to: temp.appendingPathComponent("repo/VPhoneDaemon/Tests/ResultSchema/result-producers.tsv"), atomically: true, encoding: .utf8)
        let report = check()
        XCTAssertEqual(report.stderr, ["unresolvable declaration: clipboard.get methods-catalog.tsv line 1"])
        XCTAssertEqual(report.exitCode, 2)
    }

    func testCellParserFlagOrder() {
        XCTAssertEqual(DriftCheck.parseCell("-")?.count, 0)
        let keys = DriftCheck.parseCell("a:string?~*,b:any")
        XCTAssertEqual(keys?["a"]?.optional, true)
        XCTAssertEqual(keys?["a"]?.hidden, true)
        XCTAssertEqual(keys?["a"]?.open, true)
        let nullable = DriftCheck.parseCell("a:string:null?,b:null,c:integer")
        XCTAssertEqual(nullable?["a"]?.type, .string)
        XCTAssertEqual(nullable?["a"]?.nullable, true)
        XCTAssertEqual(nullable?["a"]?.optional, true)
        XCTAssertEqual(nullable?["b"]?.type, .null)
        XCTAssertEqual(nullable?["b"]?.nullable, false)
        XCTAssertEqual(nullable?["c"]?.nullable, false)
        XCTAssertNil(DriftCheck.parseCell("a:string:nul"))
        XCTAssertNil(DriftCheck.parseCell("a:string?:null"))
        XCTAssertNil(DriftCheck.parseCell("a:string*?"))
        XCTAssertNil(DriftCheck.parseCell("a:string??"))
        XCTAssertNil(DriftCheck.parseCell("a:string,"))
        XCTAssertNil(DriftCheck.parseCell(""))
    }

    // MARK: result-producers.tsv rows

    static let producers = "repo/VPhoneDaemon/Tests/ResultSchema/result-producers.tsv"
    static let clipRow = "clipboard.get\ticli:IcliKit/Clipboard.swift#clipboardInfo\n"

    func testMissingProducerRowExitsTwo() throws {
        try mutate(Self.producers, Self.clipRow, "")
        let result = try cli(["--repo", repo.path, "--icli", icli.path])
        XCTAssertEqual(result.code, 2)
        XCTAssertTrue(result.err.contains("no producer: clipboard.get; add a row to result-producers.tsv"), result.err)
    }

    func testBadProducerRowsExitTwo() throws {
        for bad in ["clipboard.get\ticli:IcliKit/Clipboard.swift#clipboardInfo\textra\n", // wrong column count
                    "clipboard.get\t\n", // empty producers
                    "clipboard.get\tnot-an-entry\n", // unparsable entry
                    Self.clipRow + Self.clipRow] { // duplicate method
            try mutate(Self.producers, Self.clipRow, bad)
            let result = try cli(["--repo", repo.path, "--icli", icli.path])
            XCTAssertEqual(result.code, 2, bad)
            XCTAssertTrue(result.err.contains("bad producer row "), "\(bad) -> \(result.err)")
            try FileManager.default.removeItem(at: temp)
            try FileManager.default.copyItem(at: Self.fixture, to: temp)
        }
    }

    // MARK: command line

    var binary: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("ResultSchemaCheck")
    }

    func cli(_ args: [String]) throws -> (out: String, err: String, code: Int32) {
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self), process.terminationStatus)
    }

    func testHelpExitsZeroAndListsFlags() throws {
        let result = try cli(["--help"])
        XCTAssertEqual(result.code, 0)
        for flag in ["--repo", "--icli", "--method"] { XCTAssertTrue(result.out.contains(flag), flag) }
    }

    func testMissingFlagsExitTwo() throws {
        var result = try cli(["--icli", icli.path])
        XCTAssertEqual(result.code, 2)
        XCTAssertTrue(result.err.hasPrefix("missing --repo\n"))
        result = try cli(["--repo", repo.path])
        XCTAssertTrue(result.err.hasPrefix("missing --icli\n"))
        result = try cli(["--repo", repo.path, "--icli", icli.path, "--method"])
        XCTAssertEqual(result.code, 2)
        XCTAssertTrue(result.err.hasPrefix("missing --method\n"))
    }

    func testBinaryExitCodesAndStreams() throws {
        var result = try cli(["--repo", repo.path, "--icli", icli.path])
        XCTAssertEqual(result.code, 0)
        XCTAssertEqual(result.out + result.err, "")
        try mutate(Self.clipPath, "\"count\": count]", "\"count\": count, \"x\": \"v\"]")
        result = try cli(["--repo", repo.path, "--icli", icli.path])
        XCTAssertEqual(result.code, 1)
        XCTAssertTrue(result.out.hasPrefix("\(Self.clip) added key \"x\" (string)"))
        XCTAssertEqual(result.err, "")
        result = try cli(["--repo", repo.path, "--icli", icli.path, "--method", "nosuch."])
        XCTAssertEqual(result.code, 2)
        XCTAssertEqual(result.err, "no methods match nosuch.; see methods-catalog.tsv for names\n")
    }
}
