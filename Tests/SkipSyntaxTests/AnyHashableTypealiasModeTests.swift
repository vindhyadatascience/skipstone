// Copyright (c) 2026 Vindhya Data Science
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
@testable import SkipSyntax

/// RNABrowser-fiea.30: with SkipLib's AnyHashable a typealias, AnyHashable values are the raw values,
/// as under 1.9.16. Boxing them made every `[AnyHashable: Any]` read of a runtime JSON/Kotlin
/// collection throw ClassCastException on the JVM.
final class AnyHashableTypealiasModeTests: XCTestCase {
    func testAnyHashableCollectionsAreNotBoxedOrUnboxed() async throws {
        XCTAssertFalse(KotlinStandardLibraryParity.boxesAnyHashable)
        let file = try tmpFile(named: "Source.swift", contents: """
        func read(_ fields: [AnyHashable: Any]) -> String? {
            for (key, _) in fields { if let name = key as? String { return name } }
            return fields["integerValue"] as? String
        }
        func make() -> [AnyHashable: Any] { ["name": "x", 1: true] }
        """)
        let info = CodebaseInfo(moduleName: "Consumer")
        var kotlin = ""
        try await Transpiler(packageName: "consumer", transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info, transformers: builtinKotlinTransformers()).transpile { result in
            XCTAssertEqual(result.messages.filter { $0.kind == .error }.map(\.formattedMessage), [])
            kotlin += result.output.content
        }
        XCTAssertFalse(kotlin.contains("AnyHashable("), kotlin)
        XCTAssertFalse(kotlin.contains(".base"), kotlin)
        XCTAssertTrue(kotlin.contains(#"fields["integerValue"] as? String"#), kotlin)
    }
}
