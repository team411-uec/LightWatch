import AVFoundation
import CoreVideo
import Foundation

final class LightAnalyzer {
    private var rois: [LightROI]
    private var latestROIStats: [ROIStats] = []
    private let brightThreshold = 180
    private let darkThreshold = 50

    init(rois: [LightROI]) {
        self.rois = rois
    }

    func analyze(sampleBuffer: CMSampleBuffer, state: LightWatchState) throws -> LightAnalysisSnapshot {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw LightAnalyzerError.missingPixelBuffer
        }

        let timestamp = Date()
        let roiStats = try rois.map { roi in
            try analyzeROI(roi, pixelBuffer: pixelBuffer)
        }
        latestROIStats = roiStats

        let snapshot = LightAnalysisSnapshot(
            timestamp: timestamp,
            state: state,
            roiStats: roiStats,
            sceneLevel: LightSceneLevel(currentStats: roiStats)
        )
        return snapshot
    }

    private func analyzeROI(_ roi: LightROI, pixelBuffer: CVPixelBuffer) throws -> ROIStats {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw LightAnalyzerError.missingPixelBuffer
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pointer = baseAddress.assumingMemoryBound(to: UInt8.self)

        let xStart = max(0, min(width - 1, Int(roi.x * Double(width))))
        let yStart = max(0, min(height - 1, Int(roi.y * Double(height))))
        let xEnd = max(xStart + 1, min(width, Int((roi.x + roi.width) * Double(width))))
        let yEnd = max(yStart + 1, min(height, Int((roi.y + roi.height) * Double(height))))
        let step = max(1, min(width, height) / 80)

        var histogram = Array(repeating: 0, count: 256)
        var brightCount = 0
        var darkCount = 0
        var sampleCount = 0

        var y = yStart
        while y < yEnd {
            var x = xStart
            while x < xEnd {
                let offset = y * bytesPerRow + x * 4
                let blue = Double(pointer[offset])
                let green = Double(pointer[offset + 1])
                let red = Double(pointer[offset + 2])
                let luma = Int((0.2126 * red + 0.7152 * green + 0.0722 * blue).rounded())
                histogram[luma] += 1
                if luma >= brightThreshold {
                    brightCount += 1
                }
                if luma <= darkThreshold {
                    darkCount += 1
                }
                sampleCount += 1
                x += step
            }
            y += step
        }

        guard sampleCount > 0 else {
            throw LightAnalyzerError.emptyROI
        }

        let medianLuma = median(from: histogram, sampleCount: sampleCount)
        return ROIStats(
            name: roi.name,
            kind: roi.kind,
            medianLuma: medianLuma,
            brightRatio: Double(brightCount) / Double(sampleCount),
            darkRatio: Double(darkCount) / Double(sampleCount),
            isDark: medianLuma <= Double(darkThreshold)
        )
    }

    private func median(from histogram: [Int], sampleCount: Int) -> Double {
        let midpoint = (sampleCount + 1) / 2
        var running = 0
        for (luma, count) in histogram.enumerated() {
            running += count
            if running >= midpoint {
                return Double(luma)
            }
        }
        return 0
    }

}

enum LightAnalyzerError: LocalizedError {
    case missingPixelBuffer
    case emptyROI

    var errorDescription: String? {
        switch self {
        case .missingPixelBuffer:
            return "フレームのPixelBufferを取得できません。"
        case .emptyROI:
            return "ROIの解析対象ピクセルがありません。"
        }
    }
}

struct LightAnalysisSnapshot {
    let timestamp: Date
    let state: LightWatchState
    let roiStats: [ROIStats]
    let sceneLevel: LightSceneLevel

    func stat(named name: String) -> ROIStats? {
        roiStats.first { $0.name == name }
    }
}

struct ROIStats {
    let name: String
    let kind: ROIKind
    let medianLuma: Double
    let brightRatio: Double
    let darkRatio: Double
    let isDark: Bool
}

struct LightSceneLevel {
    let positiveMedian: Double
    let guardMedian: Double?
    let positiveDarkRatio: Double
    let positiveBrightRatio: Double
    let positiveROINames: [String]

    init(currentStats: [ROIStats]) {
        let positiveStats = currentStats.filter { $0.kind == .positive }
        let guardStats = currentStats.filter { $0.kind == .negative }
        positiveMedian = Self.median(positiveStats.map(\.medianLuma))
        guardMedian = guardStats.isEmpty ? nil : Self.median(guardStats.map(\.medianLuma))
        positiveDarkRatio = Self.average(positiveStats.map(\.darkRatio))
        positiveBrightRatio = Self.average(positiveStats.map(\.brightRatio))
        positiveROINames = positiveStats.map(\.name)
    }

    var values: [String: Double] {
        var values = [
            "positive_median": positiveMedian,
            "positive_dark_ratio": positiveDarkRatio,
            "positive_bright_ratio": positiveBrightRatio
        ]
        if let guardMedian {
            values["guard_median"] = guardMedian
        }
        return values
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else {
            return 0
        }
        let sortedValues = values.sorted()
        let middleIndex = sortedValues.count / 2
        if sortedValues.count.isMultiple(of: 2) {
            return (sortedValues[middleIndex - 1] + sortedValues[middleIndex]) / 2
        }
        return sortedValues[middleIndex]
    }

    private static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else {
            return 0
        }
        return values.reduce(0, +) / Double(values.count)
    }
}
