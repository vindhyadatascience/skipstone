// Copyright (c) 2026 Vindhya Data Science
// Licensed under the GNU Affero General Public License v3.0
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
@testable import SkipSyntax

final class BuiltinScalarHashableCompatibilityTests: XCTestCase {
    private func context(module: String, declarations: String) async throws -> CodebaseInfo.Context {
        let producerFile = try tmpFile(named: "Constraints.swift", contents: "// SKIP SYMBOLFILE\n" + declarations)
        let producerInfo = CodebaseInfo(moduleName: module)
        let producer = Transpiler(transpileFiles: [Source.FilePath(path: producerFile.path)], codebaseInfo: producerInfo, transformers: builtinKotlinTransformers())
        try await producer.transpile { result in XCTAssertTrue(result.messages.isEmpty) }
        let exported = try JSONDecoder().decode(CodebaseInfo.ModuleExport.self, from: JSONEncoder().encode(CodebaseInfo.ModuleExport(of: producerInfo)))
        let consumerFile = try tmpFile(named: "ConstraintConsumer.swift", contents: "import \(module)\nlet fixture = true")
        let consumerInfo = CodebaseInfo(moduleName: "ConstraintConsumer")
        consumerInfo.dependentModules = [exported]
        let consumer = Transpiler(transpileFiles: [Source.FilePath(path: consumerFile.path)], codebaseInfo: consumerInfo, transformers: builtinKotlinTransformers())
        try await consumer.transpile { result in XCTAssertTrue(result.messages.isEmpty) }
        return consumerInfo.context(importedModuleNames: [module])
    }

    func testBuiltinScalarsConformToActualStandardHashableProtocol() async throws {
        let codebase = try await context(module: "SkipLib", declarations: "public protocol Hashable {}")
        let scalars: [TypeSignature] = [.bool, .character, .string, .int, .int8, .int16, .int32, .int64, .int128,
                                        .uint, .uint8, .uint16, .uint32, .uint64, .uint128, .float, .double]
        for scalar in scalars {
            XCTAssertNotNil(scalar.compatibilityScore(target: .module("SkipLib", .named("Hashable", [])), codebaseInfo: codebase), scalar.description)
            XCTAssertNotNil(scalar.compatibilityScore(target: .module("Swift", .named("Hashable", [])), codebaseInfo: codebase), scalar.description)
        }
    }

    func testAnyAndNonconformingClassDoNotAcquireHashableConformance() async throws {
        let codebase = try await context(module: "SkipLib", declarations: "public protocol Hashable {}\npublic class Plain {}")
        let target: TypeSignature = .module("SkipLib", .named("Hashable", []))
        XCTAssertNil(TypeSignature.any.compatibilityScore(target: target, codebaseInfo: codebase))
        XCTAssertNil(TypeSignature.module("SkipLib", .named("Plain", [])).compatibilityScore(target: target, codebaseInfo: codebase))
    }

    func testSameNamedUserProtocolDoesNotReceiveBuiltinScalarConformance() async throws {
        let codebase = try await context(module: "UserConstraints", declarations: "public protocol Hashable {}")
        XCTAssertNil(TypeSignature.int.compatibilityScore(target: .module("UserConstraints", .named("Hashable", [])), codebaseInfo: codebase))
        XCTAssertNil(TypeSignature.int.compatibilityScore(target: .named("Hashable", []), codebaseInfo: codebase))
    }

    func testSameNamedUserClassIsNotTreatedAsTheStandardProtocol() async throws {
        let codebase = try await context(module: "UserConstraints", declarations: "public class Hashable {}")
        XCTAssertNil(TypeSignature.double.compatibilityScore(target: .module("UserConstraints", .named("Hashable", [])), codebaseInfo: codebase))
        XCTAssertNil(TypeSignature.double.compatibilityScore(target: .named("Hashable", []), codebaseInfo: codebase))
    }
}
