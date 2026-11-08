import Foundation

/// A producer-map failure. The tool prints `message` and exits 2.
public struct ProducerError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// How a producer entry is read (design.md, result-producers.tsv).
public enum ProducerKind: String, Sendable {
    case plain = ""
    case sink, writer
}

/// One `[kind:][icli:]path#function` entry of a `result-producers.tsv` row.
public struct ProducerEntry: Equatable, Sendable {
    public let kind: ProducerKind
    public let isIcli: Bool
    /// Path as written, without kind and `icli:` prefixes.
    public let path: String
    public let function: String

    /// `path#function` as written in the file (with the `icli:` prefix when present).
    public var text: String { (isIcli ? "icli:" : "") + path + "#" + function }
    /// `<origin> <path>#<function>` as used in drift lines.
    public var token: String { (isIcli ? "icli " : "repo ") + path + "#" + function }

    /// The file this entry names: relative to the icli checkout's `Sources/`, else to the repo root.
    public func url(repo: URL, icli: URL) -> URL {
        isIcli
            ? icli.appendingPathComponent("Sources").appendingPathComponent(path)
            : repo.appendingPathComponent(path)
    }

    /// Parses one entry; the error is the `<reason>` of `bad producer row`.
    public static func parse(_ raw: String) -> Result<ProducerEntry, ProducerError> {
        var rest = Substring(raw)
        var kind = ProducerKind.plain
        for candidate in [ProducerKind.sink, .writer] where rest.hasPrefix(candidate.rawValue + ":") {
            kind = candidate
            rest = rest.dropFirst(candidate.rawValue.count + 1)
        }
        var isIcli = false
        if rest.hasPrefix("icli:") {
            isIcli = true
            rest = rest.dropFirst(5)
        }
        let parts = rest.split(separator: "#", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return .failure(ProducerError("entry '\(raw)' is not path#function"))
        }
        let path = String(parts[0]), function = String(parts[1])
        guard !path.isEmpty, !path.contains(":"), !path.hasPrefix("/"), !path.contains("..") else {
            return .failure(ProducerError("entry '\(raw)' has an invalid path"))
        }
        guard let first = function.unicodeScalars.first,
              first == "_" || CharacterSet.letters.contains(first),
              function.unicodeScalars.allSatisfy({ $0 == "_" || CharacterSet.alphanumerics.contains($0) })
        else {
            return .failure(ProducerError("entry '\(raw)' has an invalid function name"))
        }
        return .success(ProducerEntry(kind: kind, isIcli: isIcli, path: path, function: function))
    }
}

/// `result-producers.tsv`: for each catalog method, the functions that build its result.
public struct ProducerMap {
    public let producers: [String: [ProducerEntry]]

    /// Parses the file (two tab-separated columns, no header, one row per method) and checks
    /// it names exactly the catalog methods.
    public static func parse(tsv: String, catalog: [String]) throws -> ProducerMap {
        let known = Set(catalog)
        var result: [String: [ProducerEntry]] = [:]
        let lines = tsv.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            if line.isEmpty { continue }
            let number = index + 1
            func bad(_ reason: String) -> ProducerError { ProducerError("bad producer row \(number): \(reason)") }
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count == 2 else { throw bad("expected 2 tab-separated columns, found \(columns.count)") }
            let method = String(columns[0])
            guard known.contains(method) else { throw bad("method \(method) is not in methods-catalog.tsv") }
            guard result[method] == nil else { throw bad("duplicate method \(method)") }
            let field = String(columns[1])
            guard !field.isEmpty else { throw bad("empty producers for \(method)") }
            var entries: [ProducerEntry] = []
            for raw in field.split(separator: ";", omittingEmptySubsequences: false) {
                switch ProducerEntry.parse(String(raw)) {
                case .success(let entry): entries.append(entry)
                case .failure(let error): throw bad(error.message)
                }
            }
            result[method] = entries
        }
        for method in catalog where result[method] == nil {
            throw ProducerError("no producer: \(method); add a row to result-producers.tsv")
        }
        return ProducerMap(producers: result)
    }

    static func defines(_ text: String, function: String, swift: Bool) -> Bool {
        let name = NSRegularExpression.escapedPattern(for: function)
        let pattern = swift
            ? "\\bfunc\\s+\(name)\\s*[(<]"
            : "(?<![A-Za-z0-9_])\(name)\\s*\\([^;{}]*\\)\\s*\\{"
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}
