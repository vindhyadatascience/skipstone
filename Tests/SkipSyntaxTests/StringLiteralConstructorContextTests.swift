// Copyright (c) 2026 Vindhya Data Science
// Licensed under the GNU Affero General Public License v3.0
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
@testable import SkipSyntax

final class StringLiteralConstructorContextTests: XCTestCase {
    private func transpile(_ source: String, module: String, dependencies: [CodebaseInfo.ModuleExport] = []) async throws -> (String, CodebaseInfo) {
        let file = try tmpFile(named: module + ".swift", contents: source)
        let info = CodebaseInfo(moduleName: module)
        info.dependentModules = dependencies
        let transpiler = Transpiler(packageName: KotlinTranslator.packageName(forModule: module),
            transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info, transformers: builtinKotlinTransformers())
        var kotlin = ""
        try await transpiler.transpile { result in
            XCTAssertTrue(result.messages.isEmpty, result.messages.map(\.formattedMessage).joined(separator: "\n"))
            kotlin += result.output.content

        }
        return (kotlin, info)
    }

    private func exported(_ info: CodebaseInfo) throws -> CodebaseInfo.ModuleExport {
        try JSONDecoder().decode(CodebaseInfo.ModuleExport.self, from: JSONEncoder().encode(CodebaseInfo.ModuleExport(of: info)))
    }

    func testImportedLiteralAliasConstructorPreservesLiteralWithExplicitDefaultValue() async throws {
        let (_, library) = try await transpile("""
        // SKIP SYMBOLFILE
        public protocol ExpressibleByStringLiteral {}
        public protocol ExpressibleByStringInterpolation: ExpressibleByStringLiteral {}
        """, module: "SkipLib")
        let libraryExport = try exported(library)
        let (_, foundation) = try await transpile("""
        // SKIP SYMBOLFILE
        @_exported import SkipLib
        public extension String { typealias LocalizationValue = StringLocalizationValue }
        public struct StringLocalizationValue: ExpressibleByStringInterpolation {
            public init(_ value: String) {}
            public init(stringLiteral value: String) {}
        }
        public struct Locale { public init(identifier: String) {} }
        public final class LocalizedStringResource {
            public enum BundleDescription { case main }
            public init(stringLiteral: String) {}
            public init(_ key: String.LocalizationValue, defaultValue: String.LocalizationValue? = nil,
                table: String? = nil, locale: Locale? = nil, bundle: BundleDescription? = nil, comment: String? = nil) {}
        }
        """, module: "SkipFoundation", dependencies: [libraryExport])
        let (kotlin, _) = try await transpile("""
        import SkipFoundation
        func use() {
            let resource = LocalizedStringResource("QRS", defaultValue: String.LocalizationValue("LMN"),
                table: nil, locale: Locale(identifier: "fr"), bundle: LocalizedStringResource.BundleDescription.main, comment: "comment")
        }
        """, module: "LiteralConsumer", dependencies: [libraryExport, try exported(foundation)])
        XCTAssertTrue(kotlin.contains("LocalizedStringResource(StringLocalizationValue(stringLiteral = \"QRS\")"), kotlin)
        XCTAssertFalse(kotlin.contains("LocalizedStringResource(\"QRS\""), kotlin)
        XCTAssertTrue(kotlin.contains("defaultValue = StringLocalizationValue(\"LMN\")"), kotlin)
    }

    func testNullEscapeAndLiteralBackslashZeroRemainDistinct() async throws {
        let (kotlin, _) = try await transpile(#"""
        let null = "a\0b"
        let literal = "a\\0b"
        let raw = #"a\0b"#
        """#, module: "LiteralConsumer")
        XCTAssertTrue(kotlin.contains(#""a\u0000b""#), kotlin)
        XCTAssertTrue(kotlin.contains(#""a\\0b""#), kotlin)
        XCTAssertTrue(kotlin.contains("\"\"\"a\\0b\"\"\""), kotlin)
    }
}
