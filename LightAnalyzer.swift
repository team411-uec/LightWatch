import AVFoundation
import CoreVideo
import Foundation

final class LightAnalyzer {
    private var settings: LightWatchSettings
    private var history: [LightAnalysisSnapshot] = []
    private var latestROIStats: [ROIStats] = []
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
        latestROIStats = roiStats

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

    private func makeOnSignal(
        currentStats: [ROIStats],
        timestamp: Date
    ) -> LightSignal {
        guard let previous = snapshot(near: timestamp.addingTimeInterval(-settings.shortDiffSec)) else {
            return .none
        }
        let changeContext = ROIChangeContext(currentStats: currentStats, previousSnapshot: previous)
        guard !changeContext.hasUnstableGuardROI(threshold: settings.minDeltaOn * 1.5) else {
            return .none
        }

        let positiveStats = currentStats.filter { $0.kind == .positive }
        if let globalSignal = makeGlobalOnSignal(
            currentStats: currentStats,
            positiveStats: positiveStats,
            previous: previous
        ) {
            return globalSignal
        }

        let changed = currentStats.filter { current in
            guard current.kind == .positive, let old = previous.stat(named: current.name) else {
                return false
            }
            let change = changeContext.change(current: current, old: old)
            return change.relativeMedianDelta >= settings.minDeltaOn
                && change.relativeBrightRatioDelta >= 0.03
                && change.relativeDarkRatioDelta <= -0.03
        }

        guard changed.count >= requiredPositiveROICount(availableCount: positiveStats.count) else {
            return .none
        }

        return .changed(roiNames: changed.map(\.name), deltas: deltas(for: changed, from: previous, context: changeContext))
    }

    private func makeOffSignal(
        currentStats: [ROIStats],
        timestamp: Date
    ) -> LightSignal {
        if let absoluteDarkSignal = makeAbsoluteDarkSignal(currentStats: currentStats) {
            return absoluteDarkSignal
        }

        guard let previous = snapshot(near: timestamp.addingTimeInterval(-settings.shortDiffSec)) else {
            return .none
        }
        let changeContext = ROIChangeContext(currentStats: currentStats, previousSnapshot: previous)
        guard !changeContext.hasUnstableGuardROI(threshold: abs(settings.minDeltaOff) * 1.5) else {
            return .none
        }

        let positiveStats = currentStats.filter { $0.kind == .positive }
        if let globalSignal = makeGlobalOffSignal(
            currentStats: currentStats,
            positiveStats: positiveStats,
            previous: previous
        ) {
            return globalSignal
        }

        let changed = currentStats.filter { current in
            guard current.kind == .positive, let old = previous.stat(named: current.name) else {
                return false
            }
            let change = changeContext.change(current: current, old: old)
            return change.relativeMedianDelta <= settings.minDeltaOff
                && change.relativeBrightRatioDelta <= -0.03
                && change.relativeDarkRatioDelta >= 0.03
        }

        guard changed.count >= requiredPositiveROICount(availableCount: positiveStats.count) else {
            return .none
        }

        return .changed(roiNames: changed.map(\.name), deltas: deltas(for: changed, from: previous, context: changeContext))
    }

    private func makeAbsoluteDarkSignal(currentStats: [ROIStats]) -> LightSignal? {
        let positiveStats = currentStats.filter { $0.kind == .positive }
        let darkStats = positiveStats.filter { stat in
            stat.medianLuma <= Double(darkThreshold)
                && stat.darkRatio >= 0.60
                && stat.brightRatio <= 0.02
        }
        guard darkStats.count >= requiredPositiveROICount(availableCount: positiveStats.count) else {
            return nil
        }
        return .changed(
            roiNames: darkStats.map(\.name),
            deltas: Dictionary(uniqueKeysWithValues: darkStats.map { ("\($0.name)_median", $0.medianLuma) })
        )
    }

    private func makeGlobalOnSignal(
        currentStats: [ROIStats],
        positiveStats: [ROIStats],
        previous: LightAnalysisSnapshot
    ) -> LightSignal? {
        guard guardROIsChanged(
            currentStats: currentStats,
            previous: previous,
            medianThreshold: settings.minDeltaOn / 2,
            brightRatioThreshold: 0.015,
            darkRatioThreshold: -0.015
        ) else {
            return nil
        }
        let changed = positiveStats.filter { current in
            guard let old = previous.stat(named: current.name) else {
                return false
            }
            return current.medianLuma - old.medianLuma >= settings.minDeltaOn
                && current.brightRatio - old.brightRatio >= 0.03
                && current.darkRatio - old.darkRatio <= -0.03
        }
        guard changed.count >= requiredPositiveROICount(availableCount: positiveStats.count) else {
            return nil
        }
        return .changed(roiNames: changed.map(\.name), deltas: absoluteDeltas(for: changed, from: previous))
    }

    private func makeGlobalOffSignal(
        currentStats: [ROIStats],
        positiveStats: [ROIStats],
        previous: LightAnalysisSnapshot
    ) -> LightSignal? {
        guard guardROIsChanged(
            currentStats: currentStats,
            previous: previous,
            medianThreshold: settings.minDeltaOff / 2,
            brightRatioThreshold: -0.015,
            darkRatioThreshold: 0.015
        ) else {
            return nil
        }
        let changed = positiveStats.filter { current in
            guard let old = previous.stat(named: current.name) else {
                return false
            }
            return current.medianLuma - old.medianLuma <= settings.minDeltaOff
                && current.brightRatio - old.brightRatio <= -0.03
                && current.darkRatio - old.darkRatio >= 0.03
        }
        guard changed.count >= requiredPositiveROICount(availableCount: positiveStats.count) else {
            return nil
        }
        return .changed(roiNames: changed.map(\.name), deltas: absoluteDeltas(for: changed, from: previous))
    }

    private func guardROIsChanged(
        currentStats: [ROIStats],
        previous: LightAnalysisSnapshot,
        medianThreshold: Double,
        brightRatioThreshold: Double,
        darkRatioThreshold: Double
    ) -> Bool {
        let guardStats = currentStats.filter { $0.kind == .negative }
        guard !guardStats.isEmpty else {
            return false
        }
        return guardStats.allSatisfy { current in
            guard let old = previous.stat(named: current.name) else {
                return false
            }
            let medianDelta = current.medianLuma - old.medianLuma
            let brightRatioDelta = current.brightRatio - old.brightRatio
            let darkRatioDelta = current.darkRatio - old.darkRatio
            if medianThreshold >= 0 {
                return medianDelta >= medianThreshold
                    && brightRatioDelta >= brightRatioThreshold
                    && darkRatioDelta <= darkRatioThreshold
            }
            return medianDelta <= medianThreshold
                && brightRatioDelta <= brightRatioThreshold
                && darkRatioDelta >= darkRatioThreshold
        }
    }

    private func snapshot(near date: Date) -> LightAnalysisSnapshot? {
        history.min { left, right in
            abs(left.timestamp.timeIntervalSince(date)) < abs(right.timestamp.timeIntervalSince(date))
        }
    }

    private func deltas(
        for changedStats: [ROIStats],
        from previous: LightAnalysisSnapshot,
        context: ROIChangeContext
    ) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: changedStats.compactMap { current in
            guard let old = previous.stat(named: current.name) else {
                return nil
            }
            return ("\(current.name)_relative_d5", context.change(current: current, old: old).relativeMedianDelta)
        })
    }

    private func absoluteDeltas(for changedStats: [ROIStats], from previous: LightAnalysisSnapshot) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: changedStats.compactMap { current in
            guard let old = previous.stat(named: current.name) else {
                return nil
            }
            return ("\(current.name)_absolute_d5", current.medianLuma - old.medianLuma)
        })
    }

    private func trimHistory(now: Date) {
        let lowerBound = now.addingTimeInterval(-(settings.shortDiffSec + 10))
        history.removeAll { $0.timestamp < lowerBound }
    }

    private func requiredPositiveROICount(availableCount: Int) -> Int {
        min(max(3, settings.requiredPositiveROICount), availableCount)
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
    let isDark: Bool
}

struct ROIChange {
    let relativeMedianDelta: Double
    let relativeBrightRatioDelta: Double
    let relativeDarkRatioDelta: Double
}

struct ROIChangeContext {
    private let guardMedianDelta: Double
    private let guardBrightRatioDelta: Double
    private let guardDarkRatioDelta: Double
    private let guardMedianDeltas: [Double]

    init(currentStats: [ROIStats], previousSnapshot: LightAnalysisSnapshot) {
        let guardChanges = currentStats.compactMap { current -> (median: Double, bright: Double, dark: Double)? in
            guard current.kind == .negative, let old = previousSnapshot.stat(named: current.name) else {
                return nil
            }
            return (
                median: current.medianLuma - old.medianLuma,
                bright: current.brightRatio - old.brightRatio,
                dark: current.darkRatio - old.darkRatio
            )
        }
        guardMedianDeltas = guardChanges.map(\.median)
        guardMedianDelta = Self.median(guardChanges.map(\.median))
        guardBrightRatioDelta = Self.median(guardChanges.map(\.bright))
        guardDarkRatioDelta = Self.median(guardChanges.map(\.dark))
    }

    func change(current: ROIStats, old: ROIStats) -> ROIChange {
        ROIChange(
            relativeMedianDelta: current.medianLuma - old.medianLuma - guardMedianDelta,
            relativeBrightRatioDelta: current.brightRatio - old.brightRatio - guardBrightRatioDelta,
            relativeDarkRatioDelta: current.darkRatio - old.darkRatio - guardDarkRatioDelta
        )
    }

    func hasUnstableGuardROI(threshold: Double) -> Bool {
        guard guardMedianDeltas.count >= 2 else {
            return false
        }
        return guardMedianDeltas.contains { abs($0 - guardMedianDelta) >= threshold }
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
