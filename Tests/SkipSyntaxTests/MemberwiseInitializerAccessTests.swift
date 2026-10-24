// Copyright (c) 2026 Vindhya Data Science
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
@testable import SkipSyntax

/// RNABrowser-fiea.28: the synthesized memberwise initializers must have exactly the parameters
/// and access that Swift 6.4 (Xcode 27) gives them. Each expectation below was checked with
/// `swiftc -typecheck -swift-version 6` on a two-file module:
///
/// - A private/fileprivate stored property WITH a default value (written, or a mutable
///   Optional's implicit nil) does not lower the access of the initializer callers use: Swift
///   synthesizes the full initializer at the lower access and an initializer that omits those
///   properties at the access the remaining properties allow.
/// - A property-wrapped private/fileprivate property with a default (`@State private var x = 0`)
///   is omitted from every memberwise initializer.
/// - Negative controls (Swift rejects `T(x:)` from another file): a private property without a
///   default, a private Optional `let`, and a private Optional `@Binding` keep the initializer
///   private.
final class MemberwiseInitializerAccessTests: XCTestCase {
    private func sdk() async throws -> CodebaseInfo.ModuleExport {
        let source = """
        // SKIP SYMBOLFILE
        public protocol View { @ViewBuilder var body: any View { get } }
        extension View { public func padding(_ edges: Edge.Set) -> some View { self } }
        public enum Edge { public struct Set { public static let horizontal = Set() } }
        public struct Text: View { public init(_ value: String) {} }
        public struct Binding<Value> {}
        """
        let file = try tmpFile(named: "SDK.swift", contents: source)
        let info = CodebaseInfo(moduleName: "SkipUI")
        try await Transpiler(transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info,
            transformers: builtinKotlinTransformers()).transpile { result in
                XCTAssertTrue(result.messages.isEmpty, result.messages.map(\.formattedMessage).joined(separator: "\n"))
            }
        return try JSONDecoder().decode(CodebaseInfo.ModuleExport.self,
            from: JSONEncoder().encode(CodebaseInfo.ModuleExport(of: info)))
    }

    private func transpile(_ sources: [String: String]) async throws -> (kotlin: [String: String], info: CodebaseInfo, messages: [String]) {
        var paths: [Source.FilePath] = []
        for (name, contents) in sources.sorted(by: { $0.key < $1.key }) {
            paths.append(Source.FilePath(path: try tmpFile(named: name, contents: contents).path))
        }
        let info = CodebaseInfo(moduleName: "MemberwiseConsumer")
        info.dependentModules = [try await sdk()]
        var kotlin: [String: String] = [:]
        var messages: [String] = []
        try await Transpiler(transpileFiles: paths, codebaseInfo: info,
            transformers: builtinKotlinTransformers()).transpile { result in
                messages += result.messages.filter { $0.kind == .error }.map(\.formattedMessage)
                kotlin[result.output.file.name] = result.output.content
            }
        return (kotlin, info, messages)
    }

    private func initializers(_ name: String, _ source: String) async throws -> [(labels: [String], visibility: Modifiers.Visibility)] {
        let (_, info, messages) = try await transpile(["Types.swift": "import SwiftUI\n" + source])
        XCTAssertTrue(messages.isEmpty, messages.joined(separator: "\n"))
        let type = try XCTUnwrap(info.rootTypes.first { $0.name == name })
        return type.functions.filter { $0.declarationType == .initDeclaration }
            .map { ($0.signature.parameters.compactMap(\.label), $0.modifiers.visibility) }
    }

    private func assertInitializers(_ name: String, _ source: String, _ expected: [([String], Modifiers.Visibility)], file: StaticString = #filePath, line: UInt = #line) async throws {
        let actual = try await initializers(name, source)
        XCTAssertEqual(actual.map(\.labels), expected.map(\.0), source, file: file, line: line)
        XCTAssertEqual(actual.map(\.visibility), expected.map(\.1), source, file: file, line: line)
    }

    func testPrivateDefaultedStateIsOmittedAndKeepsInitializerInternal() async throws {
        try await assertInitializers("T", """
        struct T: View { let x: Int; @State private var s = 0; var body: some View { Text("") } }
        """, [(["x"], .internal)])
        try await assertInitializers("T", """
        struct T: View { let x: Int; @State private var s: Int?; var body: some View { Text("") } }
        """, [(["x"], .internal)])
        try await assertInitializers("T", """
        struct T: View { let x: Int; @State fileprivate var s = 0; @StateObject private var o = Model(); @AppStorage("k") private var a = 0; var body: some View { Text("") } }
        final class Model {}
        """, [(["x"], .internal)])
        try await assertInitializers("T", """
        @propertyWrapper struct W { var wrappedValue: Int }
        struct T { let x: Int; @W private var w = 0 }
        """, [(["x"], .internal)])
    }

    func testInternalDefaultedStateRemainsAParameter() async throws {
        try await assertInitializers("T", """
        struct T: View { let x: Int; @State var s = 0; var body: some View { Text("") } }
        """, [(["x", "s"], .internal)])
    }

    func testPrivateDefaultedStoredPropertyAddsAnInternalInitializer() async throws {
        try await assertInitializers("T", """
        struct T { let x: Int; private var p = 0 }
        """, [(["x", "p"], .private), (["x"], .internal)])
        // A mutable Optional's implicit nil is a default.
        try await assertInitializers("T", """
        struct T { let x: Int; private var p: Int? }
        """, [(["x", "p"], .private), (["x"], .internal)])
        try await assertInitializers("T", """
        struct T { let x: Int; private var p = 0; fileprivate var f = 0; var i = 0 }
        """, [(["x", "p", "f", "i"], .private), (["x", "i"], .internal)])
    }

    func testReducedInitializerTakesTheAccessOfTheRequiredProperties() async throws {
        // Swift: same-file `T(q: 1, f: 2)` compiles; the fileprivate defaulted `f` is kept.
        try await assertInitializers("T", """
        struct T { fileprivate let q: Int; private var p = 0; fileprivate var f = 0 }
        """, [(["q", "p", "f"], .private), (["q", "f"], .fileprivate)])
    }

    // Negative controls: Swift rejects `T(x: 1)` / `T(x: 1, p: 2)` from another file for each.
    func testRequiredPrivatePropertiesKeepTheOnlyInitializerPrivate() async throws {
        try await assertInitializers("T", """
        struct T { let x: Int; private var p: Int }
        """, [(["x", "p"], .private)])
        try await assertInitializers("T", """
        struct T { let x: Int; private let p: Int? }
        """, [(["x", "p"], .private)])
        try await assertInitializers("T", """
        struct T: View { let x: Int; @Binding private var b: Int?; var body: some View { Text("") } }
        """, [(["x", "b"], .private)])
        try await assertInitializers("T", """
        struct T: View { let x: Int; @State private var s: Int; var body: some View { Text("") } }
        """, [(["x", "s"], .private)])
        try await assertInitializers("T", """
        struct T { let x: Int; private var p = 0; private var q: Int }
        """, [(["x", "p", "q"], .private)])
    }

    /// The fiea.28 symptom: a View constructed in another file, with a chained implicit member.
    func testViewWithPrivateDefaultedStateIsConstructibleFromAnotherFile() async throws {
        let (kotlin, _, messages) = try await transpile([
            "Chip.swift": """
            import SwiftUI
            struct Chip: View {
                let reasons: [String]
                @State private var showDetail = false
                private var counter = 0
                var body: some View { Text("") }
            }
            """,
            "Use.swift": """
            import SwiftUI
            struct Host: View {
                var body: some View {
                    Chip(reasons: ["a"]).padding(.horizontal)
                }
            }
            """,
        ])
        XCTAssertTrue(messages.isEmpty, messages.joined(separator: "\n"))
        let use = try XCTUnwrap(kotlin.first { $0.key.hasPrefix("Use") }?.value)
        XCTAssertTrue(use.contains("Chip(reasons = arrayOf(\"a\")).padding(Edge.Set.horizontal)"), use)
    }

    /// Negative control for the cross-file path: Swift rejects this call, and so does Skip.
    func testViewWithRequiredPrivatePropertyIsNotConstructibleFromAnotherFile() async throws {
        let (_, _, messages) = try await transpile([
            "Chip.swift": """
            import SwiftUI
            struct Chip: View {
                let reasons: [String]
                private var counter: Int
                var body: some View { Text("") }
            }
            """,
            "Use.swift": """
            import SwiftUI
            struct Host: View {
                var body: some View {
                    Chip(reasons: ["a"], counter: 1).padding(.horizontal)
                }
            }
            """,
        ])
        XCTAssertFalse(messages.isEmpty)
        XCTAssertTrue(messages.contains { $0.contains("horizontal") }, messages.joined(separator: "\n"))
    }
}
