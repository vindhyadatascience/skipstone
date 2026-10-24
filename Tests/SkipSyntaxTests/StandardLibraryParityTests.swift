// Copyright (c) 2026 Vindhya Data Science
// Licensed under the GNU Affero General Public License v3.0
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import SkipSyntax

final class StandardLibraryParityTests: XCTestCase {
    private func output(_ swift: String, expectedError: String? = nil, dependency: CodebaseInfo.ModuleExport? = nil) async throws -> String {
        let file = try tmpFile(named: "Source.swift", contents: swift)
        let info = CodebaseInfo()
        info.dependentModules = dependency.map { [$0] } ?? []
        let transpiler = Transpiler(transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info, transformers: builtinKotlinTransformers())
        var result = ""
        var messages: [Message] = []
        try await transpiler.transpile { transpilation in
            messages += transpilation.messages
            if transpilation.input.file.name == "Source.swift" { result += transpilation.output.content }
        }
        XCTAssertFalse(result.isEmpty)
        if let expectedError {
            XCTAssertTrue(messages.contains(where: { $0.kind == .error && $0.message.contains(expectedError) }), messages.map(\.formattedMessage).joined(separator: "\n") + "\n" + result)
        } else {
            XCTAssertTrue(messages.isEmpty, messages.map(\.formattedMessage).joined(separator: "\n"))
        }
        return result
    }

    func testGeneratedHashableNodesDeclareDependenciesWithoutWildcardImports() throws {
        try XCTSkipUnless(KotlinStandardLibraryParity.boxesAnyHashable, "AnyHashable boxing is off; SkipLib keeps AnyHashable a typealias (RNABrowser-fiea.30)")
        let source = Source(file: Source.FilePath(path: "/virtual/Parity.swift"), content: "value")
        let context = TypeInferenceContext(unavailableAPI: nil, source: source)
        let value = RawExpression(sourceCode: "value")
        _ = value.inferTypes(context: context, expecting: .int)
        let wrapped = KotlinStandardLibraryParity.coerce(KotlinIdentifier(name: "value"), expression: value, to: .named("AnyHashable", []))
        var dependencies = KotlinDependencies()
        wrapped.visit { node in node.insertDependencies(into: &dependencies); return .recurse(nil) }
        XCTAssertEqual(dependencies.imports, ["skip.lib.AnyHashable"])

        let optional = RawExpression(sourceCode: "optional")
        _ = optional.inferTypes(context: context, expecting: .optional(.int))
        let erased = KotlinStandardLibraryParity.coerce(KotlinIdentifier(name: "optional"), expression: optional, to: .named("AnyHashable", []))
        dependencies = KotlinDependencies()
        erased.visit { node in node.insertDependencies(into: &dependencies); return .recurse(nil) }
        XCTAssertEqual(dependencies.imports, ["skip.lib.AnyHashable", "skip.lib.anyHashableOptional"])
    }

    func testStringAppendWritesBackForCharacterStringAndSequence() async throws {
        let kotlin = try await output("""
        func appendValues() {
            var text = "start"
            let character: Character = "!"
            text.append(character)
            text.append("🎵")
            text.append(contentsOf: [character, character])
        }
        """)
        XCTAssertEqual(kotlin.components(separatedBy: "text = `skip append old` + `skip append suffix`").count - 1, 3, kotlin)
        XCTAssertTrue(kotlin.contains(".iterable.joinToString(separator = \"\")"), kotlin)
        XCTAssertFalse(kotlin.contains("text.append("), kotlin)
    }

    func testStringAppendCapturesSideEffectReceiverAndIndexExactlyOnce() async throws {
        let kotlin = try await output("""
        class Store { var texts: [String] = ["start"] }
        var shared = Store()
        func owner() -> Store { return shared }
        func index() -> Int { return 0 }
        func suffix() -> String { return "!" }
        func appendValue() { owner().texts[index()].append(suffix()) }
        """)
        XCTAssertTrue(kotlin.contains("val `skip append base` = owner().texts"), kotlin)
        XCTAssertTrue(kotlin.contains("val `skip append index 0` = index()"), kotlin)
        XCTAssertTrue(kotlin.contains("val `skip append suffix` = suffix()"), kotlin)
        XCTAssertEqual(kotlin.components(separatedBy: "= owner().texts").count - 1, 1, kotlin)
        XCTAssertEqual(kotlin.components(separatedBy: "= index()").count - 1, 1, kotlin)
        XCTAssertEqual(kotlin.components(separatedBy: "= suffix()").count - 1, 1, kotlin)
        XCTAssertTrue(kotlin.contains("`skip append base`[`skip append index 0`] = `skip append old` + `skip append suffix`"), kotlin)
    }

    func testOptionalStringAppendGuardsArgumentEvaluation() async throws {
        let kotlin = try await output("""
        func suffix() -> String { return "!" }
        func appendValue() {
            var text: String? = nil
            text?.append(suffix())
        }
        """)
        XCTAssertTrue(kotlin.contains("if (`skip append old` != null) { val `skip append suffix` = suffix()"), kotlin)
        XCTAssertTrue(kotlin.contains("text = `skip append old` + `skip append suffix`"), kotlin)
    }

    func testDictionaryGroupingUsesFactoryAndDoesNotForwardValueGeneric() async throws {
        let kotlin = try await output("""
        func group() {
            let groups: [Int: [Int]] = Dictionary<Int, [Int]>(grouping: [1, 2, 3], by: { value in value % 2 })
        }
        """)
        XCTAssertTrue(kotlin.contains("dictionaryGrouping(grouping ="), kotlin)
        XCTAssertTrue(kotlin.contains("import skip.lib.dictionaryGrouping"), kotlin)
        XCTAssertFalse(kotlin.contains("Dictionary<Int, Array<Int>>(grouping"), kotlin)
        XCTAssertFalse(kotlin.contains("dictionaryGrouping<"), kotlin)
    }

    func testGroupingNullableElementsAndExplicitReturnClosureKeepFactoryContext() async throws {
        let kotlin = try await output("""
        func group(_ values: [Int?]) {
            let nullable = Dictionary(grouping: values, by: { $0 })
            let explicit = Dictionary(grouping: [1, 2]) { value -> Int in
                return value
            }
        }
        """)
        XCTAssertEqual(kotlin.components(separatedBy: "dictionaryGrouping(grouping =").count - 1, 2, kotlin)
        XCTAssertTrue(kotlin.contains("fun(value: Int): Int"), kotlin)
        XCTAssertFalse(kotlin.contains("fun(value: *)"), kotlin)
    }

    func testOptionalErasureUsesTheActualSerializedSkipLibConstructor() async throws {
        try XCTSkipUnless(KotlinStandardLibraryParity.boxesAnyHashable, "AnyHashable boxing is off; SkipLib keeps AnyHashable a typealias (RNABrowser-fiea.30)")
        let producerFile = try tmpFile(named: "Hashable.swift", contents: """
        // SKIP SYMBOLFILE
        public struct AnyHashable {
            public init<H: Hashable>(_ value: H) {}
        }
        """)
        let producerInfo = CodebaseInfo(moduleName: "SkipLib")
        let producer = Transpiler(transpileFiles: [Source.FilePath(path: producerFile.path)], codebaseInfo: producerInfo, transformers: builtinKotlinTransformers())
        try await producer.transpile { result in
            XCTAssertTrue(result.messages.isEmpty, result.messages.map(\.formattedMessage).joined(separator: "\n"))
        }
        let data = try JSONEncoder().encode(CodebaseInfo.ModuleExport(of: producerInfo))
        let exported = try JSONDecoder().decode(CodebaseInfo.ModuleExport.self, from: data)
        let kotlin = try await output("""
        import SkipLib
        func erase(_ value: Int?) -> AnyHashable { return AnyHashable(value) }
        """, dependency: exported)
        XCTAssertTrue(kotlin.contains("anyHashableOptional(value, type = \"Int\")"), kotlin)
        XCTAssertTrue(kotlin.contains("import skip.lib.anyHashableOptional"), kotlin)
        XCTAssertFalse(kotlin.contains("AnyHashable(value)"), kotlin)
    }

    func testAnyHashableCoercionsForInitializerArgumentAssignmentAndReturn() async throws {
        try XCTSkipUnless(KotlinStandardLibraryParity.boxesAnyHashable, "AnyHashable boxing is off; SkipLib keeps AnyHashable a typealias (RNABrowser-fiea.30)")
        let kotlin = try await output("""
        func accept(_ value: AnyHashable) {}
        func convert(_ value: Int) -> AnyHashable {
            let result: AnyHashable = value
            var changed: AnyHashable = "start"
            changed = value
            accept(value)
            return value
        }
        """)
        XCTAssertTrue(kotlin.contains("result: AnyHashable = AnyHashable(value)"), kotlin)
        XCTAssertTrue(kotlin.contains("changed = AnyHashable(value)"), kotlin)
        XCTAssertTrue(kotlin.contains("accept(AnyHashable(value))"), kotlin)
        XCTAssertTrue(kotlin.contains("return AnyHashable(value)"), kotlin)
        XCTAssertTrue(kotlin.contains("AnyHashable(\"start\")"), kotlin)
    }

    func testAnyHashableFallbackRejectsAnotherOverloadsDistinctSecondLabel() async throws {
        let kotlin = try await output("""
        class Routes {
            static func route(for index: Int, valueString: String) -> String { return valueString }
            private func route(for key: AnyHashable, value: Any) -> String {
                let index = 1
                let valueString = "value"
                return route(for: index, valueString: valueString)
            }
        }
        """)
        XCTAssertTrue(kotlin.contains("route(for_ = index, valueString = valueString)"), kotlin)
        XCTAssertFalse(kotlin.contains("route(for_ = AnyHashable(index)"), kotlin)
    }

    func testAnyHashableFallbackMapsSkippedDefaultsAndVariadicActualArguments() async throws {
        try XCTSkipUnless(KotlinStandardLibraryParity.boxesAnyHashable, "AnyHashable boxing is off; SkipLib keeps AnyHashable a typealias (RNABrowser-fiea.30)")
        let kotlin = try await output("""
        func defaulted(prefix: String = "prefix", value: AnyHashable, suffix: Int = 0) {}
        func repeated(_ values: AnyHashable...) {}
        func use(_ value: Int) {
            defaulted(value: value)
            repeated(value, value)
        }
        """)
        XCTAssertTrue(kotlin.contains("defaulted(value = AnyHashable(value))"), kotlin)
        XCTAssertTrue(kotlin.contains("repeated(AnyHashable(value), AnyHashable(value))"), kotlin)
    }

    func testAnyHashableOptionalLiftingAndAlreadyWrappedValues() async throws {
        try XCTSkipUnless(KotlinStandardLibraryParity.boxesAnyHashable, "AnyHashable boxing is off; SkipLib keeps AnyHashable a typealias (RNABrowser-fiea.30)")
        let kotlin = try await output("""
        func convert(_ value: Int?, _ wrapped: AnyHashable) {
            let result: AnyHashable? = value
            let unchanged: AnyHashable = wrapped
            let absent: AnyHashable? = nil
        }
        """)
        XCTAssertTrue(kotlin.contains("(value).let { if (it == null) null else AnyHashable(it) }"), kotlin)
        XCTAssertFalse(kotlin.contains("AnyHashable(wrapped)"), kotlin)
        XCTAssertFalse(kotlin.contains("AnyHashable(null)"), kotlin)
    }

    func testExplicitAnyHashableCastsBoxStaticValuesAndPreserveTypedOptionalErasure() async throws {
        try XCTSkipUnless(KotlinStandardLibraryParity.boxesAnyHashable, "AnyHashable boxing is off; SkipLib keeps AnyHashable a typealias (RNABrowser-fiea.30)")
        let kotlin = try await output("""
        typealias Count = Int
        func casts(_ text: String, _ number: Double, _ optional: Count?, _ wrapped: AnyHashable) {
            let stringKey = text as AnyHashable
            let numberKey = number as Swift.AnyHashable
            let optionalKey = optional as AnyHashable
            let liftedKey = optional as AnyHashable?
            let unchanged = wrapped as AnyHashable
            let plain = text as String
        }
        """)
        XCTAssertTrue(kotlin.contains("stringKey = AnyHashable(text)"), kotlin)
        XCTAssertTrue(kotlin.contains("numberKey = AnyHashable(number)"), kotlin)
        XCTAssertTrue(kotlin.contains("optionalKey = anyHashableOptional(optional, type = \"Int\")"), kotlin)
        XCTAssertTrue(kotlin.contains("liftedKey = (optional).let { if (it == null) null else AnyHashable(it) }"), kotlin)
        XCTAssertFalse(kotlin.contains("AnyHashable(wrapped)"), kotlin)
        XCTAssertTrue(kotlin.contains("plain = text as String"), kotlin)
        XCTAssertFalse(kotlin.contains("text as AnyHashable"), kotlin)
        XCTAssertTrue(kotlin.contains("import skip.lib.anyHashableOptional"), kotlin)
    }

    func testConditionalAndForcedHashableCastsKeepDynamicCastSemantics() async throws {
        let kotlin = try await output("""
        func casts(_ value: Any) {
            let conditional = value as? AnyHashable
            let forced = value as! AnyHashable
        }
        """)
        XCTAssertTrue(kotlin.contains("value as? AnyHashable"), kotlin)
        XCTAssertTrue(kotlin.contains("value as AnyHashable"), kotlin)
        XCTAssertFalse(kotlin.contains("AnyHashable(value)"), kotlin)
    }

    func testExplicitHashableCastDoesNotBoxASameNamedUserType() async throws {
        let kotlin = try await output("""
        struct AnyHashable {}
        func same(_ value: AnyHashable) -> AnyHashable { return value as AnyHashable }
        """)
        XCTAssertTrue(kotlin.contains("value as AnyHashable"), kotlin)
        XCTAssertFalse(kotlin.contains("AnyHashable(value)"), kotlin)
    }

    func testExplicitNestedOptionalHashableCastKeepsUnsupportedPresenceDiagnostic() async throws {
        try XCTSkipUnless(KotlinStandardLibraryParity.boxesAnyHashable, "AnyHashable boxing is off; SkipLib keeps AnyHashable a typealias (RNABrowser-fiea.30)")
        let kotlin = try await output("""
        func erase(_ value: Int??) -> AnyHashable { return value as AnyHashable }
        """, expectedError: "cannot preserve nested Optional presence")
        XCTAssertFalse(kotlin.contains("anyHashableOptional(value"), kotlin)
    }

    func testConcreteOptionalErasurePreservesTypedNilAndResolvesAliases() async throws {
        try XCTSkipUnless(KotlinStandardLibraryParity.boxesAnyHashable, "AnyHashable boxing is off; SkipLib keeps AnyHashable a typealias (RNABrowser-fiea.30)")
        let kotlin = try await output("""
        typealias Count = Int
        func erase(_ value: Count?) -> AnyHashable { return value }
        """)
        XCTAssertTrue(kotlin.contains("anyHashableOptional(value, type = \"Int\")"), kotlin)
        XCTAssertFalse(kotlin.contains("type = \"Count\""), kotlin)
    }

    func testNestedOptionalErasureProducesExplicitDiagnostic() async throws {
        try XCTSkipUnless(KotlinStandardLibraryParity.boxesAnyHashable, "AnyHashable boxing is off; SkipLib keeps AnyHashable a typealias (RNABrowser-fiea.30)")
        let kotlin = try await output("""
        func erase(_ value: Int??) -> AnyHashable { return value }
        """, expectedError: "cannot preserve nested Optional presence")
        XCTAssertFalse(kotlin.contains("anyHashableOptional(value"), kotlin)
    }

    func testGenericOptionalErasureCannotInventAConcreteTypeKey() async throws {
        try XCTSkipUnless(KotlinStandardLibraryParity.boxesAnyHashable, "AnyHashable boxing is off; SkipLib keeps AnyHashable a typealias (RNABrowser-fiea.30)")
        let kotlin = try await output("""
        func erase<T: Hashable>(_ value: T?) -> AnyHashable { return value }
        """, expectedError: "erased wrapped type of a generic Optional")
        XCTAssertFalse(kotlin.contains("type = \"T\""), kotlin)
    }

    func testConcreteOuterGenericConstraintUsesActualOptionalTypeKey() async throws {
        try XCTSkipUnless(KotlinStandardLibraryParity.boxesAnyHashable, "AnyHashable boxing is off; SkipLib keeps AnyHashable a typealias (RNABrowser-fiea.30)")
        let kotlin = try await output("""
        struct Box<T> {}
        extension Box where T == Int64 {
            func erase(_ value: T?) -> AnyHashable { return value }
        }
        """)
        XCTAssertTrue(kotlin.contains("anyHashableOptional(value, type = \"Int64\")"), kotlin)
        XCTAssertFalse(kotlin.contains("type = \"T\""), kotlin)
    }

    func testAnyHashableArrayAndDictionaryLiteralElementsAreWrapped() async throws {
        try XCTSkipUnless(KotlinStandardLibraryParity.boxesAnyHashable, "AnyHashable boxing is off; SkipLib keeps AnyHashable a typealias (RNABrowser-fiea.30)")
        let kotlin = try await output("""
        func containers(_ value: Int) {
            let array: [AnyHashable] = [value, 1]
            let dictionary: [AnyHashable: AnyHashable] = [value: "text"]
        }
        """)
        XCTAssertTrue(kotlin.contains("AnyHashable(value)"), kotlin)
        XCTAssertTrue(kotlin.contains("AnyHashable(1)"), kotlin)
        XCTAssertTrue(kotlin.contains("AnyHashable(\"text\")"), kotlin)
    }

    func testOptionalIEEEAndGenericEqualityUseRuntimeHelper() async throws {
        let kotlin = try await output("""
        func generic<T: Equatable>(_ lhs: T, _ rhs: T) -> Bool { return lhs == rhs }
        func optional(_ lhs: Double?, _ rhs: Double?) -> Bool { return lhs != rhs }
        func integers(_ lhs: Int, _ rhs: Int) -> Bool { return lhs == rhs }
        func nilCheck(_ value: Double?) -> Bool { return value == nil }
        """)
        XCTAssertTrue(kotlin.contains("swiftEquatableEquals(lhs, rhs)"), kotlin)
        XCTAssertTrue(kotlin.contains("import skip.lib.swiftEquatableEquals"), kotlin)
        XCTAssertTrue(kotlin.contains("!swiftEquatableEquals(lhs, rhs)"), kotlin)
        XCTAssertTrue(kotlin.contains("fun integers(lhs: Int, rhs: Int): Boolean = lhs == rhs"), kotlin)
        XCTAssertFalse(kotlin.contains("swiftEquatableEquals(value, null)"), kotlin)
    }

    func testExactIntegerFactoryDoesNotChangeTruncatingNumericConstructors() async throws {
        let kotlin = try await output("""
        func exact(_ value: Float) -> Int? { return Int(exactly: value) }
        func exactDouble(_ value: Double) -> Int? { return Swift.Int(exactly: value) }
        func truncated(_ value: Float) -> Int { return Int(value) }
        func truncatedDouble(_ value: Double) -> Int { return Int(value) }
        struct Counter { init?(exactly value: Float) {} }
        func custom(_ value: Float) -> Counter? { return Counter(exactly: value) }
        """)
        XCTAssertTrue(kotlin.contains("import skip.lib.IntExactly"), kotlin)
        XCTAssertEqual(kotlin.components(separatedBy: "IntExactly(exactly = value)").count - 1, 2, kotlin)
        XCTAssertTrue(kotlin.contains("fun truncated(value: Float): Int = Int(value)"), kotlin)
        XCTAssertTrue(kotlin.contains("fun truncatedDouble(value: Double): Int = Int(value)"), kotlin)
        XCTAssertTrue(kotlin.contains("Counter(exactly = value)"), kotlin)
        XCTAssertFalse(kotlin.contains("Int(exactly ="), kotlin)
    }

    func testInferredEnumComparisonRetainsContextualMemberType() async throws {
        let kotlin = try await output("""
        class Container<T> {
            func map<R>(_ transform: (T) -> R) -> [R] { return [] }
        }
        enum ElementEnum: String { case one, two }
        func compare() {
            let enums = Container<String>().map { ElementEnum(rawValue: $0) }
            let equal = enums[1] == .two
            let unequal = enums[1] != .one
        }
        """)
        XCTAssertTrue(kotlin.contains("enums[1] == ElementEnum.two"), kotlin)
        XCTAssertTrue(kotlin.contains("enums[1] != ElementEnum.one"), kotlin)
        XCTAssertFalse(kotlin.contains("Any.two"), kotlin)
        XCTAssertFalse(kotlin.contains("Any.one"), kotlin)
        XCTAssertFalse(kotlin.contains("swiftEquatableEquals"), kotlin)
    }
}
