// Copyright (c) 2026 Vindhya Data Science
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
@testable import SkipSyntax

final class CollectionConstructorMetadataTests: XCTestCase {
    private func symbols() async throws -> CodebaseInfo.ModuleExport {
        let swift = """
        // SKIP SYMBOLFILE
        public protocol IteratorProtocol<Element> {
            associatedtype Element
            mutating func next() -> Element?
        }
        public protocol Sequence<Element> {
            associatedtype Element
            func makeIterator() -> any IteratorProtocol<Element>
        }
        public struct Array<Element>: Sequence { public init() {} }
        public struct Set<Element>: Sequence {
            public init() {}
            public init(_ sequence: any Sequence<Element>) {}
        }
        """
        let file = try tmpFile(named: "Symbols.swift", contents: swift)
        let info = CodebaseInfo(moduleName: "SkipLib")
        let transpiler = Transpiler(transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info, transformers: builtinKotlinTransformers())
        try await transpiler.transpile { _ in }
        return try JSONDecoder().decode(CodebaseInfo.ModuleExport.self, from: JSONEncoder().encode(CodebaseInfo.ModuleExport(of: info)))
    }

    func testSetSequenceConstructorInfersElementForStoredProperty() async throws {
        let file = try tmpFile(named: "Source.swift", contents: """
        class Holder {
            var writes = 0
            var members = Set([1, 2, 3]) { didSet { writes += 1 } }
        }
        """)
        let info = CodebaseInfo(moduleName: "Consumer")
        info.dependentModules = [try await symbols()]
        var kotlin = ""
        let transpiler = Transpiler(packageName: "consumer", transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info, transformers: builtinKotlinTransformers())
        try await transpiler.transpile { result in
            XCTAssertTrue(result.messages.isEmpty, result.messages.map(\.formattedMessage).joined(separator: "\n"))
            kotlin += result.output.content
        }
        let holder = try XCTUnwrap(info.rootTypes.first { $0.name == "Holder" })
        let members = try XCTUnwrap(holder.variables.first { $0.name == "members" })
        XCTAssertEqual(members.signature, .set(.int), kotlin)
        XCTAssertFalse(kotlin.contains("Set<Sequence<Int>>"), kotlin)
    }

    func testExplicitSetElementContextReachesArrayLiteral() async throws {
        let file = try tmpFile(named: "Source.swift", contents: """
        func make() { let value = Set<Float>([-0.0, 0.0]) }
        """)
        let info = CodebaseInfo(moduleName: "Consumer")
        info.dependentModules = [try await symbols()]
        var kotlin = ""
        let transpiler = Transpiler(packageName: "consumer", transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info, transformers: builtinKotlinTransformers())
        try await transpiler.transpile { result in
            XCTAssertTrue(result.messages.isEmpty, result.messages.map(\.formattedMessage).joined(separator: "\n"))
            kotlin += result.output.content
        }
        XCTAssertTrue(kotlin.contains("Set<Float>(arrayOf(-0.0f, 0.0f))"), kotlin)
    }

    /// RNABrowser-fiea.28: `[[], []]` for a `[[Double]]` parameter. 1.9.19-vds.2 asked the
    /// provisional `[?]` expectation of the second element for its iterator element, got the
    /// unbound `Element` generic, and then no overload matched (FoxCoreTests: "unable to determine
    /// the owning type for member 'log2'").
    func testNestedEmptyArrayLiteralsMatchTheirParameter() async throws {
        let file = try tmpFile(named: "Source.swift", contents: """
        public enum Scale { case log2, linear }
        public struct Input {
            public static func make(groups: [[Double]], scale: Scale) -> Input? { nil }
        }
        func use() -> Input? {
            return Input.make(groups: [[], []], scale: .log2)
        }
        """)
        let info = CodebaseInfo(moduleName: "Consumer")
        info.dependentModules = [try await symbols()]
        var kotlin = ""
        let transpiler = Transpiler(packageName: "consumer", transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info, transformers: builtinKotlinTransformers())
        try await transpiler.transpile { result in
            XCTAssertTrue(result.messages.isEmpty, result.messages.map(\.formattedMessage).joined(separator: "\n"))
            kotlin += result.output.content
        }
        XCTAssertTrue(kotlin.contains("Input.make(groups = arrayOf(arrayOf(), arrayOf()), scale = Scale.log2)"), kotlin)
    }
}
