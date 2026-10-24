// Copyright (c) 2026 Vindhya Data Science
// Licensed under the GNU Affero General Public License v3.0
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
@testable import SkipBuild

final class TestingFriendshipTests: XCTestCase {
    func testOnlyExplicitLinkedDependenciesBecomeFriends() {
        let result = KotlinTestingFriendship.gradle(requestedModules: ["Producer", "Producer", "Missing", "Consumer", "Ordinary"], currentModule: "ConsumerTests", linkedModules: ["Producer", "Consumer"])
        XCTAssertEqual(result.components(separatedBy: "tasks.withType").count - 1, 1)
        XCTAssertTrue(result.contains("project(\":Producer\").layout.buildDirectory"), result)
        XCTAssertFalse(result.contains("project(\":Consumer\")"), result)
        XCTAssertFalse(result.contains("Missing"), result)
        XCTAssertFalse(result.contains("Ordinary"), result)
        XCTAssertEqual(KotlinTestingFriendship.gradle(requestedModules: [], currentModule: "ProducerTests", linkedModules: ["Producer"]), "")
    }

    func testActualCompileLibraryProvidersDetermineVariantFriendPaths() throws {
        let result = KotlinTestingFriendship.gradle(requestedModules: ["Producer"], currentModule: "Consumer", linkedModules: ["Producer"])
        XCTAssertTrue(result.contains("tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach"), result)
        XCTAssertTrue(result.contains("friendPaths.from(libraries.elements.zip("), result)
        XCTAssertTrue(result.contains("entries.map { it.asFile }.filter { it.toPath().startsWith(directory.asFile.toPath()) }"), result)
        XCTAssertFalse(result.contains("doFirst"), result)
        XCTAssertFalse(result.contains("freeCompilerArgs"), result)
        XCTAssertFalse(result.contains("/build/"), result)
        XCTAssertFalse(result.contains("debug"), result)
        XCTAssertFalse(result.contains("release"), result)
        // Optional exact renderer evidence for the standalone Gradle friendship
        // harness. Production output is never replaced with equivalent test DSL.
        if let path = ProcessInfo.processInfo.environment["SKIP_TESTING_FRIENDSHIP_FIXTURE_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try result.write(to: directory.appendingPathComponent("testing-friendship.gradle.kts"), atomically: true, encoding: .utf8)
        }

    }
}
