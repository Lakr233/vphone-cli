import Foundation
import SwiftParser
import SwiftSyntax

/// What the tool prints and how it exits (REQ-RPC-008).
public struct DriftReport: Equatable {
    public var stdout: [String] = []
    public var stderr: [String] = []
    public var exitCode: Int32 = 0
}

/// One key of a method's declared schema, from the catalog `result` column.
struct DeclaredKey {
    let name: String
    let type: KeyType
    let nullable: Bool
    let optional: Bool
    let hidden: Bool
    let open: Bool
}

/// The source files the extractors may look into, read once.
private final class Workspace {
    let repo: URL
    let icli: URL
    private var swiftCache: [String: [SwiftSource]] = [:]
    private var nativeAll: [NativeSource]?

    init(repo: URL, icli: URL) {
        self.repo = repo
        self.icli = icli
    }

    private static let skipped: Set<String> = [".build", ".git", "Tests", "DerivedData"]

    private func files(under root: URL, extensions: Set<String>) -> [URL] {
        var result: [URL] = []
        let manager = FileManager.default
        guard let walker = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        for case let url as URL in walker {
            let name = url.lastPathComponent
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                if Self.skipped.contains(name) { walker.skipDescendants() }
            } else if extensions.contains(url.pathExtension) {
                result.append(url)
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    private func relative(_ url: URL, to base: URL) -> String {
        let prefix = base.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    func swiftSources(under root: URL, recursive: Bool = true) -> [SwiftSource] {
        let key = root.path
        if let cached = swiftCache[key] { return cached }
        let urls: [URL]
        if recursive {
            urls = files(under: root, extensions: ["swift"])
        } else {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            urls = names.filter { $0.hasSuffix(".swift") }.sorted().map { root.appendingPathComponent($0) }
        }
        let sources = urls.compactMap { url in
            (try? String(contentsOf: url, encoding: .utf8)).map { SwiftSource(file: relative(url, to: repo), text: $0) }
        }
        swiftCache[key] = sources
        return sources
    }

    func natives() -> [NativeSource] {
        if let nativeAll { return nativeAll }
        var urls: [URL] = []
        for root in [repo.appendingPathComponent("VPhoneDaemon"), repo.appendingPathComponent("VPhoneGuestComponents"),
                     icli.appendingPathComponent("Sources")] {
            urls += files(under: root, extensions: ["m", "c", "h"])
        }
        let all = urls.compactMap { url in
            (try? String(contentsOf: url, encoding: .utf8)).map { NativeSource(file: relative(url, to: repo), text: $0) }
        }
        nativeAll = all
        return all
    }

    func nativeLookup(_ name: String) -> [NativeSource] {
        natives().filter { $0.text.contains(name) }
    }

    func swiftLookup(producerFile: URL) -> SwiftLookup {
        let directory = producerFile.deletingLastPathComponent()
        let module = swiftSources(under: directory, recursive: false)
        let daemon = swiftSources(under: repo.appendingPathComponent("VPhoneDaemon"))
        let icliSources = swiftSources(under: icli.appendingPathComponent("Sources"))
        return SwiftLookup(levels: [module, daemon, icliSources], native: { [self] name in nativeLookup(name) })
    }
}

/// True when `function` contains a `switch` arm for `.caseName` (rule 0).
private final class ArmProbe: SyntaxVisitor {
    let function: String
    let arm: String
    var found = false
    private var inside = 0
    init(function: String, arm: String) {
        self.function = function
        self.arm = arm
        super.init(viewMode: .sourceAccurate)
    }
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == function { inside += 1 }
        return .visitChildren
    }
    override func visitPost(_ node: FunctionDeclSyntax) {
        if node.name.text == function { inside -= 1 }
    }
    override func visit(_ node: SwitchCaseSyntax) -> SyntaxVisitorContinueKind {
        guard inside > 0, case .case(let label) = node.label else { return .visitChildren }
        for item in label.caseItems {
            if let pattern = item.pattern.as(ExpressionPatternSyntax.self),
               let member = pattern.expression.as(MemberAccessExprSyntax.self),
               member.declName.baseName.text == arm {
                found = true
            }
        }
        return .visitChildren
    }
}

/// Compares the keys extracted from each producer to the declared schema (REQ-RPC-008).
public enum DriftCheck {
    static let tail = "; fix the entry in result-producers.tsv"

    /// Parses a catalog `result` cell; nil when malformed.
    static func parseCell(_ cell: String) -> [String: DeclaredKey]? {
        if cell == "-" { return [:] }
        guard !cell.isEmpty else { return nil }
        let order: [Character] = ["?", "~", "*"]
        var keys: [String: DeclaredKey] = [:]
        for piece in cell.split(separator: ",", omittingEmptySubsequences: false) {
            guard let colon = piece.firstIndex(of: ":") else { return nil }
            let name = String(piece[..<colon])
            var rest = piece[piece.index(after: colon)...]
            let typeText = String(rest.prefix { $0.isLetter })
            rest = rest.dropFirst(typeText.count)
            let nullable = rest.hasPrefix(":null")
            if nullable { rest = rest.dropFirst(5) }
            let flags = Array(rest)
            guard !name.isEmpty, let type = KeyType(rawValue: typeText), keys[name] == nil else { return nil }
            var last = -1
            for flag in flags {
                guard let at = order.firstIndex(of: flag), at > last else { return nil }
                last = at
            }
            keys[name] = DeclaredKey(
                name: name, type: type, nullable: nullable, optional: flags.contains("?"), hidden: flags.contains("~"), open: flags.contains("*"))
        }
        return keys
    }

    /// `<Enum>.<case>` for `case x = "<method>"` in `GuestAPI*.swift`; nil unless exactly one match.
    static func enumCase(method: String, daemon: URL) -> (enumName: String, caseName: String)? {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: daemon.path)) ?? [])
            .filter { $0.hasPrefix("GuestAPI") && $0.hasSuffix(".swift") }.sorted()
        let escaped = NSRegularExpression.escapedPattern(for: method)
        guard let pattern = try? NSRegularExpression(pattern: "(?:\\bcase\\s+|,\\s*)([A-Za-z_][A-Za-z0-9_]*)\\s*=\\s*\"\(escaped)\"") else { return nil }
        let enumPattern = try? NSRegularExpression(pattern: "\\benum\\s+([A-Za-z_][A-Za-z0-9_]*)")
        var matches: [(String, String)] = []
        for name in names {
            guard let text = try? String(contentsOf: daemon.appendingPathComponent(name), encoding: .utf8) else { continue }
            let whole = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: whole) {
                guard let caseRange = Range(match.range(at: 1), in: text) else { continue }
                let before = NSRange(location: 0, length: match.range.location)
                let enumName = enumPattern?.matches(in: text, range: before).last
                    .flatMap { Range($0.range(at: 1), in: text) }.map { String(text[$0]) } ?? "?"
                matches.append((enumName, String(text[caseRange])))
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// True when the spec arm `case .<caseName>:` in `GuestAPI*.swift` declares `paged:`; dispatch adds
    /// `total`, `truncated` and `next_cursor`, so no executor produces them.
    static func isPaged(caseName: String, daemon: URL) -> Bool {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: daemon.path)) ?? [])
            .filter { $0.hasPrefix("GuestAPI") && $0.hasSuffix(".swift") }
        let marker = "case .\(caseName):"
        for name in names {
            guard let text = try? String(contentsOf: daemon.appendingPathComponent(name), encoding: .utf8) else { continue }
            var from = text.startIndex
            while let found = text.range(of: marker, range: from ..< text.endIndex) {
                let rest = text[found.upperBound...]
                let end = ["\n        case ", "\n        }\n"].compactMap { rest.range(of: $0)?.lowerBound }.min() ?? rest.endIndex
                if rest[..<end].contains("paged:") { return true }
                from = found.upperBound
            }
        }
        return false
    }

    /// Runs every producer of the selected methods and compares it to the catalog.
    public static func run(repo: URL, icli: URL, method prefix: String?) -> DriftReport {
        var report = DriftReport()
        func fail(_ message: String) -> DriftReport {
            report.stderr.append(message)
            report.exitCode = 2
            return report
        }
        let tests = repo.appendingPathComponent("VPhoneDaemon/Tests")
        let catalogURL = tests.appendingPathComponent("methods-catalog.tsv")
        let producersURL = tests.appendingPathComponent("ResultSchema/result-producers.tsv")
        guard let catalogText = try? String(contentsOf: catalogURL, encoding: .utf8),
              let producersText = try? String(contentsOf: producersURL, encoding: .utf8)
        else { return fail("cannot read \(catalogURL.path) or \(producersURL.path)") }

        // method -> (line number, result cell or nil when the column is missing)
        var cells: [String: (line: Int, cell: String?)] = [:]
        for (index, line) in catalogText.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where !line.isEmpty {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard let name = columns.first.map(String.init), !name.isEmpty else { continue }
            cells[name] = (index + 1, columns.count > 4 ? String(columns[4]) : nil)
        }
        let map: ProducerMap
        do {
            map = try ProducerMap.parse(tsv: producersText, catalog: Array(cells.keys))
        } catch {
            return fail("\(error)")
        }
        let methods = cells.keys.sorted().filter { prefix == nil || $0.hasPrefix(prefix!) }
        if methods.isEmpty, let prefix {
            return fail("no methods match \(prefix); see methods-catalog.tsv for names")
        }

        let workspace = Workspace(repo: repo, icli: icli)
        let daemon = repo.appendingPathComponent("VPhoneDaemon/Daemon")
        var findings: [(method: String, key: String, order: Int, line: String)] = []
        var unresolvable = false
        func diagnose(_ message: String) {
            report.stderr.append(message)
            unresolvable = true
        }

        for method in methods {
            let entries = map.producers[method] ?? []
            var declared = cells[method]!.cell.flatMap(parseCell)
            if declared == nil {
                diagnose("unresolvable declaration: \(method) methods-catalog.tsv line \(cells[method]!.line)")
            }
            guard let target = enumCase(method: method, daemon: daemon) else {
                diagnose("no enum case: \(method); add case x = \"\(method)\" in GuestAPI*.swift")
                continue
            }
            if isPaged(caseName: target.caseName, daemon: daemon) {
                for key in ["total", "truncated", "next_cursor"] { declared?.removeValue(forKey: key) }
            }
            var perProducer: [(entry: ProducerEntry, keys: KeyMap)] = []
            var complete = true
            for entry in entries {
                let url = entry.url(repo: repo, icli: icli)
                guard let text = try? String(contentsOf: url, encoding: .utf8),
                      ProducerMap.defines(text, function: entry.function, swift: entry.path.hasSuffix(".swift"))
                else {
                    diagnose("producer not found: \(method) -> \(entry.text)\(tail)")
                    complete = false
                    continue
                }
                do {
                    let keys = try extract(entry, text: text, url: url, method: method, arm: target.caseName, workspace: workspace)
                    perProducer.append((entry, Dictionary(uniqueKeysWithValues: keys.map { ($0.name, $0) })))
                } catch {
                    diagnose("\(error)")
                    complete = false
                }
            }
            guard complete, let declared else { continue }
            let extracted = KeyMerge.union(perProducer.map(\.keys))
            func origin(_ key: String) -> String {
                (perProducer.first { $0.keys[key] != nil } ?? perProducer.first)?.entry.token ?? "repo ?"
            }
            let place = "\(target.enumName).\(target.caseName)"
            func add(_ key: String, _ order: Int, _ change: String, _ remedy: String) {
                findings.append((method, key, order, "\(method): \(origin(key)) \(change); \(remedy)"))
            }
            for name in Set(extracted.keys).union(declared.keys) {
                switch (extracted[name], declared[name]) {
                case (let new?, nil):
                    add(name, 0, "added key \"\(name)\" (\(new.type.rawValue))",
                        "add .required(\"\(name)\", .\(new.type.rawValue)) or .optional(\"\(name)\", .\(new.type.rawValue)) to \(place)")
                case (nil, _?):
                    add(name, 0, "removed key \"\(name)\"", "remove \"\(name)\" from \(place)")
                case (let new?, let old?):
                    if new.type != old.type {
                        add(name, 0, "key \"\(name)\" type changed \(old.type.rawValue) -> \(new.type.rawValue)",
                            "declare \"\(name)\" as .\(new.type.rawValue) in \(place)")
                    }
                    if new.nullable != old.nullable {
                        let was = old.nullable ? "nullable" : "non-null", now = new.nullable ? "nullable" : "non-null"
                        add(name, 2, "key \"\(name)\" nullability changed \(was) -> \(now)",
                            new.nullable ? "add .nullable() to \"\(name)\" in \(place)" : "remove .nullable() from \"\(name)\" in \(place)")
                    }
                    let oldPresence = old.optional ? Presence.optional : .required
                    if !old.hidden, new.presence != oldPresence {
                        let was = old.optional ? "optional" : "required", now = new.presence == .optional ? "optional" : "required"
                        add(name, 1, "key \"\(name)\" presence changed \(was) -> \(now)", "declare \"\(name)\" as \(now) in \(place)")
                    }
                case (nil, nil):
                    break
                }
            }
        }

        findings.sort { ($0.method, $0.key, $0.order) < ($1.method, $1.key, $1.order) }
        report.stdout = findings.map(\.line)
        report.exitCode = unresolvable ? 2 : (findings.isEmpty ? 0 : 1)
        return report
    }

    private static func extract(
        _ entry: ProducerEntry, text: String, url: URL, method: String, arm: String, workspace: Workspace
    ) throws -> [ExtractedKey] {
        let file = entry.path
        if entry.path.hasSuffix(".swift") {
            if entry.kind == .sink {
                let directory = workspace.swiftSources(
                    under: url.deletingLastPathComponent(), recursive: false)
                return try SwiftExtractor.extractSink(source: text, function: entry.function, directory: directory, method: method, file: file,
                    lookup: workspace.swiftLookup(producerFile: url))
            }
            let probe = ArmProbe(function: entry.function, arm: arm)
            probe.walk(Parser.parse(source: text))
            return try SwiftExtractor.extract(
                source: text, function: entry.function, arm: probe.found ? arm : nil, method: method, file: file,
                lookup: workspace.swiftLookup(producerFile: url))
        }
        let mode: NativeMode = entry.kind == .writer ? .writer : .produce
        return try NativeExtractor.extract(
            source: text, function: entry.function, mode: mode, method: method, file: file,
            lookup: workspace.nativeLookup)
    }
}
