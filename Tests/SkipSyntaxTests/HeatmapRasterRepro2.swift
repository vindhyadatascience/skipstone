import XCTest
@testable import SkipSyntax

final class NilCoalesceLocalTypeRepro: XCTestCase {
    func testRepro() async throws {
        let file = try tmpFile(named: "Source.swift", contents: """
        struct Track { var id: Int = 0 }
        struct View1 { var tracks: [Track] = [] }
        func use(annotation: Track?) {
            let tracks = annotation.map { [$0] } ?? []
            let v = View1(tracks: tracks)
            print(v)
        }
        """)
        let info = CodebaseInfo(moduleName: "Consumer")
        try await Transpiler(packageName: "consumer", transpileFiles: [Source.FilePath(path: file.path)], codebaseInfo: info, transformers: builtinKotlinTransformers()).transpile { result in
            print("MESSAGES:", result.messages.map(\.formattedMessage))
            print("KOTLIN:", result.output.content)
        }
    }
}
