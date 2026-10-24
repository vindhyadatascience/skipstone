// Copyright (c) 2026 Vindhya Data Science
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
@testable import SkipSyntax

final class LocalTypeMetadataTests: XCTestCase {
    func testLocalErrorEnumsUseSealedThrowableCasesAndKeepCatchPatterns() async throws {
        let swift = """
        func answer() -> Int {
            enum Failure: Error { case expected; case payload(Int) }
            do { throw Failure.payload(42) }
            catch Failure.payload(let value) { return value }
            catch Failure.expected { return 1 }
            catch { return 0 }
        }
        """
        let file = try tmpFile(named: "Local.swift", contents: swift)
        let info = CodebaseInfo(moduleName: "LocalFixture")
        var kotlin = ""
        let transpiler = Transpiler(packageName: "local.fixture", transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info, transformers: builtinKotlinTransformers())
        try await transpiler.transpile { result in
            XCTAssertTrue(result.messages.isEmpty, result.messages.map(\.formattedMessage).joined(separator: "\n"))
            kotlin += result.output.content
        }
        let local = try XCTUnwrap(info.rootTypes.first { $0.signature.name.hasSuffix("_Failure") })
        XCTAssertEqual(local.name, local.signature.name)
        XCTAssertEqual(local.modifiers.visibility, .private)
        XCTAssertEqual(info.context(sourceFile: Source.FilePath(path: file.path)).isSealedClassesEnum(type: local.signature).0, true)
        XCTAssertTrue(kotlin.contains("private sealed class \(local.name): Exception(), Error"), kotlin)
        XCTAssertFalse(kotlin.contains("enum class \(local.name)"), kotlin)
        XCTAssertTrue(kotlin.contains("catch (error: \(local.name).PayloadCase)"), kotlin)
        XCTAssertTrue(kotlin.contains("catch (error: \(local.name).ExpectedCase)"), kotlin)
        XCTAssertTrue(kotlin.contains("val value = error.associated0"), kotlin)
        let exported = CodebaseInfo.ModuleExport(of: info, includeTestingMetadata: true)
        XCTAssertFalse(exported.rootTypes.contains { $0.name == local.name })
        XCTAssertFalse(exported.testingMetadata?.rootTypes.contains { $0.name == local.name } ?? true)
    }

    func testLocalInferredStoredStringResolvesThroughItsHoistedOwner() async throws {
        let swift = """
        func append() -> String {
            struct Value { var text = "start" }
            var value = Value()
            value.text.append("!")
            return value.text
        }
        """
        let file = try tmpFile(named: "Local.swift", contents: swift)
        let info = CodebaseInfo(moduleName: "LocalFixture")
        var kotlin = ""
        let transpiler = Transpiler(packageName: "local.fixture", transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info, transformers: builtinKotlinTransformers())
        try await transpiler.transpile { result in
            XCTAssertTrue(result.messages.isEmpty, result.messages.map(\.formattedMessage).joined(separator: "\n"))
            kotlin += result.output.content
        }
        let local = try XCTUnwrap(info.rootTypes.first { $0.signature.name.hasSuffix("_Value") })
        let context = info.context(sourceFile: Source.FilePath(path: file.path))
        XCTAssertEqual(context.matchIdentifier(name: "text", inConstrained: local.signature)?.signature, .string)
        XCTAssertTrue(kotlin.contains("`skip append old` + `skip append suffix`"), kotlin)
        XCTAssertFalse(kotlin.contains("value.text.append("), kotlin)
        XCTAssertTrue(context.typeInfos(forNamed: .named("Value", [])).isEmpty)
    }
}
