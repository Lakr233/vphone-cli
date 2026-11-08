import Foundation
import SwiftSyntax

/// What is known about a Swift value's type: its JSON key type, the nominal type name when it is
/// a named type (so `value.member` can be looked up) and the element type of an array.
struct TypeRef: Equatable, Sendable {
    final class Element: Equatable, @unchecked Sendable {
        let ref: TypeRef
        init(_ ref: TypeRef) { self.ref = ref }
        static func == (a: Element, b: Element) -> Bool { a.ref == b.ref }
    }

    /// The members of a tuple type, in order, with their labels.
    final class Tuple: Equatable, @unchecked Sendable {
        let labels: [String?]
        let refs: [TypeRef]
        init(labels: [String?], refs: [TypeRef]) {
            self.labels = labels
            self.refs = refs
        }
        static func == (a: Tuple, b: Tuple) -> Bool { a.labels == b.labels && a.refs == b.refs }
    }

    var key: KeyType = .any
    var nominal: String?
    var element: Element?
    var tuple: Tuple?

    init(key: KeyType = .any, nominal: String? = nil, element: TypeRef? = nil, tuple: Tuple? = nil) {
        self.key = key
        self.nominal = nominal
        self.element = element.map(Element.init)
        self.tuple = tuple
    }

    /// Two declarations of one name: what they agree on.
    func unified(with other: TypeRef) -> TypeRef {
        var result = TypeRef(key: KeyMerge.unifiedType(key, other.key))
        if nominal == other.nominal { result.nominal = nominal }
        if element == other.element { result.element = element }
        if tuple == other.tuple { result.tuple = tuple }
        return result
    }

    /// The reference of a type annotation (optionality is not tracked).
    static func of(_ type: TypeSyntax) -> TypeRef {
        if let optional = type.as(OptionalTypeSyntax.self) { return of(optional.wrappedType) }
        if let optional = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) { return of(optional.wrappedType) }
        if let array = type.as(ArrayTypeSyntax.self) { return TypeRef(key: .array, element: of(array.element)) }
        if type.is(DictionaryTypeSyntax.self) { return TypeRef(key: .object) }
        if let tuple = type.as(TupleTypeSyntax.self) {
            if tuple.elements.count == 1, let only = tuple.elements.first { return of(only.type) }
            return TypeRef(tuple: Tuple(labels: tuple.elements.map { $0.firstName?.text }, refs: tuple.elements.map { of($0.type) }))
        }
        var name: String?
        var arguments: GenericArgumentClauseSyntax?
        if let identifier = type.as(IdentifierTypeSyntax.self) {
            name = identifier.name.text
            arguments = identifier.genericArgumentClause
        } else if let member = type.as(MemberTypeSyntax.self) {
            name = member.name.text
            arguments = member.genericArgumentClause
        }
        guard let name else { return TypeRef() }
        if name == "Array", let argument = arguments?.arguments.first, case .type(let element) = argument.argument {
            return TypeRef(key: .array, element: of(element))
        }
        if name == "Dictionary" { return TypeRef(key: .object) }
        let key = TypeEnv.type(of: type)
        return key == .any ? TypeRef(nominal: name) : TypeRef(key: key)
    }
}

/// Declared members and functions of the repo's types, by simple type name (REQ-RPC-007).
struct TypeIndex {
    struct Method {
        let parameters: [(label: String, optional: Bool)]
        let returns: TypeRef
    }

    var props: [String: [String: TypeRef]] = [:]
    var methods: [String: [String: [Method]]] = [:]
    var free: [String: [Method]] = [:]

    mutating func merge(_ other: TypeIndex) {
        for (type, members) in other.props {
            for (name, ref) in members { addProp(type, name, ref) }
        }
        for (type, table) in other.methods {
            for (name, list) in table { methods[type, default: [:]][name, default: []] += list }
        }
        for (name, list) in other.free { free[name, default: []] += list }
        for type in other.methods.keys where props[type] == nil { props[type] = [:] }
    }

    mutating func addProp(_ type: String, _ name: String, _ ref: TypeRef) {
        if let existing = props[type]?[name] {
            props[type]?[name] = existing.unified(with: ref)
        } else {
            props[type, default: [:]][name] = ref
        }
    }

    func isType(_ name: String) -> Bool { props[name] != nil || TypeIndex.builtin[name] != nil }

    func prop(_ type: String, _ name: String) -> TypeRef? {
        props[type]?[name] ?? TypeIndex.builtin[type]?[name]
    }

    /// Methods named `name` that `call` can reach on `type` (all types when nil), by argument labels.
    func candidates(type: String?, name: String, call: FunctionCallExprSyntax) -> [Method] {
        let all: [Method]
        if let type {
            all = methods[type]?[name] ?? []
        } else {
            all = (free[name] ?? []) + methods.values.flatMap { $0[name] ?? [] }
        }
        return all.filter { TypeIndex.accepts($0, call) }
    }

    static func accepts(_ method: Method, _ call: FunctionCallExprSyntax) -> Bool {
        var arguments = call.arguments.map { $0.label?.text ?? "_" }
        if call.trailingClosure != nil { arguments.append("") }
        var index = 0
        for parameter in method.parameters {
            if index < arguments.count, arguments[index] == parameter.label { index += 1; continue }
            if index < arguments.count, arguments[index] == "", call.trailingClosure != nil, index == arguments.count - 1 {
                index += 1; continue
            }
            if parameter.optional { continue }
            return false
        }
        return index == arguments.count
    }

    /// The common return type of several candidates; `any` when they differ or none exist.
    static func returns(_ methods: [Method]) -> TypeRef {
        guard var result = methods.first?.returns else { return TypeRef() }
        for method in methods.dropFirst() { result = result.unified(with: method.returns) }
        return result
    }

    /// Fixed SDK members (Foundation, UIKit) of the few types the repo reads.
    static let builtin: [String: [String: TypeRef]] = [
        "ProcessInfo": [
            "physicalMemory": TypeRef(key: .integer), "processorCount": TypeRef(key: .integer),
            "activeProcessorCount": TypeRef(key: .integer), "processIdentifier": TypeRef(key: .integer),
            "hostName": TypeRef(key: .string), "processName": TypeRef(key: .string),
            "isLowPowerModeEnabled": TypeRef(key: .boolean), "systemUptime": TypeRef(key: .number),
        ],
        "UIPasteboard": [
            "changeCount": TypeRef(key: .integer), "numberOfItems": TypeRef(key: .integer),
            "hasStrings": TypeRef(key: .boolean), "hasImages": TypeRef(key: .boolean),
            "string": TypeRef(key: .string),
        ],
        "Date": [
            "timeIntervalSince1970": TypeRef(key: .number), "timeIntervalSinceReferenceDate": TypeRef(key: .number),
        ],
        "URL": [
            "path": TypeRef(key: .string), "lastPathComponent": TypeRef(key: .string),
            "pathExtension": TypeRef(key: .string), "absoluteString": TypeRef(key: .string),
        ],
    ]

    /// Fixed SDK methods by receiver type.
    static let builtinMethods: [String: [String: KeyType]] = [
        "Date": ["timeIntervalSince": .number],
    ]

    /// Static members that are an instance of their own type.
    static let singletons: Set<String> = ["processInfo", "general", "shared", "default", "standard", "current", "main"]
}

/// Collects one file's declarations into a `TypeIndex`.
final class TypeIndexBuilder: SyntaxVisitor {
    var index = TypeIndex()
    private var stack: [String] = []

    init() { super.init(viewMode: .sourceAccurate) }

    static func build(_ tree: SourceFileSyntax) -> TypeIndex {
        let builder = TypeIndexBuilder()
        builder.walk(tree)
        return builder.index
    }

    private func enter(_ name: String) -> SyntaxVisitorContinueKind {
        stack.append(name)
        if index.props[name] == nil { index.props[name] = [:] }
        return .visitChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { enter(node.name.text) }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { enter(node.name.text) }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { enter(node.name.text) }
    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind { enter(node.name.text) }
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let ref = TypeRef.of(node.extendedType)
        return enter(ref.nominal ?? node.extendedType.trimmedDescription)
    }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        let result = enter(node.name.text)
        // `enum E: String` / `: Int`: `rawValue` has the raw type.
        if let first = node.inheritanceClause?.inheritedTypes.first {
            let key = TypeEnv.type(of: first.type)
            if key != .any { index.addProp(node.name.text, "rawValue", TypeRef(key: key)) }
        }
        return result
    }

    override func visitPost(_ node: StructDeclSyntax) { stack.removeLast() }
    override func visitPost(_ node: ClassDeclSyntax) { stack.removeLast() }
    override func visitPost(_ node: ActorDeclSyntax) { stack.removeLast() }
    override func visitPost(_ node: ProtocolDeclSyntax) { stack.removeLast() }
    override func visitPost(_ node: ExtensionDeclSyntax) { stack.removeLast() }
    override func visitPost(_ node: EnumDeclSyntax) { stack.removeLast() }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let parameters = node.signature.parameterClause.parameters.map {
            (label: $0.firstName.text, optional: $0.defaultValue != nil || $0.ellipsis != nil)
        }
        let returns = node.signature.returnClause.map { TypeRef.of($0.type) } ?? TypeRef()
        let method = TypeIndex.Method(parameters: parameters, returns: returns)
        if let type = stack.last {
            index.methods[type, default: [:]][node.name.text, default: []].append(method)
        } else {
            index.free[node.name.text, default: []].append(method)
        }
        return .skipChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let type = stack.last else { return .skipChildren }
        for binding in node.bindings {
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
            if let annotation = binding.typeAnnotation {
                index.addProp(type, name, TypeRef.of(annotation.type))
            } else if let initializer = binding.initializer {
                var env = TypeEnv()
                env.index = index
                index.addProp(type, name, env.ref(initializer.value))
            } else {
                index.addProp(type, name, TypeRef())
            }
        }
        return .skipChildren
    }
}
