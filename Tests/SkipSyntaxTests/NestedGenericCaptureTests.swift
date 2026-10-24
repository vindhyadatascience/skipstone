// Copyright (c) 2026 Vindhya Data Science
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
@testable import SkipSyntax

final class NestedGenericCaptureTests: XCTestCase {
    private func transpile(_ swift: String, fixture: String? = nil) async throws -> (String, CodebaseInfo) {
        let file = try tmpFile(named: "Source.swift", contents: swift)
        let info = CodebaseInfo(moduleName: "NestedFixture")
        let transpiler = Transpiler(packageName: "nested.fixture", transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info, transformers: builtinKotlinTransformers())
        var kotlin = ""
        try await transpiler.transpile { result in
            XCTAssertTrue(result.messages.isEmpty, result.messages.map(\.formattedMessage).joined(separator: "\n"))
            kotlin += result.output.content
        }
        if let fixture, let output = ProcessInfo.processInfo.environment["SKIP_NESTED_GENERIC_FIXTURE_DIR"] {
            let folder = URL(fileURLWithPath: output).appendingPathComponent(fixture)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try swift.write(to: folder.appendingPathComponent("Source.swift"), atomically: true, encoding: .utf8)
            try kotlin.write(to: folder.appendingPathComponent("Source.kt"), atomically: true, encoding: .utf8)
            let metadata = try JSONEncoder().encode(CodebaseInfo.ModuleExport(of: info, includeTestingMetadata: true))
            try metadata.write(to: folder.appendingPathComponent("Producer.skipcode.json"))
            try "fun main() { println(nested.fixture.answer()) }\n".write(to: folder.appendingPathComponent("Runner.kt"), atomically: true, encoding: .utf8)
        }
        return (kotlin, info)
    }

    func testNativeNestedCapturesKeepEqualArgumentsInDistinctBindingPositions() async throws {
        let (kotlin, info) = try await transpile("""
        struct Outer<T> {
            struct Inner<U> { let outer: T; let inner: U }
            struct Middle<V> {
                struct Deep<W> { let outer: T; let middle: V; let deep: W }
            }
            struct BodyOnly {
                func cast(_ value: Any) -> Any { return value as! T }
            }
        }
        func checkNotNull(_ value: Any) -> String { return "user function must not be selected" }
        func nullableCast<T>(_ value: Any?) -> T { return value as! T }
        func answer() -> Int {
            let mixed = Outer<Int>.Inner<String>(outer: 42, inner: "ok")
            let equal = Outer<Int>.Inner<Int>(outer: 1, inner: 2)
            let deep = Outer<Int>.Middle<Int>.Deep<Int>(outer: 1, middle: 2, deep: 3)
            let plain = Outer<Int>.BodyOnly().cast(11) as! Int
            if plain != 11 { return -1 }
            let some = Outer<Int?>.BodyOnly().cast(13) as! Int?
            if some != 13 { return -2 }
            let none: Int? = nullableCast(nil)
            if none != nil { return -3 }
            return mixed.outer + equal.inner + deep.middle
        }
        """, fixture: "native-nested")
        XCTAssertTrue(kotlin.contains("class Inner<T, U>"), kotlin)
        XCTAssertTrue(kotlin.contains("class Middle<V>"), kotlin)
        XCTAssertTrue(kotlin.contains("class Deep<T, V, W>"), kotlin)
        XCTAssertTrue(kotlin.contains("class BodyOnly<T>"), kotlin)
        // Any input is proven non-null, even when T is instantiated as Optional.
        // Nullable Any? -> T remains a nullable cast and must not receive this check.
        XCTAssertTrue(kotlin.contains("kotlin.checkNotNull(value as T).sref()"), kotlin)
        XCTAssertEqual(kotlin.components(separatedBy: "kotlin.checkNotNull(").count - 1, 1, kotlin)
        XCTAssertTrue(kotlin.contains("fun <T> nullableCast(value: Any?): T = (value as T).sref()"), kotlin)
        XCTAssertTrue(kotlin.contains("Outer.BodyOnly<Int?>().cast(13)"), kotlin)
        XCTAssertTrue(kotlin.contains("Outer.Inner<Int, Int>(outer = 1, inner = 2)"), kotlin)
        XCTAssertTrue(kotlin.contains("Outer.Middle.Deep<Int, Int, Int>(outer = 1, middle = 2, deep = 3)"), kotlin)
        XCTAssertFalse(kotlin.contains("Outer<Int>.Middle"), kotlin)
        let outer = try XCTUnwrap(info.rootTypes.first { $0.name == "Outer" })
        XCTAssertEqual(outer.types.first { $0.name == "Inner" }?.kotlinCapturedOuterGenericIndices, [0])
        let middle = try XCTUnwrap(outer.types.first { $0.name == "Middle" })
        XCTAssertEqual(middle.kotlinCapturedOuterGenericIndices, [])
        XCTAssertEqual(middle.types.first { $0.name == "Deep" }?.kotlinCapturedOuterGenericIndices, [0, 1])
    }

    func testSDKShadowedParametersAndUnusedNestedEnumsKeepTheirActualArity() async throws {
        let (kotlin, info) = try await transpile("""
        struct Stream<Element> {
            let value: Element
            func continuation() -> Continuation<Element> {
                return Continuation<Element>(value: value)
            }
            // SKIP NOWARN
            final class Continuation<Element> {
                let value: Element
                init(value: Element) { self.value = value }
                enum Termination { case finished, cancelled }
                // SKIP NOWARN
                enum YieldResult<Element> { case dropped(Element), terminated }
                enum BufferingPolicy { case unbounded, oldest(Int) }
                func yield(_ value: Element) -> YieldResult<Element> { return .dropped(value) }
                var onTermination: ((Termination) -> Void)?
            }
        }
        func answer() -> Int {
            let stream = Stream<Int>(value: 3)
            let continuation = stream.continuation()
            let explicit = Stream<String>.Continuation<Int>(value: 0)
            let result = continuation.yield(4)
            let policy: Stream<String>.Continuation<Int>.BufferingPolicy = .oldest(5)
            var dropped = 0
            if case .dropped(let value) = result { dropped = value }
            var oldest = 0
            if case .oldest(let value) = policy { oldest = value }
            return continuation.value + dropped + oldest + explicit.value
        }
        """, fixture: "sdk-shadowed")
        XCTAssertTrue(kotlin.contains("class Continuation<Element>"), kotlin)
        XCTAssertTrue(kotlin.contains("enum class Termination {"), kotlin)
        XCTAssertTrue(kotlin.contains("sealed class YieldResult<out Element>"), kotlin)
        XCTAssertTrue(kotlin.contains("sealed class BufferingPolicy {"), kotlin)
        XCTAssertFalse(kotlin.contains("Termination<"), kotlin)
        XCTAssertFalse(kotlin.contains("BufferingPolicy<"), kotlin)
        XCTAssertFalse(kotlin.contains("YieldResult<Element, Element"), kotlin)
        XCTAssertTrue(kotlin.contains("Continuation<Element>(value = value)"), kotlin)
        XCTAssertTrue(kotlin.contains("Stream.Continuation<Int>(value = 0)"), kotlin)
        XCTAssertFalse(kotlin.contains("Continuation<Any>"), kotlin)
        XCTAssertFalse(kotlin.contains("Continuation<Error>"), kotlin)
        XCTAssertFalse(kotlin.contains("Continuation<Any, Error>"), kotlin)
        let stream = try XCTUnwrap(info.rootTypes.first { $0.name == "Stream" })
        let continuation = try XCTUnwrap(stream.types.first { $0.name == "Continuation" })
        XCTAssertEqual(continuation.kotlinCapturedOuterGenericIndices, [])
        for nested in continuation.types { XCTAssertEqual(nested.kotlinCapturedOuterGenericIndices, [], nested.name) }
    }

    func testConstrainedStaticExtensionAndNominalSelfDoNotInventOuterCaptures() async throws {
        let (kotlin, info) = try await transpile("""
        struct Anchor<Value> {
            struct Source {
                let rectangle: Int?
                init(rectangle: Int?) { self.rectangle = rectangle }
                func copied() -> Self { return Self(rectangle: self.rectangle) }
            }
        }
        extension Anchor.Source where Value == Int {
            static var bounds: Anchor<Int>.Source { Anchor<Int>.Source(rectangle: nil) }
            static func rect(_ value: Int) -> Anchor<Int>.Source {
                Anchor<Int>.Source(rectangle: value)
            }
        }
        struct TypedAnchor<Value> {
            struct Payload { let value: Value }
        }
        extension TypedAnchor.Payload where Value == Int {
            static var zero: TypedAnchor<Int>.Payload { TypedAnchor<Int>.Payload(value: 0) }
        }
        func defaulted(_ value: Anchor<Int>.Source = .bounds) -> Int { value.rectangle ?? 0 }
        func answer() -> Int {
            let value = Anchor<Int>.Source.rect(7).copied()
            return (value.rectangle ?? 0) + defaulted() + TypedAnchor<Int>.Payload.zero.value
        }
        """, fixture: "constrained-source")
        let anchor = try XCTUnwrap(info.rootTypes.first { $0.name == "Anchor" })
        let source = try XCTUnwrap(anchor.types.first { $0.name == "Source" })
        XCTAssertEqual(source.kotlinCapturedOuterGenericIndices, [])
        let specializedSource = TypeSignature.member(.named("Anchor", [.int]), .named("Source", []))
        // Cover both the lexical Self in copied() and the qualified constrained
        // extension calls, without accepting two differently specialized inits.
        for constructedType in [source.signature, specializedSource] {
            let constructors = info.context().matchFunction(name: nil, inConstrained: constructedType.asMetaType(true),
                arguments: [.init(label: "rectangle", value: ArgumentValue(type: .optional(.int)))])
            XCTAssertEqual(constructors.count, 1, constructors.map { $0.signature.description }.joined(separator: "\n"))
            XCTAssertTrue(constructors.first?.signature.returnType.isSameType(as: constructedType) == true)
        }
        XCTAssertTrue(kotlin.contains("class Source {"), kotlin)
        XCTAssertFalse(kotlin.contains("class Source<Value>"), kotlin)
        XCTAssertFalse(kotlin.contains("Source<*>.Companion"), kotlin)
        XCTAssertTrue(kotlin.contains("Anchor.Source.Companion.bounds"), kotlin)
        XCTAssertTrue(kotlin.contains("Anchor.Source.Companion.rect"), kotlin)
        XCTAssertTrue(kotlin.contains("value: Anchor.Source = Anchor.Source.bounds"), kotlin)
        XCTAssertFalse(kotlin.contains("Anchor<Int>.Source"), kotlin)
        let typedAnchor = try XCTUnwrap(info.rootTypes.first { $0.name == "TypedAnchor" })
        let payload = try XCTUnwrap(typedAnchor.types.first { $0.name == "Payload" })
        XCTAssertEqual(payload.kotlinCapturedOuterGenericIndices, [0])
        XCTAssertTrue(kotlin.contains("class Payload<Value>"), kotlin)
        XCTAssertTrue(kotlin.contains("TypedAnchor.Payload.Companion.zero: TypedAnchor.Payload<Int>"), kotlin)
        XCTAssertFalse(kotlin.contains("Payload<*>.Companion"), kotlin)
    }

    func testCaptureMetadataRoundtripAndTaskLocalScopeDoNotChangeLegacyABI() async throws {
        let (_, info) = try await transpile("""
        public struct Outer<T> { public struct Inner<U> { public let value: T; public let own: U } }
        """)
        let data = try JSONEncoder().encode(CodebaseInfo.ModuleExport(of: info))
        let exported = try JSONDecoder().decode(CodebaseInfo.ModuleExport.self, from: data)
        let consumer = CodebaseInfo(moduleName: "Consumer")
        consumer.dependentModules = [exported]; consumer.prepareForUse()
        let context = consumer.context(importedModuleNames: ["NestedFixture"])
        let signature = TypeSignature.member(.named("Outer", [.int]), .named("Inner", [.int])).withModuleName("NestedFixture")
        XCTAssertEqual(KotlinNestedTypeGenerics.typeArguments(for: signature, context: context), [.int, .int])
        let rendered = KotlinNestedTypeGenerics.$current.withValue(KotlinNestedTypeRenderingScope(context: context)) { signature.kotlin }
        XCTAssertTrue(rendered.hasSuffix("Outer.Inner<Int, Int>"), rendered)
        XCTAssertNil(KotlinNestedTypeGenerics.current)
        XCTAssertEqual(KotlinNestedTypeGenerics.typeArguments(for: signature), [.int])
        let parent = try XCTUnwrap(exported.rootTypes.first { $0.name == "Outer" })
        XCTAssertNil(parent.kotlinCapturedOuterGenericIndices) // No enclosing ABI.
        XCTAssertEqual(parent.types.first { $0.name == "Inner" }?.kotlinCapturedOuterGenericIndices, [0])
        parent.types.first { $0.name == "Inner" }?.kotlinCapturedOuterGenericIndices = nil
        let legacyConsumer = CodebaseInfo(moduleName: "LegacyConsumer")
        legacyConsumer.dependentModules = [exported]; legacyConsumer.prepareForUse()
        XCTAssertEqual(KotlinNestedTypeGenerics.typeArguments(for: signature, context: legacyConsumer.context(importedModuleNames: ["NestedFixture"])), [.int])
    }
}
