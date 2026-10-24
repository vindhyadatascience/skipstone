// Copyright (c) 2026 Vindhya Data Science
// Licensed under the GNU Affero General Public License v3.0
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
@testable import SkipSyntax

final class KnownHashableConstructorMetadataTests: XCTestCase {
    private func consumer(_ source: String) async throws -> String {
        // Same public constructor/protocol shape as actual SkipLib/Hashable.swift.
        // Round-trip symbol metadata rather than replacing the generic init with
        // an unconstrained eager Kotlin-shaped initializer in the consumer.
        let symbol = try tmpFile(named: "Hashable.swift", contents: """
        // SKIP SYMBOLFILE
        public protocol Equatable {}
        public protocol Hashable: Equatable { var hashValue: Int { get } }
        public struct AnyHashable: Hashable {
            public init<H: Hashable>(_ base: H) {}
            public var base: Any { fatalError() }
            public var hashValue: Int { fatalError() }
        }
        """)
        let producerInfo = CodebaseInfo(moduleName: "SkipLib")
        let producer = Transpiler(transpileFiles: [Source.FilePath(path: symbol.path)], codebaseInfo: producerInfo, transformers: builtinKotlinTransformers())
        try await producer.transpile { result in XCTAssertTrue(result.messages.isEmpty) }
        let module = try JSONDecoder().decode(CodebaseInfo.ModuleExport.self, from: JSONEncoder().encode(CodebaseInfo.ModuleExport(of: producerInfo)))
        let file = try tmpFile(named: "WrapperConsumer.swift", contents: "import SkipLib\n" + source)
        let info = CodebaseInfo(moduleName: "WrapperConsumer")
        info.dependentModules = [module]
        let transpiler = Transpiler(transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info, transformers: builtinKotlinTransformers())
        var kotlin = ""
        try await transpiler.transpile { result in
            XCTAssertTrue(result.messages.isEmpty, result.messages.map(\.formattedMessage).joined(separator: "\n"))
            kotlin += result.output.content
            guard result.input.file.name == "WrapperConsumer.swift" else { return }
            let tree = SyntaxTree(source: result.input, codebaseInfo: info)
            var constructors = 0
            tree.root.visit { node in
                if let call = node as? FunctionCall, (call.function as? Identifier)?.name == "AnyHashable" {
                    constructors += 1
                    XCTAssertNotNil(call.apiMatch)
                    XCTAssertTrue(call.isInit)
                    XCTAssertTrue(call.inferredType.isNamed("AnyHashable"), call.inferredType.description)
                }
                if let cast = node as? BinaryOperator, cast.op.symbol == "as?" {
                    XCTAssertTrue(cast.lhs.inferredType.isNamed("AnyHashable"), cast.lhs.inferredType.description)
                }
                return .recurse(nil)
            }
            XCTAssertEqual(constructors, 1)
        }
        return kotlin
    }

    func testInferredLocalFromActualGenericHashableConstructorKeepsWrapperType() async throws {
        let kotlin = try await consumer("""
        func use() -> Double? {
            let integer = AnyHashable(Int(7))
            return integer as? Double
        }
        """)
        XCTAssertTrue(kotlin.contains("anyHashableCastValue(integer, targetSwiftType = \"Double\") as? Double"), kotlin)
        XCTAssertFalse(kotlin.contains("integer as? Double"), kotlin)
    }

    func testDirectActualGenericHashableConstructorKeepsWrapperType() async throws {
        let kotlin = try await consumer("""
        func use() -> Bool? { return AnyHashable(Double(0)) as? Bool }
        """)
        XCTAssertTrue(kotlin.contains("anyHashableCastValue(AnyHashable("), kotlin)
        XCTAssertTrue(kotlin.contains("targetSwiftType = \"Bool\") as? Boolean"), kotlin)
        XCTAssertEqual(kotlin.components(separatedBy: "anyHashableCastValue(").count - 1, 1, kotlin)
    }
}
