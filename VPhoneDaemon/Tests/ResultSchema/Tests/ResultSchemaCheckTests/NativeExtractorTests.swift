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
        XCTAssertGreaterThanOrEqual(all.count, 20)
        for e in all {
            XCTAssertEqual(try cell(text, e), e.cell, e.function)
        }
    }

    /// A boxed C comparison or logical expression is `integer`; swapping one for a BOOL value flips only that key to boolean.
    func testBoxedCExpressionsAreIntegers() throws {
        let text = try source("native-forms.m")
        let forms = ["eq": "a == b", "ne": "a != b", "lt": "a < b", "ge": "a >= b", "and": "a && b", "or": "a || b", "not": "!a"]
        let base = try cell(text, "formsBoxedC")
        for (key, expr) in forms {
            let mutated = text.replacingOccurrences(of: "@(\(expr))", with: "@YES")
            XCTAssertNotEqual(mutated, text, key)
            let swapped = try cell(mutated, "formsBoxedC")
            XCTAssertNotEqual(swapped, base, key)
            XCTAssertTrue(swapped.contains("\(key):boolean"), "\(key): \(swapped)")
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
            "enabled:any,provider:object:null,provider_running:any,x:any,y:any,z:any"
        )
    }

    /// Dropping mutableCopy handling loses the Encode keys.
    func testGyroMutableCopyRemovalChangesCell() throws {
        let text = try source("native-forms.m")
        let mutated = text.replacingOccurrences(
            of: "[VPhoneGyroscopeEncode(state) mutableCopy]", with: "[NSMutableDictionary dictionary]"
        )
        XCTAssertNotEqual(mutated, text)
        XCTAssertEqual(try cell(mutated, "vp_gyro_get"), "provider:object:null,provider_running:any,units:string")
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
            "enabled:any,error:string?,height:integer,nonce:string,ok:boolean?,width:integer"
        )
        let noCopy = text.replacingOccurrences(
            of: "[request mutableCopy]", with: "[NSMutableDictionary dictionary]"
        )
        XCTAssertEqual(
            try cell(noCopy, "vpApplyExternalRequest", .writer),
            "enabled:integer?,error:string?,name:string?,ok:boolean?"
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
        XCTAssertEqual(actual, "ext:any,n:integer,nul:any:null,w:any,y:boolean")
        XCTAssertNotEqual(actual, "ext:any,n:string,nul:any:null,w:any,y:boolean")
    }

    // MARK: typed forms (one test each; the mutation must change the cell)

    /// `NSNull` on one path makes the key nullable, `[NSNull null]` and `NSNull.null` alike; mixed types stay any.
    func testNullableForms() throws {
        let text = try source("native-forms.m")
        XCTAssertEqual(try cell(text, "formsNull"), "depth:integer:null,mixed:any,provider:object:null,tag:string:null,when:boolean:null")
        let noNull = text.replacingOccurrences(of: "r[@\"when\"] = on ? [NSNull null] : @YES;", with: "r[@\"when\"] = @YES;")
        XCTAssertNotEqual(noNull, text)
        XCTAssertTrue(try cell(noNull, "formsNull").hasSuffix("when:boolean"))
    }

    /// A null-only producer is `null`; it never becomes `any` or `string`.
    func testNullOnlyKey() throws {
        let text = "NSDictionary *f(void) { return @{@\"udid\": NSNull.null, @\"n\": [NSNull null]}; }"
        XCTAssertEqual(try cell(text, "f"), "n:null,udid:null")
    }

    /// A class check on the value gives the type; without it the value is `any`.
    func testClassCheckTypesTheGuardedValue() throws {
        let text = try source("native-forms.m")
        XCTAssertEqual(try cell(text, "formsGuard"), "ipv4:object,router:string?")
        let unguarded = text.replacingOccurrences(of: "if ([ipv4[@\"Router\"] isKindOfClass:NSString.class]) ", with: "if (service) ")
        XCTAssertNotEqual(unguarded, text)
        XCTAssertEqual(try cell(unguarded, "formsGuard"), "ipv4:object,router:any?")
    }

    /// Typed arrays: literal, `alloc`, `addObject:` and a typed local are `array`.
    func testTypedArrays() throws {
        let text = try source("native-forms.m")
        XCTAssertEqual(try cell(text, "formsArrays"), "failed:array,names:array,open:object,roots:array,sorted:array")
        let notArray = text.replacingOccurrences(of: "    [names addObject:@\"n\"];\n", with: "")
        XCTAssertNotEqual(notArray, text)
        XCTAssertEqual(try cell(notArray, "formsArrays"), "failed:array,names:array,open:object,roots:array,sorted:array")
        let plainID = text.replacingOccurrences(of: "id names = [NSMutableArray array];", with: "id names = other();")
        XCTAssertEqual(try cell(plainID, "formsArrays"), "failed:array,names:array,open:object,roots:array,sorted:array")
    }

    /// An open (`*`) object value, such as entitlements, is `object` without any subkeys.
    func testOpenObjectIsObject() throws {
        let text = "NSDictionary *f(NSDictionary *entitlements) { return @{@\"entitlements\": entitlements ?: @{}}; }"
        XCTAssertEqual(try cell(text, "f"), "entitlements:object")
        XCTAssertEqual(try cell(text.replacingOccurrences(of: "NSDictionary *entitlements", with: "id entitlements"), "f"), "entitlements:any")
    }

    /// Returned types of called functions, members, struct fields (through the lookup), selectors and arithmetic.
    func testDeclaredTypesDriveInference() throws {
        let text = try source("native-forms.m")
        XCTAssertEqual(
            try cell(text, "formsCalls"),
            "clock:number,configured:boolean,elapsed:number,flag:integer,label:string,level:integer,pid:integer,queries:integer,reasons:array"
        )
        XCTAssertEqual(try cell(text, "formsStruct"), "enabled:boolean,x:number")
        XCTAssertEqual(try cell(text, "formsException"), "native_exception:string?,ok:boolean")
        let wider = text.replacingOccurrences(of: "static double formsClock(void)", with: "static id formsClock(void)")
        XCTAssertEqual(
            try cell(wider, "formsCalls"),
            "clock:any,configured:boolean,elapsed:any,flag:integer,label:string,level:integer,pid:integer,queries:integer,reasons:array"
        )
    }

    /// Applies one mutation of the fixture text and returns the function's cell (the text must change).
    func mutated(_ text: String, _ function: String, _ from: String, _ to: String) throws -> String {
        let changed = text.replacingOccurrences(of: from, with: to)
        XCTAssertNotEqual(changed, text, from)
        return try cell(changed, function)
    }

    /// SDK property chains (CoreLocation, NSDate, NSProcessInfo) type from the head's declared class.
    func testSdkPropertyChains() throws {
        let text = try source("native-forms.m")
        XCTAssertEqual(try cell(text, "formsSdkChains"), "age:number,lat:number,simulated:boolean,up:number,when:number")
        XCTAssertEqual(
            try mutated(text, "formsSdkChains", "CLLocation *location", "id location"),
            "age:number,lat:any,simulated:any,up:number,when:number"
        )
        XCTAssertEqual(
            try mutated(text, "formsSdkChains", "processInfo.systemUptime", "processInfo.bootCount"),
            "age:number,lat:number,simulated:boolean,up:any,when:number"
        )
    }

    /// Member chains ending in `count`, `CFIndex`, boxed C strings, block calls and date formatting.
    func testScalarForms() throws {
        let text = try source("native-forms.m")
        let all = "fresh:boolean,length:integer,path:string,seen:integer,stamp:string"
        XCTAssertEqual(try cell(text, "formsScalars"), all)
        XCTAssertEqual(try mutated(text, "formsScalars", "visited.count", "visited.size"),
                       "fresh:boolean,length:integer,path:string,seen:any,stamp:string")
        XCTAssertEqual(try mutated(text, "formsScalars", "CFIndex length", "id length"),
                       "fresh:boolean,length:any,path:string,seen:integer,stamp:string")
        XCTAssertEqual(try mutated(text, "formsScalars", "const char *path", "const void *path"),
                       "fresh:boolean,length:integer,path:any,seen:integer,stamp:string")
        XCTAssertEqual(try mutated(text, "formsScalars", "BOOL (^fresh)", "id (^fresh)"),
                       "fresh:any,length:integer,path:string,seen:integer,stamp:string")
        XCTAssertEqual(try mutated(text, "formsScalars", "stringFromDate", "renderDate"),
                       "fresh:boolean,length:integer,path:string,seen:integer,stamp:any")
    }

    /// `->` receivers, `filteredArrayUsingPredicate:` and a `NSString *const` declaration.
    func testReceiverForms() throws {
        let text = try source("native-forms.m")
        XCTAssertEqual(try cell(text, "formsReceivers"), "filtered:array,prefix:string,sorted:array")
        XCTAssertEqual(try mutated(text, "formsReceivers", "sortedArrayUsingSelector", "sortedWith"),
                       "filtered:array,prefix:string,sorted:any")
        XCTAssertEqual(try mutated(text, "formsReceivers", "filteredArrayUsingPredicate", "filteredWith"),
                       "filtered:any,prefix:string,sorted:array")
        XCTAssertEqual(try mutated(text, "formsReceivers", "static NSString *const kPrefix", "static NSSet *const kPrefix"),
                       "filtered:array,prefix:any,sorted:array")
    }

    /// `array.firstObject[@"k"]` takes the type of `k` in the added dictionaries; integer and number join.
    func testElementValues() throws {
        let text = try source("native-forms.m")
        XCTAssertEqual(try cell(text, "formsElements"), "pixels:array,plus:number")
        XCTAssertEqual(try mutated(text, "formsElements", "    [displays addObject:@{@\"pixels\": pixels, @\"plus\": @(level)}];\n", ""),
                       "pixels:any,plus:any")
        XCTAssertEqual(try mutated(text, "formsElements", "@\"plus\": @(level)}", "@\"plus\": @\"x\"}"),
                       "pixels:array,plus:any")
        XCTAssertEqual(try mutated(text, "formsElements", "?: @0", "?: @\"s\""), "pixels:array,plus:any")
    }

    /// A declarator after an initializer takes the declaration's type words.
    func testLaterDeclarators() throws {
        let text = try source("native-forms.m")
        XCTAssertEqual(try cell(text, "formsDeclarators"), "failed:array,ok:array")
        XCTAssertEqual(try mutated(text, "formsDeclarators", "NSMutableArray *ok", "NSMutableSet *ok"), "failed:any,ok:any")
    }

    /// A `launchJSON(@{...})` wrapper passes its literal through; any other callee must resolve.
    func testWrapperPassThrough() throws {
        let text = try source("native-forms.m")
        XCTAssertEqual(try cell(text, "formsWrapped"), "source:string,verified:boolean")
        XCTAssertThrowsError(try cell(text.replacingOccurrences(of: "launchJSON(@{", with: "otherJSON(@{"), "formsWrapped"))
    }

    func testMissingFunctionIsUnresolvable() {
        XCTAssertThrowsError(try NativeExtractor.extract(source: "void f(void) {}", function: "g"))
    }
}
