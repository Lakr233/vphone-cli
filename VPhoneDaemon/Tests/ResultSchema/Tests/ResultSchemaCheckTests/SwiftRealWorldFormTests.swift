import Foundation
import XCTest
@testable import ResultSchemaKit

/// Forms found in the real producers (TASK-RPC-008 run over all 192 methods).
final class SwiftRealWorldFormTests: XCTestCase {
    func cell(_ source: String, _ function: String, lookup: SwiftLookup = SwiftLookup()) throws -> String {
        catalogCell(try SwiftExtractor.extract(source: source, function: function, method: "m.x", file: "f.swift", lookup: lookup))
    }

    func testLoopOverLiteralNamesGivesOptionalKeys() throws {
        let source = """
        func pressure() -> [String: Any] {
            var memory: [String: Any] = [:]
            for (key, name) in [("hw_memsize", "hw.memsize"), ("level", "kern.level")] {
                var value: Int64 = 0
                if read(name, &value) == 0 { memory[key] = size == 4 ? Int(Int32(value)) : Int(value) }
            }
            return memory
        }
        func plain() -> [String: Any] {
            var memory: [String: Any] = [:]
            for key in ["a", "b"] { memory[key] = 1 }
            return memory
        }
        """
        XCTAssertEqual(try cell(source, "pressure"), "hw_memsize:integer?,level:integer?")
        XCTAssertEqual(try cell(source, "plain"), "a:integer?,b:integer?")
        // Mutation: a list that is not a literal leaves the key unresolvable.
        XCTAssertThrowsError(try cell(source.replacingOccurrences(of: "[(\"hw_memsize\", \"hw.memsize\"), (\"level\", \"kern.level\")]", with: "pairs"), "pressure"))
        // Mutation: a tuple element that is not a string literal is unresolvable too.
        XCTAssertThrowsError(try cell(source.replacingOccurrences(of: "(\"level\", ", with: "(other, "), "pressure"))
    }

    func testOptionalMapOfHelperMergedIntoResult() throws {
        let source = """
        func describe(_ value: Int) -> [String: Any] { ["value": value, "type": "int"] }
        func read(key: String?) -> [String: Any] {
            var result: [String: Any] = ["domain": "d"]
            if let key {
                let found: Int? = lookup(key)
                result["exists"] = true
                let typed = found.map(describe) ?? ["value": NSNull(), "type": "null"]
                result.merge(typed) { $1 }
                return result
            }
            result["count"] = 0
            return result
        }
        """
        XCTAssertEqual(try cell(source, "read"), "count:integer?,domain:string,exists:boolean?,type:string?,value:integer?")
        // Mutation: mapping a closure instead of a named helper is not followed.
        XCTAssertThrowsError(try cell(source.replacingOccurrences(of: "found.map(describe)", with: "found.map { describe($0) }"), "read"))
    }

    func testTernaryOfDictionaryLiteralsIsTheUnionOfBranches() throws {
        let source = """
        func describe(_ x: Int) -> [String: Any] {
            return isFloat(x)
                ? ["value": 1.5, "type": "float"]
                : ["value": 2, "type": "int", "extra": true]
        }
        """
        XCTAssertEqual(try cell(source, "describe"), "extra:boolean?,type:string,value:any")
        // Mutation: a branch that is not a dictionary is unresolvable.
        XCTAssertThrowsError(try cell(source.replacingOccurrences(of: "[\"value\": 2, \"type\": \"int\", \"extra\": true]", with: "5"), "describe"))
    }

    func testOverloadsAreToldApartByCallLabels() throws {
        let source = """
        func caller() -> [String: Any] { return try pick(imageOutput: nil) }
        func plain() -> [String: Any] { return pick() }
        func pick() -> [String: Any] { ["no": 1] }
        func pick(imageOutput: String?) -> [String: Any] { ["img": "x"] }
        """
        XCTAssertEqual(try cell(source, "caller"), "img:string")
        XCTAssertEqual(try cell(source, "plain"), "no:integer")
        XCTAssertThrowsError(try cell(source, "pick"))
    }

    func testPlatformStubInElseClauseIsNotAnOverload() throws {
        let source = """
        #if os(macOS)
        func stub() -> [String: Any] { ["real": true] }
        #else
        func stub() -> [String: Any] { ["tv": true] }
        #endif
        """
        XCTAssertEqual(try cell(source, "stub"), "real:boolean")
    }

    func testWithLockClosureIsTheReturnedBody() throws {
        let source = """
        func a() -> [String: Any] { lock.withLock { ["entries": [1]] } }
        func b() throws -> [String: Any] {
            return try lock.withLock {
                guard x else { return ["entries": [1], "changed": false] }
                return ["entries": [2]]
            }
        }
        """
        XCTAssertEqual(try cell(source, "a"), "entries:array")
        XCTAssertEqual(try cell(source, "b"), "changed:boolean?,entries:array")
    }

    func testVariableAssignedInsideDoBlock() throws {
        let source = """
        func d() throws -> [String: Any] {
            var payload: [String: Any]
            do { payload = try helper() } catch { throw error }
            payload["seconds"] = 3
            return payload
        }
        func helper() throws -> [String: Any] { ["a": "x"] }
        """
        XCTAssertEqual(try cell(source, "d"), "a:string,seconds:integer")
    }

    func testSeveralBindingsOfOneNameAreUnioned() throws {
        let source = """
        func u() throws -> [String: Any] {
            if let result = try one() { return result }
            if let result = try two() { return result }
            return ["z": true]
        }
        func one() throws -> [String: Any]? { ["a": 1] }
        func two() throws -> [String: Any]? { ["b": 1] }
        """
        XCTAssertEqual(try cell(source, "u"), "a:integer?,b:integer?,z:boolean?")
    }

    func testAssignmentWithOperatorsInTheValueCounts() throws {
        let source = """
        func t(flag: Bool) -> [String: Any] {
            var r: [String: Any] = [:]
            r["k"] = flag ? 1 : 2
            r["j"] = flag ?? true
            return r
        }
        """
        XCTAssertEqual(Set(try SwiftExtractor.extract(source: source, function: "t").map(\.name)), ["j", "k"])
    }

    func testNonLiteralKeyInLoopOverComputedListIsUnresolvable() {
        let source = """
        func dyn() -> [String: Any] {
            var memory: [String: Any] = [:]
            for key in names() { memory[key] = size == 4 ? 1 : 2 }
            return memory
        }
        """
        XCTAssertThrowsError(try SwiftExtractor.extract(source: source, function: "dyn", method: "m.x", file: "f.swift"))
    }

    // MARK: rule 6 and 10 forms

    let native = [
        NativeSource(file: "Header.h", text: "char *icli_x_json(void);\nchar *vp_a_copy_json(void);\n"),
        NativeSource(file: "X.m", text: """
        char *icli_x_json(void) {
            return icli_json_or_empty(@{@"total": @(5L), @"name": @"x"});
        }
        char *vp_a_copy_json(void) {
            return icli_json_or_empty(@{@"on": @YES});
        }
        """),
    ]

    func testBridgeDecodedDictionaryFollowsTheNativeFunction() throws {
        let source = """
        func s() throws -> [String: Any] { try decodeBridgeJSON(takeCString(icli_x_json()), "x") }
        func viaDecoder() throws -> [String: Any] { try decodeLocation(takeCString(icli_x_json())) }
        func parsed() throws -> [String: Any] {
            guard let raw = takeCString(icli_x_json()), let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { throw E() }
            return obj
        }
        func copy() throws -> [String: Any] {
            guard let json = vp_a_copy_json() else { throw E() }
            guard let state = try JSONSerialization.jsonObject(with: Data(json)) as? [String: Any] else { throw E() }
            return state
        }
        func nativeCall() -> [String: Any] {
            guard let report = vp_a_copy_json() as? [String: Any] else { throw E() }
            return report.merging(["extra": 1], uniquingKeysWith: { _, v in v })
        }
        """
        let lookup = SwiftLookup(native: { name in self.native.filter { $0.text.contains(name) } })
        XCTAssertEqual(try cell(source, "s", lookup: lookup), "name:string,total:integer")
        XCTAssertEqual(try cell(source, "viaDecoder", lookup: lookup), "name:string,total:integer")
        XCTAssertEqual(try cell(source, "parsed", lookup: lookup), "name:string,total:integer")
        XCTAssertEqual(try cell(source, "copy", lookup: lookup), "on:boolean")
        XCTAssertEqual(try cell(source, "nativeCall", lookup: lookup), "extra:integer,on:boolean")
        XCTAssertThrowsError(try cell(source, "s"))
    }

    /// A header declaration listed before the definition must not hide the definition.
    func testNativeDefinitionAfterHeaderIsFound() throws {
        let keys = try NativeExtractor.extract(function: "icli_x_json", sources: native)
        XCTAssertEqual(catalogCell(keys), "name:string,total:integer")
        XCTAssertThrowsError(try NativeExtractor.extract(function: "icli_x_json", sources: [native[0]]))
    }
}
