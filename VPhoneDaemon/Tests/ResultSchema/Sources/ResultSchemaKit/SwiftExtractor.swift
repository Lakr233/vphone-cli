import SwiftParser
import SwiftSyntax

/// A producer expression no extraction rule covers. The tool exits 2 with `description`.
public struct Unresolvable: Error, CustomStringConvertible, Equatable {
    public let method: String
    public let file: String
    public let function: String
    public let line: Int

    public var description: String {
        "unresolvable: \(method) \(file)#\(function) line \(line); "
            + "point the result-producers.tsv entry at the function that builds the result or add an extraction rule"
    }
}

/// A Swift source offered to the extractor for helper following.
public struct SwiftSource: Sendable {
    public let file: String
    public let text: String
    public init(file: String, text: String) {
        self.file = file
        self.text = text
    }
}

/// Where helpers are looked up after the producer's own file (rule 4): `levels` in order (same
/// module directory, repo `VPhoneDaemon/`, icli checkout `Sources/`); `native` finds the repo
/// native files that may define a `vp_*_copy_json` function (rule 10).
public struct SwiftLookup {
    public var levels: [[SwiftSource]]
    public var native: (String) -> [NativeSource]
    public init(levels: [[SwiftSource]] = [], native: @escaping (String) -> [NativeSource] = { _ in [] }) {
        self.levels = levels
        self.native = native
    }
}

/// Derives a Swift function's result keys (design.md extraction rules 0-5, 10, 11).
public enum SwiftExtractor {
    /// - Parameters:
    ///   - arm: enum case of the method being checked; when the function switches on its
    ///     method enum only that arm is analysed (rule 0).
    public static func extract(
        source: String, function: String, arm: String? = nil,
        method: String = "", file: String = "", lookup: SwiftLookup = SwiftLookup()
    ) throws -> [ExtractedKey] {
        try extractResult(source: source, function: function, arm: arm, method: method, file: file, lookup: lookup).keys
    }

    /// As `extract`, also reporting `open` when a rule 10 envelope value is passed through.
    public static func extractResult(
        source: String, function: String, arm: String? = nil,
        method: String = "", file: String = "", lookup: SwiftLookup = SwiftLookup()
    ) throws -> (keys: [ExtractedKey], open: Bool) {
        let session = Session(method: method, lookup: lookup)
        let parsed = session.parse(file: file, text: source)
        let found = session.functions(named: function, in: parsed)
        guard found.count == 1, let decl = found.first, decl.body != nil else {
            let at = found.dropFirst().first ?? found.first
            throw session.fail(at.map { Syntax($0) } ?? Syntax(parsed.tree), parsed, function)
        }
        let keys = try session.analyze(decl, in: parsed, arm: arm)
        return (Array(keys.values), session.open)
    }

    /// Rule 5: the key set of a `sink:` entry. `source` defines `function`; its call sites are
    /// searched in every file of `directory` (the defining file's directory).
    public static func extractSink(
        source: String, function: String, directory: [SwiftSource],
        method: String = "", file: String = ""
    ) throws -> [ExtractedKey] {
        let session = Session(method: method, lookup: SwiftLookup())
        let parsed = session.parse(file: file, text: source)
        let found = session.functions(named: function, in: parsed)
        guard found.count == 1, let decl = found.first, let body = decl.body,
              let parameter = decl.signature.parameterClause.parameters.first
        else {
            let at = found.dropFirst().first ?? found.first
            throw session.fail(at.map { Syntax($0) } ?? Syntax(parsed.tree), parsed, function)
        }
        let backing = BackingFinder(parameter: (parameter.secondName ?? parameter.firstName).text)
        backing.walk(body)
        guard let backingName = backing.name else { throw session.fail(decl, parsed, function) }

        var sources = directory
        if !sources.contains(where: { $0.file == file }) { sources.append(SwiftSource(file: file, text: source)) }
        var sets: [KeyMap] = []
        for candidate in sources where candidate.text.contains("\(function)(") {
            let site = session.parse(file: candidate.file, text: candidate.text)
            let finder = CallFinder(name: function)
            finder.walk(site.tree)
            for call in finder.calls {
                var context = Context(session: session, parsed: site, function: function, decl: nil)
                context.types = enclosingTypes(of: call, parsed: site, session: session)
                guard let literal = call.arguments.first?.expression.as(DictionaryExprSyntax.self) else {
                    throw context.fail(call)
                }
                sets.append(try literalKeys(literal, context))
            }
        }
        guard !sets.isEmpty else { throw session.fail(decl, parsed, function) }
        // The backing variable's initial value is a reply too (readable before any call).
        let initial = InitialValueFinder(name: backingName)
        initial.walk(parsed.tree)
        if let literal = initial.literal {
            var context = Context(session: session, parsed: parsed, function: function, decl: nil)
            context.types = enclosingTypes(of: literal, parsed: parsed, session: session)
            sets.append(try literalKeys(literal, context))
        }
        var result = KeyMerge.union(sets)
        let assignments = AssignmentCollector(variable: backingName, scopeID: parsed.tree.id, allowMember: true)
        assignments.walk(parsed.tree)
        if let failure = assignments.failure { throw session.fail(failure, parsed, function) }
        for assignment in assignments.assignments {
            let type = enclosingTypes(of: assignment.value, parsed: parsed, session: session).infer(assignment.value)
            KeyMerge.merge(&result, name: assignment.key, type: type, presence: .optional)
        }
        return Array(result.values)
    }
}

private func enclosingTypes(of node: some SyntaxProtocol, parsed: ParsedFile, session: Session) -> TypeEnv {
    var current: Syntax? = Syntax(node)
    while let c = current {
        if let function = c.as(FunctionDeclSyntax.self) {
            return TypeEnv(function: function, tree: parsed.tree, index: session.typeIndex(including: parsed), c: session.cTypes)
        }
        current = c.parent
    }
    return TypeEnv()
}

private struct ParsedFile {
    let file: String
    let tree: SourceFileSyntax
    let converter: SourceLocationConverter
}

private final class Session {
    let method: String
    let lookup: SwiftLookup
    var visiting: Set<String> = []
    var open = false
    private var parsedFiles: [String: ParsedFile] = [:]

    init(method: String, lookup: SwiftLookup) {
        self.method = method
        self.lookup = lookup
    }

    func parse(file: String, text: String) -> ParsedFile {
        if let cached = parsedFiles[file] { return cached }
        let tree = Parser.parse(source: text)
        let parsed = ParsedFile(file: file, tree: tree, converter: SourceLocationConverter(fileName: file, tree: tree))
        parsedFiles[file] = parsed
        return parsed
    }

    private static nonisolated(unsafe) var fileIndexes: [String: TypeIndex] = [:]
    private var baseIndex: TypeIndex?
    lazy var cTypes = CTypes(sources: lookup.native)
    private var indexes: [String: TypeIndex] = [:]

    /// Declarations of the lookup sources plus `parsed` (REQ-RPC-007 type inference).
    func typeIndex(including parsed: ParsedFile) -> TypeIndex {
        if let cached = indexes[parsed.file] { return cached }
        let names = Set(lookup.levels.joined().map(\.file))
        let base = baseIndex ?? {
            var merged = TypeIndex()
            for source in lookup.levels.joined() {
                let key = "\(source.file)\0\(source.text.count)\0\(source.text.hashValue)"
                if Session.fileIndexes[key] == nil {
                    Session.fileIndexes[key] = TypeIndexBuilder.build(Parser.parse(source: source.text))
                }
                merged.merge(Session.fileIndexes[key]!)
            }
            baseIndex = merged
            return merged
        }()
        var result = base
        if !names.contains(parsed.file) { result.merge(TypeIndexBuilder.build(parsed.tree)) }
        indexes[parsed.file] = result
        return result
    }

    func fail(_ node: some SyntaxProtocol, _ parsed: ParsedFile, _ function: String) -> Unresolvable {
        let line = parsed.converter.location(for: node.positionAfterSkippingLeadingTrivia).line
        return Unresolvable(method: method, file: parsed.file, function: function, line: line)
    }

    func functions(named name: String, in parsed: ParsedFile) -> [FunctionDeclSyntax] {
        let finder = FunctionFinder(name: name)
        finder.walk(parsed.tree)
        return dropConditionalCopies(finder.found)
    }

    /// `#if`/`#else` clauses that declare the same signature (a platform stub) count once: the first.
    private func dropConditionalCopies(_ decls: [FunctionDeclSyntax]) -> [FunctionDeclSyntax] {
        var seen: Set<String> = []
        return decls.filter { decl in
            var current = decl.parent
            while let node = current, node.as(IfConfigDeclSyntax.self) == nil { current = node.parent }
            guard let block = current else { return true }
            return seen.insert("\(block.id.hashValue)|\(signature(of: decl))").inserted
        }
    }

    func signature(of decl: FunctionDeclSyntax) -> String {
        decl.signature.parameterClause.parameters.map { $0.firstName.text }.joined(separator: ":")
    }

    /// Overloads are told apart by the call's argument labels (defaulted parameters may be omitted).
    private func accepts(_ decl: FunctionDeclSyntax, _ call: FunctionCallExprSyntax?) -> Bool {
        guard let call else { return true }
        var arguments = Array(call.arguments.map { $0.label?.text ?? "_" })
        if call.trailingClosure != nil { arguments.append("") }
        var index = 0
        let parameters = Array(decl.signature.parameterClause.parameters)
        for parameter in parameters {
            let label = parameter.firstName.text
            if index < arguments.count, arguments[index] == label { index += 1; continue }
            if index < arguments.count, arguments[index] == "", call.trailingClosure != nil, index == arguments.count - 1 {
                index += 1; continue
            }
            if parameter.defaultValue != nil || parameter.ellipsis != nil { continue }
            return false
        }
        return index == arguments.count
    }

    /// Rule 4 lookup order; zero or several matches at the first level that has any fail.
    func resolve(
        _ name: String, from context: Context, at node: some SyntaxProtocol
    ) throws -> (FunctionDeclSyntax, ParsedFile) {
        let call = Syntax(node).as(FunctionCallExprSyntax.self)
        let local = functions(named: name, in: context.parsed).filter { accepts($0, call) }
        if local.count == 1 { return (local[0], context.parsed) }
        if local.count > 1 { throw context.fail(node) }
        for level in lookup.levels {
            var matches: [(FunctionDeclSyntax, ParsedFile)] = []
            for source in level where source.file != context.parsed.file && source.text.contains("func \(name)") {
                let parsed = parse(file: source.file, text: source.text)
                matches += functions(named: name, in: parsed).filter { accepts($0, call) }.map { ($0, parsed) }
            }
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 { throw context.fail(node) }
        }
        throw context.fail(node)
    }

    func scope(of decl: FunctionDeclSyntax, in parsed: ParsedFile, arm: String?) throws -> (CodeBlockItemListSyntax, Context) {
        var context = Context(session: self, parsed: parsed, function: decl.name.text, decl: decl)
        context.types = TypeEnv(function: decl, tree: parsed.tree, index: typeIndex(including: parsed), c: cTypes)
        guard let body = decl.body else { throw context.fail(decl) }
        var scope = body.statements
        if let arm {
            let finder = ArmFinder(arm: arm)
            finder.walk(scope)
            guard let armScope = finder.statements else { throw context.fail(body) }
            scope = armScope
        }
        return (scope, context)
    }

    /// The key set of one function; a cycle contributes nothing.
    func analyze(_ decl: FunctionDeclSyntax, in parsed: ParsedFile, arm: String?) throws -> KeyMap {
        let id = "\(parsed.file)#\(decl.position.utf8Offset)"
        if visiting.contains(id) { return [:] }
        visiting.insert(id)
        defer { visiting.remove(id) }
        let (scope, context) = try scope(of: decl, in: parsed, arm: arm)
        return try Analysis(scope: scope, context: context).run()
    }

    /// Rule 11: the element key sets of the array a helper returns.
    func returnedElements(of decl: FunctionDeclSyntax, in parsed: ParsedFile) throws -> [KeyMap] {
        let id = "\(parsed.file)#\(decl.position.utf8Offset)[]"
        if visiting.contains(id) { return [] }
        visiting.insert(id)
        defer { visiting.remove(id) }
        let (scope, context) = try scope(of: decl, in: parsed, arm: nil)
        return try Analysis(scope: scope, context: context).returnedElements()
    }

    /// Rule 11: the element dictionaries a helper returns under `key`.
    func elementKeys(of decl: FunctionDeclSyntax, in parsed: ParsedFile, key: String) throws -> KeyMap {
        let id = "\(parsed.file)#\(decl.position.utf8Offset)[\(key)]"
        if visiting.contains(id) { return [:] }
        visiting.insert(id)
        defer { visiting.remove(id) }
        let (scope, context) = try scope(of: decl, in: parsed, arm: nil)
        return try Analysis(scope: scope, context: context).elementKeys(forKey: key)
    }
}

private struct Context {
    let session: Session
    let parsed: ParsedFile
    let function: String
    let decl: FunctionDeclSyntax?
    var types = TypeEnv()

    func fail(_ node: some SyntaxProtocol) -> Unresolvable {
        session.fail(node, parsed, function)
    }
}

/// Keys of a dictionary literal, all required (rule 1 and the sink literals).
private func literalKeys(_ literal: DictionaryExprSyntax, _ context: Context) throws -> KeyMap {
    var result: KeyMap = [:]
    guard case .elements(let elements) = literal.content else { return result }
    for element in elements {
        guard let name = element.key.as(StringLiteralExprSyntax.self)?.representedLiteralValue else {
            throw context.fail(element)
        }
        KeyMerge.merge(&result, name: name, type: context.types.infer(element.value), presence: .required)
    }
    return result
}

/// Adds `other`'s keys to `result`, all optional when `optional`.
private func combine(_ result: inout KeyMap, _ other: KeyMap, optional: Bool) {
    for key in other.values {
        KeyMerge.merge(&result, name: key.name, type: key.type, presence: optional ? .optional : key.presence)
    }
}

/// Strips `try`, `await`, parentheses, `!`, `as?` casts and a `?? default`.
private func simplify(_ expression: ExprSyntax) -> ExprSyntax {
    if let wrapped = expression.as(TryExprSyntax.self) { return simplify(wrapped.expression) }
    if let wrapped = expression.as(AwaitExprSyntax.self) { return simplify(wrapped.expression) }
    if let wrapped = expression.as(ForceUnwrapExprSyntax.self) { return simplify(wrapped.expression) }
    if let tuple = expression.as(TupleExprSyntax.self), tuple.elements.count == 1, let only = tuple.elements.first,
       only.label == nil {
        return simplify(only.expression)
    }
    if let sequence = expression.as(SequenceExprSyntax.self) {
        let parts = Array(sequence.elements)
        let end = parts.firstIndex { $0.as(BinaryOperatorExprSyntax.self)?.operator.text == "??" } ?? parts.count
        let lhs = Array(parts[..<end])
        if lhs.count == 1 { return simplify(lhs[0]) }
        if lhs.count == 3, lhs[1].is(UnresolvedAsExprSyntax.self) { return simplify(lhs[0]) }
    }
    return expression
}

/// `f(...)` and `x.f(...)` both call `f`.
private func calleeName(_ call: FunctionCallExprSyntax) -> String? {
    if let reference = call.calledExpression.as(DeclReferenceExprSyntax.self) { return reference.baseName.text }
    if let member = call.calledExpression.as(MemberAccessExprSyntax.self) { return member.declName.baseName.text }
    return nil
}

private func stringKey(_ sub: SubscriptCallExprSyntax) -> String? {
    guard sub.arguments.count == 1 else { return nil }
    return sub.arguments.first?.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue
}

private final class FunctionFinder: SyntaxVisitor {
    let name: String
    var found: [FunctionDeclSyntax] = []
    init(name: String) {
        self.name = name
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == name { found.append(node) }
        return .visitChildren
    }
}

private final class CallFinder: SyntaxVisitor {
    let name: String
    var calls: [FunctionCallExprSyntax] = []
    init(name: String) {
        self.name = name
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if calleeName(node) == name { calls.append(node) }
        return .visitChildren
    }
}

/// Rule 10: names of called repo `vp_*_copy_json` functions.
private final class NativeCallFinder: SyntaxVisitor {
    var names: Set<String> = []
    init() { super.init(viewMode: .sourceAccurate) }
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let name = calleeName(node), name.hasPrefix("vp_"), name.hasSuffix("_copy_json") { names.insert(name) }
        return .visitChildren
    }
}

/// The dictionary literal a variable (or property) is declared with.
private final class InitialValueFinder: SyntaxVisitor {
    let name: String
    var literal: DictionaryExprSyntax?
    init(name: String) {
        self.name = name
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        if literal == nil, node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == name,
           let value = node.initializer?.value.as(DictionaryExprSyntax.self) {
            literal = value
        }
        return .visitChildren
    }
}

/// Calls `helper(..., &variable, ...)` anywhere in the scope, including closures (rule 12).
private final class InoutCallCollector: SyntaxVisitor {
    let variable: String
    let scopeID: SyntaxIdentifier
    var calls: [(call: FunctionCallExprSyntax, index: Int, topLevel: Bool)] = []

    init(variable: String, scopeID: SyntaxIdentifier) {
        self.variable = variable
        self.scopeID = scopeID
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        for (index, argument) in node.arguments.enumerated()
        where argument.expression.as(InOutExprSyntax.self)?.expression.as(DeclReferenceExprSyntax.self)?.baseName.text == variable {
            let item = node.parent?.as(CodeBlockItemSyntax.self)
            calls.append((node, index, item?.parent?.id == scopeID))
        }
        return .visitChildren
    }
}

/// The variable a sink function stores its parameter in: `x = value` or `self.x = value`.
private final class BackingFinder: SyntaxVisitor {
    let parameter: String
    var name: String?
    init(parameter: String) {
        self.parameter = parameter
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let parts = Array(node.elements)
        guard name == nil, parts.count == 3, parts[1].is(AssignmentExprSyntax.self),
              parts[2].as(DeclReferenceExprSyntax.self)?.baseName.text == parameter
        else { return .visitChildren }
        if let reference = parts[0].as(DeclReferenceExprSyntax.self) {
            name = reference.baseName.text
        } else if let member = parts[0].as(MemberAccessExprSyntax.self) {
            name = member.declName.baseName.text
        }
        return .skipChildren
    }
}

private final class ArmFinder: SyntaxVisitor {
    let arm: String
    var statements: CodeBlockItemListSyntax?
    init(arm: String) {
        self.arm = arm
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }

    override func visit(_ node: SwitchCaseSyntax) -> SyntaxVisitorContinueKind {
        guard statements == nil, case .case(let label) = node.label else { return .visitChildren }
        for item in label.caseItems {
            guard let pattern = item.pattern.as(ExpressionPatternSyntax.self),
                  let member = pattern.expression.as(MemberAccessExprSyntax.self),
                  member.declName.baseName.text == arm
            else { continue }
            statements = node.statements
            return .skipChildren
        }
        return .visitChildren
    }
}

/// Collects `return` statements of one scope, not entering closures or nested functions.
private final class ReturnCollector: SyntaxVisitor {
    var returns: [ReturnStmtSyntax] = []
    init() { super.init(viewMode: .sourceAccurate) }
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
        returns.append(node)
        return .skipChildren
    }
}

private struct Assignment {
    let key: String
    let value: ExprSyntax
    let topLevel: Bool
    let position: AbsolutePosition
}

/// Collects `variable["k"] = e` (rule 2) anywhere in the scope, including closures. With
/// `allowMember`, `self.variable["k"]` and `Type.variable["k"]` count too (the sink's backing variable).
private final class AssignmentCollector: SyntaxVisitor {
    let variable: String
    let scopeID: SyntaxIdentifier
    let allowMember: Bool
    var assignments: [Assignment] = []
    var failure: Syntax?

    init(variable: String, scopeID: SyntaxIdentifier, allowMember: Bool = false) {
        self.variable = variable
        self.scopeID = scopeID
        self.allowMember = allowMember
        super.init(viewMode: .sourceAccurate)
    }

    private func isTarget(_ base: ExprSyntax) -> Bool {
        if base.as(DeclReferenceExprSyntax.self)?.baseName.text == variable { return true }
        return allowMember && base.as(MemberAccessExprSyntax.self)?.declName.baseName.text == variable
    }

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let parts = Array(node.elements)
        guard parts.count >= 3,
              parts[1].is(AssignmentExprSyntax.self),
              let sub = parts[0].as(SubscriptCallExprSyntax.self),
              isTarget(sub.calledExpression)
        else { return .visitChildren }
        // A literal key, or a loop variable over a literal list of names (each name is a key).
        let literal = stringKey(sub)
        guard let names = literal.map({ [$0] }) ?? loopKeys(sub, from: node) else {
            failure = failure ?? Syntax(node)
            return .skipChildren
        }
        // The value is everything after `=`: a ternary or operator chain is a sequence of its own.
        let value: ExprSyntax = parts.count == 3
            ? parts[2] : ExprSyntax(SequenceExprSyntax(elements: ExprListSyntax(parts.dropFirst(2))))
        if value.is(NilLiteralExprSyntax.self) { return .skipChildren }
        let item = node.parent?.as(CodeBlockItemSyntax.self)
        let top = item?.parent?.id == scopeID && literal != nil
        for key in names {
            assignments.append(Assignment(key: key, value: value, topLevel: top, position: node.position))
        }
        return .visitChildren
    }
}

/// Rule 2b: `v[key] = e` where `key` is bound by `for key in [...]` or `for (key, x) in [(..), ..]` over a
/// literal list of string names; every name is a (conditional) key. Nil when `key` is anything else.
private func loopKeys(_ sub: SubscriptCallExprSyntax, from node: some SyntaxProtocol) -> [String]? {
    guard sub.arguments.count == 1,
          let name = sub.arguments.first?.expression.as(DeclReferenceExprSyntax.self)?.baseName.text
    else { return nil }
    var current = node.parent
    while let here = current {
        if let loop = here.as(ForStmtSyntax.self), let list = loop.sequence.as(ArrayExprSyntax.self) {
            var column: Int?
            if loop.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == name {
                column = -1
            } else if let tuple = loop.pattern.as(TuplePatternSyntax.self) {
                column = tuple.elements.firstIndex { $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == name }
                    .map { tuple.elements.distance(from: tuple.elements.startIndex, to: $0) }
            }
            if let column {
                var names: [String] = []
                for element in list.elements {
                    var expression = element.expression
                    if column >= 0 {
                        guard let tuple = expression.as(TupleExprSyntax.self), column < tuple.elements.count else { return nil }
                        expression = tuple.elements[tuple.elements.index(tuple.elements.startIndex, offsetBy: column)].expression
                    }
                    guard let text = expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue else { return nil }
                    names.append(text)
                }
                return names.isEmpty ? nil : names
            }
        }
        current = here.parent
    }
    return nil
}

/// `variable.merge(x, ...)` (rule 4) and `variable.append(x)` (rule 11) calls.
private final class MethodCallCollector: SyntaxVisitor {
    let variable: String
    let method: String
    let scopeID: SyntaxIdentifier
    var calls: [(argument: ExprSyntax, label: String?, topLevel: Bool, position: AbsolutePosition)] = []

    init(variable: String, method: String, scopeID: SyntaxIdentifier) {
        self.variable = variable
        self.method = method
        self.scopeID = scopeID
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self),
              member.declName.baseName.text == method,
              member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == variable,
              let first = node.arguments.first
        else { return .visitChildren }
        let item = node.parent?.as(CodeBlockItemSyntax.self)
        calls.append((first.expression, first.label?.text, item?.parent?.id == scopeID, node.position))
        return .visitChildren
    }
}

private enum Binding {
    case value(ExprSyntax)
    case element(ExprSyntax)

    /// `xs.first`, `xs.first(where:)`, `xs.last` bind an element of `xs`; anything else a value.
    init(_ initializer: ExprSyntax) {
        let expression = simplify(initializer)
        if let call = expression.as(FunctionCallExprSyntax.self),
           let member = call.calledExpression.as(MemberAccessExprSyntax.self),
           ["first", "last"].contains(member.declName.baseName.text), let base = member.base {
            self = .element(base)
        } else if let member = expression.as(MemberAccessExprSyntax.self),
                  ["first", "last"].contains(member.declName.baseName.text), let base = member.base {
            self = .element(base)
        } else {
            self = .value(initializer)
        }
    }
}

/// Everything bound to a name: `let`/`var` initialisers, `if let`/`guard let`, `for x in`.
private final class BindingFinder: SyntaxVisitor {
    let name: String
    private var declared: [Binding] = []
    private var assigned: [Binding] = []
    /// Initialisers; only when the variable has none, its plain assignments.
    var bindings: [Binding] { declared.isEmpty ? assigned : declared }
    init(name: String) {
        self.name = name
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        if node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == name,
           let value = node.initializer?.value {
            declared.append(Binding(value))
        }
        return .visitChildren
    }

    override func visit(_ node: OptionalBindingConditionSyntax) -> SyntaxVisitorContinueKind {
        if node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == name,
           let value = node.initializer?.value {
            declared.append(Binding(value))
        }
        return .visitChildren
    }

    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        if node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == name {
            declared.append(.element(node.sequence))
        }
        return .visitChildren
    }

    /// `name = value` assigns the variable declared without an initialiser.
    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let parts = Array(node.elements)
        if parts.count == 3, parts[1].is(AssignmentExprSyntax.self),
           parts[0].as(DeclReferenceExprSyntax.self)?.baseName.text == name {
            assigned.append(Binding(parts[2]))
        }
        return .visitChildren
    }
}

private struct Analysis {
    let scope: CodeBlockItemListSyntax
    let context: Context

    private func returnedExpressions() -> [ExprSyntax] {
        let collector = ReturnCollector()
        collector.walk(scope)
        var expressions = collector.returns.compactMap { $0.expression }
        if collector.returns.isEmpty, scope.count == 1, let only = scope.first?.item.as(ExprSyntax.self),
           only.is(DictionaryExprSyntax.self) || only.is(DeclReferenceExprSyntax.self)
            || only.is(FunctionCallExprSyntax.self) || only.is(TryExprSyntax.self) {
            expressions = [only]
        }
        return expressions
    }

    /// Rules 1-4: each return yields a key set; the result is their union with
    /// keys absent from any return optional.
    func run() throws -> KeyMap {
        var sets: [KeyMap] = []
        for expression in returnedExpressions() {
            if expression.is(NilLiteralExprSyntax.self) { continue }
            sets.append(try keys(returned: expression))
        }
        guard !sets.isEmpty else { throw context.fail(scope) }
        return KeyMerge.union(sets)
    }

    private func keys(returned original: ExprSyntax) throws -> KeyMap {
        let expression = simplify(original)
        if let literal = expression.as(DictionaryExprSyntax.self) { return try literalKeys(literal, context) }
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return try keys(ofVariable: reference.baseName.text, at: expression)
        }
        if let call = expression.as(FunctionCallExprSyntax.self) { return try keys(ofCall: call) }
        if let sub = expression.as(SubscriptCallExprSyntax.self) { return try keys(ofEnvelope: sub) }
        // `condition ? a : b`: the union of both branches.
        if let sequence = expression.as(SequenceExprSyntax.self) {
            let parts = Array(sequence.elements)
            if let mark = parts.firstIndex(where: { $0.is(UnresolvedTernaryExprSyntax.self) }), mark + 1 < parts.count,
               let ternary = parts[mark].as(UnresolvedTernaryExprSyntax.self) {
                let rest = Array(parts[(mark + 1)...])
                let otherwise: ExprSyntax = rest.count == 1 ? rest[0] : ExprSyntax(SequenceExprSyntax(elements: ExprListSyntax(rest)))
                return KeyMerge.union([try keys(returned: ternary.thenExpression), try keys(returned: otherwise)])
            }
        }
        throw context.fail(expression)
    }

    /// Rule 4: a followed helper, or `a.merging(b)`.
    private func keys(ofCall call: FunctionCallExprSyntax) throws -> KeyMap {
        if call.calledExpression.is(DictionaryExprSyntax.self), call.arguments.isEmpty { return [:] }
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
           member.declName.baseName.text == "merging", let base = member.base,
           let argument = call.arguments.first?.expression {
            var result = try keys(returned: base)
            combine(&result, try keys(returned: argument), optional: false)
            return result
        }
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
           ["withLock", "sync"].contains(member.declName.baseName.text), let closure = call.trailingClosure {
            return try Analysis(scope: closure.statements, context: context).run()
        }
        guard let name = calleeName(call) else { throw context.fail(call) }
        if name == "decodeBridgeJSON" || name == "takeCString" || name.hasPrefix("decode"),
           let bridge = bridgeName(in: call) {
            return try bridgeKeys(bridge)
        }
        if name == "jsonObject" { return try parsedJSONKeys() }
        // `optional.map(helper)`: the result is what `helper` returns.
        if name == "map", call.arguments.count == 1, call.trailingClosure == nil,
           let helper = call.arguments.first?.expression.as(DeclReferenceExprSyntax.self)?.baseName.text {
            let (decl, parsed) = try context.session.resolve(helper, from: context, at: call)
            return try context.session.analyze(decl, in: parsed, arm: nil)
        }
        if name.hasPrefix("vp_") { return try bridgeKeys(name) }
        let (decl, parsed) = try context.session.resolve(name, from: context, at: call)
        return try context.session.analyze(decl, in: parsed, arm: nil)
    }

    /// `JSONSerialization.jsonObject` of the one bridge (`icli_x_json`) or `vp_*_copy_json` native
    /// function this function calls (rules 6 and 10 without an envelope). With none, the JSON
    /// comes from a session whose keys another entry supplies (rule 9): no keys.
    private func parsedJSONKeys() throws -> KeyMap {
        guard let decl = context.decl else { return [:] }
        let bridge = BridgeCallFinder()
        bridge.walk(decl)
        if let name = bridge.name { return try bridgeKeys(name) }
        let native = NativeCallFinder()
        native.walk(decl)
        if native.names.count == 1, let name = native.names.first { return try bridgeKeys(name) }
        return [:]
    }

    /// Rule 6: the key set of the native `icli_x_json` function behind a bridge call.
    private func bridgeKeys(_ name: String) throws -> KeyMap {
        let session = context.session
        let keys = try NativeExtractor.extract(
            function: name, sources: session.lookup.native(name), method: session.method, lookup: session.lookup.native
        )
        var map: KeyMap = [:]
        for key in keys { map[key.name] = key }
        return map
    }

    /// Rule 10: `env["k"]` of the JSON a repo `vp_*_copy_json` returns.
    private func keys(ofEnvelope sub: SubscriptCallExprSyntax) throws -> KeyMap {
        guard let key = stringKey(sub), let decl = context.decl else { throw context.fail(sub) }
        let finder = NativeCallFinder()
        finder.walk(decl)
        guard finder.names.count == 1, let name = finder.names.first else { throw context.fail(sub) }
        let session = context.session
        let result = try NativeExtractor.unwrap(
            function: name, key: key, sources: session.lookup.native(name), method: session.method,
            lookup: session.lookup.native
        )
        if result.open { session.open = true }
        var keys: KeyMap = [:]
        for key in result.keys { keys[key.name] = key }
        return keys
    }

    private func keys(ofVariable name: String, at use: ExprSyntax) throws -> KeyMap {
        let finder = BindingFinder(name: name)
        finder.walk(scope)
        guard !finder.bindings.isEmpty else { throw context.fail(use) }
        // Several bindings of one name (e.g. an `if let result` per branch): their union.
        let sets = try finder.bindings.map { try keys(of: $0, name: name, at: use) }
        var result: KeyMap = KeyMerge.union(sets)
        let assignments = AssignmentCollector(variable: name, scopeID: scope.id)
        assignments.walk(scope)
        if let failure = assignments.failure { throw context.fail(failure) }
        for assignment in assignments.assignments where assignment.position < use.position {
            KeyMerge.merge(&result, name: assignment.key, type: context.types.infer(assignment.value),
                           presence: assignment.topLevel ? .required : .optional)
        }
        // Rule 12: a helper that writes keys into the dictionary passed as `&name`.
        let inouts = InoutCallCollector(variable: name, scopeID: scope.id)
        inouts.walk(scope)
        for site in inouts.calls where site.call.position < use.position {
            try combineInoutWrites(of: site.call, argument: site.index, topLevel: site.topLevel, into: &result)
        }
        let merges = MethodCallCollector(variable: name, method: "merge", scopeID: scope.id)
        merges.walk(scope)
        for merge in merges.calls where merge.position < use.position {
            combine(&result, try keys(returned: merge.argument), optional: !merge.topLevel)
        }
        return result
    }

    private func combineInoutWrites(
        of call: FunctionCallExprSyntax, argument: Int, topLevel: Bool, into result: inout KeyMap
    ) throws {
        guard let name = calleeName(call) else { throw context.fail(call) }
        let (decl, parsed) = try context.session.resolve(name, from: context, at: call)
        let parameters = Array(decl.signature.parameterClause.parameters)
        guard argument < parameters.count, let body = decl.body else { throw context.fail(call) }
        let parameter = (parameters[argument].secondName ?? parameters[argument].firstName).text
        let (_, helperContext) = try context.session.scope(of: decl, in: parsed, arm: nil)
        let writes = AssignmentCollector(variable: parameter, scopeID: body.statements.id)
        writes.walk(body)
        if let failure = writes.failure { throw helperContext.fail(failure) }
        for write in writes.assignments {
            KeyMerge.merge(&result, name: write.key, type: helperContext.types.infer(write.value),
                           presence: topLevel && write.topLevel ? .required : .optional)
        }
    }

    private func keys(of binding: Binding, name: String, at use: ExprSyntax) throws -> KeyMap {
        switch binding {
        case .element(let array):
            return try elementKeys(of: array)
        case .value(let initializer):
            let expression = simplify(initializer)
            if let literal = expression.as(DictionaryExprSyntax.self) {
                return try literalKeys(literal, context)
            } else if let call = expression.as(FunctionCallExprSyntax.self) {
                return try keys(ofCall: call)
            } else if let other = expression.as(DeclReferenceExprSyntax.self), other.baseName.text != name {
                return try keys(ofVariable: other.baseName.text, at: use)
            }
            throw context.fail(initializer)
        }
    }

    // MARK: rule 11

    /// The key set of the dictionaries in an array expression: a variable bound to one, or
    /// `helper()["k"]` where the helper returns the array under `k`.
    private func elementKeys(of array: ExprSyntax) throws -> KeyMap {
        let expression = simplify(array)
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            let finder = BindingFinder(name: reference.baseName.text)
            finder.walk(scope)
            guard finder.bindings.count == 1, case .value(let initializer) = finder.bindings[0] else {
                throw context.fail(expression)
            }
            return try elementKeys(of: initializer)
        }
        if let sub = expression.as(SubscriptCallExprSyntax.self), let key = stringKey(sub),
           let call = simplify(sub.calledExpression).as(FunctionCallExprSyntax.self), let name = calleeName(call) {
            let (decl, parsed) = try context.session.resolve(name, from: context, at: call)
            return try context.session.elementKeys(of: decl, in: parsed, key: key)
        }
        throw context.fail(expression)
    }

    /// This function returns a dictionary holding an array under `key`: the union of its elements.
    func elementKeys(forKey key: String) throws -> KeyMap {
        var sets: [KeyMap] = []
        for returned in returnedExpressions() {
            let value = try value(forKey: key, in: returned)
            sets += try arrayElements(of: value)
        }
        guard !sets.isEmpty else { throw context.fail(scope) }
        return KeyMerge.union(sets)
    }

    private func value(forKey key: String, in returned: ExprSyntax) throws -> ExprSyntax {
        var expression = simplify(returned)
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            let finder = BindingFinder(name: reference.baseName.text)
            finder.walk(scope)
            guard finder.bindings.count == 1, case .value(let initializer) = finder.bindings[0] else {
                throw context.fail(expression)
            }
            expression = simplify(initializer)
        }
        guard let literal = expression.as(DictionaryExprSyntax.self),
              case .elements(let elements) = literal.content,
              let element = elements.first(where: { $0.key.as(StringLiteralExprSyntax.self)?.representedLiteralValue == key })
        else { throw context.fail(expression) }
        return element.value
    }

    /// One key set per element source of an array expression: literal elements, a variable's
    /// initialiser plus its `append`s, a bridge array, or a followed helper's returned array.
    private func arrayElements(of value: ExprSyntax) throws -> [KeyMap] {
        let expression = simplify(value)
        if let array = expression.as(ArrayExprSyntax.self) {
            return try array.elements.map { try keys(returned: $0.expression) }
        }
        if let call = expression.as(FunctionCallExprSyntax.self) {
            if let bridge = bridgeName(in: call) { return [try bridgeElements(bridge, at: call)] }
            guard let name = calleeName(call) else { throw context.fail(call) }
            let (decl, parsed) = try context.session.resolve(name, from: context, at: call)
            return try context.session.returnedElements(of: decl, in: parsed)
        }
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            let name = reference.baseName.text
            let finder = BindingFinder(name: name)
            finder.walk(scope)
            guard finder.bindings.count == 1, case .value(let initializer) = finder.bindings[0] else {
                throw context.fail(expression)
            }
            var sets = try arrayElements(of: initializer)
            let appends = MethodCallCollector(variable: name, method: "append", scopeID: scope.id)
            appends.walk(scope)
            for append in appends.calls {
                if append.label == "contentsOf" {
                    sets += try arrayElements(of: append.argument)
                } else {
                    sets.append(try keys(returned: append.argument))
                }
            }
            return sets
        }
        throw context.fail(expression)
    }

    /// This function returns an array: its element key sets.
    func returnedElements() throws -> [KeyMap] {
        var sets: [KeyMap] = []
        for returned in returnedExpressions() { sets += try arrayElements(of: returned) }
        guard !sets.isEmpty else { throw context.fail(scope) }
        return sets
    }

    /// `icli_x_json` inside `decodeJSONArray(takeCString(icli_x_json()))`.
    private func bridgeName(in call: FunctionCallExprSyntax) -> String? {
        let finder = BridgeCallFinder()
        finder.walk(call)
        return finder.name
    }

    private func bridgeElements(_ name: String, at node: some SyntaxProtocol) throws -> KeyMap {
        let session = context.session
        let keys = try NativeExtractor.elements(
            function: name, sources: session.lookup.native(name), method: session.method, lookup: session.lookup.native
        )
        var map: KeyMap = [:]
        for key in keys { map[key.name] = key }
        return map
    }
}

/// The first call of an `icli_*_json` bridge function.
private final class BridgeCallFinder: SyntaxVisitor {
    var name: String?
    init() { super.init(viewMode: .sourceAccurate) }
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if name == nil, let callee = calleeName(node), callee.hasPrefix("icli_"), callee.hasSuffix("_json") {
            name = callee
        }
        return .visitChildren
    }
}
