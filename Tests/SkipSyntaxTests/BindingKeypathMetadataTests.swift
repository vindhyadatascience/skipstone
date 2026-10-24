// Copyright (c) 2026 Vindhya Data Science
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
@testable import SkipSyntax

/// Preserve the SDK's two generic parameters and collection constraint through serialized exports.
final class BindingKeypathMetadataTests: XCTestCase {
    private func exported(_ swift: String, module: String, dependencies: [CodebaseInfo.ModuleExport] = []) async throws -> CodebaseInfo.ModuleExport {
        let file = try tmpFile(named: "\(module).swift", contents: swift)
        let info = CodebaseInfo(moduleName: module)
        info.dependentModules = dependencies
        let transpiler = Transpiler(transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info, transformers: builtinKotlinTransformers())
        try await transpiler.transpile { result in
            XCTAssertTrue(result.messages.isEmpty, result.messages.map(\.formattedMessage).joined(separator: "\n"))
        }
        return try JSONDecoder().decode(CodebaseInfo.ModuleExport.self, from: JSONEncoder().encode(CodebaseInfo.ModuleExport(of: info, includeTestingMetadata: true)))
    }

    private func output(_ source: String) async throws -> String {
        let lib = try await exported("""
        // SKIP SYMBOLFILE
        public protocol Sequence<Element> { associatedtype Element }
        public protocol Collection: Sequence {}
        public protocol BidirectionalCollection: Collection {}
        public protocol RandomAccessCollection: BidirectionalCollection {}
        public struct Array<Element>: RandomAccessCollection {}
        """, module: "SkipLib")
        let ui = try await exported("""
        // SKIP SYMBOLFILE
        public protocol View {}
        public struct Binding<Value> {
            public var wrappedValue: Value
            public init(get: () -> Value, set: (Value) -> Void) {}
        }
        public struct EditActions {}
        public final class ForEach: View {}
        public final class List: View {}
        public func ForEach<D>(_ data: any RandomAccessCollection<D>, id: (D) -> AnyHashable?, @ViewBuilder content: @escaping (D) -> any View) -> ForEach { fatalError() }
        public func ForEach<C, E>(_ data: Binding<C>, id: (E) -> AnyHashable?, editActions: EditActions = EditActions(), @ViewBuilder content: @escaping (Binding<E>) -> any View) -> ForEach where C: RandomAccessCollection<E> { fatalError() }
        public func List<ObjectType>(_ data: any RandomAccessCollection<ObjectType>, id: (ObjectType) -> AnyHashable?, @ViewBuilder rowContent: (ObjectType) -> any View) -> List where ObjectType: Any { fatalError() }
        public func List<Data, ObjectType>(_ data: Binding<Data>, id: (ObjectType) -> AnyHashable?, editActions: EditActions = EditActions(), @ViewBuilder rowContent: (Binding<ObjectType>) -> any View) -> List where Data: RandomAccessCollection<ObjectType> { fatalError() }
        public func plainBinding<C, E>(_ data: Binding<C>, id: (E) -> Int, content: (Binding<E>) -> any View) where C: RandomAccessCollection<E> {}
        """, module: "SkipUI", dependencies: [lib])
        let file = try tmpFile(named: "Consumer.swift", contents: source)
        let info = CodebaseInfo(moduleName: "Consumer")
        info.dependentModules = [lib, ui]
        let transpiler = Transpiler(packageName: "consumer", transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info, transformers: builtinKotlinTransformers())
        var kotlin = ""
        try await transpiler.transpile { result in
            XCTAssertTrue(result.messages.isEmpty, result.messages.map(\.formattedMessage).joined(separator: "\n"))
            kotlin += result.output.content
        }
        return kotlin
    }

    func testBindingCollectionIDKeypathsKeepTheirOptionalHashableReturnContext() async throws {
        try XCTSkipUnless(KotlinStandardLibraryParity.boxesAnyHashable, "AnyHashable boxing is off; SkipLib keeps AnyHashable a typealias (RNABrowser-fiea.30)")
        let kotlin = try await output(#"""
        import SwiftUI
        struct Entry { let identity: Int? }
        class Cell: View {}
        func use(_ values: Binding<[Entry]>, _ entries: [Entry]) {
            ForEach(values, id: \.identity) { _ in Cell() }
            List(values, id: \.identity) { _ in Cell() }
            ForEach(entries, id: \.identity) { _ in Cell() }
            List(entries, id: \.identity) { _ in Cell() }
        }
        """#)
        let mapped = "(it.identity).let { if (it == null) null else AnyHashable(it) }"
        XCTAssertTrue(kotlin.contains("ForEach(values, id = { \(mapped) }"), kotlin)
        XCTAssertTrue(kotlin.contains("List(values, id = { \(mapped) }"), kotlin)
        XCTAssertEqual(kotlin.components(separatedBy: mapped).count - 1, 4, kotlin)
    }

    func testBindingCollectionIDKeypathsBoxConcreteLeavesWithoutBoxingPlainCallback() async throws {
        try XCTSkipUnless(KotlinStandardLibraryParity.boxesAnyHashable, "AnyHashable boxing is off; SkipLib keeps AnyHashable a typealias (RNABrowser-fiea.30)")
        let kotlin = try await output(#"""
        import SwiftUI
        struct Entry { let number: Int }
        class Cell: View {}
        func use(_ values: Binding<[Entry]>) {
            ForEach(values, id: \.number) { _ in Cell() }
            List(values, id: \.number) { _ in Cell() }
            plainBinding(values, id: \.number) { _ in Cell() }
        }
        """#)
        XCTAssertTrue(kotlin.contains("ForEach(values, id = { AnyHashable(it.number) }"), kotlin)
        XCTAssertTrue(kotlin.contains("List(values, id = { AnyHashable(it.number) }"), kotlin)
        XCTAssertTrue(kotlin.contains("plainBinding(values, id = { it.number }"), kotlin)
        XCTAssertEqual(kotlin.components(separatedBy: "AnyHashable(").count - 1, 2, kotlin)
    }
}
