// Copyright (c) 2026 Vindhya Data Science
// SPDX-License-Identifier: AGPL-3.0-only

/// One synchronous file translation owns this context and its lookup cache.
/// Task-local scoping prevents concurrent transpilation files sharing mutable
/// renderer state; the prepared global metadata is read-only during this scope.
struct KotlinNestedTypeRenderingScope: @unchecked Sendable {
    let context: CodebaseInfo.Context
}

enum KotlinNestedTypeGenerics {
    @TaskLocal static var current: KotlinNestedTypeRenderingScope?
    @TaskLocal private static var renderingQualifier = false

    static func typeArguments(for signature: TypeSignature, context: CodebaseInfo.Context? = nil) -> [TypeSignature] {
        if renderingQualifier { return [] }
        let plain = signature.asTypealiased(nil).withoutOptionality().withModuleName(nil)
        guard case .member(let base, let member) = plain else { return plain.generics }
        let context = context ?? current?.context
        guard let positions = context?.primaryTypeInfo(forNamed: signature)?.kotlinCapturedOuterGenericIndices else {
            return member.generics // Older metadata preserves its original ABI.
        }
        let enclosing = base.allGenericArguments
        return positions.map { $0 >= 0 && $0 < enclosing.count ? enclosing[$0] : .none } + member.generics
    }

    static func capturedGenerics(of declaration: TypeDeclaration, context: CodebaseInfo.Context?) -> Generics {
        let entries = declaration.enclosingTypeGenericEntries
        let positions = context?.primaryTypeInfo(forNamed: declaration.signature)?.kotlinCapturedOuterGenericIndices
            ?? declaration.kotlinCapturedOuterGenericIndices
        return Generics(entries: positions.compactMap { $0 >= 0 && $0 < entries.count ? entries[$0] : nil })
    }

    static func qualifierName(_ signature: TypeSignature) -> String {
        $renderingQualifier.withValue(true) { erasedQualifier(signature).kotlin }
    }

    static func erasedQualifier(_ signature: TypeSignature) -> TypeSignature {
        switch signature {
        case .member(let base, let member):
            return .member(erasedQualifier(base), member.withGenerics([]))
        case .module(let module, let type): return .module(module, erasedQualifier(type))
        case .typealiased(_, let type): return erasedQualifier(type)
        case .metaType(let type): return .metaType(erasedQualifier(type))
        default: return signature.withGenerics([])
        }
    }
}
