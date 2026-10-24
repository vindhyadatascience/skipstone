// Copyright (c) 2026 Vindhya Data Science
// Licensed under the GNU Affero General Public License v3.0
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import Foundation
@testable import SkipSyntax

final class CollectionModifyRegressionTests: XCTestCase {
    private func output(_ swift: String) async throws -> String {
        let file = try tmpFile(named: "CollectionModify.swift", contents: swift)
        let transpiler = Transpiler(transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: CodebaseInfo(), transformers: builtinKotlinTransformers())
        var result = ""
        try await transpiler.transpile { transpilation in
            XCTAssertTrue(transpilation.messages.isEmpty, transpilation.messages.map(\.formattedMessage).joined(separator: "\n"))
            result += transpilation.output.content
        }
        return result
    }

    func testMutatingMetadataSelectsScopedStoredArrayAccess() async throws {
        let result = try await output("""
        extension Array { mutating func poke() {} }
        final class Holder {
            var updates = 0
            var values = [Int]() { didSet { updates += 1 } }
        }
        func use(_ holder: Holder) {
            holder.values.poke()
            holder.values[0] = 7
            let copy = holder.values
        }
        """)
        XCTAssertTrue(result.contains("private var smodify_valuesstorage: Array<Int>"), result)
        XCTAssertTrue(result.contains("get() = smodify_valuesstorage.sref("), result)
        XCTAssertTrue(result.contains("internal fun <R> smodify_values(body: (InOut<Array<Int>>) -> R): R"), result)
        XCTAssertTrue(result.contains("return body(InOut({ smodify_valuesstorage }, { smodify_valuesstorage = it.sref() }))"), result)
        XCTAssertTrue(result.contains("holder.smodify_values { smodifyvalue -> smodifyvalue.value.poke() }"), result)
        XCTAssertTrue(result.contains("holder.smodify_values { smodifyvalue -> smodifyvalue.value[0] = 7 }"), result)
        XCTAssertTrue(result.contains("val copy = holder.values.sref()"), result)
        XCTAssertTrue(result.contains("finally {\n            updates += 1"), result)
    }

    func testNestedStoredStructAndInoutUseScopedAccess() async throws {
        let result = try await output("""
        extension Array { mutating func poke() {} }
        struct Value { var values = [Int]() }
        final class Holder { var value = Value() }
        func replace(_ values: inout [Int]) { values = [] }
        func use(_ holder: Holder) {
            holder.value.values.poke()
            replace(&holder.value.values)
        }
        """)
        let compact = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        XCTAssertTrue(compact.contains("holder.smodify_value { smodifyvalue -> smodifyvalue.value.smodify_values"), result)
        XCTAssertTrue(result.contains("replace(InOut({ smodifyvalue.value }, { smodifyvalue.value = it }))"), result)
        XCTAssertTrue(result.contains("willmutate()"), result)
        XCTAssertTrue(result.contains("didmutate()"), result)
    }

    func testComputedOpenAndOldValueObserversRetainCopiedReads() async throws {
        let result = try await output("""
        extension Array { mutating func poke() {} }
        class OpenHolder { var values = [Int]() }
        final class Holder {
            var observed = [Int]() { didSet { print(oldValue.count) } }
            var computed: [Int] { get { [] } set {} }
            var notified = [Int]() { willSet { print(newValue.count) } }
            var early = [Int]() { didSet { if early.isEmpty { return } } }
        }
        func use(_ open: OpenHolder, _ holder: Holder) {
            open.values.poke()
            holder.observed.poke()
            holder.computed.poke()
            holder.notified.poke()
            holder.early.poke()
        }
        """)
        XCTAssertFalse(result.contains("smodify_"), result)
        XCTAssertTrue(result.contains("holder.observed.poke()"), result)
        XCTAssertTrue(result.contains("open.values.poke()"), result)
    }

    func testThrowingArgumentAndNonmutatingExtensionDoNotBorrow() async throws {
        let result = try await output("""
        extension Array {
            func inspect() {}
            mutating func poke(_ value: Int) {}
        }
        final class Holder { var values = [Int]() }
        func throwingValue() throws -> Int { 1 }
        func use(_ holder: Holder) throws {
            holder.values.inspect()
            try holder.values.poke(throwingValue())
        }
        """)
        XCTAssertTrue(result.contains("holder.values.inspect()"), result)
        XCTAssertTrue(result.contains("holder.values.poke(throwingValue())"), result)
        XCTAssertFalse(result.contains("holder.smodify_values"), result)
    }

    func testCrossModuleCapabilitySurvivesExportAndOlderDependenciesFallBack() async throws {
        let producer = """
        public extension Array { mutating func poke() {} }
        public final class ExportedHolder {
            public var values = [Int]()
            public var object = [Int]()
            public var observed = [Int]() { didSet { print(oldValue.count) } }
            public var computed: [Int] { get { [] } set {} }
            public init() {}
        }
        """
        let consumer = """
        import Producer
        func use(_ holder: ExportedHolder) {
            holder.values.poke()
            holder.object.poke()
            holder.observed.poke()
            holder.computed.poke()
        }
        """
        func transpile(_ source: String, module: String, dependencies: [CodebaseInfo.ModuleExport] = [], transformers: [KotlinTransformer] = builtinKotlinTransformers()) async throws -> (String, CodebaseInfo.ModuleExport) {
            let file = try tmpFile(named: "\(module).swift", contents: source)
            let info = CodebaseInfo(moduleName: module)
            info.dependentModules = dependencies
            let transpiler = Transpiler(transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info, transformers: transformers)
            var result = ""
            try await transpiler.transpile { output in
                XCTAssertTrue(output.messages.isEmpty, output.messages.map(\.formattedMessage).joined(separator: "\n"))
                result += output.output.content
            }
            // The consumer gets only serialized public API, never producer observer bodies.
            let export = try JSONDecoder().decode(CodebaseInfo.ModuleExport.self, from: JSONEncoder().encode(CodebaseInfo.ModuleExport(of: info)))
            return (result, export)
        }
        let (producerOutput, export) = try await transpile(producer, module: "Producer")
        let producerVariables = try XCTUnwrap(export.rootTypes.first(where: { $0.name == "ExportedHolder" })).variables
        XCTAssertTrue(producerVariables.first(where: { $0.name == "values" })?.apiFlags?.options.contains(.scopedModify) == true)
        XCTAssertFalse(producerVariables.first(where: { $0.name == "observed" })?.apiFlags?.options.contains(.scopedModify) == true)
        XCTAssertFalse(producerVariables.first(where: { $0.name == "computed" })?.apiFlags?.options.contains(.scopedModify) == true)
        XCTAssertTrue(producerOutput.contains("public fun <R> smodify_values"), producerOutput)
        XCTAssertTrue(producerOutput.contains("public fun <R> smodify_object_("), producerOutput)
        XCTAssertFalse(producerOutput.contains("fun <R> smodify_observed"), producerOutput)
        let (consumerOutput, _) = try await transpile(consumer, module: "Consumer", dependencies: [export])
        XCTAssertTrue(consumerOutput.contains("holder.smodify_values"), consumerOutput)
        XCTAssertTrue(consumerOutput.contains("holder.smodify_object_ {"), consumerOutput)
        XCTAssertTrue(consumerOutput.contains("holder.observed.poke()"), consumerOutput)
        XCTAssertTrue(consumerOutput.contains("holder.computed.poke()"), consumerOutput)
        XCTAssertFalse(consumerOutput.contains("holder.smodify_observed"), consumerOutput)
        XCTAssertFalse(consumerOutput.contains("holder.smodify_computed"), consumerOutput)
        let oldTransformers = builtinKotlinTransformers().filter { !($0 is KotlinCollectionModifyTransformer) }
        let (_, oldExport) = try await transpile(producer, module: "Producer", transformers: oldTransformers)
        let oldVariables = try XCTUnwrap(oldExport.rootTypes.first(where: { $0.name == "ExportedHolder" })).variables
        XCTAssertFalse(oldVariables.first(where: { $0.name == "values" })?.apiFlags?.options.contains(.scopedModify) == true)
        let (oldConsumer, _) = try await transpile(consumer, module: "Consumer", dependencies: [oldExport])
        XCTAssertTrue(oldConsumer.contains("holder.values.poke()"), oldConsumer)
        XCTAssertFalse(oldConsumer.contains("holder.smodify_values"), oldConsumer)
        let (_, symbolsOnly) = try await transpile("// SKIP SYMBOLFILE\n" + producer, module: "Producer")
        let symbolVariables = try XCTUnwrap(symbolsOnly.rootTypes.first(where: { $0.name == "ExportedHolder" })).variables
        XCTAssertFalse(symbolVariables.first(where: { $0.name == "values" })?.apiFlags?.options.contains(.scopedModify) == true)
        let (symbolConsumer, _) = try await transpile(consumer, module: "Consumer", dependencies: [symbolsOnly])
        XCTAssertTrue(symbolConsumer.contains("holder.values.poke()"), symbolConsumer)
        XCTAssertFalse(symbolConsumer.contains("holder.smodify_values"), symbolConsumer)
    }

    func testPrivateTypeNamesInDifferentFilesDoNotShareCapabilities() async throws {
        let first = try tmpFile(named: "First.swift", contents: """
        extension Array { mutating func poke() {} }
        private final class SameName { var values = [Int]() }
        func first() { let holder = SameName(); holder.values.poke() }
        """)
        let second = try tmpFile(named: "Second.swift", contents: """
        private final class SameName {
            var values = [Int]() { didSet { print(oldValue.count) } }
        }
        func second() { let holder = SameName(); holder.values.poke() }
        """)
        let info = CodebaseInfo()
        let transpiler = Transpiler(transpileFiles: [first, second].map { Source.FilePath(path: $0.path) }, codebaseInfo: info, transformers: builtinKotlinTransformers())
        var outputs: [String: String] = [:]
        try await transpiler.transpile { result in
            XCTAssertTrue(result.messages.isEmpty, result.messages.map(\.formattedMessage).joined(separator: "\n"))
            outputs[result.input.file.name] = result.output.content
        }
        let eligibleOutput = try XCTUnwrap(outputs["First.swift"])
        let fallbackOutput = try XCTUnwrap(outputs["Second.swift"])
        XCTAssertTrue(eligibleOutput.contains("holder.smodify_values"), eligibleOutput)
        XCTAssertFalse(fallbackOutput.contains("smodify_values"), fallbackOutput)
        XCTAssertTrue(fallbackOutput.contains("holder.values.poke()"), fallbackOutput)
        let declarations = info.rootTypes.filter { $0.name == "SameName" }
        XCTAssertEqual(declarations.count, 2)
        for declaration in declarations {
            let hasCapability = declaration.variables.first(where: { $0.name == "values" })?.apiFlags?.options.contains(.scopedModify) == true
            XCTAssertEqual(hasCapability, declaration.sourceFile?.path == first.path)
        }
    }

    func testUnknownGenericStoredValuesDoNotPublishModifyCapability() async throws {
        let result = try await output("""
        struct Generic<T> { var value: T }
        """)
        XCTAssertFalse(result.contains("smodify_"), result)
        XCTAssertTrue(result.contains("field.sref("), result)
    }
}
