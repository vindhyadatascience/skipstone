// Copyright (c) 2026 Vindhya Data Science
// Licensed under the GNU Affero General Public License v3.0
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// An optional receiver for an ordinary member-access AST node. The child is
/// appended once, including when it is a call with side effects.
private final class KotlinHashableCastOptionalReceiver: KotlinExpression {
    let value: KotlinExpression
    init(value: KotlinExpression) {
        self.value = value
        super.init(type: .raw)
    }
    override var children: [KotlinSyntaxNode] { [value] }
    override var optionalChain: KotlinOptionalChain { .explicit }
    override func append(to output: OutputGenerator, indentation: Indentation) {
        output.append("(").append(value, indentation: indentation).append(")?")
    }
}

/// The builtin is a coercion, not a Swift function that already copied its
/// return. Keep the original cast visible and preserve its value-copy decision.
private final class KotlinProvenNonNullAnyCast: KotlinExpression {
    let value: KotlinExpression
    init(value: KotlinExpression) {
        self.value = value
        super.init(type: .raw, sourceFile: value.sourceFile, sourceRange: value.sourceRange)
    }
    override var children: [KotlinSyntaxNode] { [value] }
    override func mayBeSharedMutableStructExpression(orType: Bool) -> Bool {
        value.mayBeSharedMutableStructExpression(orType: orType)
    }
    override func append(to output: OutputGenerator, indentation: Indentation) {
        output.append("kotlin.checkNotNull(").append(value, indentation: indentation).append(")")
    }
}

/// API lowering shared by the normal expression translator. Runtime semantics live
/// in SkipLib; these nodes preserve Swift conversions and writeback at call sites.
enum KotlinStandardLibraryParity {
    static func translateFunctionCall(expression: FunctionCall, translator: KotlinTranslator) -> KotlinExpression? {
        let constructorType = canonicalType(expression.function.inferredType)
        if constructorType.isMetaType,
           constructorType.asMetaType(false).withModuleName(nil) == .int,
           expression.arguments.count == 1, expression.arguments[0].label == "exactly",
           !expression.arguments[0].value.inferredType.isOptional,
           expression.arguments[0].value.inferredType.isNumeric {
            let result = KotlinFunctionCall(function: KotlinParityRuntimeFunction(name: "IntExactly"), arguments: [
                LabeledValue(label: "exactly", value: translator.translateExpression(expression.arguments[0].value)),
            ])
            result.inferredType = .optional(.int)
            return result
        }
        if constructorType.isMetaType, isAnyHashable(constructorType.asMetaType(false)),
           expression.arguments.count == 1,
           expression.arguments[0].value.inferredType.isOptional {
            let argument = expression.arguments[0].value
            return anyHashableConversion(translator.translateExpression(argument), expression: expression,
                actualType: erasureSourceType(of: argument), optionalTarget: false)
        }
        if let member = expression.function as? MemberAccess,
           member.member == "append", member.baseType.isSameType(as: .string, withoutOptionality: true),
           let receiver = member.base, expression.arguments.count == 1,
           expression.arguments[0].label == nil || expression.arguments[0].label == "contentsOf" {
            return KotlinStringAppendParity(expression: expression, receiver: receiver, translator: translator)
        }
        guard isDictionaryConstructor(expression.function), expression.arguments.count == 2,
              expression.arguments[0].label == "grouping",
              expression.arguments[1].label == "by" || expression.trailingClosureCount == 1 else { return nil }
        // Do not forward Dictionary<Key, Value>'s explicit generics: the factory
        // infers <Key, Element>, and Value here is already Array<Element>.
        let arguments = expression.arguments.enumerated().map { index, argument in
            let value = translator.translateExpression(argument.value)
            if index == 1, let closure = value as? KotlinClosure, closure.isAnonymousFunction,
               closure.parameters.count == 1, closure.parameters[0].declaredType == .none {
                // Kotlin's anonymous functions require explicit parameter types,
                // even when Swift spells only a return type (`value -> Int in`).
                // The grouping sequence proves this parameter's element type.
                let element = expression.arguments[0].value.inferredType.elementType
                if element != .none { closure.parameters[0].declaredType = element }
            }
            return LabeledValue(label: index == 0 ? "grouping" : "by", value: value)
        }
        let result = KotlinFunctionCall(function: KotlinParityRuntimeFunction(name: "dictionaryGrouping"), arguments: arguments)
        result.hasTrailingClosures = expression.trailingClosureCount > 0
        result.inferredType = expression.inferredType
        result.mayBeSharedMutableStructType = true
        return result
    }

    private static func isDictionaryConstructor(_ function: Expression) -> Bool {
        // The standard Dictionary specialization has a metatype even when
        // isolated metadata cannot resolve its grouping initializer overload.
        guard function.inferredType.isMetaType else { return false }
        if case .dictionary = canonicalType(function.inferredType.asMetaType(false)).withModuleName(nil) { return true }
        return false
    }

    static func translateEquality(expression: BinaryOperator, translator: KotlinTranslator) -> KotlinExpression? {
        guard expression.op.symbol == "==" || expression.op.symbol == "!=",
              !(expression.lhs is NilLiteral), !(expression.rhs is NilLiteral),
              requiresSwiftEquality(erasureSourceType(of: expression.lhs), in: expression)
                || requiresSwiftEquality(erasureSourceType(of: expression.rhs), in: expression) else { return nil }
        let result = KotlinFunctionCall(function: KotlinParityRuntimeFunction(name: "swiftEquatableEquals"), arguments: [
            LabeledValue(value: translator.translateExpression(expression.lhs)),
            LabeledValue(value: translator.translateExpression(expression.rhs)),
        ])
        result.inferredType = .bool
        return expression.op.symbol == "!=" ? result.logicalNegated() : result
    }

    static func translateExplicitHashableCast(expression: BinaryOperator, translator: KotlinTranslator) -> KotlinExpression? {
        guard expression.op.symbol == "as", let target = expression.rhs as? TypeLiteral else { return nil }
        // A same-named user type does not denote the standard erasure wrapper.
        if let info = translator.codebaseInfo?.primaryTypeInfo(forNamed: target.literal.withoutOptionality()),
           info.moduleName != "Swift" && info.moduleName != "SkipLib" { return nil }
        let targetType = canonicalType(target.literal).mappingTypes { type in
            // Builtin-only consumers can retain a parsed module qualifier as a
            // member rather than a module node when no symbol module is loaded.
            guard case .member(let base, let member) = type,
                  base == .named("Swift", []) || base == .named("SkipLib", []),
                  member == .named("AnyHashable", []) else { return nil }
            return member.withModuleName(base.name)
        }
        guard isAnyHashable(targetType) else { return nil }
        let actual = erasureSourceType(of: expression.lhs)
        guard actual != .any && actual != .none else { return nil }
        let value = translator.translateExpression(expression.lhs)
        if actual.isOptional && !targetType.isOptional {
            // `Optional<T> as AnyHashable` erases the Optional itself; a nil
            // payload must remain a typed value rather than a null wrapper.
            return anyHashableConversion(value, expression: expression, actualType: actual, optionalTarget: false)
        }
        return coerce(value, expression: expression.lhs, to: targetType)
    }

    /// Return an unboxed lhs only; retain normal cast/check translation for the
    /// operator and target. This never boxes arbitrary erased input.
    static func knownHashableCastLHS(expression: BinaryOperator, translator: KotlinTranslator) -> KotlinExpression? {
        guard ["as?", "as!", "is"].contains(expression.op.symbol),
              let target = expression.rhs as? TypeLiteral else { return nil }
        let originalSource = erasureSourceType(of: expression.lhs)
        if let info = translator.codebaseInfo?.primaryTypeInfo(forNamed: originalSource.withoutOptionality()),
           info.moduleName != "Swift" && info.moduleName != "SkipLib" { return nil }
        let source = canonicalType(originalSource).mappingTypes { type in
            guard case .member(let base, let member) = type,
                  base == .named("Swift", []) || base == .named("SkipLib", []),
                  member == .named("AnyHashable", []) else { return nil }
            return member.withModuleName(base.name)
        }
        guard isAnyHashable(source),
              !(source.isOptional && source.asOptional(false).isOptional) else { return nil }
        let destination = canonicalType(target.literal)
        guard !destination.isOptional, !isAnyHashable(destination) else { return nil }
        let plain = destination.withModuleName(nil)
        let numericTarget: String?
        switch plain {
        case .bool, .int, .int8, .int16, .int32, .int64,
             .uint, .uint8, .uint16, .uint32, .uint64, .float, .double:
            numericTarget = plain.description
        case .character, .string:
            numericTarget = nil
        case .named, .member:
            // Generic nominal checks are erased by Kotlin; do not introduce a
            // successful unboxing with unproven generic/protocol target shape.
            guard destination.allGenericArguments.isEmpty,
                  !isGenericReference(destination, in: expression),
                  let info = translator.codebaseInfo?.primaryTypeInfo(forNamed: destination),
                  [.classDeclaration, .structDeclaration, .enumDeclaration].contains(info.declarationType) else { return nil }
            numericTarget = nil
        default:
            // Includes Any, AnyObject, protocol existentials and collections.
            return nil
        }
        let translated = translator.translateExpression(expression.lhs)
        if let numericTarget {
            // Numeric dynamic casts use the measured Swift erasure bridge, not
            // an ordinary JVM cast of the stored primitive's original type.
            let converted = KotlinFunctionCall(function: KotlinParityRuntimeFunction(name: "anyHashableCastValue"), arguments: [
                LabeledValue(value: translated),
                LabeledValue(label: "targetSwiftType", value: KotlinStringLiteral(literal: numericTarget)),
            ])
            converted.inferredType = .optional(.any)
            return converted
        }
        let receiver: KotlinExpression
        if source.isOptional {
            receiver = KotlinHashableCastOptionalReceiver(value: translated)
        } else {
            receiver = translated.isCompoundExpression ? KotlinParenthesized(content: translated) : translated
        }
        return KotlinMemberAccess(base: receiver, member: "base")
    }

    private static func requiresSwiftEquality(_ type: TypeSignature, in expression: Expression) -> Bool {
        let plain = type.withoutOptionality().asTypealiased(nil).withModuleName(nil)
        if type.isOptional && (plain == .double || plain == .float) { return true }
        // Any is also the inference fallback for an unresolved expression. It
        // does not prove a generic Equatable operand, and eagerly replacing its
        // comparison can lose contextual enum-member inference during normal
        // translation. Recover declared generic identifiers above instead.
        if isAnyHashable(plain) { return true }
        guard case .named(let name, let arguments) = plain, arguments.isEmpty else { return false }
        if let function = expression.owningFunctionDeclaration as? FunctionDeclaration,
           function.generics.entries.contains(where: { $0.name == name }) { return true }
        var node: SyntaxNode? = expression
        while let declaration = node?.owningTypeDeclaration {
            if declaration.generics.entries.contains(where: { $0.name == name }) { return true }
            node = declaration.parent
        }
        return false
    }

    /// Called once after normal translation, with the expected type of this
    /// source expression. In particular, do not recursively translate `expression`.
    static func coerce(_ value: KotlinExpression, expression: Expression, to expectedType: TypeSignature, sourceType: TypeSignature? = nil) -> KotlinExpression {
        // Kotlin leaves T nullable, but an ordinary forced cast cannot turn an
        // explicitly non-null Any parameter into null. Preserve the existing
        // return-copy step after refining only this proven, direct-return case.
        if canonicalType(expectedType).withModuleName(nil) == .any,
           let cast = expression as? BinaryOperator, cast.op.symbol == "as!",
           let target = cast.rhs as? TypeLiteral,
           !target.literal.isOptional, !target.literal.isUnwrappedOptional,
           isGenericReference(canonicalType(target.literal), in: expression),
           isDirectNonNullAnyParameterCast(cast),
           let ordinary = value as? KotlinBinaryOperator, ordinary.op.symbol == "as!",
           let source = cast.lhs as? Identifier,
           (ordinary.lhs as? KotlinIdentifier)?.name == source.name {
            return KotlinProvenNonNullAnyCast(value: value)
        }
        guard isAnyHashable(expectedType),
              !(expression is NilLiteral), !(value is KotlinAnyHashableParity) else { return value }
        // AnyHashable's implicit conversion is not an ExpressibleByStringLiteral
        // constructor. Preserve the String value, then box it exactly once.
        if let literal = value as? KotlinStringLiteral {
            if literal.expressibleByStringLiteralType.map(isAnyHashable) == true {
                literal.expressibleByStringLiteralType = nil
            }
            if literal.expressibleByStringInterpolationType.map({ isAnyHashable($0.0) }) == true {
                literal.expressibleByStringInterpolationType = nil
            }
        }
        let actual = sourceType ?? erasureSourceType(of: expression)
        if expectedType.isOptional && expectedType.asOptional(false).isOptional {
            value.messages.append(Message(kind: .error,
                message: "Skip cannot preserve nested Optional presence when converting to AnyHashable. Use a single-level Optional or an explicit tagged value.",
                sourceFile: expression.sourceFile, sourceRange: expression.sourceRange))
            return value
        }
        let literal = expression is NumericLiteral || expression is StringLiteral || expression is BooleanLiteral
        if !literal && isAnyHashable(actual) { return value }
        return anyHashableConversion(value, expression: expression, actualType: actual, optionalTarget: expectedType.isOptional)
    }

    /// A declared parameter and a single direct return prove this binding without
    /// treating an inferred Any fallback as evidence. Extra statements, nested
    /// closures, properties, calls and raw expressions retain their existing path.
    private static func isDirectNonNullAnyParameterCast(_ cast: BinaryOperator) -> Bool {
        guard let identifier = cast.lhs as? Identifier,
              let statement = cast.parent as? ExpressionStatement,
              statement.type == .return || statement.type == .expression,
              statement.expression === cast,
              let block = statement.parent as? CodeBlock,
              block.statements.filter({ $0.type != .empty }).count == 1,
              let function = block.parent as? FunctionDeclaration,
              function.body === block else { return false }
        return function.parameters.contains { parameter in
            parameter.internalLabel == identifier.name
                && canonicalType(parameter.declaredType).withModuleName(nil) == .any
        }
    }

    private static func anyHashableConversion(_ value: KotlinExpression, expression: Expression,
                                             actualType: TypeSignature, optionalTarget: Bool) -> KotlinExpression {
        if actualType.isOptional && actualType.asOptional(false).isOptional {
            value.messages.append(Message(kind: .error,
                message: "Skip cannot preserve nested Optional presence when converting to AnyHashable. Use a single-level Optional or an explicit tagged value.",
                sourceFile: expression.sourceFile, sourceRange: expression.sourceRange))
            return value
        }
        if actualType.isOptional && !optionalTarget {
            let wrapped = canonicalType(actualType.withoutOptionality())
            var hasGeneric = false
            _ = wrapped.mappingTypes { type in
                if isGenericReference(type, in: expression) || type == .none { hasGeneric = true }
                return nil
            }
            if hasGeneric {
                value.messages.append(Message(kind: .error,
                    message: "Skip cannot preserve the erased wrapped type of a generic Optional converted to AnyHashable. Convert a concrete Optional type before erasing it.",
                    sourceFile: expression.sourceFile, sourceRange: expression.sourceRange))
                return value
            }
            return KotlinAnyHashableParity(expression: expression, value: value, mapOptional: false,
                                           erasedOptionalType: wrapped.description)
        }
        return KotlinAnyHashableParity(expression: expression, value: value,
                                       mapOptional: actualType.isOptional && optionalTarget)
    }

    private static func erasureSourceType(of expression: Expression) -> TypeSignature {
        let declared = (expression as? Identifier)?.unconstrainedLocalType ?? .none
        let type = declared == .none ? expression.inferredType : declared
        // Same-type constraints are concrete evidence; conformance bounds are
        // not. Do not substitute Hashable/Any for an unknown wrapped type.
        var generics = Generics()
        var declarations: [Generics] = []
        var node: SyntaxNode? = expression
        while let current = node {
            if let declaration = current as? FunctionDeclaration { declarations.append(declaration.generics) }
            if let declaration = current as? TypeDeclaration { declarations.append(declaration.generics) }
            node = current.parent
        }
        for scope in declarations.reversed() { generics = generics.merge(overrides: scope, addNew: true) }
        var resolved = type
        // Follow equalities without looping on recursive/identity constraints.
        for _ in 0...generics.entries.count {
            let next = resolved.mappingTypes { signature in
                let equal = generics.constrainedType(of: signature, ifEqual: true)
                return equal == .none || equal == signature ? nil : equal
            }
            if next == resolved { break }
            resolved = next
        }
        return resolved
    }

    private static func canonicalType(_ type: TypeSignature) -> TypeSignature {
        type.mappingTypes { signature in
            if case .typealiased(_, let resolved) = signature { return canonicalType(resolved) }
            return nil
        }
    }

    private static func isAnyHashable(_ type: TypeSignature) -> Bool {
        let resolved = canonicalType(type).withoutOptionality()
        return resolved.isNamed("AnyHashable", moduleName: "Swift", generics: [])
            || resolved.isNamed("AnyHashable", moduleName: "SkipLib", generics: [])
    }

    private static func isGenericReference(_ type: TypeSignature, in expression: Expression) -> Bool {
        let name = type.withModuleName(nil).name
        if let function = expression.owningFunctionDeclaration as? FunctionDeclaration,
           function.generics.entries.contains(where: { $0.name == name }) { return true }
        var node: SyntaxNode? = expression
        while let declaration = node?.owningTypeDeclaration {
            if declaration.generics.entries.contains(where: { $0.name == name }) { return true }
            node = declaration.parent
        }
        return false
    }

    static func contextualExpectedType(of expression: Expression) -> TypeSignature {
        guard let parent = expression.parent else { return .none }
        if let declaration = parent as? VariableDeclaration, declaration.value === expression { return declaration.propertyType }
        if let assignment = parent as? BinaryOperator {
            if assignment.op.symbol == "=", assignment.rhs === expression { return assignment.lhs.inferredType }
            if assignment.op.symbol == "==" || assignment.op.symbol == "!=" {
                return assignment.lhs === expression ? assignment.rhs.inferredType : assignment.lhs.inferredType
            }
        }
        if let call = parent as? FunctionCall, let index = call.arguments.firstIndex(where: { $0.value === expression }) {
            // A selected API match already maps formals into actual argument order.
            if let match = call.apiMatch {
                let parameters = match.signature.parameters
                return index < parameters.count ? parameters[index].type : .none
            }
            // An Identifier can retain the first overload's function type even
            // when that overload does not match this call. Validate the whole
            // call shape before using it for an implicit AnyHashable conversion.
            if let types = fallbackArgumentTypes(for: call), index < types.count { return types[index] }
        }
        if let call = parent as? Subscript, let index = call.arguments.firstIndex(where: { $0.value === expression }),
           let match = call.apiMatch, index < match.signature.parameters.count { return match.signature.parameters[index].type }
        if let array = parent as? ArrayLiteral, case .array(let element) = array.inferredType.withoutOptionality() { return element ?? .none }
        if let dictionary = parent as? DictionaryLiteral,
           case .dictionary(let key, let value) = dictionary.inferredType.withoutOptionality() {
            return dictionary.entries.contains(where: { $0.key === expression }) ? key ?? .none : value ?? .none
        }
        if parent is Return {
            var node: SyntaxNode? = parent
            while let current = node {
                if let closure = current as? Closure { return closure.inferredType.returnType }
                if let function = current as? FunctionDeclaration { return function.returnType }
                node = current.parent
            }
        }
        // A closure or function may use an implicit single-expression return.
        if let statement = parent as? ExpressionStatement, let block = statement.parent as? CodeBlock,
           block.statements.count == 1 {
            if let closure = block.parent as? Closure { return closure.inferredType.returnType }
            if let function = block.parent as? FunctionDeclaration { return function.returnType }
        }
        return .none
    }

    private static func fallbackArgumentTypes(for call: FunctionCall) -> [TypeSignature]? {
        let parameters = call.function.inferredType.parameters
        var formalIndex = 0
        var variadicStarted = false
        var result: [TypeSignature] = []
        for (actualIndex, argument) in call.arguments.enumerated() {
            var matched = false
            while formalIndex < parameters.count {
                let parameter = parameters[formalIndex]
                let sameLabel = argument.label == (variadicStarted ? nil : parameter.label)
                let firstTrailingClosure = call.trailingClosureCount > 0
                    && actualIndex == call.arguments.count - call.trailingClosureCount
                    && argument.label == nil && parameter.type.isFunction && argument.value is Closure
                if sameLabel || firstTrailingClosure {
                    result.append(parameter.type)
                    if parameter.isVariadic { variadicStarted = true }
                    else { formalIndex += 1; variadicStarted = false }
                    matched = true
                    break
                }
                guard parameter.hasDefaultValue || parameter.isVariadic else { return nil }
                formalIndex += 1
                variadicStarted = false
            }
            guard matched else { return nil }
        }
        guard parameters[formalIndex...].allSatisfy({ $0.hasDefaultValue || $0.isVariadic }) else { return nil }
        return result
    }
}

/// A generated runtime reference declares its dependency directly; it must not
/// depend on an incidental import of Swift/SkipLib elsewhere in the source file.
private final class KotlinParityRuntimeFunction: KotlinExpression {
    let name: String
    init(name: String) {
        self.name = name
        super.init(type: .raw)
    }
    override func insertDependencies(into dependencies: inout KotlinDependencies) {
        dependencies.insertSkipLibType(name)
    }
    override func append(to output: OutputGenerator, indentation: Indentation) { output.append(name) }
}

private final class KotlinAnyHashableParity: KotlinExpression {
    let value: KotlinExpression
    let mapOptional: Bool
    let erasedOptionalType: String?

    init(expression: Expression, value: KotlinExpression, mapOptional: Bool, erasedOptionalType: String? = nil) {
        self.value = value
        self.mapOptional = mapOptional
        self.erasedOptionalType = erasedOptionalType
        super.init(type: .raw, expression: expression)
    }
    override var children: [KotlinSyntaxNode] { [value] }
    override func insertDependencies(into dependencies: inout KotlinDependencies) {
        dependencies.insertSkipLibType("AnyHashable")
        if erasedOptionalType != nil { dependencies.insertSkipLibType("anyHashableOptional") }
    }
    override func append(to output: OutputGenerator, indentation: Indentation) {
        if let erasedOptionalType {
            let escaped = erasedOptionalType.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            output.append("anyHashableOptional(").append(value, indentation: indentation).append(", type = \"\(escaped)\")")
        } else if mapOptional {
            output.append("(").append(value, indentation: indentation).append(").let { if (it == null) null else AnyHashable(it) }")
        } else {
            output.append("AnyHashable(").append(value, indentation: indentation).append(")")
        }
    }
}

/// Capture the address components, then read, evaluate the appended argument and
/// write once. Backticked names with spaces cannot collide with Swift identifiers.
/// Capture nodes remain ordinary Kotlin AST children so later visitors still see
/// closures, suspension, accessors and reference semantics within them.
private final class KotlinStringAppendParity: KotlinExpression, KotlinSingleStatementVetoing {
    struct Capture {
        let name: String
        let value: KotlinExpression
        let guardNonNil: Bool
    }
    let captures: [Capture]
    let target: KotlinExpression
    let argument: KotlinExpression
    let joinsCharacters: Bool
    let optionalReceiver: Bool
    let forceReceiver: Bool

    init(expression: FunctionCall, receiver: Expression, translator: KotlinTranslator) {
        var receiver = receiver
        if let postfix = receiver as? PostfixOperator, postfix.operatorSymbol == "?" || postfix.operatorSymbol == "!" {
            optionalReceiver = postfix.operatorSymbol == "?"
            forceReceiver = postfix.operatorSymbol == "!"
            receiver = postfix.target
        } else {
            optionalReceiver = false
            forceReceiver = false
        }
        var captures: [Capture] = []
        if let member = receiver as? MemberAccess, let sourceBase = member.base {
            let translated = KotlinMemberAccess.translate(expression: member, translator: translator)
            var base = translated.base ?? translator.translateExpression(sourceBase)
            let guarded = base.optionalChain != .none
            if let postfix = base as? KotlinPostfixOperator, postfix.operatorSymbol == "?" { base = postfix.target }
            captures.append(Capture(name: "`skip append base`", value: base, guardNonNil: guarded))
            translated.base = KotlinRawExpression(sourceCode: "`skip append base`")
            target = translated
        } else if let subscriptExpression = receiver as? Subscript {
            let translated = KotlinSubscript.translate(expression: subscriptExpression, translator: translator)
            var base = translated.base
            let guarded = base.optionalChain != .none
            if let postfix = base as? KotlinPostfixOperator, postfix.operatorSymbol == "?" { base = postfix.target }
            captures.append(Capture(name: "`skip append base`", value: base, guardNonNil: guarded))
            translated.base = KotlinRawExpression(sourceCode: "`skip append base`")
            for index in translated.arguments.indices {
                // Dictionary default values are autoclosures; keep them lazy.
                if translated.isDictionarySubscript && index == 1 && translated.arguments[index].label == "default" { continue }
                let name = "`skip append index \(index)`"
                captures.append(Capture(name: name, value: translated.arguments[index].value, guardNonNil: false))
                translated.arguments[index].value = KotlinRawExpression(sourceCode: name)
            }
            target = translated
        } else {
            target = translator.translateExpression(receiver)
        }
        self.captures = captures
        argument = translator.translateExpression(expression.arguments[0].value)
        joinsCharacters = expression.arguments[0].label == "contentsOf"
            && !expression.arguments[0].value.inferredType.isSameType(as: .string, withoutOptionality: true)
        super.init(type: .raw, expression: expression)
    }

    func isSingleStatementAppendable(mode: KotlinSingleStatementAppendMode) -> Bool { false }
    override var children: [KotlinSyntaxNode] { captures.map(\.value) + [target, argument] }
    override func append(to output: OutputGenerator, indentation: Indentation) {
        output.append("run { ")
        var guards = 0
        for capture in captures {
            output.append("val \(capture.name) = ").append(capture.value, indentation: indentation).append("; ")
            if capture.guardNonNil {
                output.append("if (\(capture.name) != null) { ")
                guards += 1
            }
        }
        output.append("val `skip append old` = ").append(target, indentation: indentation)
        if forceReceiver { output.append("!!") }
        output.append("; ")
        if optionalReceiver {
            output.append("if (`skip append old` != null) { ")
            guards += 1
        }
        output.append("val `skip append suffix` = ")
        if joinsCharacters { output.append("(") }
        output.append(argument, indentation: indentation)
        if joinsCharacters { output.append(").iterable.joinToString(separator = \"\")") }
        output.append("; ").append(target, indentation: indentation).append(" = `skip append old` + `skip append suffix`; ")
        for _ in 0..<guards { output.append("}; ") }
        output.append("Unit }")
    }
}
