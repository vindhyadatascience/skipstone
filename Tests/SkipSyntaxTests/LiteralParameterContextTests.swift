// Copyright (c) 2026 Vindhya Data Science
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
@testable import SkipSyntax

/// RNABrowser-fiea.28: a literal argument takes its parameter's type. 1.9.19-vds.2 reversed
/// Parameter.or's operands for array literals, so `store[key, default: []]` for a `Set` value
/// was typed as an Array literal (`arrayOf()`), which Kotlin rejects.
final class LiteralParameterContextTests: XCTestCase {
    private func sdk() async throws -> CodebaseInfo.ModuleExport {
        let source = """
        // SKIP SYMBOLFILE
        public struct Store<Key: Hashable, Value> {
            public init() {}
            public subscript(key: Key, default defaultValue: Value) -> Value { get { defaultValue } set {} }
            public func value(for key: Key, default defaultValue: Value) -> Value { defaultValue }
        }
        """
        let file = try tmpFile(named: "StoreSDK.swift", contents: source)
        let info = CodebaseInfo(moduleName: "StoreSDK")
        try await Transpiler(transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info,
            transformers: builtinKotlinTransformers()).transpile { result in
                XCTAssertTrue(result.messages.isEmpty, result.messages.map(\.formattedMessage).joined(separator: "\n"))
            }
        return try JSONDecoder().decode(CodebaseInfo.ModuleExport.self,
            from: JSONEncoder().encode(CodebaseInfo.ModuleExport(of: info)))
    }

    private func transpile(_ source: String) async throws -> String {
        let file = try tmpFile(named: "Use.swift", contents: "import StoreSDK\n" + source)
        let info = CodebaseInfo(moduleName: "StoreUser")
        info.dependentModules = [try await sdk()]
        var kotlin = ""
        try await Transpiler(transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info,
            transformers: builtinKotlinTransformers()).transpile { result in
                XCTAssertEqual(result.messages.filter { $0.kind == .error }.map(\.formattedMessage), [])
                kotlin += result.output.content
            }
        return kotlin
    }

    func testEmptyArrayLiteralTakesASetParameterType() async throws {
        let kotlin = try await transpile("""
        func lookup(_ store: Store<String, Set<String>>) -> Set<String> {
            let viaSubscript = store["a", default: []]
            let viaFunction = store.value(for: "b", default: [])
            return viaSubscript.union(viaFunction)
        }
        """)
        XCTAssertFalse(kotlin.contains("arrayOf()"), kotlin)
        XCTAssertTrue(kotlin.contains(#"store["a", setOf()]"#), kotlin)
        XCTAssertTrue(kotlin.contains(#"store.value(for_ = "b", default = setOf())"#), kotlin)
    }

    /// Control: an Array parameter still gets an Array literal.
    func testEmptyArrayLiteralForAnArrayParameterIsUnchanged() async throws {
        let kotlin = try await transpile("""
        func lookup(_ store: Store<String, [String]>) -> [String] {
            return store["a", default: []]
        }
        """)
        XCTAssertTrue(kotlin.contains(#"store["a", arrayOf()]"#), kotlin)
    }
}
