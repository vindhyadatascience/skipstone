// Copyright (c) 2026 Vindhya Data Science
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
@testable import SkipSyntax

/// RNABrowser-fiea.28, found by GeneFox's FoxCoreTests JVM build: upstream 1.9.17+ passes #expect/#require
/// message arguments through, and a Swift Testing `Comment(...)` has no Kotlin type.
final class TestingCommentMessageTests: XCTestCase {
    private func transpile(_ source: String) async throws -> (String, [String]) {
        let file = try tmpFile(named: "Source.swift", contents: source)
        let info = CodebaseInfo(moduleName: "Consumer")
        var kotlin = ""
        var errors: [String] = []
        try await Transpiler(packageName: "consumer", transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info, transformers: builtinKotlinTransformers()).transpile { result in
            errors += result.messages.filter { $0.kind == .error }.map(\.formattedMessage)
            kotlin += result.output.content
        }
        return (kotlin, errors)
    }

    /// Swift Testing messages written as `Comment(stringLiteral:)` reach SkipUnit as the String.
    func testTestingCommentMessageIsPassedAsItsText() async throws {
        let (kotlin, errors) = try await transpile("""
        import Testing
        struct T {
            @Test func check() throws {
                let n = 41
                #expect(n >= 40, Comment(stringLiteral: "n must be at least 40"))
                try #require(n > 0, Comment(rawValue: "n must be positive"))
                #expect(n != 0, "plain message")
            }
        }
        """)
        XCTAssertEqual(errors, [])
        XCTAssertFalse(kotlin.contains("Comment("), kotlin)
        XCTAssertTrue(kotlin.contains(#"expectGreaterThanOrEqual(n, 40, "n must be at least 40")"#), kotlin)
        XCTAssertTrue(kotlin.contains(#"requireGreaterThan(n, 0, "n must be positive")"#), kotlin)
        XCTAssertTrue(kotlin.contains(#"expectNotEqual(n, 0, "plain message")"#), kotlin)
    }
}
