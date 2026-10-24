// Copyright (c) 2026 Vindhya Data Science
// Licensed under the GNU Affero General Public License v3.0
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Kotlin internal visibility is granted only to explicit, capable translated
/// dependencies. The caller obtains that list from per-file @testable imports.
enum KotlinTestingFriendship {
    static func gradle(requestedModules: [String], currentModule: String, linkedModules: Set<String>) -> String {
        // A paired FooTests target shares Foo's Gradle project and already has
        // the Kotlin plugin's test/main friendship. This is project layout only;
        // the requested access list is never inferred from the target name.
        let ownProject = currentModule.hasSuffix("Tests") ? String(currentModule.dropLast(5)) : currentModule
        return Set(requestedModules).intersection(linkedModules).subtracting([currentModule, ownProject]).sorted().map { module in
            let escaped = module.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "$", with: "\\$")
            return """
            // Explicit @testable import of translated module \(module).
            tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
                friendPaths.from(libraries.elements.zip(project(":\(escaped)").layout.buildDirectory) { entries, directory ->
                    entries.map { it.asFile }.filter { it.toPath().startsWith(directory.asFile.toPath()) }
                })
            }
            """
        }.joined(separator: "\n\n")
    }
}
