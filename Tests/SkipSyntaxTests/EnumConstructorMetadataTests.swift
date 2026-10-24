// Copyright (c) 2026 Vindhya Data Science
// Licensed under the GNU Affero General Public License v3.0
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
@testable import SkipSyntax

final class EnumConstructorMetadataTests: XCTestCase {
    private func exported(_ swift: String) async throws -> CodebaseInfo.ModuleExport {
        let file = try tmpFile(named: "Producer.swift", contents: swift)
        let info = CodebaseInfo(moduleName: "EnumProducer")
        let transpiler = Transpiler(transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info, transformers: builtinKotlinTransformers())
        try await transpiler.transpile { result in
            XCTAssertTrue(result.messages.isEmpty, result.messages.map(\.formattedMessage).joined(separator: "\n"))
        }
        let data = try JSONEncoder().encode(CodebaseInfo.ModuleExport(of: info, includeTestingMetadata: true))
        return try JSONDecoder().decode(CodebaseInfo.ModuleExport.self, from: data)
    }

    func testRawEnumExportsItsFailableConstructorWithExactRawTypeAndAccess() async throws {
        let module = try await exported("""
        public enum TextKind: String { case one, two }
        public enum NumberKind: Int64 { case one = 1 }
        public struct Outer { public enum Nested: Int { case zero } }
        enum InternalKind: String { case one }
        private enum SecretKind: String { case one }
        """)
        for (name, rawType) in [("TextKind", TypeSignature.string), ("NumberKind", .int64)] {
            let type = try XCTUnwrap(module.rootTypes.first { $0.name == name })
            let initializers = type.functions.filter { $0.declarationType == .initDeclaration }
            XCTAssertEqual(initializers.count, 1)
            let initializer = try XCTUnwrap(initializers.first)
            XCTAssertTrue(initializer.isGenerated)
            XCTAssertEqual(initializer.modifiers.visibility, .public)
            XCTAssertTrue(initializer.signature.returnType.isOptional)
            XCTAssertTrue(initializer.signature.returnType.withoutOptionality().isSameType(as: type.signature))
            XCTAssertEqual(initializer.signature.parameters.map(\.label), ["rawValue"])
            XCTAssertTrue(initializer.signature.parameters[0].type.isSameType(as: rawType))
        }
        let outer = try XCTUnwrap(module.rootTypes.first { $0.name == "Outer" })
        let nested = try XCTUnwrap(outer.types.first { $0.name == "Nested" })
        XCTAssertTrue(nested.functions.contains { $0.isGenerated && $0.declarationType == .initDeclaration && $0.signature.returnType.isOptional })
        XCTAssertFalse(module.rootTypes.contains { $0.name == "InternalKind" || $0.name == "SecretKind" })
        let internalType = try XCTUnwrap(module.testingMetadata?.rootTypes.first { $0.name == "InternalKind" })
        XCTAssertEqual(internalType.functions.filter { $0.declarationType == .initDeclaration }.first?.modifiers.visibility, .internal)
        XCTAssertFalse(module.testingMetadata?.rootTypes.contains { $0.name == "SecretKind" } ?? true)
    }

    func testExplicitExactRawInitializerIsNotDuplicatedOrMadeFailable() async throws {
        let module = try await exported("""
        public enum Explicit: Int {
            case one = 1
            public init(rawValue: Int) { self = .one }
        }
        public enum Overloaded: Int {
            case one = 1
            public init(rawValue: String) { self = .one }
        }
        """)
        let explicit = try XCTUnwrap(module.rootTypes.first { $0.name == "Explicit" })
        let explicitInits = explicit.functions.filter { $0.declarationType == .initDeclaration }
        XCTAssertEqual(explicitInits.count, 1)
        XCTAssertFalse(explicitInits[0].isGenerated)
        XCTAssertFalse(explicitInits[0].signature.returnType.isOptional)
        let overload = try XCTUnwrap(module.rootTypes.first { $0.name == "Overloaded" })
        let overloadInits = overload.functions.filter { $0.declarationType == .initDeclaration }
        XCTAssertEqual(overloadInits.count, 2)
        let generated = try XCTUnwrap(overloadInits.first { $0.isGenerated })
        XCTAssertTrue(generated.signature.returnType.isOptional)
        XCTAssertTrue(generated.signature.parameters[0].type.isSameType(as: .int))
    }
}
