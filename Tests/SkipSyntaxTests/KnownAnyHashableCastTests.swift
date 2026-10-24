// Copyright (c) 2026 Vindhya Data Science
// Licensed under the GNU Affero General Public License v3.0
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import SkipSyntax

/// These tests forbid casting a statically known erasure box as its payload.
/// They do not prescribe a helper name or authorize boxing an arbitrary Any.
final class KnownAnyHashableCastTests: XCTestCase {
    private func output(_ source: String) async throws -> String {
        let file = try tmpFile(named: "KnownWrapper.swift", contents: source)
        let info = CodebaseInfo(moduleName: "KnownWrapperConsumer")
        let transpiler = Transpiler(transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info, transformers: builtinKotlinTransformers())
        var kotlin = ""
        try await transpiler.transpile { result in
            XCTAssertTrue(result.messages.isEmpty, result.messages.map(\.formattedMessage).joined(separator: "\n"))
            kotlin += result.output.content
        }
        return kotlin
    }

    func testKnownNonoptionalAndOptionalWrappersDoNotCastTheBoxAsItsPayload() async throws {
        try XCTSkipUnless(KotlinStandardLibraryParity.boxesAnyHashable, "AnyHashable boxing is off; SkipLib keeps AnyHashable a typealias (RNABrowser-fiea.30)")
        let kotlin = try await output("""
        func integer(_ wrapped: AnyHashable) -> Int? { return wrapped as? Int }
        func text(_ optional: AnyHashable?) -> String? { return optional as? String }
        func qualified(_ qualified: Swift.AnyHashable) -> Int? { return qualified as? Int }
        """)
        XCTAssertFalse(kotlin.contains("wrapped as? Int"), kotlin)
        XCTAssertFalse(kotlin.contains("optional as? String"), kotlin)
        XCTAssertFalse(kotlin.contains("qualified as? Int"), kotlin)
        XCTAssertFalse(kotlin.contains("AnyHashable(wrapped)"), kotlin)
    }

    func testKnownWrapperCastEvaluatesItsSideEffectingSourceOnce() async throws {
        try XCTSkipUnless(KotlinStandardLibraryParity.boxesAnyHashable, "AnyHashable boxing is off; SkipLib keeps AnyHashable a typealias (RNABrowser-fiea.30)")
        let kotlin = try await output("""
        func next() -> AnyHashable? { return AnyHashable(7) }
        func integer() -> Int? { return next() as? Int }
        """)
        // Exactly one declaration and one call, even when unboxing needs a
        // temporary or nullable branch. Runtime fixture counts actual effects.
        XCTAssertEqual(kotlin.components(separatedBy: "next()").count - 1, 2, kotlin)
        XCTAssertFalse(kotlin.contains("next() as? Int"), kotlin)
    }

    func testGenericWrappingKeepsConcreteCastAndOrdinaryAnyCastsSeparate() async throws {
        try XCTSkipUnless(KotlinStandardLibraryParity.boxesAnyHashable, "AnyHashable boxing is off; SkipLib keeps AnyHashable a typealias (RNABrowser-fiea.30)")
        let kotlin = try await output("""
        struct Token: Hashable { let identifier: Int }
        func erase<T: Hashable>(_ value: T) -> AnyHashable { return AnyHashable(value) }
        func token(_ token: Token) -> Token? {
            let boxed = erase(token)
            return boxed as? Token
        }
        func ordinary(_ value: Any) -> Int? { return value as? Int }
        """)
        XCTAssertFalse(kotlin.contains("boxed as? Token"), kotlin)
        XCTAssertTrue(kotlin.contains("internal fun ordinary(value: Any): Int? = value as? Int"), kotlin)
        XCTAssertFalse(kotlin.contains("AnyHashable(value as? Int)"), kotlin)
    }

    func testForcedCastsAndTypeChecksUnboxOnlyKnownPayloadTargets() async throws {
        try XCTSkipUnless(KotlinStandardLibraryParity.boxesAnyHashable, "AnyHashable boxing is off; SkipLib keeps AnyHashable a typealias (RNABrowser-fiea.30)")
        let kotlin = try await output("""
        func force(_ wrapped: AnyHashable) -> Int { return wrapped as! Int }
        func check(_ optional: AnyHashable?) -> Bool { return optional is Int }
        """)
        XCTAssertFalse(kotlin.contains("wrapped as Int"), kotlin)
        XCTAssertFalse(kotlin.contains("optional is Int"), kotlin)
    }

    func testErasedProtocolGenericAndSameNamedUserShapesAreNotUnboxed() async throws {
        let kotlin = try await output("""
        func retained(_ wrapped: AnyHashable) {
            let opaque = wrapped as Any
            let same = wrapped as? AnyHashable
            let hashable = wrapped is any Hashable
            let equatable = wrapped is any Equatable
        }
        func generic<T>(_ wrapped: AnyHashable, _ type: T.Type) -> T? { return wrapped as? T }
        """)
        XCTAssertFalse(kotlin.contains("wrapped.base"), kotlin)
        XCTAssertTrue(kotlin.contains("wrapped as Any"), kotlin)
        XCTAssertTrue(kotlin.contains("wrapped as? AnyHashable"), kotlin)
        XCTAssertTrue(kotlin.contains("wrapped as? T"), kotlin)
        let userType = try await output("""
        struct AnyHashable { let identifier: Int }
        func check(_ wrapped: AnyHashable) -> Bool { return wrapped is Int }
        """)
        XCTAssertTrue(userType.contains("wrapped is Int"), userType)
        XCTAssertFalse(userType.contains("wrapped.base"), userType)
    }
    func testNumericPayloadConversionsUseTheSwiftTargetWithoutReplacingCastOperators() async throws {
        try XCTSkipUnless(KotlinStandardLibraryParity.boxesAnyHashable, "AnyHashable boxing is off; SkipLib keeps AnyHashable a typealias (RNABrowser-fiea.30)")
        let kotlin = try await output("""
        func integer(_ wrapped: AnyHashable) -> Int? { return wrapped as? Int }
        func forced(_ optional: AnyHashable?) -> UInt64 { return optional as! UInt64 }
        func check(_ optional: AnyHashable?) -> Bool { return optional is Float }
        """)
        XCTAssertTrue(kotlin.contains("anyHashableCastValue(wrapped, targetSwiftType = \"Int\") as? Int"), kotlin)
        XCTAssertTrue(kotlin.contains("anyHashableCastValue(optional, targetSwiftType = \"UInt64\") as ULong"), kotlin)
        XCTAssertTrue(kotlin.contains("anyHashableCastValue(optional, targetSwiftType = \"Float\") is Float"), kotlin)
        XCTAssertTrue(kotlin.contains("import skip.lib.anyHashableCastValue"), kotlin)
    }

}
