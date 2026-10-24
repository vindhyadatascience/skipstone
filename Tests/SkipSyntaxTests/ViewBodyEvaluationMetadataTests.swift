// Copyright (c) 2026 Vindhya Data Science
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
@testable import SkipSyntax

final class ViewBodyEvaluationMetadataTests: XCTestCase {
    private func output(_ source: String, capability: Bool = true) async throws -> String {
        let marker = capability ? "public enum SkipUIBodyEvaluationCapabilityV1 {}" : ""
        let sdk = """
        // SKIP SYMBOLFILE
        public protocol View { @ViewBuilder var body: any View { get } }
        public struct Text: View { public init(_ value: String) {} }
        public struct Binding<Value> {}
        public struct State<Value> {}
        public class SDKAdapter {}
        \(marker)
        """
        let sdkFile = try tmpFile(named: "SDK.swift", contents: sdk)
        let sdkInfo = CodebaseInfo(moduleName: "SkipUI")
        try await Transpiler(transpileFiles: [Source.FilePath(path: sdkFile.path)], codebaseInfo: sdkInfo,
            transformers: builtinKotlinTransformers()).transpile { result in
                XCTAssertTrue(result.messages.isEmpty, result.messages.map(\.formattedMessage).joined(separator: "\n"))
            }
        let exported = try JSONDecoder().decode(CodebaseInfo.ModuleExport.self,
            from: JSONEncoder().encode(CodebaseInfo.ModuleExport(of: sdkInfo)))
        let file = try tmpFile(named: "Consumer.swift", contents: source)
        let info = CodebaseInfo(moduleName: "BodyConsumer")
        info.dependentModules = [exported]
        var kotlin = ""
        try await Transpiler(packageName: "body.consumer", transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info,
            transformers: builtinKotlinTransformers()).transpile { result in
                XCTAssertTrue(result.messages.isEmpty, result.messages.map(\.formattedMessage).joined(separator: "\n"))
                kotlin += result.output.content
            }
        return kotlin
    }

    func testProvenImmutableInputsUseRawFloatingBitsAndClassIdentity() async throws {
        let kotlin = try await output("""
        import SwiftUI
        final class ReferenceToken { let label: String }
        struct Proven: View {
            let number: Int
            let label: String
            let double: Double
            let float: Float
            let token: ReferenceToken
            var body: some View { Text(label) }
        }
        """)
        XCTAssertTrue(kotlin.contains("skip.ui.evaluateImmutableViewBody(context, options"), kotlin)
        XCTAssertTrue(kotlin.contains("java.lang.Double.doubleToRawLongBits(this.double)"), kotlin)
        XCTAssertTrue(kotlin.contains("java.lang.Float.floatToRawIntBits(this.float)"), kotlin)
        XCTAssertTrue(kotlin.contains("skip.ui.bodyInputReference(this.token)"), kotlin)
        XCTAssertTrue(kotlin.contains("{ this.body() }"), kotlin)
        XCTAssertFalse(kotlin.contains("rememberView"), kotlin)
    }

    func testRawTypeBodyAndFieldOverridesKeepTheirExistingPath() async throws {
        let kotlin = try await output("""
        import SwiftUI
        // SKIP DECLARE: internal class RawType: View
        struct RawType: View { let number: Int; var body: some View { Text("Body") } }
        struct RawBody: View {
            let number: Int
            // SKIP REPLACE: override fun body(): View = Text("Raw body")
            var body: some View { Text("Body") }
        }
        struct RawField: View {
            // SKIP DECLARE: internal var number: Int
            let number: Int
            var body: some View { Text("Body") }
        }
        struct RawStatement: View {
            let number: Int
            var body: some View {
                // SKIP REPLACE: Text("Raw statement")
                Text("Body")
            }
        }
        """)
        XCTAssertFalse(kotlin.contains("evaluateImmutableViewBody"), kotlin)
    }

    func testCountedChildStatementsAndExplicitReturnRemainInsideTheRetainedBuilder() async throws {
        let kotlin = try await output("""
        import SwiftUI
        final class BodyCounter { var bodies = 0 }
        struct CountedValueChild: View {
            let value: Int
            let counter: BodyCounter
            var body: some View {
                counter.bodies += 1
                return Text("Child value \\(value)")
            }
        }
        """)
        XCTAssertTrue(kotlin.contains("skip.ui.evaluateImmutableViewBody(context, options"), kotlin)
        XCTAssertTrue(kotlin.contains("skip.ui.bodyInputReference(this.counter)"), kotlin)
        XCTAssertTrue(kotlin.contains("counter.bodies += 1"), kotlin)
        XCTAssertTrue(kotlin.contains("return@l Text"), kotlin)
    }

    func testAnOlderSDKWithoutTheCapabilityKeepsItsExistingEvaluatePath() async throws {
        let kotlin = try await output("""
        import SwiftUI
        struct Plain: View { let number: Int; var body: some View { Text("Body") } }
        """, capability: false)
        XCTAssertFalse(kotlin.contains("evaluateImmutableViewBody"), kotlin)
        XCTAssertFalse(kotlin.contains("override fun Evaluate"), kotlin)
    }

    func testUnprovenInputsAndUserEvaluateImplementationsKeepTheExistingPath() async throws {
        let kotlin = try await output("""
        import SwiftUI
        struct Value { let number: Int }
        struct Mutable: View { var number: Int; var body: some View { Text("Body") } }
        struct ClosureInput: View { let action: () -> Void; var body: some View { Text("Body") } }
        struct BindingInput: View { let binding: Binding<Int>; var body: some View { Text("Body") } }
        struct Wrapped: View { @Binding var number: Int; var body: some View { Text("Body") } }
        struct ValueInput: View { let value: Value; var body: some View { Text("Body") } }
        struct Unknown: View { let value: Any; var body: some View { Text("Body") } }
        struct Generic<T>: View { let value: T; var body: some View { Text("Body") } }
        struct SDKInput: View { let value: SDKAdapter; var body: some View { Text("Body") } }
        class ReferenceView: View { let number: Int; var body: some View { Text("Body") } }
        struct UserEvaluation: View {
            let number: Int
            var body: some View { Text("Body") }
            func Evaluate(context: Any, options: Int) -> [Any] { [] }
        }
        """)
        XCTAssertFalse(kotlin.contains("evaluateImmutableViewBody"), kotlin)
        XCTAssertTrue(kotlin.contains("fun Evaluate"), kotlin)
    }
}
