// Copyright (c) 2026 Vindhya Data Science
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
@testable import SkipSyntax

/// RNABrowser-fiea.28 (vds.4): an explicitly typed closure that Kotlin must emit as a lambda (an
/// `@MainActor`/async closure parameter cannot take an anonymous function) wrote its parameter
/// types in Swift spelling: `l@{ _: Bool, ... ->` is "Unresolved reference 'Bool'" in Kotlin
/// (GeneFox DestinationClaimTests). Every parameter type must use its Kotlin spelling.
final class ClosureParameterKotlinTypeTests: XCTestCase {
    func testLambdaParameterTypesUseKotlinSpellings() async throws {
        let file = try tmpFile(named: "Source.swift", contents: """
        struct Plan<T> { let value: T }
        @MainActor func run(_ apply: @MainActor (Bool, Int, Double, Float, String, Int64, UInt8, Character) -> Bool) {}
        @MainActor func runNested(_ apply: @MainActor ([Int], [String: Bool], Plan<Bool>?, Int?, Set<Int64>, (Int) -> Bool) -> Bool) {}
        @MainActor func use() {
            run { (b: Bool, i: Int, d: Double, f: Float, s: String, l: Int64, u: UInt8, c: Character) -> Bool in
                let ok = b && i > 0
                return ok
            }
            runNested { (a: [Int], m: [String: Bool], p: Plan<Bool>?, o: Int?, z: Set<Int64>, g: (Int) -> Bool) -> Bool in
                let ok = a.isEmpty || g(1)
                return ok
            }
        }
        """)
        let info = CodebaseInfo(moduleName: "Consumer")
        var kotlin = ""
        try await Transpiler(packageName: "consumer", transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info, transformers: builtinKotlinTransformers()).transpile { result in
            XCTAssertEqual(result.messages.filter { $0.kind == .error }.map(\.formattedMessage), [])
            kotlin += result.output.content
        }
        XCTAssertTrue(kotlin.contains("b: Boolean, i: Int, d: Double, f: Float, s: String, l: Long, u: UByte, c: Char ->"), kotlin)
        XCTAssertTrue(kotlin.contains("a: Array<Int>, m: Dictionary<String, Boolean>, p: Plan<Boolean>?, o: Int?, z: Set<Long>, g: (Int) -> Boolean ->"), kotlin)
        XCTAssertFalse(kotlin.contains(": Bool,"), kotlin)
        XCTAssertFalse(kotlin.contains("Int64"), kotlin)
    }
}
