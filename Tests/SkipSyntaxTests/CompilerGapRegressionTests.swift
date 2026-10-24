// Copyright (c) 2026 Vindhya Data Science
// Licensed under the GNU Affero General Public License v3.0
// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import SkipSyntax

final class CompilerGapRegressionTests: XCTestCase {
    func testInferredSuspendWithExplicitSynchronousReturn() async throws {
        try await check(swift: """
        func accept(body: () async -> Int) {}
        func f() {
            accept { () -> Int in 42 }
            accept { () -> Int in
                let value = 7
                return value * 6
            }
        }
        """, kotlin: """
        internal fun accept(body: suspend () -> Int) = Unit
        internal fun f() {
            accept { -> Async.run { 42 } }
            accept { -> Async.run l@{
                val value = 7
                return@l value * 6
            } }
        }
        """)
    }

    func testInferredSuspendWithExplicitVoidReturn() async throws {
        try await check(swift: """
        func accept(body: () async -> Void) {}
        func f() {
            accept { () -> Void in print("done") }
        }
        """, kotlin: """
        internal fun accept(body: suspend () -> Unit) = Unit
        internal fun f() {
            accept { -> Async.run { print("done") } }
        }
        """)
    }

    func testUnicodeEscapeUTF16Encoding() async throws {
        try await check(swift: #""\u{1F98A}""#, kotlin: #""\uD83E\uDD8A""#)
        try await check(swift: #""\u{41}\u{00000042}\u{10FFFF}""#, kotlin: #""\u0041\u0042\uDBFF\uDFFF""#)
        try await check(swift: #""\\u{1F98A}""#, kotlin: #""\\u{1F98A}""#)
    }
    func testTrailingClosureBeforeDefaultedCallback() async throws {
        try await check(swift: """
        func row(value: Int, label: () -> String, onEditingChanged: (Bool) -> Void = { _ in }) {}
        func f() {
            row(value: 3) { "count" }
        }
        """, kotlin: """
        internal fun row(value: Int, label: () -> String, onEditingChanged: (Boolean) -> Unit = { _ ->  }) = Unit
        internal fun f() {
            row(value = 3, label = { -> "count" })
        }
        """)
    }

    func testLocalTypesAreHoistedWithLexicalIdentity() async throws {
        let swift = """
        func first() -> Int {
            class Value { static let answer = 42 }
            return Value.answer
        }
        func second() -> Int {
            struct Value { let answer: Int }
            return Value(answer: 7).answer
        }
        """
        let file = try tmpFile(named: "Source.swift", contents: swift)
        let transpiler = Transpiler(transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: CodebaseInfo(), transformers: builtinKotlinTransformers())
        var output = ""
        try await transpiler.transpile { result in
            XCTAssertTrue(result.messages.isEmpty, result.messages.map(\.formattedMessage).joined(separator: "\n"))
            output += result.output.content
        }
        XCTAssertTrue(output.contains("private open class Local_Source_swift_2_5_Value"), output)
        XCTAssertTrue(output.contains("private class Local_Source_swift_6_5_Value"), output)
        XCTAssertTrue(output.contains("fun first(): Int = Local_Source_swift_2_5_Value.answer"), output)
        XCTAssertTrue(output.contains("Local_Source_swift_6_5_Value(answer = 7).answer"), output)
    }

    func testSignedFloatLiteralConstructorsPreserveNegativeZero() async throws {
        try await check(swift: """
        let negative = Float(-0.0)
        let positive = Swift.Float(0.0)
        let value = Float(-1.25)
        """, kotlin: """
        internal val negative = -0.0f
        internal val positive = 0.0f
        internal val value = -1.25f
        """)
    }

    func testBooleanIdentityInitializer() async throws {
        try await check(swift: """
        let no = Bool(false)
        let yes = Swift.Bool(true)
        """, kotlin: """
        internal val no = false
        internal val yes = true
        """)
    }

    func testNestedPatternAndGuardedCatchHaveNoUnsupportedDiagnostics() async throws {
        let swift = """
        enum Inner { case number(Int); case empty }
        enum Outer { case box(Inner); case empty }
        enum Failure: Error { case value(Int); case other }
        func f(_ value: Outer) -> Int {
            switch value {
            case .box(.number(let code)) where code > 0: return code
            default: return -1
            }
        }
        func g() throws -> Int {
            do { throw Failure.value(42) }
            catch Failure.value(let code) where code > 0 { return code }
        }
        """
        let file = try tmpFile(named: "Source.swift", contents: swift)
        let transpiler = Transpiler(transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: CodebaseInfo(), transformers: builtinKotlinTransformers())
        var output = ""
        try await transpiler.transpile { result in
            XCTAssertTrue(result.messages.isEmpty, result.messages.map(\.formattedMessage).joined(separator: "\n"))
            output += result.output.content
        }
        XCTAssertTrue(output.contains("when {"), output)
        XCTAssertTrue(output.contains("&& run {"), output)
        XCTAssertTrue(output.contains("throw caughtError"), output)
        XCTAssertTrue(output.contains("associated0 is Inner.NumberCase"), output)
    }

    func testCompoundTestingMacrosKeepPrecedenceAndOptionalBooleanUnwrap() async throws {
        try await check(swift: """
        func verify(value: Int, flag: Bool, optional: Bool?) throws {
            #expect(value >= 0 && value < 2)
            #expect(value < 0 || value > 2, "outside")
            try #require(value >= 0 && value < 2)
            try #require(flag)
            let unwrapped = try #require(optional)
        }
        """, kotlin: """
        internal fun verify(value: Int, flag: Boolean, optional: Boolean?) {
            expectTrue(value >= 0 && value < 2)
            expectTrue(value < 0 || value > 2, "outside")
            requireTrue(value >= 0 && value < 2)
            requireTrue(flag)
            val unwrapped = requireNotNil(optional)
        }
        """)
    }

    func testLocalTrailingClosureRetainsOmittedParameterMatch() async throws {
        try await check(swift: """
        func verify() -> String {
            func row(value: Int, label: () -> String, onEditingChanged: (Bool) -> Void = { _ in }) -> String {
                label() + String(value)
            }
            return row(value: 42) { "count:" }
        }
        """, kotlin: """
        internal fun verify(): String {
            fun row(value: Int, label: () -> String, onEditingChanged: (Boolean) -> Unit = { _ ->  }): String = label() + String(value)
            return row(value = 42, label = { -> "count:" })
        }
        """)
    }

    func testUnsignedOperatorLiteralsRetainTheirPeerType() async throws {
        try await check(swift: """
        let wide = UInt64(42)
        let next = wide + 1
        let below = wide < 43
        let unsigned = UInt(4) + 1
        let signed = 4 + 1
        """, kotlin: """
        internal val wide = 42UL
        internal val next = wide + 1UL
        internal val below = wide < 43UL
        internal val unsigned = 4U + 1U
        internal val signed = 4 + 1
        """)
    }

    func testCompoundSealedSwitchHasAnUnreachableExhaustiveFallback() async throws {
        let swift = """
        enum Inner { case value(Int); case empty }
        enum Outer { case inner(Inner); case empty }
        func value(_ outer: Outer) -> Int {
            switch outer {
            case .inner(.value(let value)): return value
            case .inner(.empty): return 0
            case .empty: return -1
            }
        }
        """
        let file = try tmpFile(named: "Source.swift", contents: swift)
        let transpiler = Transpiler(transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: CodebaseInfo(), transformers: builtinKotlinTransformers())
        var output = ""
        try await transpiler.transpile { result in
            XCTAssertTrue(result.messages.isEmpty, result.messages.map(\.formattedMessage).joined(separator: "\n"))
            output += result.output.content
        }
        XCTAssertTrue(output.contains("else -> throw NoWhenBranchMatchedException()"), output)
        XCTAssertTrue(output.contains("outer is Outer.InnerCase && outer.associated0 is Inner.ValueCase"), output)
    }

    func testContextualFloatLiteralsKeepTheirWidthAndNegativeZero() async throws {
        try await check(swift: """
        let positive: Float = 1.5
        let negative: Float = -0.0
        let integers: [Float] = [1, -2]
        let double: Double = 1.5
        """, kotlin: """
        import skip.lib.Array

        internal val positive: Float = 1.5f
        internal val negative: Float = -0.0f
        internal val integers: Array<Float> = arrayOf(1.0f, -2.0f)
        internal val double: Double = 1.5
        """)
    }

    func testUInt64MethodLiteralArgumentsUseTheDeclaredWidth() async throws {
        try await check(supportingSwift: """
        final class Cursor {
            func seek(toOffset offset: UInt64) {}
            func truncate(atOffset offset: UInt64) {}
        }
        """, swift: """
        func verify(_ cursor: Cursor, offset: UInt64) {
            cursor.seek(toOffset: 4)
            cursor.seek(toOffset: 100)
            cursor.truncate(atOffset: 0)
            cursor.seek(toOffset: offset)
        }
        """, kotlin: """
        internal fun verify(cursor: Cursor, offset: ULong) {
            cursor.seek(toOffset = 4UL)
            cursor.seek(toOffset = 100UL)
            cursor.truncate(atOffset = 0UL)
            cursor.seek(toOffset = offset)
        }
        """)
    }

}
