// Copyright (c) 2026 Vindhya Data Science
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
@testable import SkipSyntax

/// RNABrowser-fiea.28: `T(...)` always yields `T` in Swift. When `T` comes from another module and
/// none of its visible initializers match (for example a public struct whose memberwise initializer
/// is internal), the call still has type `T`, so an enclosing overload such as
/// `items.contains(T(...))` must pick the element overload rather than an unavailable generic one.
/// No initializer signature is invented: arguments are not checked or typed against one.
final class ExternalConstructorResultTypeTests: XCTestCase {
    private func sdk() async throws -> CodebaseInfo.ModuleExport {
        let source = """
        // SKIP SYMBOLFILE
        public protocol Pattern {}
        public struct QueryItem: Equatable {
            public var name: String
            public var value: String?
        }
        public struct Count {
            public init(value: Int) {}
        }
        public struct Box<T> {
            public var value: T
        }
        // Mirrors SkipLib: Sequence.contains(_:) and the unavailable
        // BidirectionalCollection.contains(_: some RegexComponent).
        public protocol Seq<Element> { associatedtype Element }
        extension Seq {
            public func has(_ element: Element) -> Bool { false }
        }
        public protocol BiColl: Seq {}
        extension BiColl {
            @available(*, unavailable)
            public func has(_ pattern: some Pattern) -> Bool { false }
        }
        public final class Bag<Element>: BiColl {
            public init() {}
        }
        """
        let file = try tmpFile(named: "Producer.swift", contents: source)
        let info = CodebaseInfo(moduleName: "Producer")
        try await Transpiler(transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info,
            transformers: builtinKotlinTransformers()).transpile { result in
                XCTAssertTrue(result.messages.isEmpty, result.messages.map(\.formattedMessage).joined(separator: "\n"))
            }
        return try JSONDecoder().decode(CodebaseInfo.ModuleExport.self,
            from: JSONEncoder().encode(CodebaseInfo.ModuleExport(of: info)))
    }

    private func transpile(_ source: String) async throws -> (kotlin: String, errors: [String]) {
        let file = try tmpFile(named: "Consumer.swift", contents: "import Producer\n" + source)
        let info = CodebaseInfo(moduleName: "Consumer")
        info.dependentModules = [try await sdk()]
        var kotlin = ""
        var errors: [String] = []
        try await Transpiler(transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info,
            transformers: builtinKotlinTransformers()).transpile { result in
                errors += result.messages.filter { $0.kind == .error }.map(\.formattedMessage)
                kotlin += result.output.content
            }
        return (kotlin, errors)
    }

    /// The CBioPortalTests shape: a dependency struct with only an internal memberwise init.
    func testDependencyStructWithoutPublicInitSelectsElementOverload() async throws {
        let (kotlin, errors) = try await transpile("""
        func check(_ items: Bag<QueryItem>) -> Bool {
            return items.has(QueryItem(name: "pageSize", value: "100"))
        }
        """)
        XCTAssertEqual(errors, [])
        XCTAssertTrue(kotlin.contains(#"items.has(QueryItem(name = "pageSize", value = "100"))"#), kotlin)
    }

    /// The GEOFinderValidator shape: a dependency type whose public inits do not take the argument.
    func testUnmatchedDependencyInitializerStillYieldsItsType() async throws {
        let (_, errors) = try await transpile("""
        func check(_ counts: Bag<Count>, _ n: Int) -> Bool {
            return counts.has(Count(n))
        }
        """)
        XCTAssertEqual(errors, [])
    }

    // Negative controls.

    /// No signature is invented for the arguments: an implicit member argument still has no
    /// owning type to resolve against.
    func testArgumentsAreNotTypedAgainstAnInventedInitializer() async throws {
        let (_, errors) = try await transpile("""
        func check(_ items: Bag<QueryItem>) -> Bool {
            return items.has(QueryItem(name: .init(), value: .none))
        }
        """)
        XCTAssertTrue(errors.contains { $0.contains("init") }, errors.joined(separator: "\n"))
    }

    /// A generic dependency type's arguments come from its initializer, so no type is assumed.
    func testGenericDependencyTypeIsNotAssumed() async throws {
        let (_, errors) = try await transpile("""
        func check(_ boxes: Bag<Box<Int>>) -> Bool {
            return boxes.has(Box(value: 1))
        }
        """)
        XCTAssertFalse(errors.isEmpty)
    }

    /// This module's types keep their real (generated) initializers; no fallback applies.
    func testOwnModuleTypeWithoutMatchingInitIsNotAssumed() async throws {
        let (_, errors) = try await transpile("""
        struct Local: Equatable { let name: String }
        func check(_ items: Bag<Local>) -> Bool {
            return items.has(Local(title: "x"))
        }
        """)
        XCTAssertFalse(errors.isEmpty)
    }
}
