import XCTest
@testable import ResultSchemaKit

final class CatalogCellTests: XCTestCase {
    func testCellSortsAndFlags() {
        let keys = [
            ExtractedKey(name: "b", type: .integer, presence: .optional),
            ExtractedKey(name: "a", type: .string, presence: .required),
        ]
        XCTAssertEqual(catalogCell(keys), "a:string,b:integer?")
        XCTAssertEqual(catalogCell([]), "-")
    }

    func testNullableAndNullOnlyCells() {
        let keys = [
            ExtractedKey(name: "a", type: .string, presence: .required, nullable: true),
            ExtractedKey(name: "b", type: .integer, presence: .optional, nullable: true),
            ExtractedKey(name: "c", type: .null, presence: .required),
        ]
        XCTAssertEqual(catalogCell(keys), "a:string:null,b:integer:null?,c:null")
    }

    func testMergeRules() {
        var keys: KeyMap = [:]
        KeyMerge.merge(&keys, name: "x", type: .string, presence: .required)
        KeyMerge.merge(&keys, name: "x", type: .null, presence: .required)
        XCTAssertEqual(keys["x"], ExtractedKey(name: "x", type: .string, presence: .required, nullable: true))
        KeyMerge.merge(&keys, name: "x", type: .integer, presence: .required)
        XCTAssertEqual(keys["x"]?.type, .any)
        KeyMerge.merge(&keys, name: "n", type: .null, presence: .required)
        KeyMerge.merge(&keys, name: "n", type: .null, presence: .required)
        XCTAssertEqual(keys["n"], ExtractedKey(name: "n", type: .null, presence: .required))
    }

    func testUnionOrsNullabilityAndKeepsPresence() {
        let a: KeyMap = ["k": ExtractedKey(name: "k", type: .string, presence: .required)]
        let b: KeyMap = ["k": ExtractedKey(name: "k", type: .null, presence: .required)]
        XCTAssertEqual(KeyMerge.union([a, b])["k"], ExtractedKey(name: "k", type: .string, presence: .required, nullable: true))
        XCTAssertEqual(KeyMerge.union([a, [:]])["k"]?.presence, .optional)
    }
}
