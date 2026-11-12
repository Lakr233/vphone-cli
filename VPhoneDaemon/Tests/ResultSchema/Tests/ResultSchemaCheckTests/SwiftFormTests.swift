import Foundation
import XCTest
@testable import ResultSchemaKit

/// Value types flow through dictionary subscripts, optional chains, closures and branch expressions.
final class SwiftFormTests: XCTestCase {
    var text = ""

    override func setUpWithError() throws {
        let url = SwiftTypeInferenceTests.fixtures.appendingPathComponent("swift-forms.swift")
        text = try String(contentsOf: url, encoding: .utf8)
    }

    func cell(_ source: String, _ function: String) throws -> String {
        catalogCell(try SwiftExtractor.extract(source: source, function: function, arm: nil, lookup: SwiftLookup(native: { _ in [] })))
    }

    func testFormFixtureCases() throws {
        var count = 0
        for line in text.split(separator: "\n") {
            guard let range = line.range(of: "// expect: ") else { continue }
            let parts = line[range.upperBound...].components(separatedBy: " => ")
            XCTAssertEqual(try cell(text, parts[0]), parts[1], parts[0])
            count += 1
        }
        XCTAssertEqual(count, 12)
    }

    /// Each row breaks the one token a form depends on; the cell must then change as stated.
    func testBreakingAFormChangesItsCell() throws {
        let mutations: [(function: String, from: String, to: String, cell: String)] = [
            ("dictSubscript", "[String: Int] = values()", "[String: Any] = values()", "count:any"),
            ("optionalChain", "info?.path", "info?.count", "name:integer"),
            ("optionalMap", ".map { $0.count }", ".map { $0.path }", "size:string"),
            ("coalesced", "info?.path ?? \"\"", "info?.count ?? \"\"", "path:any"),
            ("castAny", "n as Any", "n as Any?", "n:integer:null"),
            ("tryOptional", "try? values()", "try? rows()", "info:array"),
            ("switchValue", "default: \"other\"", "default: 1", "level:any"),
            ("ifValue", "else { 2 }", "else { \"2\" }", "level:any"),
            ("localClosure", "{ \"label\" }", "{ 1 }", "label:integer"),
            ("reduceInto", "[String: Int]()", "[Int]()", "total:array"),
            ("shapeRead", "out[\"name\"] = \"n\"", "out[\"name\"] = 1", "name:any"),
        ]
        for mutation in mutations {
            let mutated = text.replacingOccurrences(of: mutation.from, with: mutation.to)
            XCTAssertNotEqual(mutated, text, mutation.function)
            XCTAssertEqual(try cell(mutated, mutation.function), mutation.cell, mutation.function)
        }
    }
}
