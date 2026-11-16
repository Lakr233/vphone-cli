import Foundation

// Prints "<method><tab><result cell><tab><area><tab><reported access><tab><declared access>" for every method, sorted by
// name; area and reported access come from GuestMethodArea.catalog, the declared access from the spec. The cell lists the result keys sorted by name
// as name:type[:null][?|~][*] (? optional, ~ hidden, * open), "-" when empty and "missing" when undeclared; a paged
// method also lists the paging keys dispatch adds. Compiled
// by run-methods-tests.sh with GuestMethodSpec.swift, the GuestAPI*Methods.swift files, GuestAPIStub.swift and a
// generated file defining `kinds`. The cell grammar is the one DriftCheck.parseCell reads.
// With `--catalog` it prints instead the text of VPhoneMCP/VPhoneMCPCLI/GuestCatalog.swift: the methods.list catalog
// (GuestMethodArea.catalog, keys sorted, methods sorted by name, one method per line) in a raw string constant whose
// delimiter has more `#` than the longest `#` run in the JSON. `--catalog-escape` and `--catalog-escape-json` print the file and
// the JSON of a synthetic catalog whose description holds `\#(x)` and `"""#`, for the self-test of that delimiter.
@main
struct MethodsHarness {
    static func main() {
        if CommandLine.arguments.dropFirst().first == "--catalog" {
            print(catalogFile(catalogLines(GuestMethodArea.catalog(kinds)["methods"] as? [[String: Any]] ?? [])), terminator: "")
            return
        }
        if CommandLine.arguments.dropFirst().first?.hasPrefix("--catalog-escape") == true {
            let lines = catalogLines([["name": "a.b", "description": "x \\#(x) \"\"\"# ## y"]])
            print(CommandLine.arguments[1] == "--catalog-escape" ? catalogFile(lines) : catalogJSONText(lines), terminator: "")
            return
        }
        let listed = (GuestMethodArea.catalog(kinds)["methods"] as? [[String: Any]] ?? [])
            .reduce(into: [String: [String: Any]]()) { $0[$1["name"] as? String ?? ""] = $1 }
        let rows = kinds.flatMap { $0.entries() }.map { name, spec in
            (name, cell(spec.result.map { $0 + (spec.paged == nil ? [] : GuestMethodArea.pagingResult) }),
             listed[name]?["area"] as? String ?? "", listed[name]?["access"] as? String ?? "", spec.access.rawValue)
        }
        for (name, cell, area, access, declared) in rows.sorted(by: { $0.0 < $1.0 }) {
            print("\(name)\t\(cell)\t\(area)\t\(access)\t\(declared)")
        }
    }

    /// One JSON line per method, sorted by name.
    static func catalogLines(_ methods: [[String: Any]]) -> [String] {
        methods.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }.map { method in
            let data = (try? JSONSerialization.data(withJSONObject: method, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }

    static func catalogJSONText(_ lines: [String]) -> String {
        "{\"methods\":[\n" + lines.joined(separator: ",\n") + "\n]}"
    }

    static func catalogFile(_ lines: [String]) -> String {
        let json = catalogJSONText(lines)
        var longest = 0, run = 0
        for character in json {
            run = character == "#" ? run + 1 : 0
            longest = max(longest, run)
        }
        let hashes = String(repeating: "#", count: longest + 1)
        return "// Generated from the daemon's methods.list catalog; do not edit. Rewrite it with\n"
            + "// `zsh VPhoneDaemon/Tests/run-methods-tests.sh --write-catalog`; run-methods-tests.sh fails when it differs.\n\n"
            + "let guestCatalogJSON = \(hashes)\"\"\"\n" + json + "\n\"\"\"\(hashes)\n"
    }

    static func cell(_ result: [ResultKey]?) -> String {
        guard let result else { return "missing" }
        if result.isEmpty { return "-" }
        return result.sorted { $0.name < $1.name }.map { key in
            let presence = key.presence == .optional ? "?" : key.presence == .hidden ? "~" : ""
            return "\(key.name):\(key.type.rawValue)\(key.isNullable && key.type != .null ? ":null" : "")\(presence)\(key.isOpen ? "*" : "")"
        }.joined(separator: ",")
    }
}
