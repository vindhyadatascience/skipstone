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
        struct Button: View { init(_ title: String, action: () -> Void) {} }
        extension View {
            func onChange(of value: Int, perform: (Int) -> Void) -> Self { self }
            func onAppear(perform: () -> Void) -> Self { self }
        }
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
            .compactMap { line in
                // Include constructors in declarations and assignments, not just statements.
                for prefix in ["Task(", "Task {", "Task.detached"] {
                    if let range = line.range(of: prefix) { return String(line[range.lowerBound...]) }
                }
                return nil
            }
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
    func testAssignedLocalsInheritEnclosingActor() async throws {
        let lines = try await taskLines("""
        @MainActor struct ExportView {
            func run() {
                let first = Task { print("let-local") }
                var second = Task { print("var-local") }
            }
        }
        @MainActor func runOnMain() {
            let third = Task { print("actor-function") }
        }
        """)
        XCTAssertEqual(lines, ["Task(isMainActor = true) { -> print(\"let-local\") }", "Task(isMainActor = true) { -> print(\"var-local\") }", "Task(isMainActor = true) { -> print(\"actor-function\") }"])
    }

    func testStoredTaskInitializersDoNotInheritTypeActor() async throws {
        let lines = try await taskLines("""
        @MainActor class ExportView {
            let first = Task { print("let-property") }
            var second = Task { print("var-property") }
            lazy var third = Task { print("lazy-property") }
        }
        """)
        XCTAssertEqual(lines, ["Task { -> print(\"let-property\") }", "Task { -> print(\"var-property\") }", "Task { -> print(\"lazy-property\") }"])
    }

    func testViewBodyNestedActionsAndCompletionClosures() async throws {
        let lines = try await taskLines("""
        import SwiftUI
        func completion(_ action: () -> Void) { action() }
        struct ExportView: View {
            var body: some View {
                Button("export") {
                    let task = Task { print("button") }
                }
                .onChange(of: 1) { value in
                    let task = Task { print("change") }
                }
                .onAppear {
                    let task = Task { print("appear") }
                }
            }
            func run() {
                completion { let task = Task { print("completion") } }
            }
        }
        """)
        XCTAssertEqual(lines, ["Task(isMainActor = true) { -> print(\"button\") }", "Task(isMainActor = true) { -> print(\"change\") }", "Task(isMainActor = true) { -> print(\"appear\") }", "Task(isMainActor = true) { -> print(\"completion\") }"])
    }

    func testWeakCaptureAndExplicitActorInAssignedTasks() async throws {
        let lines = try await taskLines("""
        @MainActor class ExportView {
            func run() {
                let task = Task { [weak self] in print(self) }
            }
            nonisolated func background() {
                let task = Task { @MainActor in print("explicit-assigned") }
            }
        }
        """)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("Task(isMainActor = true)"), lines.joined(separator: "\n"))
        XCTAssertEqual(lines[1], "Task(isMainActor = true) { -> print(\"explicit-assigned\") }")
    }

    func testAssignedTasksRespectNonisolatedDetachedAndSendableBoundaries() async throws {
        let lines = try await taskLines("""
        @MainActor struct ExportView {
            nonisolated func run() { let task = Task { print("nonisolated-local") } }
            func background() {
                let detached = Task.detached {
                    let nested = Task { print("detached-local") }
                }
                let callback: @Sendable () -> Void = {
                    let task = Task { print("sendable-local") }
                }
                let asyncCallback: @Sendable () async -> Void = {
                    let task = Task { print("sendable-async-local") }
                }
            }
        }
        class Worker { var task = Task { print("ordinary-property") } }
        """)
        XCTAssertEqual(lines, ["Task { -> print(\"nonisolated-local\") }", "Task.detached { ->", "Task { -> print(\"detached-local\") }", "Task { -> print(\"sendable-local\") }", "Task { -> print(\"sendable-async-local\") }", "Task { -> print(\"ordinary-property\") }"])
    }

    func testViewStoredTaskAndExplicitActorCallback() async throws {
        let lines = try await taskLines("""
        import SwiftUI
        struct ExportView: View {
            var body: some View { Text("export") }
            let task = Task { print("view-property") }
        }
        struct Worker {
            func run() {
                let callback: @MainActor @Sendable () -> Void = {
                    let task = Task { print("actor-callback") }
                }
                let explicit = { @MainActor in
                    let task = Task { print("explicit-callback") }
                }
            }
        }
        @MainActor class BackgroundProperty {
            nonisolated let task = Task { print("nonisolated-property") }
        }
        """)
        XCTAssertEqual(lines, ["Task { -> print(\"view-property\") }", "Task(isMainActor = true) { -> print(\"actor-callback\") }", "Task(isMainActor = true) { -> print(\"explicit-callback\") }", "Task { -> print(\"nonisolated-property\") }"])
    }

    func testPropertyAssignmentAndComputedAccessorInheritActor() async throws {
        let lines = try await taskLines("""
        @MainActor class ExportView {
            var task: Task<Void, Never>?
            init() { task = Task { print("initializer-assignment") } }
            func run() { task = Task { print("method-assignment") } }
            var computed: Task<Void, Never> { Task { print("computed-property") } }
        }
        """)
        XCTAssertEqual(lines, ["Task(isMainActor = true) { -> print(\"initializer-assignment\") }", "Task(isMainActor = true) { -> print(\"method-assignment\") }", "Task(isMainActor = true) { -> print(\"computed-property\") }"])
    }

    func testPropertyObserversInheritThePropertyActor() async throws {
        let lines = try await taskLines("""
        class Observer {
            @MainActor var value = 0 {
                willSet { Task { print("will-set") } }
                didSet { Task { print("did-set") } }
            }
        }
        """)
        XCTAssertEqual(lines, ["Task(isMainActor = true) { -> print(\"will-set\") }", "Task(isMainActor = true) { -> print(\"did-set\") }"])
    }

}
