import Foundation
import SwiftSyntax

/// Types of locals, parameters, file-level properties and expressions (REQ-RPC-007).
struct TypeEnv {
    var local: [String: TypeRef] = [:]
    var file: [String: TypeRef] = [:]
    var index = TypeIndex()
    var c: CTypes?
    /// Functions declared inside the function being analysed.
    var functions: [String: [TypeIndex.Method]] = [:]
    /// Names declared as a non-optional array (`[T]` annotation, array literal): `.map` on them is an array.
    var arrays: Set<String> = []

    init() {}

    init(function: FunctionDeclSyntax, tree: SourceFileSyntax, index: TypeIndex, c: CTypes? = nil) {
        self.index = index
        self.c = c
        let fileLevel = TypeCollector(skipBodies: true, index: index)
        fileLevel.c = c
        fileLevel.walk(tree)
        file = fileLevel.types
        let locals = TypeCollector(skipBodies: false, fileTypes: file, index: index)
        locals.c = c
        for parameter in function.signature.parameterClause.parameters {
            let name = (parameter.secondName ?? parameter.firstName).text
            locals.record(name, TypeRef.of(parameter.type))
            if parameter.type.is(ArrayTypeSyntax.self) { locals.arrays.insert(name) } else { locals.notArrays.insert(name) }
        }
        if let body = function.body { locals.walk(body) }
        local = locals.types
        functions = locals.functions
        arrays = locals.arrays.subtracting(locals.notArrays)
    }

    static func type(of type: TypeSyntax) -> KeyType {
        if let optional = type.as(OptionalTypeSyntax.self) { return Self.type(of: optional.wrappedType) }
        if let optional = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) { return Self.type(of: optional.wrappedType) }
        if type.is(ArrayTypeSyntax.self) { return .array }
        if type.is(DictionaryTypeSyntax.self) { return .object }
        guard let name = type.as(IdentifierTypeSyntax.self)?.name.text else { return .any }
        switch name {
        case "Int", "UInt", "Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16", "UInt32", "UInt64": return .integer
        case "Double", "Float", "CGFloat": return .number
        case "Bool": return .boolean
        case "String": return .string
        default: return .any
        }
    }

    func infer(_ expression: ExprSyntax) -> KeyType { ref(expression).key }

    /// Member names whose type holds for every receiver.
    static let memberTypes: [String: KeyType] = [
        "count": .integer, "isEmpty": .boolean, "description": .string, "localizedDescription": .string,
        "uuidString": .string,
    ]
    /// Method names whose result type holds for every receiver.
    static let methodTypes: [String: KeyType] = [
        "joined": .string, "uppercased": .string, "lowercased": .string, "trimmingCharacters": .string,
        "replacingOccurrences": .string, "base64EncodedString": .string, "capitalized": .string,
        "hasPrefix": .boolean, "hasSuffix": .boolean, "contains": .boolean, "allSatisfy": .boolean,
        "starts": .boolean, "sorted": .array, "compactMap": .array, "components": .array, "split": .array,
    ]

    func ref(_ expression: ExprSyntax) -> TypeRef {
        if expression.is(StringLiteralExprSyntax.self) { return TypeRef(key: .string) }
        if expression.is(IntegerLiteralExprSyntax.self) { return TypeRef(key: .integer) }
        if expression.is(FloatLiteralExprSyntax.self) { return TypeRef(key: .number) }
        if expression.is(BooleanLiteralExprSyntax.self) { return TypeRef(key: .boolean) }
        if expression.is(ArrayExprSyntax.self) { return TypeRef(key: .array) }
        if expression.is(DictionaryExprSyntax.self) { return TypeRef(key: .object) }
        if let prefix = expression.as(PrefixOperatorExprSyntax.self) {
            if prefix.operator.text == "!" { return TypeRef(key: .boolean) }
            if prefix.operator.text == "-" { return ref(prefix.expression) }
        }
        if let tuple = expression.as(TupleExprSyntax.self), tuple.elements.count == 1, let only = tuple.elements.first {
            return ref(only.expression)
        }
        if let unwrap = expression.as(ForceUnwrapExprSyntax.self) { return ref(unwrap.expression) }
        if let chain = expression.as(OptionalChainingExprSyntax.self) { return ref(chain.expression) }
        if let wrapped = expression.as(TryExprSyntax.self) { return ref(wrapped.expression) }
        if let wrapped = expression.as(AwaitExprSyntax.self) { return ref(wrapped.expression) }
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return local[reference.baseName.text] ?? file[reference.baseName.text] ?? TypeRef()
        }
        if let member = expression.as(MemberAccessExprSyntax.self) { return ref(member) }
        if let call = expression.as(FunctionCallExprSyntax.self) { return ref(call) }
        if let subscripted = expression.as(SubscriptCallExprSyntax.self) {
            // An element of an array whose element type is known.
            return ref(subscripted.calledExpression).element?.ref ?? TypeRef()
        }
        if let sequence = expression.as(SequenceExprSyntax.self) { return ref(Array(sequence.elements)) }
        return TypeRef()
    }

    /// `Type` named in an expression that is not a local: `ProcessInfo` in `ProcessInfo.processInfo`.
    private func typeName(_ expression: ExprSyntax?) -> String? {
        guard let name = expression?.as(DeclReferenceExprSyntax.self)?.baseName.text,
              local[name] == nil, file[name] == nil, index.isType(name) else { return nil }
        return name
    }

    private func ref(_ member: MemberAccessExprSyntax) -> TypeRef {
        let name = member.declName.baseName.text
        guard let base = member.base else { return TypeRef() }
        if base.as(DeclReferenceExprSyntax.self)?.baseName.text == "self" { return file[name] ?? TypeRef() }
        if let type = typeName(base) {
            if let found = index.prop(type, name) { return found }
            return TypeIndex.singletons.contains(name) ? TypeRef(nominal: type) : TypeRef()
        }
        let receiver = ref(base)
        if let tuple = receiver.tuple {
            if let position = Int(name), position < tuple.refs.count { return tuple.refs[position] }
            if let position = tuple.labels.firstIndex(of: name) { return tuple.refs[position] }
        }
        if let nominal = receiver.nominal {
            if let found = index.prop(nominal, name) { return found }
            if let found = c?.field(nominal, name) { return found }
        }
        if ["first", "last"].contains(name), let element = receiver.element { return element.ref }
        if let key = TypeEnv.memberTypes[name] { return TypeRef(key: key) }
        return TypeRef()
    }

    /// Free functions whose result type is fixed.
    static let freeCalls: [String: KeyType] = [
        "getpid": .integer, "getppid": .integer, "getuid": .integer, "geteuid": .integer, "getgid": .integer,
        "getegid": .integer,
    ]

    private func ref(_ call: FunctionCallExprSyntax) -> TypeRef {
        // `[T]()` and `[K: V]()`.
        if call.calledExpression.is(ArrayExprSyntax.self) { return TypeRef(key: .array) }
        if call.calledExpression.is(DictionaryExprSyntax.self) { return TypeRef(key: .object) }
        if let name = call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text {
            let converted = Self.type(of: TypeSyntax(IdentifierTypeSyntax(name: .identifier(name))))
            if converted != .any { return TypeRef(key: converted) }
            if name == "Array" { return TypeRef(key: .array) }
            if local[name] == nil, file[name] == nil, index.isType(name) { return TypeRef(nominal: name) }
            if let nested = functions[name]?.filter({ TypeIndex.accepts($0, call) }), !nested.isEmpty {
                return TypeIndex.returns(nested)
            }
            if ["min", "max", "abs"].contains(name) { return arithmetic(call.arguments.map(\.expression)) }
            if let key = TypeEnv.freeCalls[name] { return TypeRef(key: key) }
            let found = index.candidates(type: nil, name: name, call: call)
            if !found.isEmpty { return TypeIndex.returns(found) }
            return c?.returnType(name) ?? TypeRef()
        }
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self) else { return TypeRef() }
        let name = member.declName.baseName.text
        let base = member.base
        if let type = typeName(base) {
            return TypeIndex.returns(index.candidates(type: type, name: name, call: call))
        }
        if let base {
            if base.as(DeclReferenceExprSyntax.self)?.baseName.text == "self" {
                return TypeIndex.returns(index.candidates(type: nil, name: name, call: call))
            }
            if let nominal = ref(base).nominal {
                let found = index.candidates(type: nominal, name: name, call: call)
                if !found.isEmpty { return TypeIndex.returns(found) }
            }
            if ["map", "filter", "reversed"].contains(name), isArray(base) { return TypeRef(key: .array) }
            // `x.rounded()` and friends keep the number type of `x`.
            if ["rounded", "squareRoot", "magnitude"].contains(name), call.arguments.isEmpty || name == "rounded" {
                let receiver = ref(base).key
                if receiver == .number || receiver == .integer { return TypeRef(key: receiver) }
            }
            if let nominal = ref(base).nominal, let key = TypeIndex.builtinMethods[nominal]?[name] { return TypeRef(key: key) }
        }
        if let key = TypeEnv.methodTypes[name] { return TypeRef(key: key) }
        return TypeRef()
    }

    /// A non-optional array: literal, declared array name, or a call chain that returns one.
    private func isArray(_ expression: ExprSyntax) -> Bool {
        if expression.is(ArrayExprSyntax.self) { return true }
        if let reference = expression.as(DeclReferenceExprSyntax.self) { return arrays.contains(reference.baseName.text) }
        if let call = expression.as(FunctionCallExprSyntax.self) { return ref(call).key == .array }
        return false
    }

    /// Flat operator sequences, lowest precedence first: ternary, `&&`/`||`, comparison and `is`,
    /// `??`, `as`, then arithmetic.
    private func ref(_ parts: [ExprSyntax]) -> TypeRef {
        func sub(_ range: ArraySlice<ExprSyntax>) -> ExprSyntax {
            range.count == 1 ? range[range.startIndex] : ExprSyntax(SequenceExprSyntax(elements: ExprListSyntax(range)))
        }
        func binary(_ part: ExprSyntax) -> String? { part.as(BinaryOperatorExprSyntax.self)?.operator.text }
        if let mark = parts.firstIndex(where: { $0.is(UnresolvedTernaryExprSyntax.self) }), mark + 1 < parts.count,
           let ternary = parts[mark].as(UnresolvedTernaryExprSyntax.self) {
            let then = ref(ternary.thenExpression)
            let otherwise = ref(sub(parts[(mark + 1)...]))
            return then.key == otherwise.key ? then.unified(with: otherwise) : TypeRef()
        }
        let operators = parts.compactMap(binary)
        if operators.contains(where: { ["&&", "||", "==", "!=", "<", ">", "<=", ">=", "===", "!==", "~="].contains($0) })
            || parts.contains(where: { $0.is(UnresolvedIsExprSyntax.self) }) {
            return TypeRef(key: .boolean)
        }
        if let mark = parts.firstIndex(where: { binary($0) == "??" }), mark > 0, mark + 1 < parts.count {
            let value = ref(sub(parts[..<mark]))
            let fallback = sub(parts[(mark + 1)...])
            let other = ref(fallback)
            if value.key == other.key { return value.unified(with: other) }
            return value.key == .number && fallback.is(IntegerLiteralExprSyntax.self) ? TypeRef(key: .number) : TypeRef()
        }
        if let mark = parts.firstIndex(where: { $0.is(UnresolvedAsExprSyntax.self) }), mark + 1 < parts.count,
           let type = parts[mark + 1].as(TypeExprSyntax.self) {
            return TypeRef.of(type.type)
        }
        // Arithmetic: Swift operands share one type, so one known operand decides.
        guard !operators.isEmpty, operators.allSatisfy({ ["+", "-", "*", "/", "%"].contains($0) }) else { return TypeRef() }
        return arithmetic(parts.enumerated().filter { $0.offset % 2 == 0 }.map(\.element))
    }

    /// The common type of operands: equal types; an integer literal adapts to a floating operand; an
    /// operand of unknown, non-nominal type takes the type of the known ones (Swift has no mixed arithmetic).
    private func arithmetic(_ operands: [ExprSyntax]) -> TypeRef {
        let refs = operands.map { ref($0) }
        let known = refs.map(\.key).filter { $0 != .any }
        guard let first = known.first else { return TypeRef() }
        if refs.contains(where: { $0.key == .any && $0.nominal != nil }) { return TypeRef() }
        if known.allSatisfy({ $0 == first }) { return TypeRef(key: first) }
        let floating = known.contains(.number)
        let adapts = zip(operands, refs).allSatisfy {
            $1.key == .any || $1.key == .number || ($1.key == .integer && $0.is(IntegerLiteralExprSyntax.self))
        }
        return floating && adapts ? TypeRef(key: .number) : TypeRef()
    }
}

final class TypeCollector: SyntaxVisitor {
    var types: [String: TypeRef] = [:]
    let skipBodies: Bool
    var fileTypes: [String: TypeRef] = [:]
    let index: TypeIndex
    var arrays: Set<String> = []
    var notArrays: Set<String> = []
    var c: CTypes?
    var functions: [String: [TypeIndex.Method]] = [:]
    init(skipBodies: Bool, fileTypes: [String: TypeRef] = [:], index: TypeIndex) {
        self.skipBodies = skipBodies
        self.fileTypes = fileTypes
        self.index = index
        super.init(viewMode: .sourceAccurate)
    }

    func record(_ name: String, _ ref: TypeRef) {
        types[name] = types[name].map { $0.unified(with: ref) } ?? ref
    }

    /// The environment as built so far: later bindings see earlier ones.
    private var env: TypeEnv {
        var env = TypeEnv()
        env.local = types
        env.file = fileTypes
        env.index = index
        env.functions = functions
        env.c = c
        return env
    }

    /// Functions nested in the analysed body (the analysed function itself is not walked) are local functions.
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if skipBodies { return .skipChildren }
        let parameters = node.signature.parameterClause.parameters.map {
            (label: $0.firstName.text, optional: $0.defaultValue != nil || $0.ellipsis != nil)
        }
        let returns = node.signature.returnClause.map { TypeRef.of($0.type) } ?? TypeRef()
        functions[node.name.text, default: []].append(TypeIndex.Method(parameters: parameters, returns: returns))
        return .visitChildren
    }
    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind { skipBodies ? .skipChildren : .visitChildren }
    override func visit(_ node: AccessorDeclSyntax) -> SyntaxVisitorContinueKind { skipBodies ? .skipChildren : .visitChildren }

    /// Untyped closure parameters shadow outer names and have no known type.
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        if skipBodies { return .skipChildren }
        switch node.signature?.parameterClause {
        case .simpleInput(let list):
            for parameter in list { record(parameter.name.text, TypeRef()) }
        case .parameterClause(let clause):
            for parameter in clause.parameters {
                record((parameter.secondName ?? parameter.firstName).text, parameter.type.map(TypeRef.of) ?? TypeRef())
            }
        case nil:
            break
        }
        return .visitChildren
    }

    /// `if let x = e` / `guard let x = e`: `x` has the type of `e` (stripped of its optionality).
    override func visit(_ node: OptionalBindingConditionSyntax) -> SyntaxVisitorContinueKind {
        guard let name = node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { return .visitChildren }
        if let initializer = node.initializer {
            record(name, env.ref(initializer.value))
        } else {
            record(name, types[name] ?? fileTypes[name] ?? TypeRef())
        }
        notArrays.insert(name)
        return .visitChildren
    }

    /// `for x in xs`: `x` is an element of `xs`.
    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        if let tuple = node.pattern.as(TuplePatternSyntax.self) {
            bind(tuple, to: nil)
        } else if let name = node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text {
            record(name, env.ref(node.sequence).element?.ref ?? TypeRef())
            notArrays.insert(name)
        }
        return .visitChildren
    }

    /// `let (a, b) = e`: the members of `e`'s tuple type by position, else unknown.
    private func bind(_ pattern: TuplePatternSyntax, to initializer: ExprSyntax?) {
        let tuple = initializer.flatMap { env.ref($0).tuple }
        for (position, element) in pattern.elements.enumerated() {
            guard let name = element.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
            record(name, tuple.flatMap { position < $0.refs.count ? $0.refs[position] : nil } ?? TypeRef())
            notArrays.insert(name)
        }
    }

    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        if let tuple = node.pattern.as(TuplePatternSyntax.self) {
            bind(tuple, to: node.initializer?.value)
            return .visitChildren
        }
        guard let name = node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { return .visitChildren }
        if let annotation = node.typeAnnotation {
            record(name, TypeRef.of(annotation.type))
            if annotation.type.is(ArrayTypeSyntax.self) { arrays.insert(name) } else { notArrays.insert(name) }
        } else if let initializer = node.initializer {
            if initializer.value.is(ArrayExprSyntax.self) { arrays.insert(name) } else { notArrays.insert(name) }
            record(name, env.ref(initializer.value))
        } else {
            record(name, TypeRef())
        }
        return .visitChildren
    }
}
