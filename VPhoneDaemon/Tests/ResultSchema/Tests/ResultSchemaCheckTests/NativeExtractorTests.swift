import Foundation
import XCTest
@testable import ResultSchemaKit

final class NativeExtractorTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    struct Expectation {
        let function: String
        let mode: NativeMode
        let cell: String
    }

    func source(_ name: String) throws -> String {
        try String(contentsOf: Self.fixtures.appendingPathComponent(name), encoding: .utf8)
    }

    /// Parses `// expect: <function>[@writer] => <cell>` lines.
    func expectations(_ source: String) -> [Expectation] {
        source.split(separator: "\n").compactMap { line in
            guard let range = line.range(of: "// expect: ") else { return nil }
            let parts = line[range.upperBound...].components(separatedBy: " => ")
            guard parts.count == 2 else { return nil }
            let target = parts[0].split(separator: "@", maxSplits: 1).map(String.init)
            let mode: NativeMode = target.count > 1 ? .writer : .produce
            return Expectation(function: target[0], mode: mode, cell: parts[1])
        }
    }

    func lookup() throws -> (String) -> [NativeSource] {
        let remote = try source("native-icli.m")
        return { _ in [NativeSource(file: "icli:native-icli.m", text: remote)] }
    }

    func cell(_ text: String, _ e: Expectation) throws -> String {
        catalogCell(try NativeExtractor.extract(
            source: text, function: e.function, mode: e.mode, lookup: try lookup()
        ))
    }

    func cell(_ text: String, _ function: String, _ mode: NativeMode = .produce) throws -> String {
        try cell(text, Expectation(function: function, mode: mode, cell: ""))
    }

    func testFormsFixtureCases() throws {
        let text = try source("native-forms.m")
        let all = expectations(text)
        XCTAssertGreaterThanOrEqual(all.count, 13)
        for e in all {
            XCTAssertEqual(try cell(text, e), e.cell, e.function)
        }
    }

    /// Rule 10: `// expect-unwrap: <function>["key"] => <cell>|open`.
    func testEnvelopeUnwrap() throws {
        let text = try source("native-forms.m")
        let sources = [NativeSource(file: "native-forms.m", text: text)]
        var count = 0
        for line in text.split(separator: "\n") {
            guard let range = line.range(of: "// expect-unwrap: ") else { continue }
            let parts = line[range.upperBound...].components(separatedBy: " => ")
            let target = parts[0].split(separator: "[", maxSplits: 1).map(String.init)
            let key = String(target[1].dropFirst().dropLast(2))
            let result = try NativeExtractor.unwrap(function: target[0], key: key, sources: sources)
            XCTAssertEqual(result.open ? "open" : catalogCell(result.keys), parts[1], target[0])
            count += 1
        }
        XCTAssertEqual(count, 3)
        // The envelope literal is needed: without a `result` entry the function is unresolvable.
        let broken = text.replacingOccurrences(of: "@\"result\": @{@\"a\": @1}", with: "@\"other\": @{@\"a\": @1}")
        XCTAssertThrowsError(try NativeExtractor.unwrap(
            function: "vp_demo_copy_json", key: "result", sources: [NativeSource(file: "n.m", text: broken)]
        ))
    }

    /// Rule 11 bridge: `// expect-elements: <function> => <cell>`; only the returned array counts.
    func testBridgeElements() throws {
        let text = try source("native-forms.m")
        let sources = [NativeSource(file: "native-forms.m", text: text)]
        let keys = try NativeExtractor.elements(function: "icli_rows_json", sources: sources)
        XCTAssertEqual(catalogCell(keys), "id:string,name:string?,size:integer")
        let broken = text.replacingOccurrences(of: "[out addObject:icliRowDictionary(proxy)];", with: "")
        XCTAssertThrowsError(try NativeExtractor.elements(
            function: "icli_rows_json", sources: [NativeSource(file: "n.m", text: broken)]
        ))
    }

    /// Removing a subscript assignment from the vp_gyro_get shape must change its cell.
    func testGyroSubscriptRemovalChangesCell() throws {
        let text = try source("native-forms.m")
        let mutated = text.replacingOccurrences(of: "    result[@\"units\"] = @\"rad/s\";\n", with: "")
        XCTAssertNotEqual(mutated, text)
        XCTAssertEqual(
            try cell(mutated, "vp_gyro_get"),
            "enabled:any,provider:any,provider_running:any,x:any,y:any,z:any"
        )
    }

    /// Dropping mutableCopy handling loses the Encode keys.
    func testGyroMutableCopyRemovalChangesCell() throws {
        let text = try source("native-forms.m")
        let mutated = text.replacingOccurrences(
            of: "[VPhoneGyroscopeEncode(state) mutableCopy]", with: "[NSMutableDictionary dictionary]"
        )
        XCTAssertNotEqual(mutated, text)
        XCTAssertEqual(try cell(mutated, "vp_gyro_get"), "provider:any,provider_running:any,units:string")
    }

    /// display.external: both the subscript assignments and the request literal reached
    /// through mutableCopy are needed.
    func testDisplayExternalNeedsSubscriptAndMutableCopy() throws {
        let text = try source("native-forms.m")
        let noName = text.replacingOccurrences(
            of: "            status[@\"name\"] = width == 3840 ? @\"VPhone External 4K\" : @\"VPhone External 1080p\";\n",
            with: "            (void)width;\n"
        )
        XCTAssertNotEqual(noName, text)
        XCTAssertEqual(
            try cell(noName, "vpApplyExternalRequest", .writer),
            "enabled:any,error:any?,height:integer,nonce:string,ok:boolean?,width:integer"
        )
        let noCopy = text.replacingOccurrences(
            of: "[request mutableCopy]", with: "[NSMutableDictionary dictionary]"
        )
        XCTAssertEqual(
            try cell(noCopy, "vpApplyExternalRequest", .writer),
            "enabled:any?,error:any?,name:string?,ok:boolean?"
        )
    }

    func testUnconditionalAssignmentBecomesRequired() throws {
        let text = try source("native-forms.m")
        let mutated = text.replacingOccurrences(
            of: "    if (flag) {\n        [d setObject:@3 forKey:@\"beta\"];\n    }\n",
            with: "    [d setObject:@3 forKey:@\"beta\"];\n"
        )
        XCTAssertNotEqual(mutated, text)
        XCTAssertEqual(try cell(mutated, "setObjectForm"), "alpha:string,beta:integer,gamma:boolean?")
    }

    func testFollowedFunctionNeedsLookup() throws {
        let text = try source("native-forms.m")
        XCTAssertThrowsError(
            try NativeExtractor.extract(source: text, function: "bridgeRemote", method: "m.x", file: "F.m")
        ) { error in
            XCTAssertTrue("\(error)".hasPrefix("unresolvable: m.x F.m#bridgeRemote line "), "\(error)")
        }
    }

    func testUnresolvableForms() throws {
        let text = try source("native-unresolvable.m")
        let tail = "; point the result-producers.tsv entry at the function that builds the result or add an extraction rule"
        XCTAssertThrowsError(
            try NativeExtractor.extract(source: text, function: "objectsForKeys", method: "m.x", file: "U.m")
        ) { error in
            XCTAssertEqual("\(error)", "unresolvable: m.x U.m#objectsForKeys line 4" + tail)
        }
    }

    /// REQ-RPC-007: each table row, and a swapped expectation must not match.
    func testTypeInferenceTable() throws {
        let text = """
        NSDictionary *f(int n, NSNumber *w) {
            return @{@"n": @(n), @"ext": @(pasteboard.changeCount), @"y": @YES, @"w": w, @"nul": w ?: NSNull.null};
        }
        """
        let actual = try cell(text, "f")
        XCTAssertEqual(actual, "ext:any,n:integer,nul:any,w:any,y:boolean")
        XCTAssertNotEqual(actual, "ext:any,n:string,nul:any,w:any,y:boolean")
    }

    func testMissingFunctionIsUnresolvable() {
        XCTAssertThrowsError(try NativeExtractor.extract(source: "void f(void) {}", function: "g"))
    }
}
