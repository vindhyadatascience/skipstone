// Copyright (c) 2026 Vindhya Data Science
// Licensed under the GNU Affero General Public License v3.0
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
@testable import SkipSyntax

final class XCTestUnwrapSymbolMetadataTests: XCTestCase {
    func testSerializedUnwrapMetadataRetainsGenericNonoptionalResult() async throws {
        let producerFile = try tmpFile(named: "XCTest.swift", contents: """
        // SKIP SYMBOLFILE
        public func XCTUnwrap<T>(_ value: T?, _ msg: String = "") throws -> T { return value! }
        """)
        let producerInfo = CodebaseInfo(moduleName: "SkipUnit")
        let producer = Transpiler(transpileFiles: [Source.FilePath(path: producerFile.path)], codebaseInfo: producerInfo, transformers: builtinKotlinTransformers())
        try await producer.transpile { result in XCTAssertTrue(result.messages.isEmpty) }
        let module = try JSONDecoder().decode(CodebaseInfo.ModuleExport.self, from: JSONEncoder().encode(CodebaseInfo.ModuleExport(of: producerInfo)))
        let file = try tmpFile(named: "UnwrapConsumer.swift", contents: """
        import SkipUnit
        final class Probe { var text: String = "retained" }
        func use(_ value: Probe?) throws -> String {
            let result = try XCTUnwrap(value)
            return result.text
        }
        """)
        let info = CodebaseInfo(moduleName: "Consumer")
        info.dependentModules = [module]
        let consumer = Transpiler(transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info, transformers: builtinKotlinTransformers())
        try await consumer.transpile { result in
            XCTAssertTrue(result.messages.isEmpty, result.messages.map(\.formattedMessage).joined(separator: "\n"))
            guard result.input.file.name == "UnwrapConsumer.swift" else { return }
            let tree = SyntaxTree(source: result.input, codebaseInfo: info)
            var matches = 0
            tree.root.visit { node in
                if let call = node as? FunctionCall, (call.function as? Identifier)?.name == "XCTUnwrap" {
                    matches += 1
                    XCTAssertNotNil(call.apiMatch)
                    XCTAssertTrue(call.inferredType.isNamed("Probe"), call.inferredType.description)
                    XCTAssertFalse(call.inferredType.isOptional)
                    XCTAssertNotEqual(call.apiMatch?.signature.apiFlags.throwsType, TypeSignature.none)
                }
                return .recurse(nil)
            }
            XCTAssertEqual(matches, 1)
        }
    }
}
