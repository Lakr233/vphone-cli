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
}
