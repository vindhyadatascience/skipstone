// Copyright (c) 2026 Vindhya Data Science
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
@testable import SkipSyntax

/// RNABrowser-fiea.28: `a...b` must match a `ClosedRange<Bound>` parameter, or the call goes
/// unmatched and a trailing closure that is not the last parameter loses its Kotlin label
/// (GeneFox's bounded `Stepper(value:in:step:) { label }` bound it to `onEditingChanged`).
final class ClosedRangeArgumentTests: XCTestCase {
    func testClosedRangeLiteralMatchesAndLabelsTheTrailingClosure() async throws {
        let file = try tmpFile(named: "Source.swift", contents: """
        struct Picker {
            init(value: Int, in bounds: ClosedRange<Int>, step: Int = 1, label: () -> String, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {}
        }
        func make(_ low: Int, _ high: Int) -> Picker {
            return Picker(value: 1, in: low...high, step: 2) { "label" }
        }
        """)
        let info = CodebaseInfo(moduleName: "Consumer")
        var kotlin = ""
        try await Transpiler(packageName: "consumer", transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info, transformers: builtinKotlinTransformers()).transpile { result in
            XCTAssertEqual(result.messages.filter { $0.kind == .error }.map(\.formattedMessage), [])
            kotlin += result.output.content
        }
        XCTAssertTrue(kotlin.contains("Picker(value = 1, in_ = low..high, step = 2, label = { ->"), kotlin)
    }
}
