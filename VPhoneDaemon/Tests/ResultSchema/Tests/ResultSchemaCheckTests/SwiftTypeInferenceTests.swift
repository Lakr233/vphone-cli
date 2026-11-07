import Foundation
import XCTest
@testable import ResultSchemaKit

/// REQ-RPC-007: a key whose source expression has a determinable type gets that type; `any` is kept otherwise.
final class SwiftTypeInferenceTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    func read(_ path: String) throws -> String {
        try String(contentsOf: Self.fixtures.appendingPathComponent(path), encoding: .utf8)
    }

    func lookup() throws -> SwiftLookup {
        let header = NativeSource(file: "swift-types.h", text: try read("swift-types.h"))
        return SwiftLookup(native: { _ in [header] })
    }

    func cell(_ text: String, _ function: String) throws -> String {
        catalogCell(try SwiftExtractor.extract(source: text, function: function, arm: nil, lookup: try lookup()))
    }

    func testInferenceFixtureCases() throws {
        let text = try read("swift-types.swift")
        var count = 0
        for line in text.split(separator: "\n") {
            guard let range = line.range(of: "// expect: ") else { continue }
            let parts = line[range.upperBound...].components(separatedBy: " => ")
            XCTAssertEqual(try cell(text, parts[0]), parts[1], parts[0])
            count += 1
        }
        XCTAssertGreaterThanOrEqual(count, 17)
    }

    func testDifferentBranchTypesStayAny() throws {
        let text = try read("swift-types.swift")
        let mutated = text.replacingOccurrences(of: "flag ? 1 : 2", with: "flag ? 1 : \"2\"")
        XCTAssertNotEqual(mutated, text)
        XCTAssertEqual(try cell(mutated, "ternaries"), "agree:any,disagree:any")
    }

    func testCStructFieldNeedsTheHeader() throws {
        let text = try read("swift-types.swift")
        let without = catalogCell(try SwiftExtractor.extract(source: text, function: "cStruct", arm: nil, lookup: SwiftLookup()))
        XCTAssertEqual(without, "height:any,width:any")
    }
}
