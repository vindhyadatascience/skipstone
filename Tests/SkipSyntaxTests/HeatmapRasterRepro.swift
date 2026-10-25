import XCTest
@testable import SkipSyntax

final class HeatmapRasterRepro: XCTestCase {
    func testRepro() async throws {
        let support = """
        import SwiftUI
        protocol View {
            @ViewBuilder @MainActor var body: some View { get }
        }
        struct VStack: View {
            init(alignment: Any? = nil, spacing: Double? = nil, @ViewBuilder content: () -> any View) {}
        }
        struct HeatmapRasterView: View {
            let matrix: [[Double?]]
            let rowLabels: [String]
            let low: Double
            let high: Double
            let zNormalized: Bool
            let valueUnits: String
            let widthPoints: Double
            let pixelScale: Double
            var tracks: [Int] = []
            var trackHeight: Double = 12.0
            var trackSpacing: Double = 3.0
            var rowDendrogram: [Int] = []
            var columnDendrogram: [Int] = []
            var interactive: Bool = false
            var columnLabels: [String] = []
            @State private var pick = 0
            var rowHeight: Double = 13.0
            var maximumPlotHeight: Double? = nil
            var labelColumnWidth: Double = 84.0
            var labelPointSize: Double? = nil
            var renderKey: String = ""
            var maximumPixelsPerDimension: Int = 8192
            var maximumPixels: Int = 8000000
            var colorScale: Int? = nil
            var annotations: [Int] = []
        }
        """
        let swift = """
        import SwiftUI
        struct Screen: View {
            var matrix: [[Double?]] = []
            var body: some View {
                heatmapFigure()
            }
            func heatmapFigure() -> some View {
                let matrixWidth = 100.0
                let rowBand: [Int] = []
                let rowBandGap = rowBand.isEmpty ? 0.0 : 4.0
                let pixelScale = 2.0
                let tracks: [Int] = []
                let rowTree: [Int] = []
                let columnTree: [Int] = []
                let interactive = false
                return VStack(alignment: .leading, spacing: 6) {
                    HeatmapRasterView(
                        matrix: matrix,
                        rowLabels: ["a"],
                        low: 0.0,
                        high: 1.0,
                        zNormalized: false,
                        valueUnits: "x",
                        widthPoints: matrixWidth - rowBandGap,
                        pixelScale: pixelScale,
                        tracks: tracks,
                        rowDendrogram: rowTree,
                        columnDendrogram: columnTree,
                        interactive: interactive,
                        columnLabels: ["s"],
                        renderKey: "k",
                        colorScale: nil,
                        annotations: []
                    )
                }
            }
        }
        """
        var files: [Source.FilePath] = []
        let supportFile = try tmpFile(named: "Support.swift", contents: support)
        files.append(Source.FilePath(path: supportFile.path))
        let src = try tmpFile(named: "Source.swift", contents: swift)
        files.append(Source.FilePath(path: src.path))
        let transpiler = Transpiler(transpileFiles: files, codebaseInfo: CodebaseInfo(), transformers: builtinKotlinTransformers())
        try await transpiler.transpile { result in
            print("MESSAGES:", result.messages.map(\.formattedMessage))
        }
    }
}
