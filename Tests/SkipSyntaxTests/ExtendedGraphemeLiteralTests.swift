// Copyright (c) 2026 Vindhya Data Science
// Licensed under the GNU Affero General Public License v3.0
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
@testable import SkipSyntax

final class ExtendedGraphemeLiteralTests: XCTestCase {
    private let types = """
    public struct LiteralKey: ExpressibleByExtendedGraphemeClusterLiteral {
        public let character: Character
        public init(extendedGraphemeClusterLiteral character: Character) { self.character = character }
    }
    public struct LiteralText: ExpressibleByExtendedGraphemeClusterLiteral {
        public let text: String
        public init(extendedGraphemeClusterLiteral text: String) { self.text = text }
    }
    """

    private func transpile(_ source: String, module: String = "LiteralConsumer",
                           dependencies: [CodebaseInfo.ModuleExport] = []) async throws -> (String, [Message], CodebaseInfo.ModuleExport) {
        let file = try tmpFile(named: "\(module).swift", contents: source)
        let info = CodebaseInfo(moduleName: module)
        info.dependentModules = dependencies
        let transpiler = Transpiler(packageName: KotlinTranslator.packageName(forModule: module), transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info, transformers: builtinKotlinTransformers())
        var kotlin = ""
        var messages: [Message] = []
        try await transpiler.transpile { result in kotlin += result.output.content; messages += result.messages }
        let data = try JSONEncoder().encode(CodebaseInfo.ModuleExport(of: info))
        return (kotlin, messages, try JSONDecoder().decode(CodebaseInfo.ModuleExport.self, from: data))
    }

    func testCharacterBackedLiteralsResolveFollowingContextAndLeaveStringsUnwrapped() async throws {
        let (kotlin, messages, _) = try await transpile(types + #"""

        enum Modifier { case command, shift }
        enum Localization { case automatic, custom }
        func shortcut(_ key: LiteralKey, modifiers: [Modifier], localization: Localization) {}
        func plain(_ value: String) {}
        func use() {
            shortcut("s", modifiers: [.command, .shift], localization: .custom)
            let accent: LiteralKey = "é"
            let arrow: LiteralKey = "\u{F702}"
            plain("ordinary")
        }
        """#)
        XCTAssertTrue(messages.isEmpty, messages.map(\.formattedMessage).joined(separator: "\n"))
        XCTAssertTrue(kotlin.contains("LiteralKey(extendedGraphemeClusterLiteral = 's')"), kotlin)
        XCTAssertTrue(kotlin.contains("LiteralKey(extendedGraphemeClusterLiteral = 'é')"), kotlin)
        XCTAssertTrue(kotlin.contains("LiteralKey(extendedGraphemeClusterLiteral = '\\uF702')"), kotlin)
        XCTAssertTrue(kotlin.contains("Modifier.command"), kotlin)
        XCTAssertTrue(kotlin.contains("Modifier.shift"), kotlin)
        XCTAssertTrue(kotlin.contains("Localization.custom"), kotlin)
        XCTAssertTrue(kotlin.contains("plain(\"ordinary\")"), kotlin)
        XCTAssertFalse(kotlin.contains("LiteralKey(stringLiteral"), kotlin)
        XCTAssertFalse(kotlin.contains("Any.command"), kotlin)
    }

    func testStringBackedSingleGraphemesPreserveAllUnicodeUnits() async throws {
        let (kotlin, messages, _) = try await transpile(types + #"""

        func use() {
            let emoji: LiteralText = "🦊"
            let combined: LiteralText = "e\u{301}"
        }
        """#)
        XCTAssertTrue(messages.isEmpty, messages.map(\.formattedMessage).joined(separator: "\n"))
        XCTAssertTrue(kotlin.contains("LiteralText(extendedGraphemeClusterLiteral = \"🦊\")"), kotlin)
        XCTAssertTrue(kotlin.contains("LiteralText(extendedGraphemeClusterLiteral = \"e\\u0301\")"), kotlin)
        XCTAssertFalse(kotlin.contains("LiteralText(stringLiteral"), kotlin)
    }

    func testOverloadedStringAndGraphemeCallsKeepValidStringAndSingleGraphemeCandidates() async throws {
        let (kotlin, messages, _) = try await transpile(types + """
        func choose(_ value: String) -> String { return value }
        func choose(_ value: LiteralKey) -> Int { return 1 }
        func use() {
            let ordinary: String = choose("ordinary")
            let key: Int = choose("s")
        }
        """)
        XCTAssertTrue(messages.isEmpty, messages.map(\.formattedMessage).joined(separator: "\n"))
        XCTAssertTrue(kotlin.contains("choose(\"ordinary\")"), kotlin)
        XCTAssertTrue(kotlin.contains("choose(LiteralKey(extendedGraphemeClusterLiteral = 's'))"), kotlin)
        XCTAssertFalse(kotlin.contains("extendedGraphemeClusterLiteral = \"ordinary\""), kotlin)
    }

    func testQualifiedLiteralTypeUsesSerializedProducerMetadata() async throws {
        let (_, producerMessages, exported) = try await transpile(types, module: "LiteralProducer")
        XCTAssertTrue(producerMessages.isEmpty, producerMessages.map(\.formattedMessage).joined(separator: "\n"))
        let (kotlin, messages, _) = try await transpile("""
        import LiteralProducer
        func receive(_ value: LiteralProducer.LiteralKey) {}
        func use() { receive("é") }
        """, dependencies: [exported])
        XCTAssertTrue(messages.isEmpty, messages.map(\.formattedMessage).joined(separator: "\n"))
        XCTAssertTrue(kotlin.contains("LiteralKey(extendedGraphemeClusterLiteral = 'é')"), kotlin)
        XCTAssertFalse(kotlin.contains("stringLiteral ="), kotlin)
    }

    func testUnsupportedInterpolationAndUnrepresentableCharacterHaveExplicitDiagnostics() async throws {
        let (_, messages, _) = try await transpile(types + #"""

        func use(_ text: String) {
            let interpolated: LiteralKey = "\(text)"
            let multiple: LiteralKey = "ab"
            let emoji: LiteralKey = "🦊"
        }
        """#)
        let errors = messages.filter { $0.kind == .error }.map(\.message).joined(separator: "\n")
        XCTAssertTrue(errors.contains("String interpolation cannot initialize"), errors)
        XCTAssertTrue(errors.contains("exactly one Character"), errors)
        XCTAssertTrue(errors.contains("single Kotlin Char"), errors)
    }
}
