// Copyright (c) 2026 Vindhya Data Science
// SPDX-License-Identifier: AGPL-3.0-only

/// Only count/isEmpty may bypass a copying getter. No stored wrapper, element,
/// iterator or callback escapes these generated primitive-returning accessors.
enum KotlinCollectionScalarReads {
    static func names(for property: String) -> (count: String, isEmpty: String) {
        let name = property.removingBacktickEscaping
        return ("sread_\(name)_count", "sread_\(name)_isEmpty")
    }

    static func isCollection(_ type: TypeSignature) -> Bool {
        guard !type.isOptional, !type.isUnwrappedOptional else { return false }
        switch type.asTypealiased(nil).withModuleName(nil) {
        case .array, .dictionary, .set: return true
        default: return false
        }
    }

    /// Inspect owner declarations during gather, while their weak parent links
    /// are alive. Resolved collection types are checked separately in preflight.
    static func canGenerateDeclaration(for variable: VariableDeclaration, owner: TypeDeclaration) -> Bool {
        guard variable.names.count == 1, !variable.apiFlags.options.contains(.async),
              !hasCustomDeclaration(variable), !hasCustomDeclaration(owner) else { return false }
        let encoded = variable.propertyName.fixingKeyword(in: KotlinIdentifier.hardKeywords)
        let readers = names(for: encoded)
        let generated = [readers.count, readers.isEmpty]
        // Kotlin properties also occupy generated JVM getter names. Refuse a
        // collision rather than emit a new helper that shadows an existing API.
        let reserved = Set(generated + generated.map { "getS" + $0.dropFirst() })
        var encodedProperties: [String] = []
        for member in owner.members {
            let occupied: [String]
            if let declaration = member as? VariableDeclaration {
                occupied = declaration.names.compactMap { $0 }
                encodedProperties += occupied.map { $0.fixingKeyword(in: KotlinIdentifier.hardKeywords) }
            } else if let function = member as? FunctionDeclaration {
                occupied = [function.name]
            } else if let declaration = member as? TypeDeclaration {
                occupied = [declaration.name]
            } else if let alias = member as? TypealiasDeclaration {
                occupied = [alias.name]
            } else {
                occupied = []
            }
            if occupied.contains(where: { reserved.contains($0.fixingKeyword(in: KotlinIdentifier.hardKeywords)) }) { return false }
        }
        return encodedProperties.filter { $0 == encoded }.count == 1
    }

    private static func hasCustomDeclaration(_ statement: Statement) -> Bool {
        statement.extras?.directives.contains { directive in
            switch directive {
            case .replace, .declaration: return true
            default: return false
            }
        } == true
    }

    static func rewrite(_ access: KotlinMemberAccess) {
        guard access.member == "count" || access.member == "isEmpty",
              access.optionalChain == .none, !access.isStaticReferenceOrTypeName, !access.isFunctionReference,
              access.apiMatch?.signature.isFunction != true, isCollection(access.baseType) else { return }
        let receiver: KotlinExpression?
        let propertyName: String
        let propertyMatch: APIMatch
        if let property = access.base as? KotlinMemberAccess,
           property.optionalChain == .none, !property.isStaticReferenceOrTypeName,
           let match = property.apiMatch, match.memberOf != nil {
            receiver = property.base
            propertyName = property.member
            propertyMatch = match
        } else if let property = access.base as? KotlinIdentifier,
                  property.valueSuffix == nil, let match = property.apiMatch, match.memberOf != nil {
            // Preserve the lexical instance: receiver lambdas such as with(density)
            // rebind plain `this`, while an unqualified helper can be locally shadowed.
            // Imported extension scopes have no enclosing class label to prove; keep
            // their ordinary copying getter rather than invent a receiver.
            guard let owner = access.owningTypeDeclaration as? KotlinClassDeclaration,
                  let memberOf = match.memberOf,
                  owner.signature.withGenerics([]).withModuleName(nil)
                    == memberOf.declaringType.withGenerics([]).withModuleName(nil) else { return }
            receiver = KotlinIdentifier(name: "this@" + owner.name)
            propertyName = property.name
            propertyMatch = match
        } else {
            return
        }
        guard propertyMatch.apiFlags.options.contains(.scopedCollectionRead),
              !propertyMatch.apiFlags.options.contains(.async), isCollection(propertyMatch.signature) else { return }
        let reader = names(for: propertyName)
        let scalarType: TypeSignature = access.member == "count" ? .int : .bool
        access.base = receiver // The original receiver is still evaluated exactly once.
        access.baseType = .none
        access.baseKClass = nil
        access.member = access.member == "count" ? reader.count : reader.isEmpty
        access.generics = nil
        access.mayBeSharedMutableStruct = false
        access.isTypealiasFor = .none
        access.apiMatch = APIMatch(signature: scalarType, apiFlags: propertyMatch.apiFlags,
                                  declarationType: .variableDeclaration, memberOf: propertyMatch.memberOf)
        access.assignParentReferences()
    }
}
