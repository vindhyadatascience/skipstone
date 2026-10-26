// Copyright 2026 Vindhya Data Science
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import SkipSyntax

final class TaskActorInheritanceTests: XCTestCase {
    private func taskLines(_ swift: String) async throws -> [String] {
        let source = try tmpFile(named: "Source.swift", contents: swift)
        let support = try tmpFile(named: "Support.swift", contents: """
        import SwiftUI
        protocol View {
            @ViewBuilder @MainActor var body: any View { get }
        }
        struct Text: View { init(_ text: String) {} }
        struct Task<Success, Failure> where Failure: Error {
            init(priority: TaskPriority? = nil, operation: @escaping () async throws -> Success) {}
            static func detached<T>(operation: () throws -> T) async -> T { fatalError() }
        }
        """)
        let files = [source, support].map { Source.FilePath(path: $0.path) }
        let transpiler = Transpiler(transpileFiles: files, codebaseInfo: CodebaseInfo(), transformers: builtinKotlinTransformers())
        var output = ""
        try await transpiler.transpile { result in
            XCTAssertTrue(result.messages.isEmpty, result.messages.map(\.formattedMessage).joined(separator: "\n"))
            if result.input.file == files[0] { output += result.output.content }
        }
        return output.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("Task {") || $0.hasPrefix("Task(") || $0.hasPrefix("Task.detached") }
    }

    func testSynchronousMethodInMainActorType() async throws {
        let lines = try await taskLines("""
        @MainActor struct ExportView {
            func export() { Task { print("typed") } }
        }
        """)
        XCTAssertEqual(lines, ["Task(isMainActor = true) { -> print(\"typed\") }"])
    }

    func testPrivateViewMethodInheritsProtocolIsolation() async throws {
        let lines = try await taskLines("""
        @MainActor protocol ActorBoundView {}
        struct ExportView: ActorBoundView {
            private func export() { Task { print("view") } }
        }
        """)
        XCTAssertEqual(lines, ["Task(isMainActor = true) { -> print(\"view\") }"])
    }

    func testSwiftUIViewMethodWithBodyOnlyActorMetadata() async throws {
        let lines = try await taskLines("""
        import SwiftUI
        struct ExportView: View {
            var body: some View { Text("export") }
            private func startExport() { Task { print("implicit-view") } }
            nonisolated func background() { Task { print("background-view") } }
            func detached() {
                Task.detached { Task { print("detached-view") } }
            }
        }
        """)
        XCTAssertEqual(lines, ["Task(isMainActor = true) { -> print(\"implicit-view\") }", "Task { -> print(\"background-view\") }", "Task.detached { ->", "Task { -> print(\"detached-view\") }"])
    }

    func testUnrelatedViewProtocolDoesNotImplyMainActor() async throws {
        let lines = try await taskLines("""
        enum Custom { protocol View {} }
        struct Worker: Custom.View {
            func run() { Task { print("custom-view") } }
        }
        """)
        XCTAssertEqual(lines, ["Task { -> print(\"custom-view\") }"])
    }

    func testExtensionMethodInheritsTypeIsolation() async throws {
        let lines = try await taskLines("""
        @MainActor class ExportView {}
        extension ExportView {
            func export() { Task { print("extension") } }
        }
        """)
        XCTAssertEqual(lines, ["Task(isMainActor = true) { -> print(\"extension\") }"])
    }

    func testNonisolatedMethodAndDetachedTaskDoNotInherit() async throws {
        let lines = try await taskLines("""
        @MainActor struct ExportView {
            nonisolated func background() { Task { print("background") } }
            func detached() {
                Task.detached {
                    Task { print("nested") }
                }
            }
        }
        """)
        XCTAssertEqual(lines, ["Task { -> print(\"background\") }", "Task.detached { ->", "Task { -> print(\"nested\") }"])
    }

    func testOrdinaryMethodsStayUnisolatedAndExplicitClosureStillWins() async throws {
        let lines = try await taskLines("""
        struct Worker {
            func run() { Task { print("worker") } }
        }
        @MainActor struct ExportView {
            nonisolated func run() { Task { @MainActor in print("explicit") } }
        }
        """)
        XCTAssertEqual(lines, ["Task { -> print(\"worker\") }", "Task(isMainActor = true) { -> print(\"explicit\") }"])
    }
}
