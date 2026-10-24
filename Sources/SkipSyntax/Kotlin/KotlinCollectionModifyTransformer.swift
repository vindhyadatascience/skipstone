// Copyright (c) 2026 Vindhya Data Science
// Licensed under the GNU Affero General Public License v3.0
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// A stored value read must copy its wrapper, but a scoped mutation can borrow that wrapper.
/// Only declarations in this compilation with statically dispatched storage are eligible.
final class KotlinCollectionModifyTransformer: KotlinTransformer {
    private let lock = NSLock()
    private var declarations: [(TypeSignature, VariableDeclaration)] = []
    private var eligible: Set<String> = []
    private var scalarReadEligible: Set<String> = []
    private var scalarReadCandidates: Set<String> = []

    func gather(from syntaxTree: SyntaxTree) {
        guard !syntaxTree.isBridgeFile, !syntaxTree.isSymbolFile else { return }
        var found: [(TypeSignature, VariableDeclaration)] = []
        var foundScalarReads: Set<String> = []
        syntaxTree.root.visit { node in
            guard let variable = node as? VariableDeclaration,
                  let owner = variable.parent as? TypeDeclaration,
                  !Self.isLocalType(owner),
                  owner.type == .structDeclaration || owner.type == .classDeclaration,
                  owner.type == .structDeclaration || owner.modifiers.isFinal || variable.modifiers.isFinal,
                  owner.attributes.isEmpty, variable.attributes.isEmpty,
                  variable.apiFlags.options.contains(.writeable),
                  !variable.modifiers.isStatic, !variable.modifiers.isOverride, !variable.modifiers.isLazy,
                  variable.getter == nil, variable.setter == nil, variable.willSet == nil,
                  !variable.propertyType.isOptional, !variable.propertyType.isUnwrappedOptional,
                  !owner.members.contains(where: { ($0 as? FunctionDeclaration)?.name == Self.modifyName(variable.propertyName.fixingKeyword(in: KotlinIdentifier.hardKeywords)) }) else {
                return .recurse(nil)
            }
            var readsOldValue = false
            variable.didSet?.body?.visit { child in
                // A setter's Unit return cannot be transplanted into a generic modify finally.
                if child is Return { readsOldValue = true }
                if let identifier = child as? Identifier,
                   identifier.name == "oldValue" || identifier.name == variable.didSet?.parameterName {
                    readsOldValue = true
                }
                return .recurse(nil)
            }
            if !readsOldValue {
                found.append((owner.signature, variable))
                // Gather trees are released before preflight; do not rely on
                // variable.parent (weak) when checking owner collisions later.
                if KotlinCollectionScalarReads.canGenerateDeclaration(for: variable, owner: owner) {
                    foundScalarReads.insert(Self.key(owner.signature, variable.propertyName, sourceFile: variable.sourceFile))
                }
            }
            return .recurse(nil)
        }
        lock.lock()
        declarations.append(contentsOf: found)
        scalarReadCandidates.formUnion(foundScalarReads)
        lock.unlock()
    }

    func prepareForUse(codebaseInfo: CodebaseInfo?) {
        let properties: [(type: TypeSignature, name: String, sourceFile: Source.FilePath?)] = declarations.compactMap { owner, variable in
            let context = codebaseInfo?.context(sourceFile: variable.sourceFile)
            let type = context?.primaryTypeInfo(forNamed: owner)?.variables.first(where: { $0.name == variable.propertyName })?.signature ?? variable.propertyType
            guard !type.isOptional, !type.isUnwrappedOptional,
                  type.kotlinMayBeSharedMutableStruct(codebaseInfo: context) else { return nil }
            switch type {
            case .array, .dictionary, .set:
                break
            default:
                // A concrete struct permits nested modify access; unknown/generic types do not.
                guard context?.primaryTypeInfo(forNamed: type)?.declarationType == .structDeclaration,
                      context?.mayBeMutableStruct(type: type) == true else { return nil }
            }
            return (owner, variable.propertyName, variable.sourceFile)
        }
        eligible = Set(properties.map { Self.key($0.type, $0.name, sourceFile: $0.sourceFile) })
        codebaseInfo?.markScopedModifyProperties(properties)
        let readProperties = declarations.compactMap { owner, variable -> (type: TypeSignature, name: String, sourceFile: Source.FilePath?)? in
            let key = Self.key(owner, variable.propertyName, sourceFile: variable.sourceFile)
            guard eligible.contains(key), scalarReadCandidates.contains(key) else { return nil }
            let context = codebaseInfo?.context(sourceFile: variable.sourceFile)
            let type = context?.primaryTypeInfo(forNamed: owner)?.variables.first(where: { $0.name == variable.propertyName })?.signature ?? variable.propertyType
            guard KotlinCollectionScalarReads.isCollection(type) else { return nil }
            return (owner, variable.propertyName, variable.sourceFile)
        }
        scalarReadEligible = Set(readProperties.map { Self.key($0.type, $0.name, sourceFile: $0.sourceFile) })
        codebaseInfo?.markScopedCollectionReadProperties(readProperties)
    }

    func apply(to syntaxTree: KotlinSyntaxTree, translator: KotlinTranslator) -> [KotlinTransformerOutput] {
        // Must run after observation/wrapper lowering, so their custom accessors are never bypassed.
        syntaxTree.root.visit(ifSkipBlockContent: syntaxTree.isBridgeFile) { node in
            if let variable = node as? KotlinVariableDeclaration,
               let owner = variable.parent as? KotlinClassDeclaration,
               eligible.contains(Self.key(owner.signature, variable.preEscapedPropertyName ?? variable.propertyName, sourceFile: variable.sourceFile)),
               variable.getter == nil, variable.setter == nil, variable.storage == nil,
               variable.role == .property, !variable.isOpen {
                variable.collectionModifyName = Self.modifyName(variable.propertyName)
                if scalarReadEligible.contains(Self.key(owner.signature, variable.preEscapedPropertyName ?? variable.propertyName, sourceFile: variable.sourceFile)) {
                    variable.collectionReadNames = KotlinCollectionScalarReads.names(for: variable.propertyName)
                }
                // Initial dependency gathering precedes transformers.
                syntaxTree.dependencies.insertSkipLibType("InOut")
            }
            return .recurse(nil)
        }
        syntaxTree.root.visit(ifSkipBlockContent: syntaxTree.isBridgeFile) { node in
            if let statement = node as? KotlinExpressionStatement,
               let assignment = statement.expression as? KotlinBinaryOperator,
               assignment.op.precedence == .assignment,
               let subscriptExpression = assignment.lhs as? KotlinSubscript,
               !Self.mayThrowWhileEvaluating(assignment.rhs),
               subscriptExpression.arguments.allSatisfy({ !Self.mayThrowWhileEvaluating($0.value) }),
               let replacement = borrow(subscriptExpression.base, body: { value in
                   subscriptExpression.base = value
                   return assignment
               }) {
                statement.expression = replacement
                statement.assignParentReferences()
            } else if let call = node as? KotlinFunctionCall {
                rewrite(call)
            } else if let member = node as? KotlinMemberAccess {
                KotlinCollectionScalarReads.rewrite(member)
            }
            return .recurse(nil)
        }
        return []
    }

    private func rewrite(_ call: KotlinFunctionCall) {
        if let function = call.function as? KotlinMemberAccess,
           call.apiMatch?.apiFlags.options.contains(.mutating) == true,
           call.apiMatch?.apiFlags.options.contains(.async) != true,
           let base = function.base,
           call.arguments.allSatisfy({ !Self.mayThrowWhileEvaluating($0.value) }) {
            let inner = copy(call)
            guard let replacement = borrow(base, body: { value in
                function.base = value
                return inner
            }) else { return }
            install(replacement, in: call)
        } else if let first = call.arguments.first?.value as? KotlinInOut {
            // Moving a later argument into the receiver position could change evaluation order.
            // Multiple inout accesses retain existing lowering and Swift's exclusivity behavior.
            guard call.apiMatch?.apiFlags.options.contains(.async) != true,
                  call.arguments.dropFirst().allSatisfy({ !($0.value is KotlinInOut) && !Self.mayThrowWhileEvaluating($0.value) }) else { return }
            let inner = copy(call)
            guard let replacement = borrow(first.target, body: { value in
                first.target = value
                return inner
            }) else { return }
            install(replacement, in: call)
        }
    }

    private func borrow(_ property: KotlinExpression, body: (KotlinExpression) -> KotlinExpression) -> KotlinFunctionCall? {
        let name: String
        let base: KotlinExpression?
        let hasCapability: Bool
        if let member = property as? KotlinMemberAccess,
           member.optionalChain == .none, member.apiMatch?.memberOf != nil {
            name = member.member
            base = member.base
            hasCapability = member.apiMatch?.apiFlags.options.contains(.scopedModify) == true
        } else if let identifier = property as? KotlinIdentifier,
                  identifier.apiMatch?.memberOf != nil {
            name = identifier.name
            base = nil
            hasCapability = identifier.apiMatch?.apiFlags.options.contains(.scopedModify) == true
        } else {
            return nil
        }
        // This bit is exported only by a producer that generated the matching accessor.
        // In particular, never infer eligibility from an imported symbol's missing observer body.
        guard hasCapability else { return nil }
        let parameter = KotlinIdentifier(name: "smodifyvalue")
        parameter.valueSuffix = ".value"
        let operation = body(parameter)
        let closure = KotlinClosure(body: KotlinCodeBlock(statements: [KotlinExpressionStatement(expression: operation)]))
        closure.parameters = [Parameter<Void>(externalLabel: "smodifyvalue")]
        func makeCall(_ receiver: KotlinExpression?) -> KotlinFunctionCall {
            let function: KotlinExpression = receiver.map { KotlinMemberAccess(base: $0, member: Self.modifyName(name)) }
                ?? KotlinIdentifier(name: Self.modifyName(name))
            let call = KotlinFunctionCall(function: function, arguments: [LabeledValue(label: nil, value: closure)])
            call.hasTrailingClosures = true
            return call
        }
        // Recursively borrow a stored struct receiver rather than taking another read-copy.
        if let base, let outer = borrow(base, body: { makeCall($0) }) { return outer }
        return makeCall(base)
    }

    private func copy(_ call: KotlinFunctionCall) -> KotlinFunctionCall {
        let inner = KotlinFunctionCall(function: call.function, arguments: call.arguments)
        inner.apiMatch = call.apiMatch
        inner.inferredType = call.inferredType
        inner.hasTrailingClosures = call.hasTrailingClosures
        inner.isOptionalInit = call.isOptionalInit
        inner.mayBeSharedMutableStructType = call.mayBeSharedMutableStructType
        return inner
    }

    private func install(_ replacement: KotlinFunctionCall, in call: KotlinFunctionCall) {
        call.function = replacement.function
        call.arguments = replacement.arguments
        call.apiMatch = nil
        call.hasTrailingClosures = true
        call.assignParentReferences()
    }

    private static func mayThrowWhileEvaluating(_ expression: KotlinExpression) -> Bool {
        var mayThrow = false
        expression.visit { node in
            if let closure = node as? KotlinClosure {
                // Capture initializers run now; the closure body runs inside the mutator.
                if closure.labeledCaptureList.contains(where: { mayThrowWhileEvaluating($0.value) }) { mayThrow = true }
                return .skip
            }
            if let call = node as? KotlinFunctionCall,
               call.apiMatch == nil || call.apiMatch?.apiFlags.options.contains(.throws) == true || call.apiMatch?.apiFlags.options.contains(.async) == true {
                mayThrow = true
            }
            return .recurse(nil)
        }
        return mayThrow
    }

    private static func key(_ type: TypeSignature, _ name: String, sourceFile: Source.FilePath?) -> String {
        return (sourceFile?.path ?? "") + ":" + type.withModuleName(nil).withGenerics([]).name + "." + name.removingBacktickEscaping
    }

    private static func isLocalType(_ type: TypeDeclaration) -> Bool {
        var ancestor = type.parent
        while let node = ancestor {
            if node is FunctionDeclaration || node is Closure { return true }
            ancestor = node.parent
        }
        return false
    }

    private static func modifyName(_ name: String) -> String {
        // Kotlin declaration/member names have already been escaped. Re-escaping is not
        // idempotent: Swift's distinct `object` and `object_` become object_ and object__.
        return "smodify_" + name.removingBacktickEscaping
    }
}
