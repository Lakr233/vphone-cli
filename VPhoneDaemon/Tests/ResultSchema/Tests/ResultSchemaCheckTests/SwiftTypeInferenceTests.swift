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

    // MARK: nullability

    func testAsAnyOptionalMarksNullable() throws {
        let text = """
        func cast(count: Int?, name: String) -> [String: Any] {
            return ["count": count as Any?, "name": name as Any?, "both": count as Any? ?? NSNull(), "plain": count]
        }
        """
        XCTAssertEqual(try cell(text, "cast"), "both:integer:null,count:integer:null,name:string:null,plain:integer")
    }

    func testNilAndNSNullOnlyAreNull() throws {
        let text = """
        func nulls(flag: Bool, id: Int) -> [String: Any] {
            return ["a": NSNull(), "b": nil, "c": flag ? nil : id, "d": id as Any? ?? 0, "e": id!]
        }
        """
        XCTAssertEqual(try cell(text, "nulls"), "a:null,b:null,c:integer:null,d:integer,e:integer")
    }

    // MARK: scoping of same-named bindings

    func testClosureParameterDoesNotUnifyWithOuterLocal() throws {
        let text = """
        func scoped(rows: [String]) -> [String: Any] {
            let item = 1
            let names = rows.map { item in item.uppercased() }
            return ["item": item, "names": names]
        }
        """
        XCTAssertEqual(try cell(text, "scoped"), "item:integer,names:array")
    }

    func testOtherArmLocalsAreSkipped() throws {
        let text = """
        func run(method: Method) -> [String: Any] {
            switch method {
            case .a:
                let value = 1
                return ["value": value]
            case .b:
                let value = "x"
                return ["value": value]
            }
        }
        """
        let keys = try SwiftExtractor.extract(source: text, function: "run", arm: "a", lookup: SwiftLookup())
        XCTAssertEqual(catalogCell(keys), "value:integer")
        let other = try SwiftExtractor.extract(source: text, function: "run", arm: "b", lookup: SwiftLookup())
        XCTAssertEqual(catalogCell(other), "value:string")
    }

    func testCatchPatternBindsErrorType() throws {
        let text = """
        struct Failure: Error { let message: String }
        func attempt() -> [String: Any] {
            do { try work(); return ["ok": true] }
            catch let error as Failure { return ["error": error.message] }
        }
        """
        XCTAssertEqual(try cell(text, "attempt"), "error:string?,ok:boolean?")
    }

    func testBareCallPrefersEnclosingTypeMember() throws {
        let text = """
        struct A { static func state() -> Int { 1 }; static func report() -> [String: Any] { ["state": state()] } }
        struct B { static func state() -> String { "s" } }
        """
        XCTAssertEqual(try cell(text, "report"), "state:integer")
    }

    func testSinkCallResolvesShapeAndCrossFileTypes() throws {
        let sink = try read("swift-sink/sink.swift")
        let shaped = sink.replacingOccurrences(
            of: "setProgress([\"phase\": \"preparing\", \"layout\": layout])",
            with: "let row = [\"layout\": layout]\n        setProgress([\"phase\": \"preparing\", \"layout\": row[\"layout\"]])")
        XCTAssertNotEqual(shaped, sink)
        let keys = try SwiftExtractor.extractSink(
            source: shaped, function: "setProgress",
            directory: [SwiftSource(file: "sink.swift", text: shaped)], file: "sink.swift"
        )
        XCTAssertTrue(catalogCell(keys).contains("layout:string"), catalogCell(keys))
    }

    func testNullWithDifferentTypesStaysAny() throws {
        let text = """
        func mixed(flag: Bool) -> [String: Any] {
            if flag { return ["v": 1, "w": NSNull()] }
            return ["v": "s", "w": 2.5]
        }
        """
        XCTAssertEqual(try cell(text, "mixed"), "v:any,w:number:null")
    }

    func testCStructFieldNeedsTheHeader() throws {
        let text = try read("swift-types.swift")
        let without = catalogCell(try SwiftExtractor.extract(source: text, function: "cStruct", arm: nil, lookup: SwiftLookup()))
        XCTAssertEqual(without, "height:any,width:any")
    }
}
