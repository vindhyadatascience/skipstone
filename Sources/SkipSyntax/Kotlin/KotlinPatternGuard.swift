// Copyright (c) 2026 Vindhya Data Science
// SPDX-License-Identifier: AGPL-3.0-only

/// Evaluate a where clause after a successful pattern, with bindings scoped to
/// the predicate. The selected body gets its own bindings through KotlinCase.
final class KotlinPatternGuard: KotlinExpression {
    let bindings: [KotlinBindingVariable]
    let predicate: KotlinExpression

    init(bindings: [KotlinBindingVariable], predicate: KotlinExpression) {
        self.bindings = bindings.map { binding in
            KotlinBindingVariable(names: binding.names, value: KotlinSharedExpressionPointer(shared: binding.value), isLet: binding.isLet)
        }
        self.predicate = predicate
        super.init(type: .raw)
    }

    override var children: [KotlinSyntaxNode] { bindings.map(\.value) + [predicate] }

    override func append(to output: OutputGenerator, indentation: Indentation) {
        output.append("run {\n")
        for binding in bindings {
            output.append(indentation.inc())
            binding.append(to: output, indentation: indentation.inc())
            output.append("\n")
        }
        output.append(indentation.inc()).append(predicate, indentation: indentation.inc()).append("\n")
        output.append(indentation).append("}")
    }
}
