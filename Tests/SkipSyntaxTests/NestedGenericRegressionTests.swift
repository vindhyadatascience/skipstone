// Copyright (c) 2026 Vindhya Data Science
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import SkipSyntax

final class NestedGenericRegressionTests: XCTestCase {
    func testRepeatedInheritedGenericMappingDoesNotTrap() {
        let element = TypeSignature.named("Element", [])
        let signature = TypeSignature.member(.named("Outer", [element]), .named("Associated", [element]))
        XCTAssertEqual(signature.mappingTypes(from: signature.allGenericArguments, to: [.int, .int]),
                       .member(.named("Outer", [.int]), .named("Associated", [.int])))
    }

    func testNestedTypesRetainEnclosingGenericArguments() async throws {
        let swift = """
        struct Outer<T> {
            struct Inner<U> { let outer: T; let inner: U }
        }
        func answer() -> Int {
            let value = Outer<Int>.Inner<String>(outer: 42, inner: "ok")
            return value.outer
        }
        """
        let file = try tmpFile(named: "Source.swift", contents: swift)
        let info = CodebaseInfo()
        let transpiler = Transpiler(transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info, transformers: builtinKotlinTransformers())
        var output = ""
        try await transpiler.transpile { result in
            XCTAssertTrue(result.messages.isEmpty, result.messages.map(\.formattedMessage).joined(separator: "\n"))
            output += result.output.content
        }
        XCTAssertTrue(output.contains("class Inner<T, U>"), output)
        XCTAssertTrue(output.contains("Outer.Inner<Int, String>(outer = 42, inner = \"ok\")"), output)
        let nested = TypeSignature.member(.named("Outer", [.int]), .named("Inner", [.string]))
        let match = info.context().matchIdentifier(name: "outer", inConstrained: nested)
        XCTAssertEqual(match?.signature, .int)
    }
}
