import Foundation
import XCTest
@testable import ResultSchemaKit

final class SwiftExtractorTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    struct Expectation {
        let function: String
        let arm: String?
        let cell: String
    }

    func source(_ name: String) throws -> String {
        try String(contentsOf: Self.fixtures.appendingPathComponent(name), encoding: .utf8)
    }

    /// Parses `// expect: <function>[@<arm>] => <cell>` lines.
    func expectations(_ source: String) -> [Expectation] {
        source.split(separator: "\n").compactMap { line in
            guard let range = line.range(of: "// expect: ") else { return nil }
            let parts = line[range.upperBound...].components(separatedBy: " => ")
            guard parts.count == 2 else { return nil }
            let target = parts[0].split(separator: "@", maxSplits: 1).map(String.init)
            return Expectation(function: target[0], arm: target.count > 1 ? target[1] : nil, cell: parts[1])
        }
    }

    func cell(_ source: String, _ e: Expectation) throws -> String {
        catalogCell(try SwiftExtractor.extract(source: source, function: e.function, arm: e.arm))
    }

    func testBasicFixtureCases() throws {
        let text = try source("swift-basic.swift")
        let all = expectations(text)
        XCTAssertGreaterThanOrEqual(all.count, 8)
        for e in all {
            XCTAssertEqual(try cell(text, e), e.cell, "\(e.function)@\(e.arm ?? "-")")
        }
    }

    /// Optional vs required: an unconditional assignment must change the cell.
    func testGuardedAssignmentMutationChangesCell() throws {
        let text = try source("swift-basic.swift")
        let mutated = text.replacingOccurrences(
            of: "    if flag {\n        result[\"note\"] = \"set\"\n    }\n",
            with: "    result[\"note\"] = \"set\"\n"
        )
        XCTAssertNotEqual(mutated, text)
        let e = Expectation(function: "boundVariable", arm: nil, cell: "")
        XCTAssertEqual(try cell(mutated, e), "flag:boolean,items:array,note:string,path:string")
    }

    /// A two-arm dispatcher gives each method only its own arm, never the union.
    func testDispatcherArmsAreDisjoint() throws {
        let text = try source("swift-basic.swift")
        let alpha = try SwiftExtractor.extract(source: text, function: "dispatcher", arm: "alpha")
        XCTAssertFalse(alpha.contains { $0.name == "b" })
        let unionCell = try SwiftExtractor.extract(source: text, function: "dispatcher")
        XCTAssertNotEqual(catalogCell(alpha), catalogCell(unionCell))
    }

    func testUnresolvableNamesMethodFunctionLine() throws {
        let text = "func f() -> [String: Any] {\n    let x = other()\n    return x\n}\n"
        XCTAssertThrowsError(
            try SwiftExtractor.extract(source: text, function: "f", method: "m.x", file: "A.swift")
        ) { error in
            XCTAssertEqual(
                "\(error)",
                "unresolvable: m.x A.swift#f line 2; point the result-producers.tsv entry at the function that builds the result or add an extraction rule"
            )
        }
    }

    /// REQ-RPC-007: each table row, and a swapped expectation must not match.
    func testTypeInferenceTable() throws {
        let text = """
        func f(_ pasteboard: Pasteboard, value: Int?) -> [String: Any] {
            let n: Int = 4
            return ["n": n, "ext": pasteboard.changeCount, "t": true, "v": value ?? NSNull(), "s": String(n)]
        }
        """
        let cell = catalogCell(try SwiftExtractor.extract(source: text, function: "f"))
        XCTAssertEqual(cell, "ext:any,n:integer,s:string,t:boolean,v:any")
        XCTAssertNotEqual(cell, "ext:any,n:string,s:string,t:boolean,v:any")
    }

    func testMissingFunctionAndMissingArmAreUnresolvable() {
        XCTAssertThrowsError(try SwiftExtractor.extract(source: "func f() {}", function: "g"))
        XCTAssertThrowsError(
            try SwiftExtractor.extract(source: "func f() -> Int { return [\"a\": 1] }", function: "f", arm: "nope")
        )
    }
}
