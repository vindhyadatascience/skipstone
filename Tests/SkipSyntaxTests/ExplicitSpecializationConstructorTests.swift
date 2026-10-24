// Copyright (c) 2026 Vindhya Data Science
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
@testable import SkipSyntax

/// RNABrowser-fiea.28: `T<X>(...)` has type `T<X>`. Inside a generic type, an explicitly
/// specialized constructor call over the enclosing generic must not be typed `T<Any>`:
/// 1.9.19-vds.2 wrote that type out for a mutable stored struct property
/// (`private var gate: AsyncPublicationGate<Any>`), which Kotlin rejects.
final class ExplicitSpecializationConstructorTests: XCTestCase {
    private func transpile(_ source: String) async throws -> (kotlin: String, errors: [String]) {
        let file = try tmpFile(named: "Gate.swift", contents: source)
        let info = CodebaseInfo(moduleName: "GateModule")
        var kotlin = ""
        var errors: [String] = []
        try await Transpiler(transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info,
            transformers: builtinKotlinTransformers()).transpile { result in
                errors += result.messages.filter { $0.kind == .error }.map(\.formattedMessage)
                kotlin += result.output.content
            }
        return (kotlin, errors)
    }

    func testSpecializedConstructorOverEnclosingGenericKeepsTheGeneric() async throws {
        let (kotlin, errors) = try await transpile("""
        nonisolated public struct Token<Context: Equatable & Sendable>: Equatable, Sendable {
            fileprivate let generation: Int
            public let context: Context
        }
        nonisolated public struct Gate<Context: Equatable & Sendable>: Sendable {
            private var generation = 0
            public init() {}
            public mutating func begin(_ context: Context) -> Token<Context> {
                generation += 1
                return Token(generation: generation, context: context)
            }
        }
        public nonisolated struct Session<Request: Equatable & Sendable>: Sendable {
            private var gate = Gate<Request>()
            public private(set) var current: Request? = nil
            public init() {}
            public mutating func begin(_ request: Request) -> Token<Request> {
                current = request
                return gate.begin(request)
            }
            public mutating func invalidate() {
                gate.begin(current!)
            }
        }
        """)
        XCTAssertEqual(errors, [])
        XCTAssertFalse(kotlin.contains("Gate<Any>"), kotlin)
        XCTAssertTrue(kotlin.contains("Gate<Request>()"), kotlin)
        // The scoped-modify storage writes the type out, so it must be the specialized one.
        XCTAssertTrue(kotlin.contains("private var smodify_gatestorage: Gate<Request> = Gate<Request>()"), kotlin)
        XCTAssertTrue(kotlin.contains("body: (InOut<Gate<Request>>) -> R"), kotlin)
    }

    /// Control: a concrete specialization is unchanged.
    func testConcreteSpecializationIsUnchanged() async throws {
        let (kotlin, errors) = try await transpile("""
        public struct Gate<Context: Equatable> {
            private var generation = 0
            public init() {}
            public mutating func bump() { generation += 1 }
        }
        public struct Owner {
            private var gate = Gate<Int>()
            public mutating func bump() { gate.bump() }
        }
        """)
        XCTAssertEqual(errors, [])
        XCTAssertFalse(kotlin.contains("Gate<Any>"), kotlin)
        XCTAssertTrue(kotlin.contains("Gate<Int>()"), kotlin)
    }
}
