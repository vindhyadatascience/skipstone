// Copyright (c) 2026 Vindhya Data Science
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import SkipSyntax

/// RNABrowser-fiea.28 (vds.5): `KotlinAwait.setIsAsync` marks every nested main-actor targeting
/// node `isInAwait`, and the concurrency transformer warned on any of them whose API call did
/// not match. An argument constructor inside an awaited call — `await run(..., pager:
/// RecordingPager(..., failure: CancellationError()))` — is not itself the awaited API, and the
/// Kotlin for such calls is identical to previous releases, so the warning was spurious. GeneFox
/// saw 31 new project warnings per transpile; only the View-kind ones were real regressions.
final class AwaitNestedArgumentWarningTests: XCTestCase {
    private func transpile(swift: String, supportingSwift: String? = nil) async throws -> (kotlin: String, messages: [String]) {
        var files: [Source.FilePath] = []
        if let supportingSwift {
            let support = try tmpFile(named: "Support.swift", contents: supportingSwift)
            files.append(Source.FilePath(path: support.path))
        }
        let src = try tmpFile(named: "Source.swift", contents: swift)
        files.append(Source.FilePath(path: src.path))
        let transpiler = Transpiler(transpileFiles: files, codebaseInfo: CodebaseInfo(), transformers: builtinKotlinTransformers())
        var kotlin = ""
        var messages: [String] = []
        try await transpiler.transpile { result in
            messages += result.messages.map(\.formattedMessage)
            if result.outputType == .default {
                kotlin += result.output.content
            }
        }
        return (kotlin, messages)
    }

    private static let actorWarning = "Skip is unable to match this API call to determine the correct actor on which to run it"

    /// A constructor argument evaluated inside an awaited call must not warn: the awaited call
    /// itself matches, and the nested expression inherited `isInAwait` from it.
    func testNestedConstructorArgumentInAwaitDoesNotWarn() async throws {
        let (kotlin, messages) = try await transpile(swift: """
        struct Pager { var datasets: [String]; var total: Int; var failure: Error? }
        func firstPage(_ r: String, usabilityLedger: String, pager: Pager) async -> Int { 0 }
        func use() async {
            let x = await firstPage("x", usabilityLedger: "", pager: Pager(datasets: [], total: 0, failure: CancellationError()))
            print(x)
        }
        """)
        XCTAssertEqual(messages.filter { $0.contains(Self.actorWarning) }, [], messages.joined(separator: "\n"))
        XCTAssertTrue(kotlin.contains("CancellationError()"), kotlin)
        XCTAssertTrue(kotlin.contains("firstPage("), kotlin)
    }

    /// Negative control: the awaited call itself failing to match still warns.
    func testUnmatchedAwaitedCallStillWarns() async throws {
        let (_, messages) = try await transpile(swift: """
        struct Box { var value: Int = 0 }
        func use() async {
            let b = await Box(nonexistent: 1)
            print(b)
        }
        """)
        XCTAssertTrue(messages.contains { $0.contains(Self.actorWarning) }, messages.joined(separator: "\n"))
    }

    /// Negative control: the awaited call keeps its warning even when Swift's expression-spanning
    /// `await` makes it the left operand of a comparison inside the awaited expression.
    func testUnmatchedAwaitedCallInComparisonStillWarns() async throws {
        let (_, messages) = try await transpile(swift: """
        struct Box { var value: Int = 0 }
        func expect(_ condition: Bool) {}
        func use() async {
            expect(await Box(nonexistent: 1) == [String]())
        }
        """)
        XCTAssertTrue(messages.contains { $0.contains(Self.actorWarning) }, messages.joined(separator: "\n"))
    }

    /// An operand on the far side of an operator inside an awaited expression — GeneFox's
    /// `#expect(await loader.requestedGenes() == [String]())` — is not the awaited call and
    /// must not warn (HeatmapPipelineBindingTests.swift:268).
    func testOperatorOperandInAwaitDoesNotWarn() async throws {
        let (_, messages) = try await transpile(swift: """
        struct Loader { var genes: [String] = [] }
        func requestedGenes(_ loader: Loader) async -> [String] { loader.genes }
        func expect(_ condition: Bool) {}
        func use(_ loader: Loader) async {
            expect(await requestedGenes(loader) == [String]())
        }
        """)
        XCTAssertEqual(messages.filter { $0.contains(Self.actorWarning) }, [], messages.joined(separator: "\n"))
    }

    /// The View-kind type-inference warning names the argument labels the unmatched call used,
    /// so the site can be compared against the declaration's parameter order.
    func testViewTypeInferenceWarningNamesArgumentLabels() async throws {
        let support = """
        import SwiftUI
        protocol View {
            @ViewBuilder @MainActor var body: some View { get }
        }
        struct ExportButton: View {
            var label: String = "Export"
            var systemImage: String = "doc"
            let make: () -> Int
            init(label: String = "Export", systemImage: String = "doc", make: @escaping () -> Int) {
                self.label = label
                self.systemImage = systemImage
                self.make = make
            }
        }
        """
        let (_, messages) = try await transpile(swift: """
        import SwiftUI
        struct Screen: View {
            var body: some View {
                ExportButton(make: { 1 }, label: "Export", systemImage: "doc")
            }
        }
        """, supportingSwift: support)
        let viewWarnings = messages.filter { $0.contains("Skip is unable to match this API call to determine whether it results in a View") }
        XCTAssertEqual(viewWarnings.count, 1, messages.joined(separator: "\n"))
        XCTAssertTrue(viewWarnings.first?.contains("(argument labels: make, label, systemImage)") == true, viewWarnings.joined(separator: "\n"))
    }
}
