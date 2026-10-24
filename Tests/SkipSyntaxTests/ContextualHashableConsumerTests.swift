// Copyright (c) 2026 Vindhya Data Science
// Licensed under the GNU Affero General Public License v3.0
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import SkipSyntax

final class ContextualHashableConsumerTests: XCTestCase {
    private func output(_ source: String, module: String = "Consumer", package: String = "consumer") async throws -> String {
        let file = try tmpFile(named: "Source.swift", contents: source)
        let info = CodebaseInfo(moduleName: module)
        let transpiler = Transpiler(packageName: package, transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info, transformers: builtinKotlinTransformers())
        var result = ""
        var messages: [Message] = []
        try await transpiler.transpile { result += $0.output.content; messages += $0.messages }
        XCTAssertTrue(messages.isEmpty, messages.map(\.formattedMessage).joined(separator: "\n"))
        return result
    }

    func testContextualClosureResultsBoxImplicitAndExplicitReturns() async throws {
        let kotlin = try await output("""
        func accept(_ id: (Int) -> AnyHashable?) {}
        func use() {
            accept { value in value }
            accept { value in return value }
            accept { value in value > 0 ? value : nil }
            let result: (Int) -> AnyHashable? = { $0 }
        }
        """)
        XCTAssertEqual(kotlin.components(separatedBy: "AnyHashable(").count - 1, 4, kotlin)
        XCTAssertFalse(kotlin.contains("accept { value -> value }"), kotlin)
    }

    func testDictionaryKeysBoxOnlyForHashableKeyDictionary() async throws {
        let kotlin = try await output("""
        func read(_ erased: [AnyHashable: String], _ strings: [String: String], _ key: String) {
            let first = erased["link"]
            let second = erased[key]
            let plain = strings[key]
        }
        """)
        XCTAssertTrue(kotlin.contains("erased[AnyHashable(\"link\")]"), kotlin)
        XCTAssertTrue(kotlin.contains("erased[AnyHashable(key)]"), kotlin)
        XCTAssertTrue(kotlin.contains("strings[key]"), kotlin)
    }

    func testFunctionConvertedKeyPathBoxesActualLeaf() async throws {
        let kotlin = try await output(#"""
        struct Item { let number: Int; let optional: String? }
        func accept(_ id: (Item) -> AnyHashable?) {}
        func intID(_ id: (Int) -> AnyHashable?) {}
        func plain(_ id: (Item) -> Int) {}
        func use() {
            accept(\.number)
            accept(\.optional)
            intID(\.self)
            plain(\.number)
        }
        """#)
        XCTAssertTrue(kotlin.contains("AnyHashable(it.number)"), kotlin)
        XCTAssertTrue(kotlin.contains("AnyHashable(it)"), kotlin)
        XCTAssertTrue(kotlin.contains("it.optional"), kotlin)
        XCTAssertEqual(kotlin.components(separatedBy: "AnyHashable(").count - 1, 3, kotlin)
        XCTAssertTrue(kotlin.contains("plain({ it.number })"), kotlin)
    }

    func testConditionalCastResultsKeepTheirOptionalPresenceWhenBoxed() async throws {
        let kotlin = try await output("""
        func accept(_ id: (Any) -> AnyHashable?) {}
        func use() {
            accept { $0 as? Int }
            accept { $0 as? String }
        }
        """)
        XCTAssertTrue(kotlin.contains("(it as? Int).let { if (it == null) null else AnyHashable(it) }"), kotlin)
        XCTAssertTrue(kotlin.contains("(it as? String).let { if (it == null) null else AnyHashable(it) }"), kotlin)
        XCTAssertFalse(kotlin.contains("AnyHashable(it as?"), kotlin)
    }

    func testOptionalCallbackKeyPathRetainsConcreteLeafForHashableConversion() async throws {
        let kotlin = try await output(#"""
        func accept(id: ((Int) -> AnyHashable?)? = nil) {}
        func use() { accept(id: \.self) }
        """#)
        XCTAssertTrue(kotlin.contains("id = { AnyHashable(it) }"), kotlin)
    }

    func testArraysOfOptionSetsStayCollectionsWhileOptionLiteralsCombineFlags() async throws {
        let kotlin = try await output("""
        struct Flags: OptionSet {
            let rawValue: Int
            static let first = Flags(rawValue: 1)
            static let second = Flags(rawValue: 2)
        }
        func use() {
            let formats: [Flags] = [[], [.first], [.first, .second]]
            let inferred = [Flags.first, Flags.second]
            let combined: Flags = [.first, .second]
        }
        """)
        XCTAssertTrue(kotlin.contains("formats: Array<Flags> = arrayOf(Flags.of(), Flags.of(Flags.first), Flags.of(Flags.first, Flags.second))"), kotlin)
        XCTAssertTrue(kotlin.contains("inferred = arrayOf(Flags.first, Flags.second)"), kotlin)
        XCTAssertTrue(kotlin.contains("combined: Flags = Flags.of(Flags.first, Flags.second)"), kotlin)
    }

    func testGeneratedViewsInsideSkipUIImportComposeDependencies() async throws {
        let kotlin = try await output("""
        import SwiftUI
        protocol View { var body: some View { get } }
        struct Text: View { init(_ text: String) {} }
        struct Probe: View {
            @State var count = 0
            var body: some View { Text("Count") }
        }
        """, module: "SwiftUI", package: "skip.ui")
        for name in ["androidx.compose.runtime.Composable", "androidx.compose.runtime.mutableStateOf", "androidx.compose.runtime.saveable.rememberSaveable", "androidx.compose.runtime.saveable.Saver"] {
            XCTAssertTrue(kotlin.contains("import " + name), kotlin)
        }
        XCTAssertTrue(kotlin.contains("override fun Evaluate"), kotlin)
    }
}
