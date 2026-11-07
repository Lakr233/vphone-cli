import Foundation
import XCTest
@testable import ResultSchemaKit

/// Rules 4, 5, 10 and 11, helper lookup order, cycles and the unresolvable message.
final class SwiftHelperTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
    static let tail = "; point the result-producers.tsv entry at the function that builds the result or add an extraction rule"

    func read(_ path: String) throws -> String {
        try String(contentsOf: Self.fixtures.appendingPathComponent(path), encoding: .utf8)
    }

    func directory(_ path: String) throws -> [SwiftSource] {
        let url = Self.fixtures.appendingPathComponent(path)
        return try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
            .filter { $0.hasSuffix(".swift") }
            .map { SwiftSource(file: "\(path)/\($0)", text: try read("\(path)/\($0)")) }
    }

    func nativeLookup() throws -> SwiftLookup {
        let native = NativeSource(file: "native-forms.m", text: try read("native-forms.m"))
        return SwiftLookup(native: { _ in [native] })
    }

    func marked(_ prefix: String, in text: String) -> [[String]] {
        text.split(separator: "\n").compactMap { line in
            guard let range = line.range(of: prefix) else { return nil }
            return line[range.upperBound...].components(separatedBy: " => ")
        }
    }

    func cell(_ text: String, _ function: String, arm: String? = nil, lookup: SwiftLookup) throws -> String {
        catalogCell(try SwiftExtractor.extract(source: text, function: function, arm: arm, lookup: lookup))
    }

    func testHelperFixtureCases() throws {
        let text = try read("swift-helpers.swift")
        let lookup = try nativeLookup()
        let all = marked("// expect: ", in: text)
        XCTAssertGreaterThanOrEqual(all.count, 16)
        for parts in all {
            let target = parts[0].split(separator: "@", maxSplits: 1).map(String.init)
            XCTAssertEqual(
                try cell(text, target[0], arm: target.count > 1 ? target[1] : nil, lookup: lookup),
                parts[1], parts[0]
            )
        }
    }

    // MARK: rule 4 mutations

    func testMergeIsNeeded() throws {
        let text = try read("swift-helpers.swift")
        let mutated = text.replacingOccurrences(of: "    out.merge(plainKeys()) { current, _ in current }\n", with: "")
        XCTAssertNotEqual(mutated, text)
        XCTAssertEqual(
            try cell(mutated, "mergeStatement", lookup: SwiftLookup()),
            "extra:boolean?,id:string,mine:string,tail:integer?"
        )
    }

    func testNestedAssignmentsAreOptionalPerKind() throws {
        let text = try read("swift-helpers.swift")
        XCTAssertEqual(
            try cell(text, "nestedAssignments", lookup: SwiftLookup()), "base:string,c:boolean?,f:integer?,i:integer?"
        )
        // Making each assignment unconditional makes exactly that key required.
        let unconditional = text
            .replacingOccurrences(of: "for _ in items { out[\"f\"] = 1 }", with: "out[\"f\"] = 1")
            .replacingOccurrences(of: "if flag { out[\"i\"] = 2 }", with: "out[\"i\"] = 2")
            .replacingOccurrences(of: "items.forEach { _ in out[\"c\"] = true }", with: "out[\"c\"] = true")
        XCTAssertEqual(
            try cell(unconditional, "nestedAssignments", lookup: SwiftLookup()),
            "base:string,c:boolean,f:integer,i:integer"
        )
    }

    func testCycleTerminates() throws {
        let text = try read("swift-helpers.swift")
        XCTAssertEqual(try cell(text, "pong", lookup: SwiftLookup()), "p:integer?,q:string?")
    }

    func testUnresolvableHelperNamesMethodFileFunctionLine() throws {
        let text = try read("swift-helpers.swift")
        let line = text.split(separator: "\n", omittingEmptySubsequences: false)
            .firstIndex { $0.contains("return missingHelper(first)") }! + 1
        XCTAssertThrowsError(
            try SwiftExtractor.extract(source: text, function: "unresolvableHelper", method: "m.x", file: "H.swift")
        ) { error in
            XCTAssertEqual("\(error)", "unresolvable: m.x H.swift#unresolvableHelper line \(line)" + Self.tail)
        }
    }

    func testSameNamedHelpersInOneFileAreUnresolvable() throws {
        let text = try read("swift-helpers.swift")
        XCTAssertThrowsError(
            try SwiftExtractor.extract(source: text, function: "ambiguousHelper", method: "m.y", file: "H.swift")
        ) { error in
            XCTAssertTrue("\(error)".hasPrefix("unresolvable: m.y H.swift#ambiguousHelper line "), "\(error)")
        }
    }

    /// Rule 11 bridge: both the native array and the Swift helper's array contribute.
    func testBridgeArrayNeedsBothSources() throws {
        let text = try read("swift-helpers.swift")
        let lookup = try nativeLookup()
        XCTAssertEqual(try cell(text, "rowInfo", lookup: lookup), "extra:boolean?,id:string,name:string?,size:integer?")
        let noAppend = text.replacingOccurrences(of: "    rows.append(contentsOf: scanRows())\n", with: "")
        XCTAssertNotEqual(noAppend, text)
        XCTAssertEqual(try cell(noAppend, "rowInfo", lookup: lookup), "id:string,name:string?,size:integer")
        XCTAssertThrowsError(try cell(text, "rowInfo", lookup: SwiftLookup()))
    }

    // MARK: lookup order

    func testLookupOrderAcrossRoots() throws {
        let producer = try read("swift-lookup/producer.swift")
        let lookup = SwiftLookup(levels: [
            try directory("swift-lookup/module"), try directory("swift-lookup/repo"), try directory("swift-lookup/icli"),
        ])
        func cell(_ function: String) throws -> String {
            try SwiftExtractor.extract(source: producer, function: function, file: "producer.swift", lookup: lookup)
                |> catalogCell
        }
        XCTAssertEqual(try cell("viaSameFile"), "file:integer")
        XCTAssertEqual(try cell("viaModule"), "m:string")
        XCTAssertEqual(try cell("viaRepo"), "r:string")
        XCTAssertEqual(try cell("viaIcli"), "i:boolean")
        XCTAssertEqual(try cell("viaShadow"), "level:string")
        // Without the icli root the icli-only helper cannot be found.
        let noIcli = SwiftLookup(levels: Array(lookup.levels.prefix(2)))
        XCTAssertThrowsError(
            try SwiftExtractor.extract(source: producer, function: "viaIcli", method: "m.z", file: "producer.swift", lookup: noIcli)
        )
    }

    func testTwoSameNamedHelpersAtFirstLevelAreUnresolvable() throws {
        let producer = try read("swift-lookup/producer.swift")
        let lookup = SwiftLookup(levels: [try directory("swift-lookup/module"), try directory("swift-lookup/repo")])
        XCTAssertThrowsError(
            try SwiftExtractor.extract(source: producer, function: "viaTwins", method: "m.t", file: "producer.swift", lookup: lookup)
        ) { error in
            XCTAssertEqual("\(error)", "unresolvable: m.t producer.swift#viaTwins line 8" + Self.tail)
        }
        XCTAssertThrowsError(
            try SwiftExtractor.extract(source: producer, function: "viaMissing", method: "m.n", file: "producer.swift", lookup: lookup)
        )
    }

    // MARK: rule 5

    func testSinkUnionAcrossTwoFiles() throws {
        let sink = try read("swift-sink/sink.swift")
        let both = try directory("swift-sink")
        let keys = try SwiftExtractor.extractSink(source: sink, function: "setProgress", directory: both, file: "swift-sink/sink.swift")
        XCTAssertEqual(
            catalogCell(keys),
            "downloaded_bytes:integer?,error:string?,layout:string?,phase:string,tag:string?,total_bytes:integer?"
        )
        // A key in every literal of the sink file and call site A is required; B lacks it.
        let tagged = sink.replacingOccurrences(of: "\"layout\": layout])", with: "\"layout\": layout, \"tag\": \"t\"])")
        XCTAssertNotEqual(tagged, sink)
        let withB = try SwiftExtractor.extractSink(source: tagged, function: "setProgress", directory: both, file: "swift-sink/sink.swift")
        XCTAssertTrue(catalogCell(withB).contains("tag:string?"))
        let single = both.filter { $0.file.hasSuffix("sink.swift") || $0.file.hasSuffix("callsA.swift") }
        let one = try SwiftExtractor.extractSink(source: tagged, function: "setProgress", directory: single, file: "swift-sink/sink.swift")
        XCTAssertEqual(catalogCell(one), "downloaded_bytes:integer?,layout:string?,phase:string,tag:string?,total_bytes:integer?")
    }

    func testSinkInitialValueMakesKeysOptional() throws {
        let sink = try read("swift-sink/sink.swift")
        let empty = sink.replacingOccurrences(of: "[\"phase\": \"idle\"]", with: "[:]")
        XCTAssertNotEqual(empty, sink)
        let keys = try SwiftExtractor.extractSink(
            source: empty, function: "setProgress", directory: try directory("swift-sink"), file: "swift-sink/sink.swift"
        )
        XCTAssertTrue(catalogCell(keys).contains("phase:string?"))
        let opaque = sink.replacingOccurrences(of: "[\"phase\": \"idle\"]", with: "Self.initial()")
        XCTAssertNotEqual(opaque, sink)
        let without = try SwiftExtractor.extractSink(
            source: opaque, function: "setProgress", directory: try directory("swift-sink"), file: "swift-sink/sink.swift"
        )
        XCTAssertTrue(catalogCell(without).contains("layout:string,"))
    }

    func testInoutWriteIsNeeded() throws {
        let text = try read("swift-helpers.swift")
        let mutated = text.replacingOccurrences(of: "        mergeService(service, into: &payload)\n", with: "")
        XCTAssertNotEqual(mutated, text)
        XCTAssertEqual(try cell(mutated, "inoutStatus", lookup: SwiftLookup()), "domains:array,label:string,running:boolean")
        let always = text.replacingOccurrences(of: "    if flag { target[\"sometimes\"] = \"x\" }", with: "    target[\"sometimes\"] = \"x\"")
        XCTAssertNotEqual(always, text)
        XCTAssertEqual(try cell(always, "inoutTop", lookup: SwiftLookup()), "always:boolean,sometimes:string")
    }

    func testSinkBackingAssignmentIsNeeded() throws {
        let sink = try read("swift-sink/sink.swift")
        let mutated = sink.replacingOccurrences(of: "        progress[\"downloaded_bytes\"] = received\n", with: "")
        XCTAssertNotEqual(mutated, sink)
        let keys = try SwiftExtractor.extractSink(
            source: mutated, function: "setProgress", directory: try directory("swift-sink"), file: "swift-sink/sink.swift"
        )
        XCTAssertEqual(catalogCell(keys), "downloaded_bytes:integer?,error:string?,layout:string?,phase:string,tag:string?,total_bytes:integer?")
        let nothing = sink.replacingOccurrences(of: "        progress[\"downloaded_bytes\"] = received\n", with: "")
            .replacingOccurrences(of: "            progress[\"total_bytes\"] = total\n", with: "")
        let bare = try SwiftExtractor.extractSink(
            source: nothing, function: "setProgress", directory: try directory("swift-sink"), file: "swift-sink/sink.swift"
        )
        XCTAssertEqual(catalogCell(bare), "downloaded_bytes:integer?,error:string?,layout:string?,phase:string,tag:string?")
    }

    func testSinkWithNonLiteralArgumentIsUnresolvable() throws {
        let sink = try read("swift-sink/sink.swift")
        let extra = SwiftSource(file: "swift-sink/callsC.swift", text: "func c(v: [String: Any]) { setProgress(v) }\n")
        XCTAssertThrowsError(
            try SwiftExtractor.extractSink(
                source: sink, function: "setProgress", directory: try directory("swift-sink") + [extra],
                method: "bootstrap.status", file: "swift-sink/sink.swift"
            )
        ) { error in
            XCTAssertEqual(
                "\(error)", "unresolvable: bootstrap.status swift-sink/callsC.swift#setProgress line 1" + Self.tail
            )
        }
    }
}

infix operator |>: AdditionPrecedence
private func |> <A, B>(value: A, function: (A) -> B) -> B { function(value) }
