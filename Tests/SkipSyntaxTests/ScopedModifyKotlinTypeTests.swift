// Copyright (c) 2026 Vindhya Data Science
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
@testable import SkipSyntax

/// RNABrowser-fiea.28: two Kotlin rendering defects in 1.9.19-vds.2 output, both reached through
/// its new explicit property types and scoped-modify accessors.
final class ScopedModifyKotlinTypeTests: XCTestCase {
    private func transpile(_ source: String) async throws -> String {
        let file = try tmpFile(named: "Scoped.swift", contents: source)
        let info = CodebaseInfo(moduleName: "ScopedModule")
        var kotlin = ""
        try await Transpiler(transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info,
            transformers: builtinKotlinTransformers()).transpile { result in
                XCTAssertEqual(result.messages.filter { $0.kind == .error }.map(\.formattedMessage), [])
                kotlin += result.output.content
            }
        return kotlin
    }

    /// `Alias?` for a function typealias is a nullable function type: `((...) -> T)?`, not
    /// `(...) -> T?` (a function returning an optional), which cannot hold `null`.
    func testOptionalFunctionTypealiasKeepsParentheses() async throws {
        let kotlin = try await transpile("""
        public typealias Arming = (Int, @escaping () -> Void) -> String
        public struct Holder {
            private var arm: Arming? = nil
            public init() {}
            public mutating func set(_ a: @escaping Arming) { arm = a }
            public func call() -> String { arm!(1, {}) }
        }
        """)
        XCTAssertTrue(kotlin.contains("private var arm: ((Int, () -> Unit) -> String)? = null"), kotlin)
    }

    /// A closure passed for an optional function-typealias parameter still gets the alias's
    /// return type as context, so an implicit member resolves (ReportStoreAdapterTests shape).
    func testClosureForOptionalFunctionTypealiasParameterHasReturnContext() async throws {
        let kotlin = try await transpile("""
        public struct ReadResult { public static let missing = ReadResult() }
        public typealias Reader = @Sendable () async -> ReadResult
        public func retry(reader: Reader?, other: Reader? = nil) async {}
        func use() async {
            await retry(reader: { .missing })
        }
        """)
        XCTAssertTrue(kotlin.contains("ReadResult.missing"), kotlin)
    }

    /// A private property whose type is a private nested type keeps a private scoped-modify
    /// accessor; an internal one exposes the private type and Kotlin rejects it.
    func testPrivatePropertyScopedModifyAccessorIsPrivate() async throws {
        let kotlin = try await transpile("""
        public struct Decoder {
            private struct Bits { var position = 0; mutating func advance() { position += 1 } }
            public final class Chunks {
                private var bits = Bits()
                public init() {}
                public func step() { bits.advance() }
            }
        }
        """)
        XCTAssertFalse(kotlin.contains("internal fun <R> smodify_bits"), kotlin)
        if kotlin.contains("smodify_bits") {
            XCTAssertTrue(kotlin.contains("private fun <R> smodify_bits"), kotlin)
        }
    }
}
