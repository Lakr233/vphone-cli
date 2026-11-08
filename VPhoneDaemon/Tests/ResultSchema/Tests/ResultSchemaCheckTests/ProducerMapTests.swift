import Foundation
import XCTest
@testable import ResultSchemaKit

final class ProducerMapTests: XCTestCase {
    static let tests = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let repo = tests.deletingLastPathComponent().deletingLastPathComponent()

    let catalog = ["a.one", "a.two", "ui.tree"]

    func message(_ tsv: String, catalog: [String]? = nil, file: StaticString = #filePath, line: UInt = #line) -> String? {
        do {
            _ = try ProducerMap.parse(tsv: tsv, catalog: catalog ?? self.catalog)
            XCTFail("expected failure", file: file, line: line)
            return nil
        } catch {
            return (error as? ProducerError)?.message
        }
    }

    // MARK: parsing

    func testOneRowPerEntryKind() throws {
        let map = try ProducerMap.parse(
            tsv: "a.one\tFoo.swift#plain;sink:Foo.swift#setProgress;writer:N/x.m#write;icli:IcliKit/Z.swift#zed\n"
                + "a.two\ticli:IcliKit/Z.swift#zed\nui.tree\tD/Input.swift#executeInterface;D/Hier.swift#nestedHierarchy\n",
            catalog: catalog)
        let one = try XCTUnwrap(map.producers["a.one"])
        XCTAssertEqual(one.map(\.kind), [.plain, .sink, .writer, .plain])
        XCTAssertEqual(one.map(\.isIcli), [false, false, false, true])
        XCTAssertEqual(one.map(\.path), ["Foo.swift", "Foo.swift", "N/x.m", "IcliKit/Z.swift"])
        XCTAssertEqual(one.map(\.function), ["plain", "setProgress", "write", "zed"])
        XCTAssertEqual(one[3].text, "icli:IcliKit/Z.swift#zed")
        XCTAssertEqual(one[3].token, "icli IcliKit/Z.swift#zed")
        XCTAssertEqual(one[0].token, "repo Foo.swift#plain")
        XCTAssertEqual(map.producers["ui.tree"]?.map(\.function), ["executeInterface", "nestedHierarchy"])
        XCTAssertEqual(map.producers["ui.tree"]?.map(\.kind), [.plain, .plain])
    }

    func testEntryPathsResolveRelativeToRepoOrIcliSources() {
        let repo = URL(fileURLWithPath: "/r"), icli = URL(fileURLWithPath: "/i")
        let plain = ProducerEntry(kind: .plain, isIcli: false, path: "V/a.swift", function: "f")
        let ic = ProducerEntry(kind: .plain, isIcli: true, path: "IcliKit/a.swift", function: "f")
        XCTAssertEqual(plain.url(repo: repo, icli: icli).path, "/r/V/a.swift")
        XCTAssertEqual(ic.url(repo: repo, icli: icli).path, "/i/Sources/IcliKit/a.swift")
    }

    func testBadRows() {
        let ok = "a.two\tF.swift#f\nui.tree\tF.swift#f\n"
        XCTAssertEqual(message("a.one\t\n" + ok), "bad producer row 1: empty producers for a.one")
        XCTAssertEqual(message(ok + "a.one\tF.swift\n"), "bad producer row 3: entry 'F.swift' is not path#function")
        XCTAssertEqual(
            message("a.one\tF.swift#f\nA.one\tF.swift#f\n"),
            "bad producer row 2: method A.one is not in methods-catalog.tsv")
        XCTAssertEqual(message("a.one\tF.swift#f\na.one\tG.swift#g\n" + ok), "bad producer row 2: duplicate method a.one")
        XCTAssertEqual(
            message("a.one\tF.swift#f\tcolumn\n" + ok), "bad producer row 1: expected 2 tab-separated columns, found 3")
        XCTAssertEqual(message("a.one\n" + ok), "bad producer row 1: expected 2 tab-separated columns, found 1")
        XCTAssertEqual(message("a.one\tF.swift#f;\n" + ok), "bad producer row 1: entry '' is not path#function")
        XCTAssertEqual(message("a.one\tbogus:F.swift#f\n" + ok), "bad producer row 1: entry 'bogus:F.swift#f' has an invalid path")
        XCTAssertEqual(message("a.one\t#f\n" + ok), "bad producer row 1: entry '#f' has an invalid path")
        XCTAssertEqual(message("a.one\tF.swift#\n" + ok), "bad producer row 1: entry 'F.swift#' has an invalid function name")
        XCTAssertEqual(message("a.one\tF.swift#a b\n" + ok), "bad producer row 1: entry 'F.swift#a b' has an invalid function name")
        XCTAssertEqual(message("a.one\tF.swift#f#g\n" + ok), "bad producer row 1: entry 'F.swift#f#g' is not path#function")
        XCTAssertEqual(message("a.one\t../F.swift#f\n" + ok), "bad producer row 1: entry '../F.swift#f' has an invalid path")
    }

    func testCatalogMethodWithoutRow() {
        XCTAssertEqual(
            message("a.one\tF.swift#f\nui.tree\tF.swift#f\n"),
            "no producer: a.two; add a row to result-producers.tsv")
        XCTAssertEqual(message(""), "no producer: a.one; add a row to result-producers.tsv")
    }

    // MARK: existence

    func fixtureTree() throws -> (repo: URL, icli: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("producer-map-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo"), icli = root.appendingPathComponent("icli")
        func write(_ base: URL, _ path: String, _ text: String) throws {
            let url = base.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write(repo, "V/F.swift", "func repoFn() -> [String: Any] { [:] }\n")
        try write(repo, "V/N.m", "NSDictionary *vp_native(void) {\n  return @{};\n}\n")
        try write(icli, "Sources/IcliKit/Z.swift", "public func appInfo(_ id: String) -> [String: Any] { [:] }\n")
        return (repo, icli)
    }

    func testDefinesFindsExistingFunctionsAndRejectsMissingOnes() throws {
        let (repo, _) = try fixtureTree()
        let swift = try String(contentsOf: repo.appendingPathComponent("V/F.swift"), encoding: .utf8)
        let objc = try String(contentsOf: repo.appendingPathComponent("V/N.m"), encoding: .utf8)
        XCTAssertTrue(ProducerMap.defines(swift, function: "repoFn", swift: true))
        XCTAssertTrue(ProducerMap.defines(objc, function: "vp_native", swift: false))
        XCTAssertFalse(ProducerMap.defines(swift, function: "nope", swift: true))
        XCTAssertFalse(ProducerMap.defines(objc, function: "vp_missing", swift: false))
        XCTAssertFalse(ProducerMap.defines(swift, function: "repoFn", swift: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("V/Gone.swift").path))
    }

    func testFunctionNameIsNotAPrefixOrACall() {
        XCTAssertFalse(ProducerMap.defines("func repoFn() {}\n", function: "repo", swift: true))
        XCTAssertFalse(ProducerMap.defines("func a() { repo(1) }\n", function: "repo", swift: true))
        XCTAssertFalse(ProducerMap.defines("int xrepo(void) {\n}\n", function: "repo", swift: false))
        XCTAssertFalse(ProducerMap.defines("void a(void) { repo(1); }\n", function: "repo", swift: false))
    }

    // MARK: the real files

    func testRealMapNamesEveryCatalogMethodAndEveryFunctionExists() throws {
        let icli = ProcessInfo.processInfo.environment["RS_ICLI"].map { URL(fileURLWithPath: $0) }
        let catalogURL = Self.tests.appendingPathComponent("methods-catalog.tsv")
        let producersURL = Self.tests.appendingPathComponent("ResultSchema/result-producers.tsv")
        let methods = try String(contentsOf: catalogURL, encoding: .utf8)
            .split(separator: "\n").compactMap { $0.split(separator: "\t", omittingEmptySubsequences: false).first.map(String.init) }
        XCTAssertFalse(methods.isEmpty)
        XCTAssertEqual(Set(methods).count, methods.count, "a catalog row repeats a method")
        let map = try ProducerMap.parse(tsv: try String(contentsOf: producersURL, encoding: .utf8), catalog: methods)
        XCTAssertEqual(map.producers.count, methods.count)
        XCTAssertEqual(map.producers["ui.tree"]?.count, 2)
        guard let icli else {
            if !(ProcessInfo.processInfo.environment["CI"] ?? "").isEmpty { XCTFail("RS_ICLI is not set in CI") }
            return
        }
        for method in methods {
            for entry in map.producers[method] ?? [] {
                let text = try? String(contentsOf: entry.url(repo: Self.repo, icli: icli), encoding: .utf8)
                XCTAssertTrue(
                    text.map { ProducerMap.defines($0, function: entry.function, swift: entry.path.hasSuffix(".swift")) } ?? false,
                    "producer not found: \(method) -> \(entry.text)")
            }
        }
    }
}
