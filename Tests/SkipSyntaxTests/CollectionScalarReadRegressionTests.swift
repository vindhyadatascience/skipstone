// Copyright (c) 2026 Vindhya Data Science
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
@testable import SkipSyntax

final class CollectionScalarReadRegressionTests: XCTestCase {
    private func symbols() async throws -> CodebaseInfo.ModuleExport {
        let swift = """
        // SKIP SYMBOLFILE
        public struct Array<Element> {
            public init() {}
            public var count: Int { 0 }
            public var isEmpty: Bool { true }
            public subscript(_ index: Int) -> Element { fatalError() }
        }
        public struct Dictionary<Key, Value> {
            public init() {}
            public var count: Int { 0 }
            public var isEmpty: Bool { true }
        }
        public struct Set<Element> {
            public init() {}
            public var count: Int { 0 }
            public var isEmpty: Bool { true }
        }
        """
        return try await transpile(swift, module: "SkipLib", dependencies: []).1
    }

    private func transpile(_ swift: String, module: String = "Consumer", dependencies: [CodebaseInfo.ModuleExport]? = nil) async throws -> (String, CodebaseInfo.ModuleExport) {
        let file = try tmpFile(named: module + ".swift", contents: swift)
        let info = CodebaseInfo(moduleName: module)
        if let dependencies { info.dependentModules = dependencies }
        else { info.dependentModules = [try await symbols()] }
        let transpiler = Transpiler(transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info, transformers: builtinKotlinTransformers())
        var kotlin = ""
        try await transpiler.transpile { result in
            XCTAssertTrue(result.messages.isEmpty, result.messages.map(\.formattedMessage).joined(separator: "\n"))
            kotlin += result.output.content
        }
        let exported = try JSONDecoder().decode(CodebaseInfo.ModuleExport.self, from: JSONEncoder().encode(CodebaseInfo.ModuleExport(of: info, includeTestingMetadata: true)))
        return (kotlin, exported)
    }

    func testPrimitiveReadersUseRawStorageAndRetainOrdinaryCopyingGetter() async throws {
        let (kotlin, _) = try await transpile("""
        final class Holder {
            var updates = 0
            var values: [Int] = [] { didSet { updates += 1 } }
            var mapping: [String: Int] = [:]
            var members = Set<Int>()
            func ownCount() -> Int { let sread_values_count = 90; return values.count + sread_values_count }
            func localCount() -> Int { let values: [Int] = []; return values.count }
        }
        func count(_ holder: Holder) -> Int {
            holder.values.count + holder.mapping.count + holder.members.count
        }
        func empty(_ holder: Holder) -> Bool {
            holder.values.isEmpty && holder.mapping.isEmpty && holder.members.isEmpty
        }
        func escaped(_ holder: Holder) -> [Int] { holder.values }
        """)
        for property in ["values", "mapping", "members"] {
            XCTAssertTrue(kotlin.contains("internal val sread_\(property)_count: Int"), kotlin)
            XCTAssertTrue(kotlin.contains("get() = smodify_\(property)storage.count"), kotlin)
            XCTAssertTrue(kotlin.contains("get() = smodify_\(property)storage.isEmpty"), kotlin)
            XCTAssertTrue(kotlin.contains("holder.sread_\(property)_count"), kotlin)
            XCTAssertTrue(kotlin.contains("holder.sread_\(property)_isEmpty"), kotlin)
        }
        XCTAssertTrue(kotlin.contains("get() = smodify_valuesstorage.sref("), kotlin)
        XCTAssertTrue(kotlin.contains("internal fun escaped(holder: Holder): Array<Int> = holder.values.sref()"), kotlin)
        XCTAssertTrue(kotlin.contains("return this@Holder.sread_values_count + sread_values_count"), kotlin)
        XCTAssertTrue(kotlin.contains("return values.count"), kotlin)
        XCTAssertFalse(kotlin.contains("holder.smodify_values"), kotlin)
    }

    func testReceiverRunsOnceAndSubscriptIterationAndEscapesRemainOrdinaryReads() async throws {
        let (kotlin, _) = try await transpile("""
        final class Holder { var values: [Int] = [] }
        func owner() -> Holder { Holder() }
        func index() -> Int { 0 }
        func scalar() -> Int { owner().values.count }
        func other(_ holder: Holder) -> Int {
            let escaped = holder.values
            let item = holder.values[index()]
            var sum = item
            for value in holder.values { sum += value }
            return sum + escaped.count
        }
        """)
        XCTAssertEqual(kotlin.components(separatedBy: "owner().sread_values_count").count - 1, 1, kotlin)
        XCTAssertTrue(kotlin.contains("val escaped = holder.values.sref()"), kotlin)
        XCTAssertTrue(kotlin.contains("holder.values[index()]"), kotlin)
        XCTAssertEqual(kotlin.components(separatedBy: "index()]").count - 1, 1, kotlin)
        XCTAssertTrue(kotlin.contains("in holder.values.sref()"), kotlin)
        XCTAssertTrue(kotlin.contains("escaped.count"), kotlin)
        XCTAssertFalse(kotlin.contains("sread_escaped"), kotlin)
    }

    func testComputedOpenLazyOptionalAsyncAndOldValueObserversDoNotAdvertiseReaders() async throws {
        let (kotlin, exported) = try await transpile("""
        public class OpenHolder { public var values: [Int] = [] }
        public final class Holder {
            public var observed: [Int] = [] { didSet { print(oldValue.count) } }
            public var notified: [Int] = [] { willSet { print(newValue.count) } }
            public var computed: [Int] { [] }
            public lazy var lazyValues: [Int] = []
            public var optional: [Int]? = nil
            public var asynchronous: [Int] { get async { [] } }
        }
        """)
        XCTAssertFalse(kotlin.contains("sread_"), kotlin)
        for type in exported.rootTypes {
            for variable in type.variables {
                XCTAssertFalse(variable.apiFlags?.options.contains(.scopedCollectionRead) == true, variable.name)
            }
        }
    }

    func testCollisionsIncludingJvmGetterNamesFallBackAndKeywordReaderNamesStayConsistent() async throws {
        let (kotlin, exported) = try await transpile("""
        public final class Holder {
            public var collision: [Int] = []
            public var propertyCollision: [Int] = []
            public var sread_propertyCollision_count = 0
            public var object: [Int] = []
            public func getSread_collision_count() -> Int { 0 }
        }
        func use(_ holder: Holder) -> Int {
            holder.collision.count + holder.propertyCollision.count + holder.object.count
        }
        """)
        let holder = try XCTUnwrap(exported.rootTypes.first { $0.name == "Holder" })
        for name in ["collision", "propertyCollision"] {
            XCTAssertFalse(holder.variables.first { $0.name == name }?.apiFlags?.options.contains(.scopedCollectionRead) == true)
            XCTAssertTrue(kotlin.contains("holder.\(name).count"), kotlin)
        }
        XCTAssertTrue(kotlin.contains("public val sread_object__count: Int"), kotlin)
        XCTAssertTrue(kotlin.contains("holder.sread_object__count"), kotlin)
        XCTAssertFalse(kotlin.contains("val sread_collision_count"), kotlin)
    }

    func testPublicReadCapabilityRoundtripsButOldModifyOnlyAndSymbolModulesFallBack() async throws {
        let producer = """
        public final class Holder {
            public var values: [Int] = []
            public private(set) var readOnlyOutside: [Int] = []
            private var hidden: [Int] = []
            public init() {}
        }
        """
        let consumer = """
        import Producer
        func use(_ holder: Holder) -> Int { holder.values.count + holder.readOnlyOutside.count }
        """
        let builtin = try await symbols()
        let (emitted, exported) = try await transpile(producer, module: "Producer", dependencies: [builtin])
        let holder = try XCTUnwrap(exported.rootTypes.first { $0.name == "Holder" })
        XCTAssertFalse(holder.variables.contains { $0.name == "hidden" })
        XCTAssertTrue(holder.variables.first { $0.name == "values" }?.apiFlags?.options.contains(.scopedCollectionRead) == true)
        XCTAssertTrue(emitted.contains("public val sread_readOnlyOutside_count: Int"), emitted)
        XCTAssertTrue(emitted.contains("private val sread_hidden_count: Int"), emitted)
        let (current, _) = try await transpile(consumer, dependencies: [builtin, exported])
        XCTAssertTrue(current.contains("holder.sread_values_count"), current)
        XCTAssertTrue(current.contains("holder.sread_readOnlyOutside_count"), current)
        let legacy = try JSONDecoder().decode(CodebaseInfo.ModuleExport.self, from: JSONEncoder().encode(exported))
        let legacyHolder = try XCTUnwrap(legacy.rootTypes.first { $0.name == "Holder" })
        // The translated-module testing payload is the canonical lookup copy,
        // so model an older producer on both serialized visibility surfaces.
        for payload in [legacy, legacy.testingMetadata].compactMap({ $0 }) {
            let type = try XCTUnwrap(payload.rootTypes.first { $0.name == "Holder" })
            for index in type.variables.indices {
                var flags = type.variables[index].apiFlags ?? APIFlags()
                flags.options.remove(.scopedCollectionRead)
                type.variables[index].apiFlags = flags
            }
        }
        XCTAssertTrue(legacyHolder.variables.first { $0.name == "values" }?.apiFlags?.options.contains(.scopedModify) == true)
        let (old, _) = try await transpile(consumer, dependencies: [builtin, legacy])
        XCTAssertFalse(old.contains("sread_"), old)
        XCTAssertTrue(old.contains("holder.values.count"), old)
        let (_, symbolsOnly) = try await transpile("// SKIP SYMBOLFILE\n" + producer, module: "Producer", dependencies: [builtin])
        let (symbolConsumer, _) = try await transpile(consumer, dependencies: [builtin, symbolsOnly])
        XCTAssertFalse(symbolConsumer.contains("sread_"), symbolConsumer)
        XCTAssertTrue(symbolConsumer.contains("holder.values.count"), symbolConsumer)
    }

    func testPrivateSameNamedTypesInDifferentFilesDoNotShareReadCapability() async throws {
        let first = try tmpFile(named: "First.swift", contents: """
        private final class SameName { var values: [Int] = [] }
        func first() -> Int { let holder = SameName(); return holder.values.count }
        """)
        let second = try tmpFile(named: "Second.swift", contents: """
        private final class SameName { var values: [Int] { [] } }
        func second() -> Int { let holder = SameName(); return holder.values.count }
        """)
        let info = CodebaseInfo(moduleName: "PrivateNames")
        info.dependentModules = [try await symbols()]
        let transpiler = Transpiler(transpileFiles: [first, second].map { Source.FilePath(path: $0.path) }, codebaseInfo: info, transformers: builtinKotlinTransformers())
        var results: [String: String] = [:]
        try await transpiler.transpile { result in
            XCTAssertTrue(result.messages.isEmpty, result.messages.map(\.formattedMessage).joined(separator: "\n"))
            results[result.input.file.name] = result.output.content
        }
        let eligible = try XCTUnwrap(results["First.swift"])
        let fallback = try XCTUnwrap(results["Second.swift"])
        XCTAssertTrue(eligible.contains("holder.sread_values_count"), eligible)
        XCTAssertFalse(fallback.contains("sread_"), fallback)
        XCTAssertTrue(fallback.contains("holder.values.count"), fallback)
        for declaration in info.rootTypes where declaration.name == "SameName" {
            let capable = declaration.variables.first { $0.name == "values" }?.apiFlags?.options.contains(.scopedCollectionRead) == true
            XCTAssertEqual(capable, declaration.sourceFile?.path == first.path)
        }
        let exported = CodebaseInfo.ModuleExport(of: info, includeTestingMetadata: true)
        XCTAssertFalse(exported.rootTypes.contains { $0.name == "SameName" })
        XCTAssertFalse(exported.testingMetadata?.rootTypes.contains { $0.name == "SameName" } ?? true)
    }

    func testImplicitReadersPreserveLexicalOwnerInsideNestedKotlinReceiverLambdas() async throws {
        let (kotlin, _) = try await transpile("""
        final class Density {}
        // SKIP REPLACE: internal fun withDensity(density: Density, body: Density.() -> Int): Int = density.body()
        func withDensity(_ density: Density, _ body: () -> Int) -> Int { body() }
        final class Holder {
            var values: [Int] = []
            func nested(_ density: Density) -> Int {
                let sread_values_count = 90
                return withDensity(density) {
                    values.count + withDensity(density) { values.count } + sread_values_count
                }
            }
        }
        """)
        XCTAssertTrue(kotlin.contains("body: Density.() -> Int"), kotlin)
        XCTAssertEqual(kotlin.components(separatedBy: "this@Holder.sread_values_count").count - 1, 2, kotlin)
        XCTAssertFalse(kotlin.contains("this.sread_values_count"), kotlin)
        XCTAssertTrue(kotlin.contains("val sread_values_count = 90"), kotlin)
        XCTAssertTrue(kotlin.contains("internal val sread_values_count: Int"), kotlin)
    }

    func testRawPropertyAndOwnerDeclarationsDoNotPromiseScalarReaderAccessors() async throws {
        let (kotlin, exported) = try await transpile("""
        public final class PropertyHolder {
            // SKIP REPLACE: public var values: Array<Int> = arrayOf()
            public var values: [Int] = []
        }
        // SKIP DECLARE: public class DeclaredHolder
        public final class DeclaredHolder {
            public var values: [Int] = []
        }
        // SKIP REPLACE: public class ReplacedHolder { public var values: Array<Int> = arrayOf() }
        public final class ReplacedHolder {
            public var values: [Int] = []
        }
        func count(_ property: PropertyHolder, _ declared: DeclaredHolder, _ replaced: ReplacedHolder) -> Int {
            property.values.count + declared.values.count + replaced.values.count
        }
        """)
        XCTAssertFalse(kotlin.contains("sread_"), kotlin)
        XCTAssertTrue(kotlin.contains("property.values.count"), kotlin)
        XCTAssertTrue(kotlin.contains("declared.values.count"), kotlin)
        XCTAssertTrue(kotlin.contains("replaced.values.count"), kotlin)
        for payload in [exported, exported.testingMetadata].compactMap({ $0 }) {
            for type in payload.rootTypes {
                for variable in type.variables {
                    XCTAssertFalse(variable.apiFlags?.options.contains(.scopedCollectionRead) == true, type.name + "." + variable.name)
                }
            }
        }
    }

    func testImportedExtensionImplicitReadFallsBackWithoutInventingClassLabel() async throws {
        let builtin = try await symbols()
        let (_, producer) = try await transpile("""
        public final class Holder { public var values: [Int] = []; public init() {} }
        """, module: "Producer", dependencies: [builtin])
        let (kotlin, _) = try await transpile("""
        import Producer
        extension Holder {
            func externalCount() -> Int { values.count }
        }
        """, dependencies: [builtin, producer])
        XCTAssertTrue(kotlin.contains("Holder.externalCount"), kotlin)
        XCTAssertTrue(kotlin.contains("values.count"), kotlin)
        XCTAssertFalse(kotlin.contains("sread_"), kotlin)
        XCTAssertFalse(kotlin.contains("this@Holder"), kotlin)
    }
}
