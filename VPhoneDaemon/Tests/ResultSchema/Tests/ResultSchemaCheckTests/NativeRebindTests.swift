import Foundation
import XCTest
@testable import ResultSchemaKit

/// Rules found by running every producer: variables bound more than once, header inlines,
/// block-wrapped returns.
final class NativeRebindTests: XCTestCase {
    func cell(_ text: String, _ function: String, lookup: @escaping (String) -> [NativeSource] = { _ in [] }) throws -> String {
        catalogCell(try NativeExtractor.extract(source: text, function: function, lookup: lookup))
    }

    static let tryCatch = """
    NSDictionary *walk(void) { return @{@"a": @1, @"b": @"x"}; }
    NSDictionary *hierarchy(void) {
     NSDictionary *result = nil;
     @try {
      result = walk();
     } @catch (NSException *e) {
      NSMutableDictionary *failure = [walk() mutableCopy];
      failure[@"native_exception"] = e.name; result = failure.copy;
     }
     NSMutableDictionary *report = [result mutableCopy];
     report[@"symbols"] = @{@"k": @1};
     result = report.copy;
     return result;
    }
    """

    func testNilThenAssignedInTryCatchUnionsTheValues() throws {
        XCTAssertEqual(try cell(Self.tryCatch, "hierarchy"),
                       "a:integer,b:string,native_exception:any?,symbols:object")
        // Mutation: without the catch assignment the exception key is gone.
        let noCatch = Self.tryCatch.replacingOccurrences(of: "failure[@\"native_exception\"] = e.name; ", with: "")
        XCTAssertEqual(try cell(noCatch, "hierarchy"), "a:integer,b:string,symbols:object")
    }

    func testSerializedDictionaryIsTheResult() throws {
        let text = """
        char *copy_json(void) {
         NSMutableDictionary *result = [@{@"a": @1} mutableCopy];
         result[@"b"] = @"x";
         NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];
         if (!json) return NULL;
         return strndup(json.bytes, json.length);
        }
        """
        XCTAssertEqual(try cell(text, "copy_json"), "a:integer,b:string")
        // Mutation: without the serialized variable the call is not followed.
        XCTAssertThrowsError(try cell(text.replacingOccurrences(of: "strndup(json.bytes, json.length)", with: "strndup(other(), 1)"), "copy_json"))
    }

    func testBlockReturnsAreNotTheFunctionsReturns() throws {
        let text = """
        BOOL ready(void) {
         BOOL (^pick)(int) = ^BOOL(int x) { return x > 0; };
         return pick(1);
        }
        NSDictionary *d(void) {
         __block int n = 0;
         void (^each)(void) = ^bool(void) { if (n) { return true; } return false; };
         return @{@"n": @(n)};
        }
        """
        XCTAssertEqual(try cell(text, "d"), "n:integer")
    }

    func testBlockWrappedReturnIsFollowed() throws {
        let text = """
        char *with_locale(char *(^body)(void)) { return body(); }
        NSDictionary *read(void) { return @{@"control": @"x", @"files": @[]}; }
        char *read_json(void) {
         return icli_archive_with_utf8_names(^{ return icli_json(read()); });
        }
        """
        XCTAssertEqual(try cell(text, "read_json"), "control:string,files:array")
        // Mutation: a wrapper that is not a block wrapper is followed into its own body and fails.
        XCTAssertThrowsError(try cell(text.replacingOccurrences(of: "icli_archive_with_utf8_names", with: "with_locale"), "read_json"))
    }

    func testPlistWrittenElsewhereUnderTheSamePathLiteral() throws {
        let reader = """
        static NSString *const requestPath = @"/var/x/request.plist";
        NSDictionary *status(void) {
         NSDictionary *request = [NSDictionary dictionaryWithContentsOfFile:requestPath];
         NSMutableDictionary *s = [request mutableCopy];
         s[@"ok"] = @YES;
         return s;
        }
        """
        let writer = """
        static NSString *const path = @"/var/x/request.plist";
        void put(void) {
         NSDictionary *r = @{@"enabled": @YES, @"nonce": @"n"};
         [r writeToFile:path atomically:YES];
        }
        """
        let found = { (name: String) -> [NativeSource] in name.contains("/var/x/request.plist") ? [NativeSource(file: "w.m", text: writer)] : [] }
        XCTAssertEqual(try cell(reader, "status", lookup: found), "enabled:boolean,nonce:string,ok:boolean")
        // Mutation: a writer of a different path contributes nothing.
        let other = { (name: String) -> [NativeSource] in
            [NativeSource(file: "w.m", text: writer.replacingOccurrences(of: "/var/x/request.plist", with: "/var/x/other.plist"))]
        }
        XCTAssertThrowsError(try cell(reader, "status", lookup: other))
    }

    func testConditionalReassignmentKeepsBothValues() throws {
        let text = """
        NSDictionary *f(int x) {
         NSDictionary *r = @{@"a": @1};
         if (x) { r = @{@"b": @2}; }
         return r;
        }
        """
        XCTAssertEqual(try cell(text, "f"), "a:integer?,b:integer?")
        // Mutation: an unconditional re-assignment discards the first value.
        XCTAssertEqual(try cell(text.replacingOccurrences(of: "if (x) { r = @{@\"b\": @2}; }", with: "r = @{@\"b\": @2};"), "f"),
                       "b:integer")
    }
}
