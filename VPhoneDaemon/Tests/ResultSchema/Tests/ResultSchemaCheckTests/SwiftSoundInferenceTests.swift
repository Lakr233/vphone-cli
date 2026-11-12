import Foundation
import XCTest
@testable import ResultSchemaKit

/// Forms that give a key its real type from where the value comes from (no pinned types).
final class SwiftSoundInferenceTests: XCTestCase {
    func cell(_ source: String, _ function: String) throws -> String {
        catalogCell(try SwiftExtractor.extract(source: source, function: function, method: "m.x", file: "f.swift", lookup: SwiftLookup()))
    }

    func testFoundationPathBuiltins() throws {
        let source = """
        func paths(dir: String) throws -> [String: Any] {
            let names = try FileManager.default.contentsOfDirectory(atPath: dir)
            let leaf = (dir as NSString).lastPathComponent
            return ["names": names, "ext": (dir as NSString).appendingPathExtension("x"), "joined": (dir as NSString).appendingPathComponent(leaf)]
        }
        """
        XCTAssertEqual(try cell(source, "paths"), "ext:string,joined:string,names:array")
    }

    func testCoalescedFallbackUnionsBothSides() throws {
        let source = """
        func load() -> [String: Any]? { ["b": "x"] }
        func result() -> [String: Any] {
            return load() ?? ["a": 1]
        }
        """
        XCTAssertEqual(try cell(source, "result"), "a:integer?,b:string?")
    }

    func testAnyReturningFunctionTakesItsReturnedShape() throws {
        let source = """
        func respring(_ ok: Bool) -> Any {
            if ok { return ["status": "ok", "pid": 1] }
            return ["status": "failed", "pid": 2]
        }
        func result() -> [String: Any] {
            ["respring": respring(true)]
        }
        """
        XCTAssertEqual(try cell(source, "result"), "respring:object")
    }

    func testSwitchOnCastSpecialisesToTheArgument() throws {
        let source = """
        func safe(_ value: Any) -> Any {
            switch value {
            case let text as String: return text
            case let dict as [String: Any]: return dict.mapValues { safe($0) }
            default: return "\\(value)"
            }
        }
        func result(entitlements: [String: Any]) -> [String: Any] {
            ["entitlements": safe(entitlements)]
        }
        """
        XCTAssertEqual(try cell(source, "result"), "entitlements:object")
    }

    func testClosureParameterBindsToTheElement() throws {
        let source = """
        func result(names: [String]) -> [String: Any] {
            let rows = names.map { ["name": $0, "size": 1] }
            return ["rows": rows]
        }
        """
        XCTAssertEqual(try cell(source, "result"), "rows:array")
    }

    func nativeCell(_ source: String, _ function: String) throws -> String {
        catalogCell(try NativeExtractor.extract(source: source, function: function, file: "f.m"))
    }

    func testNativeTableEntryKeyTakesTheLiteralsType() throws {
        let source = """
        static NSDictionary *entry(NSString *selector, NSString *title) {
            return @{ @"id": selector, @"title": title };
        }
        static NSArray *table(void) {
            static NSArray *catalog;
            catalog = @[ entry(@"a:", @"A"), entry(@"b:", @"B") ];
            return catalog;
        }
        static NSDictionary *run(NSDictionary *spec) {
            return @{@"operation": spec[@"id"], @"submitted": @YES};
        }
        static NSDictionary *go(void) {
            NSDictionary *spec = nil;
            for (NSDictionary *candidate in table()) { spec = candidate; }
            return run(spec);
        }
        """
        XCTAssertEqual(try nativeCell(source, "run"), "operation:string,submitted:boolean")
        // Mutation: a call that passes something else leaves the key untyped.
        let other = source.replacingOccurrences(of: "return run(spec);", with: "return run(other);")
        XCTAssertEqual(try nativeCell(other, "run"), "operation:any,submitted:boolean")
    }

    func testNativeCFBooleanNumberIsBoolean() throws {
        let source = """
        static NSNumber *flag(void) {
            CFPropertyListRef value = CFPreferencesCopyValue(k, d, u, h);
            NSNumber *number = value && CFGetTypeID(value) == CFBooleanGetTypeID() ? CFBridgingRelease(value) : nil;
            return number;
        }
        NSDictionary *state(void) {
            NSNumber *after = flag();
            return @{@"visible": after};
        }
        """
        XCTAssertEqual(try nativeCell(source, "state"), "visible:boolean")
        // Mutation: without the CFBoolean check the number is untyped.
        XCTAssertEqual(try nativeCell(source.replacingOccurrences(of: "CFGetTypeID(value) == CFBooleanGetTypeID()", with: "value != NULL"), "state"), "visible:any")
    }

    func testNativeBridgeEnvelopeElements() throws {
        let source = """
        char *json(void) {
            NSMutableArray *rows = [NSMutableArray array];
            [rows addObject:@{@"pid": @1, @"name": @"x"}];
            return icli_system_json(@{@"processes": rows, @"count": @1});
        }
        """
        let keys = try NativeExtractor.elements(
            function: "json", key: "processes", sources: [NativeSource(file: "f.m", text: source)])
        XCTAssertEqual(catalogCell(keys), "name:string,pid:integer")
    }

    func testSameNameInSeparateScopesTakesTheVisibleBinding() throws {
        let source = """
        func result(flag: Bool) -> [String: Any] {
            if flag {
                let value = "text"
                return ["v": value]
            }
            let value = 3
            return ["v": value]
        }
        """
        XCTAssertEqual(try cell(source, "result"), "v:any")
    }
}
