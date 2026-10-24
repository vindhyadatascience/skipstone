// Copyright (c) 2026 Vindhya Data Science
// Licensed under the GNU Affero General Public License v3.0
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
@testable import SkipSyntax

/// Reproduce SDK consumers through a real serialized module boundary, rather than
/// local function declarations whose contextual types have already been inferred.
final class ContextualHashableMetadataTests: XCTestCase {
    private func serializedModuleExport(internalCollector: Bool = false) async throws -> CodebaseInfo.ModuleExport {
        let source = """
        // SKIP SYMBOLFILE
        public protocol Renderable {}
        public class ComposeContext {}
        public struct IndexSet {}
        public class LazyItemCollector {
            public var indexedItems: (Range<Int>, ((Any) -> AnyHashable?)?, ((IndexSet) -> Void)?, ((IndexSet, Int) -> Void)?, Int, (Int, ComposeContext) -> Renderable) -> Void = { _, _, _, _, _, _ in }
            public var plainItems: ((Any) -> Int, Int) -> Void = { _, _ in }
        }
        public class UNNotificationContent {
            public var userInfo: [AnyHashable: Any] = [:]
            public var plainInfo: [String: Any] = [:]
        }
        public class UNNotificationRequest { public let content: UNNotificationContent }
        public class UNNotification { public let request: UNNotificationRequest }
        public class UNNotificationResponse { public let notification: UNNotification }
        """
        let sdkSource = internalCollector ? source.replacingOccurrences(of: "public var indexedItems:", with: "internal var indexedItems:") : source
        let file = try tmpFile(named: "SDK.swift", contents: sdkSource)
        let info = CodebaseInfo(moduleName: "SDKMetadata")
        let transpiler = Transpiler(transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info, transformers: builtinKotlinTransformers())
        try await transpiler.transpile { result in
            XCTAssertTrue(result.messages.isEmpty, result.messages.map(\.formattedMessage).joined(separator: "\n"))
        }
        let encoded = try JSONEncoder().encode(CodebaseInfo.ModuleExport(of: info, includeTestingMetadata: true))
        return try JSONDecoder().decode(CodebaseInfo.ModuleExport.self, from: encoded)
    }

    private func output(_ source: String, internalCollector: Bool = false) async throws -> String {
        let file = try tmpFile(named: "Consumer.swift", contents: source)
        let info = CodebaseInfo(moduleName: "Consumer")
        info.dependentModules = [try await serializedModuleExport(internalCollector: internalCollector)]
        let transpiler = Transpiler(packageName: "consumer", transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info, transformers: builtinKotlinTransformers())
        var kotlin = ""
        try await transpiler.transpile { result in
            XCTAssertTrue(result.messages.isEmpty, result.messages.map(\.formattedMessage).joined(separator: "\n"))
            kotlin += result.output.content
        }
        return kotlin
    }

    func testSDKFunctionPropertyOptionalCallbackResultsRecoverContextAcrossMetadata() async throws {
        try XCTSkipUnless(KotlinStandardLibraryParity.boxesAnyHashable, "AnyHashable boxing is off; SkipLib keeps AnyHashable a typealias (RNABrowser-fiea.30)")
        let kotlin = try await output("""
        import SDKMetadata
        class Cell: Renderable {}
        func collect(_ collector: LazyItemCollector, _ number: Int?, _ text: String?) {
            collector.indexedItems(0..<3, { _ in 7 }, nil, nil, 0, { _, _ in Cell() })
            collector.indexedItems(0..<3, { _ in return 9 }, nil, nil, 0, { _, _ in Cell() })
            collector.indexedItems(0..<3, { _ in number }, nil, nil, 0, { _, _ in Cell() })
            collector.indexedItems(0..<3, { _ in text }, nil, nil, 0, { _, _ in Cell() })
            collector.plainItems({ _ in 11 }, 0)
        }
        """)
        XCTAssertTrue(kotlin.contains("AnyHashable(7)"), kotlin)
        XCTAssertTrue(kotlin.contains("AnyHashable(9)"), kotlin)
        XCTAssertTrue(kotlin.contains("(number).let { if (it == null) null else AnyHashable(it) }"), kotlin)
        XCTAssertTrue(kotlin.contains("(text).let { if (it == null) null else AnyHashable(it) }"), kotlin)
        XCTAssertEqual(kotlin.components(separatedBy: "AnyHashable(").count - 1, 4, kotlin)
        XCTAssertFalse(kotlin.contains("AnyHashable(11)"), kotlin)
    }

    func testSDKMemberReturnedDictionaryKeysRecoverContextAcrossMetadata() async throws {
        try XCTSkipUnless(KotlinStandardLibraryParity.boxesAnyHashable, "AnyHashable boxing is off; SkipLib keeps AnyHashable a typealias (RNABrowser-fiea.30)")
        let kotlin = try await output("""
        import SDKMetadata
        func read(_ response: UNNotificationResponse, _ key: String) {
            let userInfo = response.notification.request.content.userInfo
            let first = userInfo["link"]
            let second = response.notification.request.content.userInfo[key]
            let plainInfo = response.notification.request.content.plainInfo
            let plain = plainInfo[key]
        }
        """)
        XCTAssertTrue(kotlin.contains("userInfo[AnyHashable(\"link\")]"), kotlin)
        XCTAssertTrue(kotlin.contains(".userInfo[AnyHashable(key)]"), kotlin)
        XCTAssertTrue(kotlin.contains("plainInfo[key]"), kotlin)
        XCTAssertEqual(kotlin.components(separatedBy: "AnyHashable(").count - 1, 2, kotlin)
    }
    func testSDKInternalCollectorMetadataRequiresExplicitTestableImportForNestedFixture() async throws {
        try XCTSkipUnless(KotlinStandardLibraryParity.boxesAnyHashable, "AnyHashable boxing is off; SkipLib keeps AnyHashable a typealias (RNABrowser-fiea.30)")
        let source = """
        import SDKMetadata
        class Cell: Renderable {}
        final class CollectorFixture { let collector = LazyItemCollector() }
        func collect() {
            let fixture = CollectorFixture()
            fixture.collector.indexedItems(0..<3, { _ in 7 }, nil, nil, 0, { _, _ in Cell() })
        }
        """
        // An ordinary import must not gain internal member/initializer access by inspecting
        // the serialized testing payload through a contextual-conversion fallback.
        let ordinary = try await output(source, internalCollector: true)
        XCTAssertFalse(ordinary.contains("AnyHashable(7)"), ordinary)

        let testable = try await output(source.replacingOccurrences(of: "import SDKMetadata", with: "@testable import SDKMetadata"), internalCollector: true)
        XCTAssertTrue(testable.contains("fixture.collector.indexedItems"), testable)
        XCTAssertTrue(testable.contains("AnyHashable(7)"), testable)
    }

    func testSDKCallbackContextSurvivesAStoredCollectorInAPrivateExtensionNestedFixture() async throws {
        try XCTSkipUnless(KotlinStandardLibraryParity.boxesAnyHashable, "AnyHashable boxing is off; SkipLib keeps AnyHashable a typealias (RNABrowser-fiea.30)")
        let kotlin = try await output("""
        @testable import SDKMetadata
        class Cell: Renderable {}
        class ConsumerTests {
            func collect() {
                let fixture = CollectorFixture()
                fixture.collector.indexedItems(0..<3, { index in 10 + (index as! Int) }, nil, nil, 0, { _, _ in Cell() })
            }
        }
        private extension ConsumerTests {
            final class CollectorFixture {
                let collector = LazyItemCollector()
            }
        }
        """, internalCollector: true)
        XCTAssertTrue(kotlin.contains("fixture.collector.indexedItems"), kotlin)
        XCTAssertTrue(kotlin.contains("AnyHashable(10 + (index as Int))"), kotlin)
    }

}
