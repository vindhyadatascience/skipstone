// Copyright (c) 2026 Vindhya Data Science
// Licensed under the GNU Affero General Public License v3.0
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
@testable import SkipSyntax

/// Consumers receive only real serialized module exports, never the producer's
/// in-memory declaration bodies. Optional fixture output is test evidence only.
final class CompilerCrossModuleRegressionTests: XCTestCase {
    private let producer = """
    public final class PublicValue {
        public let value: Int
        public init?(value: Int, offset: Int = 0) {
            if value < 0 { return nil }
            self.value = value + offset
        }
    }
    public final class InternalValue {
        public let value: Int
        init?(value: Int) {
            if value < 0 { return nil }
            self.value = value
        }
        private init?(secret: String) { self.value = secret.count }
    }
    public struct InitOnlyLet {
        public let value: Int
        public init(value: Int) { self.value = value }
    }
    public struct PublicMemberwiseOnly { public let value: Int }
    public func defaulted(value: Int = 7) -> Int { return value }
    public func row(value: Int, label: () -> String, onEditingChanged: (Bool) -> Void = { _ in }) -> String {
        return label()
    }
    """

    private let publicConsumer = #"""
    import ParityProducer
    func usePublic() -> String {
        let missing = PublicValue(value: -1)
        let accepted = PublicValue(value: 5, offset: 2)
        let initialized = InitOnlyLet(value: 9)
        let text = row(value: 3) { "label" }
        return "\(missing == nil)|\(accepted?.value ?? -1)|\(initialized.value)|\(defaulted())|\(text)"
    }
    """#

    private let testableConsumer = #"""
    @testable import ParityProducer
    func useInternal() -> String {
        let missing = InternalValue(value: -1)
        let accepted = InternalValue(value: 6)
        let memberwise = PublicMemberwiseOnly(value: 9)
        return "\(missing == nil)|\(accepted?.value ?? -1)|\(memberwise.value)"
    }
    """#

    private func transpile(_ swift: String, module: String,
                           dependencies: [CodebaseInfo.ModuleExport] = [], includeTestingMetadata: Bool = false) async throws -> (String, CodebaseInfo.ModuleExport, Data) {
        let file = try tmpFile(named: "\(module).swift", contents: swift)
        let info = CodebaseInfo(moduleName: module)
        info.dependentModules = dependencies
        let transpiler = Transpiler(packageName: KotlinTranslator.packageName(forModule: module), transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info, transformers: builtinKotlinTransformers())
        var kotlin = ""
        try await transpiler.transpile { result in
            XCTAssertTrue(result.messages.isEmpty, result.messages.map(\.formattedMessage).joined(separator: "\n"))
            kotlin += result.output.content
        }
        let data = try JSONEncoder().encode(CodebaseInfo.ModuleExport(of: info, includeTestingMetadata: includeTestingMetadata))
        let decoded = try JSONDecoder().decode(CodebaseInfo.ModuleExport.self, from: data)
        return (kotlin, decoded, data)
    }

    private func recordFixture(_ name: String, producerKotlin: String, consumerSwift: String,
                               consumerKotlin: String, export: Data, entry: String, expected: String) throws {
        guard let path = ProcessInfo.processInfo.environment["SKIP_CROSS_MODULE_FIXTURE_DIR"] else { return }
        let directory = URL(fileURLWithPath: path).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try producer.write(to: directory.appendingPathComponent("Producer.swift"), atomically: true, encoding: .utf8)
        try consumerSwift.write(to: directory.appendingPathComponent("Consumer.swift"), atomically: true, encoding: .utf8)
        try producerKotlin.write(to: directory.appendingPathComponent("Producer.kt"), atomically: true, encoding: .utf8)
        try consumerKotlin.write(to: directory.appendingPathComponent("Consumer.kt"), atomically: true, encoding: .utf8)
        try export.write(to: directory.appendingPathComponent("Producer.skipcode.json"))
        let package = consumerKotlin.components(separatedBy: "\n").first(where: { $0.hasPrefix("package ") })?.dropFirst("package ".count)
        let call = package.map { "\($0).\(entry)()" } ?? "\(entry)()"
        try "fun main() { println(\(call)) }\n".write(to: directory.appendingPathComponent("Runner.kt"), atomically: true, encoding: .utf8)
        try expected.write(to: directory.appendingPathComponent("expected.stdout"), atomically: true, encoding: .utf8)
    }

    func testPublicFailableInitializerDefaultsAndInitOnlyLetSurviveExport() async throws {
        let (producerKotlin, exported, data) = try await transpile(producer, module: "ParityProducer")
        let publicValue = try XCTUnwrap(exported.rootTypes.first(where: { $0.name == "PublicValue" }))
        let initializer = try XCTUnwrap(publicValue.functions.first(where: { $0.declarationType == .initDeclaration }))
        XCTAssertTrue(initializer.signature.returnType.isOptional)
        XCTAssertTrue(initializer.signature.parameters.last?.hasDefaultValue == true)
        let (consumerKotlin, _, _) = try await transpile(publicConsumer, module: "ParityConsumer", dependencies: [exported])
        XCTAssertTrue(producerKotlin.contains("class PublicValue {\n    val value: Int"), producerKotlin)
        XCTAssertFalse(producerKotlin.contains("var value:"), producerKotlin)
        XCTAssertTrue(producerKotlin.contains("throw NullReturnException()"), producerKotlin)
        XCTAssertTrue(consumerKotlin.contains("catch (_: NullReturnException) { null }"), consumerKotlin)
        XCTAssertTrue(consumerKotlin.contains("PublicValue(value = -1)"), consumerKotlin)
        XCTAssertTrue(consumerKotlin.contains("PublicValue(value = 5, offset = 2)"), consumerKotlin)
        XCTAssertTrue(consumerKotlin.contains("InitOnlyLet(value = 9)"), consumerKotlin)
        XCTAssertTrue(consumerKotlin.contains("defaulted()"), consumerKotlin)
        XCTAssertTrue(consumerKotlin.contains("row(value = 3, label ="), consumerKotlin)
        try recordFixture("public", producerKotlin: producerKotlin, consumerSwift: publicConsumer,
                          consumerKotlin: consumerKotlin, export: data, entry: "usePublic", expected: "true|7|9|7|label\n")
    }

    func testTestableInternalFailableInitializerSurvivesSerializedExport() async throws {
        let (producerKotlin, exported, data) = try await transpile(producer, module: "ParityProducer", includeTestingMetadata: true)
        let (consumerKotlin, _, _) = try await transpile(testableConsumer, module: "UnrelatedConsumer", dependencies: [exported])
        XCTAssertTrue(producerKotlin.contains("internal constructor(value: Int)"), producerKotlin)
        XCTAssertTrue(consumerKotlin.contains("InternalValue(value = -1)"), consumerKotlin)
        XCTAssertTrue(consumerKotlin.contains("catch (_: NullReturnException) { null }"), consumerKotlin)
        try recordFixture("testable", producerKotlin: producerKotlin, consumerSwift: testableConsumer,
                          consumerKotlin: consumerKotlin, export: data, entry: "useInternal", expected: "true|6|9\n")
    }

    /// Executed by the lead's native test slot. Builds only these hermetic tiny
    /// fixtures, so valid Swift access contracts and invalid reports are measured.
    func testTestingMetadataIsExplicitBackwardCompatibleAndFileLocal() async throws {
        let (_, ordinary, ordinaryData) = try await transpile(producer, module: "ParityProducer")
        XCTAssertNil(ordinary.testingMetadata)
        XCTAssertFalse(String(decoding: ordinaryData, as: UTF8.self).contains("\"testing\""))
        let (_, capable, _) = try await transpile(producer, module: "ParityProducer", includeTestingMetadata: true)
        XCTAssertNotNil(capable.testingMetadata)
        let publicInternalValue = try XCTUnwrap(capable.rootTypes.first { $0.name == "InternalValue" })
        XCTAssertFalse(publicInternalValue.functions.contains { $0.declarationType == .initDeclaration })
        let testingInternalValue = try XCTUnwrap(capable.testingMetadata?.rootTypes.first { $0.name == "InternalValue" })
        XCTAssertEqual(testingInternalValue.functions.filter { $0.declarationType == .initDeclaration }.count, 1)
        XCTAssertFalse(testingInternalValue.functions.contains { $0.modifiers.visibility == .private || $0.modifiers.visibility == .fileprivate })

        let info = CodebaseInfo(moduleName: "ParityProducerTests") // Name grants no access.
        info.dependentModules = [capable]
        let plainFile = Source.FilePath(path: "/virtual/Plain.swift")
        let testFile = Source.FilePath(path: "/virtual/Testing.swift")
        info.gather(from: SyntaxTree(source: Source(file: plainFile, content: "import ParityProducer")))
        info.gather(from: SyntaxTree(source: Source(file: testFile, content: "@testable import ParityProducer")))
        info.prepareForUse()
        let type = TypeSignature.named("InternalValue", []).withModuleName("ParityProducer")
        let plain = info.context(importedModuleNames: ["ParityProducer"], sourceFile: plainFile)
        let testing = info.context(importedModuleNames: ["ParityProducer"], sourceFile: testFile)
        let plainType = try XCTUnwrap(plain.primaryTypeInfo(forNamed: type))
        let testingType = try XCTUnwrap(testing.primaryTypeInfo(forNamed: type))
        XCTAssertFalse(plain.visibleMembers(of: plainType).contains { $0.declarationType == .initDeclaration })
        XCTAssertTrue(testing.visibleMembers(of: testingType).contains { $0.declarationType == .initDeclaration })
        XCTAssertEqual(info.testableDependencyModuleNames, ["ParityProducer"])

        let withoutCapability = CodebaseInfo(moduleName: "IndependentTests")
        withoutCapability.dependentModules = [ordinary]
        withoutCapability.prepareForUse()
        let denied = withoutCapability.context(importedModuleNames: ["ParityProducer"], testableImportedModuleNames: ["ParityProducer"])
        let deniedType = try XCTUnwrap(denied.primaryTypeInfo(forNamed: type))
        XCTAssertFalse(denied.visibleMembers(of: deniedType).contains { $0.declarationType == .initDeclaration })
    }

    func testTestingSurfaceNeverExposesPrivateOrInternalEnclosingTypesToOrdinaryImports() async throws {
        let (_, exported, _) = try await transpile("""
        class Hidden { public class Nested {} }
        private class Secret {}
        fileprivate class FileSecret {}
        public class PublicShell {
            private var secret: Int = 0
            fileprivate var fileSecret: Int = 0
            var internalValue: Int = 0
        }
        extension PublicShell {
            public func exported() -> Int { return 1 }
            func testingOnly() -> Int { return 2 }
        }
        extension String { public func publicBuiltinExtension() -> Int { return 3 } }
        """, module: "ParityProducer", includeTestingMetadata: true)
        let info = CodebaseInfo(moduleName: "Consumer")
        info.dependentModules = [exported]
        info.prepareForUse()
        let plain = info.context(importedModuleNames: ["ParityProducer"])
        let testing = info.context(importedModuleNames: ["ParityProducer"], testableImportedModuleNames: ["ParityProducer"])
        let hidden = TypeSignature.named("Hidden", []).withModuleName("ParityProducer")
        XCTAssertTrue(plain.typeInfos(forNamed: hidden).isEmpty)
        let nested = TypeSignature.member(hidden, .named("Nested", []))
        XCTAssertTrue(plain.typeInfos(forNamed: nested).isEmpty)
        XCTAssertFalse(testing.typeInfos(forNamed: nested).isEmpty)
        for name in ["Secret", "FileSecret"] {
            XCTAssertTrue(testing.typeInfos(forNamed: .named(name, []).withModuleName("ParityProducer")).isEmpty)
        }
        let shell = try XCTUnwrap(testing.primaryTypeInfo(forNamed: .named("PublicShell", []).withModuleName("ParityProducer")))
        let members = testing.visibleMembers(of: shell)
        XCTAssertTrue(members.contains { $0.name == "internalValue" })
        XCTAssertFalse(members.contains { $0.name == "secret" || $0.name == "fileSecret" })
        let shellType = TypeSignature.named("PublicShell", []).withModuleName("ParityProducer")
        let plainExtensionMembers = plain.typeInfos(forNamed: shellType).flatMap { plain.visibleMembers(of: $0) }
        let testingExtensionMembers = testing.typeInfos(forNamed: shellType).flatMap { testing.visibleMembers(of: $0) }
        XCTAssertTrue(plainExtensionMembers.contains { $0.name == "exported" })
        XCTAssertFalse(plainExtensionMembers.contains { $0.name == "testingOnly" })
        XCTAssertTrue(testingExtensionMembers.contains { $0.name == "testingOnly" })
        let builtinMembers = plain.typeInfos(forNamed: .string).flatMap { plain.visibleMembers(of: $0) }
        XCTAssertTrue(builtinMembers.contains { $0.name == "publicBuiltinExtension" })


    }

    func testNativePublicAndTestableAccessReference() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("skip-cross-module-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let producerFile = directory.appendingPathComponent("Producer.swift")
        try producer.write(to: producerFile, atomically: true, encoding: .utf8)
        #if os(macOS)
        let library = directory.appendingPathComponent("libParityProducer.dylib")
        #else
        let library = directory.appendingPathComponent("libParityProducer.so")
        #endif
        let module = directory.appendingPathComponent("ParityProducer.swiftmodule")
        let built = try swiftc(["-emit-module", "-emit-library", "-enable-testing", "-module-name", "ParityProducer", "-emit-module-path", module.path, "-o", library.path, producerFile.path])
        XCTAssertEqual(built.0, 0, built.1)
        guard built.0 == 0 else { return }
        for (name, source, entry, expected) in [
            ("Public", publicConsumer, "usePublic", "true|7|9|7|label\n"),
            ("Testable", testableConsumer, "useInternal", "true|6|9\n"),
        ] {
            let consumerFile = directory.appendingPathComponent(name + ".swift")
            let driverFile = directory.appendingPathComponent(name + "Driver.swift")
            let binary = directory.appendingPathComponent(name)
            try source.write(to: consumerFile, atomically: true, encoding: .utf8)
            try "@main struct Driver { static func main() { print(\(entry)()) } }".write(to: driverFile, atomically: true, encoding: .utf8)
            let compiled = try swiftc(["-I", directory.path, "-L", directory.path, "-lParityProducer", "-Xlinker", "-rpath", "-Xlinker", directory.path, consumerFile.path, driverFile.path, "-o", binary.path])
            XCTAssertEqual(compiled.0, 0, compiled.1)
            if compiled.0 == 0 {
                let ran = try process(binary.path, [])
                XCTAssertEqual(ran.0, 0, ran.1)
                XCTAssertEqual(ran.1, expected)
            }
        }
        let invalidConsumers = [
            "import ParityProducer\nlet value = InternalValue(value: 1)",
            "import ParityProducer\nlet value = PublicMemberwiseOnly(value: 1)",
            "@testable import ParityProducer\nlet value = InternalValue(secret: \"hidden\")",
        ]
        for (index, source) in invalidConsumers.enumerated() {
            let file = directory.appendingPathComponent("Invalid\(index).swift")
            try source.write(to: file, atomically: true, encoding: .utf8)
            let checked = try swiftc(["-typecheck", "-I", directory.path, file.path])
            XCTAssertNotEqual(checked.0, 0, "Swift unexpectedly accepted inaccessible initializer: " + source)
            XCTAssertTrue(checked.1.contains("inaccessible") || checked.1.contains("incorrect argument label"), checked.1)
        }
    }

    private func swiftc(_ arguments: [String]) throws -> (Int32, String) {
        #if os(macOS)
        return try process("/usr/bin/xcrun", ["swiftc"] + arguments)
        #else
        return try process("/usr/bin/env", ["swiftc"] + arguments)
        #endif
    }

    private func process(_ executable: String, _ arguments: [String]) throws -> (Int32, String) {
        let command = Process()
        command.executableURL = URL(fileURLWithPath: executable)
        command.arguments = arguments
        let pipe = Pipe()
        command.standardOutput = pipe
        command.standardError = pipe
        try command.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        command.waitUntilExit()
        return (command.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
