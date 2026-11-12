import Foundation
import SwiftSyntax

/// Types of locals, parameters, file-level properties and expressions (REQ-RPC-007).
struct TypeEnv {
    var local: [String: TypeRef] = [:]
    /// Bindings made inside a closure body, by closure: visible to the expressions inside that closure.
    var closureLocal: [SyntaxIdentifier: [String: TypeRef]] = [:]
    var file: [String: TypeRef] = [:]
    var index = TypeIndex()
    var c: CTypes?
    /// Functions declared inside the function being analysed.
    var functions: [String: [TypeIndex.Method]] = [:]
    /// Locals bound to a no-parameter closure: the type of calling it (`let elapsed = { Int(x) }`).
    var closureResults: [String: TypeRef] = [:]
    /// The type whose member the analysed function is: a bare call `f()` resolves to its own member first.
    var enclosing: String?
    /// The value type of `base["key"]` from the key set of `base` (the extractor's own dictionary analysis).
    var shape: ((SubscriptCallExprSyntax) -> TypeRef?)?
    /// Names declared as a non-optional array (`[T]` annotation, array literal): `.map` on them is an array.
    var arrays: Set<String> = []
    /// How many `Any`-returning bodies are being followed.
    var depth = 0

    init() {}

    /// - Parameters:
    ///   - skipping: `switch` cases whose locals are out of scope (the other arms of the analysed one).
    ///   - constants: parameters the analysed call site passes a literal for (`f(nil)`): their type there.
    init(
        function: FunctionDeclSyntax, tree: SourceFileSyntax, index: TypeIndex, c: CTypes? = nil,
        skipping: Set<SyntaxIdentifier> = [], shape: ((SubscriptCallExprSyntax) -> TypeRef?)? = nil,
        constants: [String: TypeRef] = [:]
    ) {
        self.index = index
        self.c = c
        self.shape = shape
        enclosing = Self.enclosingType(of: function)
        let fileLevel = TypeCollector(skipBodies: true, index: index)
        fileLevel.c = c
        fileLevel.walk(tree)
        file = fileLevel.types
        let locals = TypeCollector(skipBodies: false, fileTypes: file, index: index)
        locals.c = c
        locals.enclosing = enclosing
        locals.skipping = skipping
        locals.shape = shape
        for parameter in function.signature.parameterClause.parameters {
            let name = (parameter.secondName ?? parameter.firstName).text
            locals.record(name, constants[name] ?? TypeRef.of(parameter.type))
            if parameter.type.is(ArrayTypeSyntax.self) { locals.arrays.insert(name) } else { locals.notArrays.insert(name) }
        }
        if let body = function.body { locals.walk(body) }
        local = locals.types
        closureLocal = locals.closureTypes
        functions = locals.functions
        closureResults = locals.closureResults
        arrays = locals.arrays.subtracting(locals.notArrays)
    }

    private static func enclosingType(of function: FunctionDeclSyntax) -> String? {
        var current = function.parent
        while let node = current {
            if let decl = node.as(StructDeclSyntax.self) { return decl.name.text }
            if let decl = node.as(ClassDeclSyntax.self) { return decl.name.text }
            if let decl = node.as(EnumDeclSyntax.self) { return decl.name.text }
            if let decl = node.as(ActorDeclSyntax.self) { return decl.name.text }
            if let decl = node.as(ExtensionDeclSyntax.self) {
                return TypeRef.of(decl.extendedType).nominal ?? decl.extendedType.trimmedDescription
            }
            current = node.parent
        }
        return nil
    }

    static func type(of type: TypeSyntax) -> KeyType {
        if let optional = type.as(OptionalTypeSyntax.self) { return Self.type(of: optional.wrappedType) }
        if let optional = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) { return Self.type(of: optional.wrappedType) }
        if type.is(ArrayTypeSyntax.self) { return .array }
        if type.is(DictionaryTypeSyntax.self) { return .object }
        guard let name = type.as(IdentifierTypeSyntax.self)?.name.text else { return .any }
        switch name {
        case "Int", "UInt", "Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16", "UInt32", "UInt64": return .integer
        case "Double", "Float", "CGFloat", "TimeInterval", "CFTimeInterval", "CFAbsoluteTime": return .number
        case "Bool": return .boolean
        case "String": return .string
        default: return .any
        }
    }

    func infer(_ expression: ExprSyntax) -> KeyType { ref(expression).key }

    /// The key type and whether the value can be nil/NSNull.
    func inferKey(_ expression: ExprSyntax) -> (type: KeyType, nullable: Bool) {
        let found = ref(expression)
        return (found.key, found.nullable)
    }

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
        "starts": .boolean, "mapValues": .object, "sorted": .array, "compactMap": .array, "components": .array, "split": .array,
    ]

    func ref(_ expression: ExprSyntax) -> TypeRef {
        var found = plainRef(expression)
        if chained(expression) { found.optional = true }
        return found
    }

    /// `a?.b`, `a?.b.c()`: the access hangs off an optional chain, so its result is an Optional.
    private func chained(_ expression: ExprSyntax) -> Bool {
        let base: ExprSyntax?
        if let member = expression.as(MemberAccessExprSyntax.self) {
            base = member.base
        } else if let call = expression.as(FunctionCallExprSyntax.self) {
            base = call.calledExpression
        } else if let subscripted = expression.as(SubscriptCallExprSyntax.self) {
            base = subscripted.calledExpression
        } else {
            return false
        }
        guard let base else { return false }
        return base.is(OptionalChainingExprSyntax.self) || chained(base)
    }

    private func plainRef(_ expression: ExprSyntax) -> TypeRef {
        if expression.is(StringLiteralExprSyntax.self) { return TypeRef(key: .string) }
        if expression.is(IntegerLiteralExprSyntax.self) { return TypeRef(key: .integer) }
        if expression.is(FloatLiteralExprSyntax.self) { return TypeRef(key: .number) }
        if expression.is(BooleanLiteralExprSyntax.self) { return TypeRef(key: .boolean) }
        if expression.is(NilLiteralExprSyntax.self) { return .nilValue }
        if let array = expression.as(ArrayExprSyntax.self) { return ref(array) }
        if let dictionary = expression.as(DictionaryExprSyntax.self) { return ref(dictionary) }
        if let branch = expression.as(SwitchExprSyntax.self) {
            return Self.joined(branch.cases.compactMap { $0.as(SwitchCaseSyntax.self) }.map { branchRef($0) })
        }
        if let branch = expression.as(IfExprSyntax.self) { return ref(branch) }
        if let prefix = expression.as(PrefixOperatorExprSyntax.self) {
            if prefix.operator.text == "!" { return TypeRef(key: .boolean) }
            if prefix.operator.text == "-" { return ref(prefix.expression) }
        }
        if let tuple = expression.as(TupleExprSyntax.self), tuple.elements.count == 1, let only = tuple.elements.first {
            return ref(only.expression)
        }
        if let unwrap = expression.as(ForceUnwrapExprSyntax.self) {
            var inner = ref(unwrap.expression)
            inner.nullable = false
            inner.optional = false
            return inner
        }
        if let chain = expression.as(OptionalChainingExprSyntax.self) { return ref(chain.expression) }
        if let wrapped = expression.as(TryExprSyntax.self) {
            var inner = ref(wrapped.expression)
            if wrapped.questionOrExclamationMark?.text == "?" { inner.optional = true }
            return inner
        }
        if let wrapped = expression.as(AwaitExprSyntax.self) { return ref(wrapped.expression) }
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return closureScoped(reference) ?? local[reference.baseName.text] ?? file[reference.baseName.text] ?? TypeRef()
        }
        if let member = expression.as(MemberAccessExprSyntax.self) { return ref(member) }
        if let call = expression.as(FunctionCallExprSyntax.self) { return ref(call) }
        if let subscripted = expression.as(SubscriptCallExprSyntax.self) {
            if let found = shape?(subscripted) { return found }
            let base = ref(subscripted.calledExpression)
            // A dictionary subscript is an Optional of the value type.
            if var value = base.value?.ref {
                value.optional = true
                return value
            }
            // An element of an array whose element type is known.
            return base.element?.ref ?? TypeRef()
        }
        if let sequence = expression.as(SequenceExprSyntax.self) { return ref(Array(sequence.elements)) }
        return TypeRef()
    }

    /// The binding of `reference` made inside the innermost enclosing closure that makes one.
    private func closureScoped(_ reference: DeclReferenceExprSyntax) -> TypeRef? {
        guard !closureLocal.isEmpty else { return nil }
        var current = reference.parent
        while let node = current {
            if let closure = node.as(ClosureExprSyntax.self), let found = closureLocal[closure.id]?[reference.baseName.text] {
                return found
            }
            current = node.parent
        }
        return nil
    }

    /// `Type` named in an expression that is not a local: `ProcessInfo` in `ProcessInfo.processInfo`.
    func typeName(_ expression: ExprSyntax?) -> String? {
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
            if name == "NSNull", call.arguments.isEmpty { return TypeRef(key: .null) }
            let converted = Self.type(of: TypeSyntax(IdentifierTypeSyntax(name: .identifier(name))))
            if converted != .any { return TypeRef(key: converted) }
            if name == "Array" { return TypeRef(key: .array) }
            if local[name] == nil, file[name] == nil, index.isType(name) { return TypeRef(nominal: name) }
            if call.arguments.isEmpty, call.trailingClosure == nil, let result = closureResults[name] { return result }
            if let nested = functions[name]?.filter({ TypeIndex.accepts($0, call) }), !nested.isEmpty {
                return returns(nested, call)
            }
            if ["min", "max", "abs"].contains(name) { return arithmetic(call.arguments.map(\.expression)) }
            if let key = TypeEnv.freeCalls[name] { return TypeRef(key: key) }
            if let enclosing {
                let own = index.candidates(type: enclosing, name: name, call: call)
                if !own.isEmpty { return returns(own, call) }
            }
            let found = index.candidates(type: nil, name: name, call: call)
            if !found.isEmpty { return returns(found, call) }
            return c?.returnType(name) ?? TypeRef()
        }
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self) else { return TypeRef() }
        let name = member.declName.baseName.text
        let base = member.base
        if let type = typeName(base) {
            return returns(index.candidates(type: type, name: name, call: call), call)
        }
        if let base {
            if base.as(DeclReferenceExprSyntax.self)?.baseName.text == "self" {
                return returns(index.candidates(type: nil, name: name, call: call), call)
            }
            if let nominal = ref(base).nominal {
                let found = index.candidates(type: nominal, name: name, call: call)
                if !found.isEmpty { return returns(found, call) }
            }
            if let result = higherOrder(name, base, call) { return result }
            // `x.rounded()` and friends keep the number type of `x`.
            if ["rounded", "squareRoot", "magnitude"].contains(name), call.arguments.isEmpty || name == "rounded" {
                let receiver = ref(base).key
                if receiver == .number || receiver == .integer { return TypeRef(key: receiver) }
            }
            if let nominal = ref(base).nominal, let found = TypeIndex.builtinMethods[nominal]?[name] { return found }
        }
        if let key = TypeEnv.methodTypes[name] { return TypeRef(key: key) }
        return TypeRef()
    }

    /// The return type of the candidates reached by `call`. A lone candidate that returns `Any` by switching on its
    /// first parameter's dynamic type (`switch value { case let x as [String: Any]: ... }`) returns, for a call whose
    /// argument has a known array or dictionary type, the type of the one arm that argument selects.
    private func returns(_ methods: [TypeIndex.Method], _ call: FunctionCallExprSyntax) -> TypeRef {
        let general = TypeIndex.returns(methods)
        guard general.key == .any, general.nominal == nil || general.nominal == "Any",
              let decl = methods.first?.decl,
              // The same declaration may be indexed twice (the producer's file is also a lookup source).
              methods.allSatisfy({ $0.decl?.trimmedDescription == decl.trimmedDescription }) else { return general }
        return switched(decl, call, general) ?? returned(by: decl) ?? general
    }

    /// The arm of a `switch` on the parameter's dynamic type that the call's argument selects.
    private func switched(_ decl: FunctionDeclSyntax, _ call: FunctionCallExprSyntax, _ general: TypeRef) -> TypeRef? {
        guard let parameter = decl.signature.parameterClause.parameters.first,
              let argument = call.arguments.first?.expression,
              let item = decl.body?.statements.first, decl.body?.statements.count == 1,
              let subject = (item.item.as(ExpressionStmtSyntax.self)?.expression ?? item.item.as(ExprSyntax.self))?.as(SwitchExprSyntax.self)
        else { return nil }
        let name = (parameter.secondName ?? parameter.firstName).text
        guard subject.subject.as(DeclReferenceExprSyntax.self)?.baseName.text == name else { return nil }
        let actual = ref(argument)
        guard actual.key == .array || actual.key == .object, !actual.optional else { return nil }
        let scalars: Set<String> = ["NSNumber", "Data", "Date", "NSNull", "URL", "UUID"]
        for arm in subject.cases.compactMap({ $0.as(SwitchCaseSyntax.self) }) {
            guard case .case(let label) = arm.label, label.caseItems.count == 1, let pattern = label.caseItems.first?.pattern,
                  let (binding, cast) = Self.castPattern(pattern)
            else { return nil }
            let declared = TypeRef.of(cast)
            if declared.key == actual.key {
                var inner = self
                if let binding { inner.local[binding] = actual }
                return inner.branchRef(arm.statements)
            }
            // An earlier arm must be unable to match a collection.
            guard [.string, .integer, .number, .boolean].contains(declared.key)
                    || declared.nominal.map(scalars.contains) == true
            else { return nil }
        }
        return nil
    }

    /// What an `Any`-returning function returns when every `return` in its body has the same known type
    /// (`do { return try f() } catch { return ["error": e] }` is an object either way).
    private func returned(by decl: FunctionDeclSyntax) -> TypeRef? {
        guard depth < 3, let body = decl.body, let tree = decl.root.as(SourceFileSyntax.self) else { return nil }
        let collector = ReturnExpressions()
        collector.walk(body)
        guard !collector.expressions.isEmpty else { return nil }
        var inner = TypeEnv(function: decl, tree: tree, index: index, c: c)
        inner.depth = depth + 1
        inner.shape = nil
        let refs = collector.expressions.map { inner.ref($0) }
        let result = Self.joined(refs)
        return result.key == .any ? nil : result
    }

    /// `case let x as T` and `case is T`: the binding name and the type.
    private static func castPattern(_ pattern: PatternSyntax) -> (String?, TypeSyntax)? {
        if let test = pattern.as(IsTypePatternSyntax.self) { return (nil, test.type) }
        guard let binding = pattern.as(ValueBindingPatternSyntax.self),
              let cast = binding.pattern.as(ExpressionPatternSyntax.self)?.expression.as(SequenceExprSyntax.self)
        else { return nil }
        let parts = Array(cast.elements)
        guard parts.count == 3, parts[1].is(UnresolvedAsExprSyntax.self), let type = parts[2].as(TypeExprSyntax.self),
              let name = parts[0].as(PatternExprSyntax.self)?.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
                ?? parts[0].as(DeclReferenceExprSyntax.self)?.baseName.text
        else { return nil }
        return (name, type.type)
    }

    /// A non-optional array: literal, declared array name, or an expression of a known array type.
    private func isArray(_ expression: ExprSyntax) -> Bool {
        if expression.is(ArrayExprSyntax.self) { return true }
        if let reference = expression.as(DeclReferenceExprSyntax.self), arrays.contains(reference.baseName.text) { return true }
        let found = ref(expression)
        return found.key == .array && !found.optional
    }

    /// A non-optional Sequence whose `map`/`filter`/`compactMap` produce an Array: an array, `enumerated()`, a
    /// dictionary's `keys`/`values`.
    private func isSequence(_ expression: ExprSyntax) -> Bool {
        if isArray(expression) { return true }
        if let call = expression.as(FunctionCallExprSyntax.self), let member = call.calledExpression.as(MemberAccessExprSyntax.self),
           member.declName.baseName.text == "enumerated", call.arguments.isEmpty, let base = member.base {
            return isArray(base)
        }
        if let member = expression.as(MemberAccessExprSyntax.self), ["keys", "values"].contains(member.declName.baseName.text),
           let base = member.base {
            let receiver = ref(base)
            return receiver.key == .object && receiver.value != nil && !receiver.optional
        }
        return false
    }

    /// `x.map { }` on an Optional gives an Optional of the closure result; on a Sequence, an Array.
    private func higherOrder(_ name: String, _ base: ExprSyntax, _ call: FunctionCallExprSyntax) -> TypeRef? {
        let closure = call.trailingClosure ?? call.arguments.last?.expression.as(ClosureExprSyntax.self)
        let receiver = ref(base)
        // `optional.flatMap(Type.init(label:))`: an optional of that type.
        if receiver.optional, !chained(base), ["map", "flatMap"].contains(name), closure == nil,
           let member = call.arguments.first?.expression.as(MemberAccessExprSyntax.self),
           member.declName.baseName.text == "init", let type = typeName(member.base) {
            return TypeRef(nominal: type, optional: true)
        }
        if receiver.optional, !chained(base), ["map", "flatMap"].contains(name), let closure {
            var wrapped = receiver
            wrapped.optional = false
            wrapped.nullable = false
            var result = closureResult(closure, argument: wrapped)
            result.optional = true
            return result
        }
        // `reduce(into:)` is its initial value's type.
        if name == "reduce", call.arguments.first?.label?.text == "into", let initial = call.arguments.first?.expression,
           isSequence(base) {
            return ref(initial)
        }
        // A non-optional dictionary: `sorted`/`map`/`compactMap`/`flatMap` give an Array.
        if receiver.key == .object, receiver.value != nil, !receiver.optional,
           ["sorted", "map", "compactMap", "flatMap"].contains(name) {
            return TypeRef(key: .array)
        }
        guard isSequence(base) else { return nil }
        switch name {
        case "map":
            guard let closure else { return TypeRef(key: .array) }
            let mapped = closureResult(closure, argument: receiver.element?.ref ?? TypeRef())
            return mapped.key == .any && mapped.nominal == nil ? TypeRef(key: .array) : TypeRef(key: .array, element: mapped)
        case "compactMap", "flatMap": return TypeRef(key: .array)
        case "filter", "reversed", "sorted", "prefix", "suffix", "dropFirst", "dropLast":
            return receiver.key == .array ? receiver : TypeRef(key: .array)
        case "first", "last":
            guard call.arguments.first?.label?.text == "where", var element = receiver.element?.ref else { return nil }
            element.optional = true
            return element
        default: return nil
        }
    }

    /// The type a closure returns when called with `argument`: its declared return type, else its single expression.
    func closureResult(_ closure: ClosureExprSyntax, argument: TypeRef) -> TypeRef {
        if let returned = closure.signature?.returnClause?.type { return TypeRef.of(returned) }
        guard closure.statements.count == 1, let item = closure.statements.first?.item else { return TypeRef() }
        var inner = self
        switch closure.signature?.parameterClause {
        case .simpleInput(let list):
            if let first = list.first { inner.closureLocal[closure.id, default: [:]][first.name.text] = argument }
        case .parameterClause(let clause):
            if let first = clause.parameters.first {
                inner.closureLocal[closure.id, default: [:]][(first.secondName ?? first.firstName).text] = argument
            }
        case nil:
            inner.local["$0"] = argument
        }
        return inner.branchRef([item]) ?? TypeRef()
    }

    /// The type of a branch or closure body of one expression; nil when it cannot produce a value (`throw`, `fatalError`).
    private func branchRef(_ statements: CodeBlockItemListSyntax) -> TypeRef? { branchRef(Array(statements.map(\.item))) }

    private func branchRef(_ items: [CodeBlockItemSyntax.Item]) -> TypeRef? {
        guard items.count == 1, let item = items.first else { return TypeRef() }
        switch item {
        case .expr(let expression):
            if let call = expression.as(FunctionCallExprSyntax.self),
               call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "fatalError" { return nil }
            return ref(expression)
        case .stmt(let statement):
            if statement.is(ThrowStmtSyntax.self) { return nil }
            if let returned = statement.as(ReturnStmtSyntax.self)?.expression { return ref(returned) }
            return TypeRef()
        case .decl:
            return TypeRef()
        }
    }

    /// What several branches agree on; branches that cannot produce a value are skipped.
    static func joined(_ refs: [TypeRef?]) -> TypeRef {
        let known = refs.compactMap { $0 }
        guard var result = known.first else { return TypeRef() }
        for other in known.dropFirst() { result = result.unified(with: other) }
        return result
    }

    private func ref(_ array: ArrayExprSyntax) -> TypeRef {
        let refs = array.elements.map { ref($0.expression) }
        guard var element = refs.first else { return TypeRef(key: .array) }
        for other in refs.dropFirst() { element = element.unified(with: other) }
        return element.key == .any && element.nominal == nil ? TypeRef(key: .array) : TypeRef(key: .array, element: element)
    }

    /// A dictionary literal whose values agree has that value type.
    private func ref(_ dictionary: DictionaryExprSyntax) -> TypeRef {
        guard case .elements(let elements) = dictionary.content, var value = elements.first.map({ ref($0.value) }) else {
            return TypeRef(key: .object)
        }
        for element in elements.dropFirst() { value = value.unified(with: ref(element.value)) }
        return value.key == .any && value.nominal == nil ? TypeRef(key: .object) : TypeRef(key: .object, value: value)
    }

    private func branchRef(_ branch: SwitchCaseSyntax) -> TypeRef? { branchRef(branch.statements) }

    private func ref(_ branch: IfExprSyntax) -> TypeRef {
        guard let other = branch.elseBody else { return TypeRef() }
        let rest: TypeRef?
        switch other {
        case .codeBlock(let block): rest = branchRef(block.statements)
        case .ifExpr(let chained): rest = ref(chained)
        }
        return Self.joined([branchRef(branch.body.statements), rest])
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
            return then.key == otherwise.key || then.key == .null || otherwise.key == .null
                ? then.unified(with: otherwise) : TypeRef()
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
            // `nil ?? x` is `x` (a parameter the call site passes `nil` for).
            if value.none { return other }
            // `x ?? [:]` / `x ?? []` keep what is known of `x`.
            if value.key == other.key, (fallback.as(DictionaryExprSyntax.self).map { if case .colon = $0.content { true } else { false } } ?? false)
                || fallback.as(ArrayExprSyntax.self)?.elements.isEmpty == true {
                var kept = value
                kept.optional = false
                return kept
            }
            // `x ?? NSNull()` / `x ?? nil` is nullable; any other fallback removes the nil of `x`.
            if value.key == other.key || other.key == .null {
                var joined = value.unified(with: other)
                joined.nullable = other.key == .null || other.nullable
                joined.optional = other.optional
                return joined
            }
            return value.key == .number && fallback.is(IntegerLiteralExprSyntax.self) ? TypeRef(key: .number) : TypeRef()
        }
        if let mark = parts.firstIndex(where: { $0.is(UnresolvedAsExprSyntax.self) }), mark + 1 < parts.count,
           let type = parts[mark + 1].as(TypeExprSyntax.self) {
            // `x as Any` keeps the type of `x`; `x as Any?` also marks it nullable.
            if type.type.as(IdentifierTypeSyntax.self)?.name.text == "Any" { return ref(sub(parts[..<mark])) }
            if let optional = type.type.as(OptionalTypeSyntax.self),
               optional.wrappedType.as(IdentifierTypeSyntax.self)?.name.text == "Any" {
                var inner = ref(sub(parts[..<mark]))
                inner.nullable = true
                return inner
            }
            var cast = TypeRef.of(type.type)
            if parts[mark].as(UnresolvedAsExprSyntax.self)?.questionOrExclamationMark?.text == "?" { cast.optional = true }
            return cast
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
    /// The type whose member the analysed function is: a bare call in a binding resolves to its own member first.
    var enclosing: String?
    var skipping: Set<SyntaxIdentifier> = []
    var shape: ((SubscriptCallExprSyntax) -> TypeRef?)?
    var functions: [String: [TypeIndex.Method]] = [:]
    var closureResults: [String: TypeRef] = [:]
    init(skipBodies: Bool, fileTypes: [String: TypeRef] = [:], index: TypeIndex) {
        self.skipBodies = skipBodies
        self.fileTypes = fileTypes
        self.index = index
        super.init(viewMode: .sourceAccurate)
    }

    /// Bindings made inside a closure body, by the innermost closure: they shadow outer names only there.
    var closureTypes: [SyntaxIdentifier: [String: TypeRef]] = [:]
    private var closureStack: [SyntaxIdentifier] = []

    private func known(_ name: String) -> TypeRef? {
        closureStack.last.flatMap { closureTypes[$0]?[name] } ?? types[name]
    }

    private func set(_ name: String, _ ref: TypeRef) {
        if let top = closureStack.last { closureTypes[top, default: [:]][name] = ref } else { types[name] = ref }
    }

    func record(_ name: String, _ ref: TypeRef) {
        let own = closureStack.last.flatMap { closureTypes[$0]?[name] } ?? (closureStack.isEmpty ? types[name] : nil)
        set(name, own.map { $0.unified(with: ref) } ?? ref)
    }

    /// The environment as built so far: later bindings see earlier ones.
    private var env: TypeEnv {
        var env = TypeEnv()
        env.local = types
        env.closureLocal = closureTypes
        env.file = fileTypes
        env.index = index
        env.functions = functions
        env.closureResults = closureResults
        env.c = c
        env.enclosing = enclosing
        env.shape = shape
        return env
    }

    /// Functions nested in the analysed body (the analysed function itself is not walked) are local functions.
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if skipBodies { return .skipChildren }
        let parameters = node.signature.parameterClause.parameters.map {
            (label: $0.firstName.text, optional: $0.defaultValue != nil || $0.ellipsis != nil)
        }
        let returns = node.signature.returnClause.map { TypeRef.of($0.type) } ?? TypeRef()
        functions[node.name.text, default: []].append(TypeIndex.Method(parameters: parameters, returns: returns, decl: node))
        return .visitChildren
    }
    override func visit(_ node: SwitchCaseSyntax) -> SyntaxVisitorContinueKind { skipping.contains(node.id) ? .skipChildren : .visitChildren }
    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind { skipBodies ? .skipChildren : .visitChildren }
    override func visit(_ node: AccessorDeclSyntax) -> SyntaxVisitorContinueKind { skipBodies ? .skipChildren : .visitChildren }

    /// Untyped closure parameters shadow outer names and have no known type.
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        closureStack.append(node.id)
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

    override func visitPost(_ node: ClosureExprSyntax) { closureStack.removeLast() }

    /// `if let x = e` / `guard let x = e`: `x` has the type of `e` (stripped of its optionality).
    override func visit(_ node: OptionalBindingConditionSyntax) -> SyntaxVisitorContinueKind {
        guard let name = node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { return .visitChildren }
        let bound = node.initializer.map { env.ref($0.value) } ?? known(name) ?? fileTypes[name] ?? TypeRef()
        // The binding shadows the optional it unwraps: from here on the name is non-nil.
        var unwrapped = known(name).map { $0.unified(with: bound) } ?? bound
        unwrapped.optional = false
        unwrapped.nullable = false
        set(name, unwrapped)
        notArrays.insert(name)
        return .visitChildren
    }

    /// `catch let error as T`: `error` is a `T`.
    override func visit(_ node: CatchItemSyntax) -> SyntaxVisitorContinueKind {
        guard let binding = node.pattern?.as(ValueBindingPatternSyntax.self),
              let cast = binding.pattern.as(ExpressionPatternSyntax.self)?.expression.as(SequenceExprSyntax.self)
        else { return .visitChildren }
        let parts = Array(cast.elements)
        // `catch let error as T` parses `error` as a pattern; a plain reference is the same binding.
        let bound = parts.first.flatMap {
            $0.as(PatternExprSyntax.self)?.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
                ?? $0.as(DeclReferenceExprSyntax.self)?.baseName.text
        }
        if parts.count == 3, let name = bound,
           parts[1].is(UnresolvedAsExprSyntax.self), let type = parts[2].as(TypeExprSyntax.self) {
            record(name, TypeRef.of(type.type))
            notArrays.insert(name)
        }
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
        if let annotation = node.typeAnnotation, Self.isAny(annotation.type), let initializer = node.initializer {
            // `let x: Any = e` boxes `e`: the dynamic type stays that of `e`.
            record(name, env.ref(initializer.value))
            notArrays.insert(name)
        } else if let annotation = node.typeAnnotation {
            record(name, TypeRef.of(annotation.type))
            if annotation.type.is(ArrayTypeSyntax.self) { arrays.insert(name) } else { notArrays.insert(name) }
        } else if let initializer = node.initializer {
            if initializer.value.is(ArrayExprSyntax.self) { arrays.insert(name) } else { notArrays.insert(name) }
            if let closure = initializer.value.as(ClosureExprSyntax.self), closure.signature == nil {
                closureResults[name] = env.closureResult(closure, argument: TypeRef())
            }
            record(name, env.ref(initializer.value))
        } else {
            record(name, TypeRef())
        }
        return .visitChildren
    }

    private static func isAny(_ type: TypeSyntax) -> Bool {
        let base = type.as(OptionalTypeSyntax.self)?.wrappedType ?? type
        return base.as(IdentifierTypeSyntax.self)?.name.text == "Any"
    }
}

/// The `return` expressions of one function body, not entering closures or nested functions.
final class ReturnExpressions: SyntaxVisitor {
    var expressions: [ExprSyntax] = []
    init() { super.init(viewMode: .sourceAccurate) }
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
        if let expression = node.expression { expressions.append(expression) }
        return .skipChildren
    }
}
