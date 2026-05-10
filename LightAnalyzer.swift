import AVFoundation
import CoreVideo
import Foundation
import Vision

final class LightAnalyzer {
    private var rois: [LightROI]
    private var latestROIStats: [ROIStats] = []
    private let personSegmentationRequest = VNGeneratePersonSegmentationRequest()
    private let personSegmentationHandler = VNSequenceRequestHandler()
    private let brightThreshold = 180
    private let darkThreshold = 50
    private let personMaskThreshold = 128
    private let minimumObservableRatio = 0.35

    init(rois: [LightROI]) {
        self.rois = rois
        personSegmentationRequest.qualityLevel = .balanced
        personSegmentationRequest.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    func analyze(sampleBuffer: CMSampleBuffer, state: LightWatchState) throws -> LightAnalysisSnapshot {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw LightAnalyzerError.missingPixelBuffer
        }

        let timestamp = Date()
        let personMask = try makePersonMask(pixelBuffer: pixelBuffer)
        let personPresence = try analyzePersonPresence(personMask: personMask)
        let roiStats = try rois.map { roi in
            try analyzeROI(roi, pixelBuffer: pixelBuffer, personMask: personMask)
        }
        latestROIStats = roiStats

        let snapshot = LightAnalysisSnapshot(
            timestamp: timestamp,
            state: state,
            roiStats: roiStats,
            sceneLevel: LightSceneLevel(currentStats: roiStats, personPresence: personPresence)
        )
        return snapshot
    }

    private func makePersonMask(pixelBuffer: CVPixelBuffer) throws -> CVPixelBuffer? {
        do {
            try personSegmentationHandler.perform([personSegmentationRequest], on: pixelBuffer, orientation: .up)
            return personSegmentationRequest.results?.first?.pixelBuffer
        } catch {
            throw LightAnalyzerError.personSegmentationFailed(error.localizedDescription)
        }
    }

    private func analyzePersonPresence(personMask: CVPixelBuffer?) throws -> PersonPresence {
        guard let personMask else {
            return PersonPresence(maskedRatio: 0)
        }

        CVPixelBufferLockBaseAddress(personMask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(personMask, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(personMask) else {
            throw LightAnalyzerError.missingPixelBuffer
        }

        let width = CVPixelBufferGetWidth(personMask)
        let height = CVPixelBufferGetHeight(personMask)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(personMask)
        let pointer = baseAddress.assumingMemoryBound(to: UInt8.self)
        let step = max(1, min(width, height) / 120)

        var personCount = 0
        var sampleCount = 0
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                if Int(pointer[y * bytesPerRow + x]) >= personMaskThreshold {
                    personCount += 1
                }
                sampleCount += 1
                x += step
            }
            y += step
        }

        guard sampleCount > 0 else {
            return PersonPresence(maskedRatio: 0)
        }
        return PersonPresence(maskedRatio: Double(personCount) / Double(sampleCount))
    }

    private func analyzeROI(_ roi: LightROI, pixelBuffer: CVPixelBuffer, personMask: CVPixelBuffer?) throws -> ROIStats {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        if let personMask {
            CVPixelBufferLockBaseAddress(personMask, .readOnly)
        }
        defer {
            if let personMask {
                CVPixelBufferUnlockBaseAddress(personMask, .readOnly)
            }
        }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw LightAnalyzerError.missingPixelBuffer
        }
        let personMaskReader = try PersonMaskReader(personMask: personMask)

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
        var totalSampleCount = 0

        var y = yStart
        while y < yEnd {
            var x = xStart
            while x < xEnd {
                totalSampleCount += 1
                if personMaskReader.isPersonPixel(x: x, y: y, imageWidth: width, imageHeight: height, threshold: personMaskThreshold) {
                    x += step
                    continue
                }
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

        guard totalSampleCount > 0 else {
            throw LightAnalyzerError.emptyROI
        }

        let observableRatio = Double(sampleCount) / Double(totalSampleCount)
        guard sampleCount > 0, observableRatio >= minimumObservableRatio else {
            return ROIStats(
                name: roi.name,
                kind: roi.kind,
                medianLuma: 0,
                brightRatio: 0,
                darkRatio: 0,
                observableRatio: observableRatio,
                isObservable: false,
                isDark: false
            )
        }

        let medianLuma = median(from: histogram, sampleCount: sampleCount)
        return ROIStats(
            name: roi.name,
            kind: roi.kind,
            medianLuma: medianLuma,
            brightRatio: Double(brightCount) / Double(sampleCount),
            darkRatio: Double(darkCount) / Double(sampleCount),
            observableRatio: observableRatio,
            isObservable: true,
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
    case personSegmentationFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingPixelBuffer:
            return "フレームのPixelBufferを取得できません。"
        case .emptyROI:
            return "ROIの解析対象ピクセルがありません。"
        case .personSegmentationFailed(let message):
            return "人物領域の検出に失敗しました: \(message)"
        }
    }
}

struct PersonMaskReader {
    private let pointer: UnsafeMutablePointer<UInt8>?
    private let width: Int
    private let height: Int
    private let bytesPerRow: Int

    init(personMask: CVPixelBuffer?) throws {
        guard let personMask else {
            pointer = nil
            width = 0
            height = 0
            bytesPerRow = 0
            return
        }
        guard let baseAddress = CVPixelBufferGetBaseAddress(personMask) else {
            throw LightAnalyzerError.missingPixelBuffer
        }
        pointer = baseAddress.assumingMemoryBound(to: UInt8.self)
        width = CVPixelBufferGetWidth(personMask)
        height = CVPixelBufferGetHeight(personMask)
        bytesPerRow = CVPixelBufferGetBytesPerRow(personMask)
    }

    func isPersonPixel(x: Int, y: Int, imageWidth: Int, imageHeight: Int, threshold: Int) -> Bool {
        guard let pointer else {
            return false
        }
        let maskX = max(0, min(width - 1, x * width / max(1, imageWidth)))
        let maskY = max(0, min(height - 1, y * height / max(1, imageHeight)))
        return Int(pointer[maskY * bytesPerRow + maskX]) >= threshold
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
    let observableRatio: Double
    let isObservable: Bool
    let isDark: Bool
}

struct PersonPresence {
    let maskedRatio: Double

    var isPresent: Bool {
        maskedRatio >= 0.02
    }
}

struct LightSceneLevel {
    let positiveMedian: Double
    let guardMedian: Double?
    let positiveDarkRatio: Double
    let positiveBrightRatio: Double
    let observablePositiveCount: Int
    let isObservable: Bool
    let personMaskedRatio: Double
    let isPersonPresent: Bool
    let positiveROINames: [String]

    init(currentStats: [ROIStats], personPresence: PersonPresence) {
        let positiveStats = currentStats.filter { $0.kind == .positive && $0.isObservable }
        let guardStats = currentStats.filter { $0.kind == .negative && $0.isObservable }
        positiveMedian = Self.median(positiveStats.map(\.medianLuma))
        guardMedian = guardStats.isEmpty ? nil : Self.median(guardStats.map(\.medianLuma))
        positiveDarkRatio = Self.average(positiveStats.map(\.darkRatio))
        positiveBrightRatio = Self.average(positiveStats.map(\.brightRatio))
        observablePositiveCount = positiveStats.count
        isObservable = positiveStats.count >= 3
        personMaskedRatio = personPresence.maskedRatio
        isPersonPresent = personPresence.isPresent
        positiveROINames = positiveStats.map(\.name)
    }

    var values: [String: Double] {
        var values = [
            "positive_median": positiveMedian,
            "positive_dark_ratio": positiveDarkRatio,
            "positive_bright_ratio": positiveBrightRatio,
            "observable_positive_count": Double(observablePositiveCount),
            "person_masked_ratio": personMaskedRatio
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
