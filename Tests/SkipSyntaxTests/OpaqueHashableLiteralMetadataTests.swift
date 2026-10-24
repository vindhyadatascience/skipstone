// Copyright (c) 2026 Vindhya Data Science
// Licensed under the GNU Affero General Public License v3.0
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
@testable import SkipSyntax

final class OpaqueHashableLiteralMetadataTests: XCTestCase {
    private func export(_ source: String, module: String, dependencies: [CodebaseInfo.ModuleExport] = []) async throws -> CodebaseInfo.ModuleExport {
        let file = try tmpFile(named: module + ".swift", contents: "// SKIP SYMBOLFILE\n" + source)
        let info = CodebaseInfo(moduleName: module)
        info.dependentModules = dependencies
        let transpiler = Transpiler(transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info, transformers: builtinKotlinTransformers())
        try await transpiler.transpile { result in XCTAssertTrue(result.messages.isEmpty) }
        return try JSONDecoder().decode(CodebaseInfo.ModuleExport.self, from: JSONEncoder().encode(CodebaseInfo.ModuleExport(of: info)))
    }

    func testPublicOpaqueHashableFormalKeepsItsStringLiteralPayloadAcrossMetadata() async throws {
        let library = try await export("public protocol Equatable {}\npublic protocol Hashable: Equatable {}", module: "SkipLib")
        // Exact opaque formal used by CoordinateSpaceProtocol.named(_:).
        let sdk = try await export("""
        @_exported import SkipLib
        public func named(_ name: some Hashable) -> Int { return 0 }
        """, module: "CoordinateSDK", dependencies: [library])
        let file = try tmpFile(named: "LiteralConsumer.swift", contents: "import CoordinateSDK\nfunc use() { let value = named(\"literal\") }")
        let info = CodebaseInfo(moduleName: "LiteralConsumer")
        info.dependentModules = [library, sdk]
        let transpiler = Transpiler(transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info, transformers: builtinKotlinTransformers())
        var kotlin = ""
        try await transpiler.transpile { result in
            XCTAssertTrue(result.messages.isEmpty, result.messages.map(\.formattedMessage).joined(separator: "\n"))
            kotlin += result.output.content
            guard result.input.file.name == "LiteralConsumer.swift" else { return }
            let tree = SyntaxTree(source: result.input, codebaseInfo: info)
            tree.root.visit { node in
                if let call = node as? FunctionCall, (call.function as? Identifier)?.name == "named" {
                    XCTAssertNotNil(call.apiMatch)
                    if let literal = call.arguments.first?.value as? StringLiteral {
                        XCTAssertNil(literal.expressibleByStringLiteralType)
                        XCTAssertNil(literal.expressibleByStringInterpolationType)
                    } else { XCTFail("Expected the original String literal argument") }
                }
                return .recurse(nil)
            }
        }
        XCTAssertTrue(kotlin.contains("named(\"literal\")"), kotlin)
        XCTAssertFalse(kotlin.contains("Hashable(stringLiteral"), kotlin)
    }
}
