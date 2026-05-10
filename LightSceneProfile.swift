import Foundation

enum LightScene: String, Codable, Equatable {
    case dark
    case bright
}

struct LightReferenceProfile: Codable, Equatable {
    let scene: LightScene
    let samples: [LightReferenceSample]
}

struct LightReferenceSample: Codable, Equatable {
    let roiName: String
    let medianLuma: Double
    let brightRatio: Double
    let darkRatio: Double
}

struct LightSceneClassification: Equatable {
    let scene: LightScene
    let darkDistance: Double
    let brightDistance: Double
}

enum LightReferenceProfileError: LocalizedError {
    case missingFrame
    case emptyEdgeROI
    case missingReference
    case insufficientCommonROI

    var errorDescription: String? {
        switch self {
        case .missingFrame:
            return "基準にするフレームがまだありません。"
        case .emptyEdgeROI:
            return "端にあるpositive ROIがありません。"
        case .missingReference:
            return "消灯基準と点灯基準の両方を保存してください。"
        case .insufficientCommonROI:
            return "基準比較に使える共通ROIが足りません。"
        }
    }
}

enum LightSceneProfileBuilder {
    static func makeProfile(scene: LightScene, rois: [LightROI], roiStats: [ROIStats]) throws -> LightReferenceProfile {
        let edgePositiveROIs = rois.filter { $0.kind == .positive && $0.isEdgeArea }
        guard !edgePositiveROIs.isEmpty else {
            throw LightReferenceProfileError.emptyEdgeROI
        }

        let statsByName = Dictionary(uniqueKeysWithValues: roiStats.map { ($0.name, $0) })
        let samples = edgePositiveROIs.compactMap { roi -> LightReferenceSample? in
            guard let stat = statsByName[roi.name] else {
                return nil
            }
            return LightReferenceSample(
                roiName: roi.name,
                medianLuma: stat.medianLuma,
                brightRatio: stat.brightRatio,
                darkRatio: stat.darkRatio
            )
        }

        guard !samples.isEmpty else {
            throw LightReferenceProfileError.emptyEdgeROI
        }

        return LightReferenceProfile(scene: scene, samples: samples)
    }
}

enum LightSceneClassifier {
    static func classify(
        roiStats: [ROIStats],
        darkProfile: LightReferenceProfile?,
        brightProfile: LightReferenceProfile?,
        margin: Double
    ) throws -> LightSceneClassification {
        guard let darkProfile, let brightProfile else {
            throw LightReferenceProfileError.missingReference
        }

        let darkDistance = try distance(from: roiStats, to: darkProfile)
        let brightDistance = try distance(from: roiStats, to: brightProfile)

        if brightDistance + margin < darkDistance {
            return LightSceneClassification(
                scene: .bright,
                darkDistance: darkDistance,
                brightDistance: brightDistance
            )
        }

        if darkDistance + margin < brightDistance {
            return LightSceneClassification(
                scene: .dark,
                darkDistance: darkDistance,
                brightDistance: brightDistance
            )
        }

        throw LightReferenceProfileError.insufficientCommonROI
    }

    private static func distance(from roiStats: [ROIStats], to profile: LightReferenceProfile) throws -> Double {
        let statsByName = Dictionary(uniqueKeysWithValues: roiStats.map { ($0.name, $0) })
        let distances = profile.samples.compactMap { sample -> Double? in
            guard let current = statsByName[sample.roiName] else {
                return nil
            }
            return abs(current.medianLuma - sample.medianLuma)
                + abs(current.brightRatio - sample.brightRatio) * 64
                + abs(current.darkRatio - sample.darkRatio) * 64
        }
        .sorted()

        guard !distances.isEmpty else {
            throw LightReferenceProfileError.insufficientCommonROI
        }

        let usableCount = max(1, Int((Double(distances.count) * 0.5).rounded(.up)))
        let usableDistances = distances.prefix(usableCount)
        return usableDistances.reduce(0, +) / Double(usableDistances.count)
    }
}

private extension LightROI {
    var isEdgeArea: Bool {
        x <= 0.12 || y <= 0.12 || x + width >= 0.88 || y + height >= 0.88
    }
}
