import AVFoundation
import CoreVideo
import Foundation

final class LightAnalyzer {
    private var settings: LightWatchSettings
    private var history: [LightAnalysisSnapshot] = []
    private let brightThreshold = 180
    private let darkThreshold = 50

    init(settings: LightWatchSettings) {
        self.settings = settings
    }

    func analyze(sampleBuffer: CMSampleBuffer, state: LightWatchState) throws -> LightAnalysisSnapshot {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw LightAnalyzerError.missingPixelBuffer
        }

        let timestamp = Date()
        let roiStats = try settings.rois.map { roi in
            try analyzeROI(roi, pixelBuffer: pixelBuffer)
        }

        let snapshot = LightAnalysisSnapshot(
            timestamp: timestamp,
            state: state,
            roiStats: roiStats,
            onSignal: makeOnSignal(currentStats: roiStats, timestamp: timestamp),
            offSignal: makeOffSignal(currentStats: roiStats, timestamp: timestamp)
        )
        history.append(snapshot)
        trimHistory(now: timestamp)
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

        return ROIStats(
            name: roi.name,
            kind: roi.kind,
            medianLuma: median(from: histogram, sampleCount: sampleCount),
            brightRatio: Double(brightCount) / Double(sampleCount),
            darkRatio: Double(darkCount) / Double(sampleCount)
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

    private func makeOnSignal(currentStats: [ROIStats], timestamp: Date) -> LightSignal {
        guard let previous = snapshot(near: timestamp.addingTimeInterval(-settings.shortDiffSec)) else {
            return .none
        }

        let changed = currentStats.filter { current in
            guard current.kind == .positive, let old = previous.stat(named: current.name) else {
                return false
            }
            let delta = current.medianLuma - old.medianLuma
            let brightDelta = current.brightRatio - old.brightRatio
            return delta >= settings.minDeltaOn
                && brightDelta > 0
        }

        guard changed.count >= settings.requiredPositiveROICount else {
            return .none
        }

        return .changed(roiNames: changed.map(\.name), deltas: deltas(for: changed, from: previous))
    }

    private func makeOffSignal(currentStats: [ROIStats], timestamp: Date) -> LightSignal {
        guard let previous = snapshot(near: timestamp.addingTimeInterval(-settings.shortDiffSec)) else {
            return .none
        }

        let changed = currentStats.filter { current in
            guard current.kind == .positive, let old = previous.stat(named: current.name) else {
                return false
            }
            let delta = current.medianLuma - old.medianLuma
            return delta <= settings.minDeltaOff
                && current.brightRatio < old.brightRatio
                && current.darkRatio > old.darkRatio
        }

        guard changed.count >= settings.requiredPositiveROICount else {
            return .none
        }

        return .changed(roiNames: changed.map(\.name), deltas: deltas(for: changed, from: previous))
    }

    private func snapshot(near date: Date) -> LightAnalysisSnapshot? {
        history.min { left, right in
            abs(left.timestamp.timeIntervalSince(date)) < abs(right.timestamp.timeIntervalSince(date))
        }
    }

    private func deltas(for changedStats: [ROIStats], from previous: LightAnalysisSnapshot) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: changedStats.compactMap { current in
            guard let old = previous.stat(named: current.name) else {
                return nil
            }
            return ("\(current.name)_d5", current.medianLuma - old.medianLuma)
        })
    }

    private func trimHistory(now: Date) {
        let lowerBound = now.addingTimeInterval(-(settings.shortDiffSec + 10))
        history.removeAll { $0.timestamp < lowerBound }
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
    let onSignal: LightSignal
    let offSignal: LightSignal

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
}

enum LightSignal {
    case none
    case changed(roiNames: [String], deltas: [String: Double])

    var isChanged: Bool {
        switch self {
        case .none:
            return false
        case .changed:
            return true
        }
    }

    var reason: String {
        switch self {
        case .none:
            return ""
        case .changed(let roiNames, _):
            return roiNames.joined(separator: "+") + " delta"
        }
    }

    var roiNames: [String] {
        switch self {
        case .none:
            return []
        case .changed(let roiNames, _):
            return roiNames
        }
    }

    var deltas: [String: Double] {
        switch self {
        case .none:
            return [:]
        case .changed(_, let deltas):
            return deltas
        }
    }
}
