// Copyright (c) 2026 Vindhya Data Science
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
@testable import SkipSyntax

final class EnvironmentMemberwiseConstructorMetadataTests: XCTestCase {
    private func sdk() async throws -> CodebaseInfo.ModuleExport {
        let source = """
        // SKIP SYMBOLFILE
        public protocol View { @ViewBuilder var body: any View { get } }
        public struct Text: View { public init(_ value: String) {} }
        public struct DismissAction { public func callAsFunction() {} }
        public protocol ObservableObject {}
        public final class Model: ObservableObject {}
        public struct Binding<Value> {}
        public struct EnvironmentValues {
            public var dismiss: DismissAction { fatalError() }
            public var optionalModel: Model? { nil }
        }
        """
        let file = try tmpFile(named: "SDK.swift", contents: source)
        let info = CodebaseInfo(moduleName: "SkipUI")
        try await Transpiler(transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info,
            transformers: builtinKotlinTransformers()).transpile { result in
                XCTAssertTrue(result.messages.isEmpty, result.messages.map(\.formattedMessage).joined(separator: "\n"))
            }
        return try JSONDecoder().decode(CodebaseInfo.ModuleExport.self,
            from: JSONEncoder().encode(CodebaseInfo.ModuleExport(of: info)))
    }

    private func transpile(_ source: String) async throws -> (String, CodebaseInfo, CodebaseInfo.ModuleExport) {
        let file = try tmpFile(named: "Consumer.swift", contents: source)
        let info = CodebaseInfo(moduleName: "EnvironmentConsumer")
        info.dependentModules = [try await sdk()]
        var kotlin = ""
        try await Transpiler(transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info,
            transformers: builtinKotlinTransformers()).transpile { result in
                XCTAssertTrue(result.messages.isEmpty, result.messages.map(\.formattedMessage).joined(separator: "\n"))
                kotlin += result.output.content
            }
        let export = try JSONDecoder().decode(CodebaseInfo.ModuleExport.self,
            from: JSONEncoder().encode(CodebaseInfo.ModuleExport(of: info, includeTestingMetadata: true)))
        return (kotlin, info, export)
    }

    private func initializer(_ type: CodebaseInfo.TypeInfo) throws -> CodebaseInfo.FunctionInfo {
        let initializers = type.functions.filter { $0.declarationType == .initDeclaration }
        XCTAssertEqual(initializers.count, 1, type.name)
        return try XCTUnwrap(initializers.first)
    }

    func testEnvironmentBackedDestinationKeepsLabelOnlyMetadataAndComposesEveryCall() async throws {
        let (kotlin, info, exported) = try await transpile("""
        import SwiftUI
        public struct Destination: View {
            public let label: String
            @Environment(\\.dismiss) private var dismiss
            public var body: some View { Text(label) }
        }
        func modal(@ViewBuilder content: () -> any View) -> any View { content() }
        @ViewBuilder func destinations() -> some View {
            Destination(label: "direct")
            modal { Destination(label: "nested") }
        }
        """)
        let type = try XCTUnwrap(info.rootTypes.first { $0.name == "Destination" })
        let generated = try initializer(type)
        XCTAssertTrue(generated.isGenerated)
        XCTAssertEqual(generated.signature.parameters.map(\.label), ["label"])
        XCTAssertEqual(generated.modifiers.visibility, .internal)
        XCTAssertTrue(kotlin.contains("constructor(label: String)"), kotlin)
        XCTAssertTrue(kotlin.contains("Destination(label = \"direct\").Compose(composectx)"), kotlin)
        XCTAssertTrue(kotlin.contains("Destination(label = \"nested\").Compose(composectx)"), kotlin)
        let testingType = try XCTUnwrap(exported.testingMetadata?.rootTypes.first { $0.name == "Destination" })
        XCTAssertEqual(try initializer(testingType).signature.parameters.map(\.label), ["label"])
        let publicType = try XCTUnwrap(exported.rootTypes.first { $0.name == "Destination" })
        XCTAssertFalse(publicType.functions.contains { $0.declarationType == .initDeclaration })
    }

    func testOptionalEnvironmentEnvironmentObjectAndFocusStateDoNotBecomeRequiredPrivateInputs() async throws {
        let (_, info, _) = try await transpile("""
        import SwiftUI
        public struct ManagedFields: View {
            public let label: String
            @Environment(\\.optionalModel) private var model: Model?
            @EnvironmentObject private var shared: Model
            @FocusState private var focused: Bool
            public var body: some View { Text(label) }
        }
        """)
        let type = try XCTUnwrap(info.rootTypes.first { $0.name == "ManagedFields" })
        // hasValue also represents Optional's implicit nil; it is not proof of a written initializer.
        XCTAssertTrue(try XCTUnwrap(type.variables.first { $0.name == "model" }).hasValue)
        let generated = try initializer(type)
        XCTAssertEqual(generated.signature.parameters.map(\.label), ["label"])
        XCTAssertEqual(generated.modifiers.visibility, .internal)
    }

    func testOrdinaryPrivateFieldsDefaultsAndBindingParametersRetainTheirRules() async throws {
        let (_, info, _) = try await transpile("""
        import SwiftUI
        public struct PrivateField { public let label: String; private var secret: Int }
        public struct DefaultedField { public let label: String; public var count: Int = 3 }
        public struct RequiredBinding { public let label: String; @Binding public var value: Int }
        """)
        let hidden = try initializer(XCTUnwrap(info.rootTypes.first { $0.name == "PrivateField" }))
        XCTAssertEqual(hidden.signature.parameters.map(\.label), ["label", "secret"])
        XCTAssertEqual(hidden.modifiers.visibility, .private)
        let defaulted = try initializer(XCTUnwrap(info.rootTypes.first { $0.name == "DefaultedField" }))
        XCTAssertEqual(defaulted.signature.parameters.map(\.label), ["label", "count"])
        XCTAssertTrue(defaulted.signature.parameters[1].hasDefaultValue)
        let binding = try initializer(XCTUnwrap(info.rootTypes.first { $0.name == "RequiredBinding" }))
        XCTAssertEqual(binding.signature.parameters.map(\.label), ["label", "value"])
        XCTAssertTrue(binding.signature.parameters[1].type.isSameType(as: TypeSignature.int.asBinding()))
        XCTAssertFalse(binding.signature.parameters[1].hasDefaultValue)
    }
}
