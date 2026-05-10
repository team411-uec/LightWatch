import Foundation

final class SettingsStore {
    let applicationSupportDirectory: URL
    let logsDirectory: URL

    private let configURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) {
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LightWatch", isDirectory: true)
        applicationSupportDirectory = baseDirectory
        logsDirectory = baseDirectory.appendingPathComponent("logs", isDirectory: true)
        configURL = baseDirectory.appendingPathComponent("config.json")
    }

    func load() throws -> LightWatchSettings {
        try ensureDirectories()
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            let settings = LightWatchSettings.default
            save(settings)
            return settings
        }
        let data = try Data(contentsOf: configURL)
        let settings = try decoder.decode(LightWatchSettings.self, from: data).normalized()
        save(settings)
        return settings
    }

    func save(_ settings: LightWatchSettings) {
        do {
            try ensureDirectories()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            try data.write(to: configURL, options: .atomic)
        } catch {
            NSLog("LightWatch設定保存に失敗しました: \(error.localizedDescription)")
        }
    }

    private func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
    }
}

struct LightWatchSettings: Codable, Equatable {
    var discordWebhookURL: String
    var cameraUniqueID: String
    var launchAtLogin: Bool
    var captureIntervalSec: TimeInterval
    var onConfirmSec: TimeInterval
    var offConfirmSec: TimeInterval
    var minDeltaOn: Double
    var minDeltaOff: Double
    var requiredPositiveROICount: Int
    var rois: [LightROI]

    enum CodingKeys: String, CodingKey {
        case discordWebhookURL
        case cameraUniqueID
        case launchAtLogin
        case captureIntervalSec
        case onConfirmSec
        case offConfirmSec
        case minDeltaOn
        case minDeltaOff
        case requiredPositiveROICount
        case rois
    }

    init(
        discordWebhookURL: String,
        cameraUniqueID: String,
        launchAtLogin: Bool,
        captureIntervalSec: TimeInterval,
        onConfirmSec: TimeInterval,
        offConfirmSec: TimeInterval,
        minDeltaOn: Double,
        minDeltaOff: Double,
        requiredPositiveROICount: Int,
        rois: [LightROI]
    ) {
        self.discordWebhookURL = discordWebhookURL
        self.cameraUniqueID = cameraUniqueID
        self.launchAtLogin = launchAtLogin
        self.captureIntervalSec = captureIntervalSec
        self.onConfirmSec = onConfirmSec
        self.offConfirmSec = offConfirmSec
        self.minDeltaOn = minDeltaOn
        self.minDeltaOff = minDeltaOff
        self.requiredPositiveROICount = requiredPositiveROICount
        self.rois = rois
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        discordWebhookURL = try container.decode(String.self, forKey: .discordWebhookURL)
        cameraUniqueID = try container.decodeIfPresent(String.self, forKey: .cameraUniqueID) ?? ""
        launchAtLogin = try container.decode(Bool.self, forKey: .launchAtLogin)
        captureIntervalSec = try container.decode(TimeInterval.self, forKey: .captureIntervalSec)
        onConfirmSec = try container.decode(TimeInterval.self, forKey: .onConfirmSec)
        offConfirmSec = try container.decode(TimeInterval.self, forKey: .offConfirmSec)
        minDeltaOn = try container.decode(Double.self, forKey: .minDeltaOn)
        minDeltaOff = try container.decode(Double.self, forKey: .minDeltaOff)
        requiredPositiveROICount = try container.decode(Int.self, forKey: .requiredPositiveROICount)
        rois = try container.decode([LightROI].self, forKey: .rois)
    }

    static let `default` = LightWatchSettings(
        discordWebhookURL: "",
        cameraUniqueID: "",
        launchAtLogin: false,
        captureIntervalSec: 1,
        onConfirmSec: 45,
        offConfirmSec: 45,
        minDeltaOn: 18,
        minDeltaOff: -18,
        requiredPositiveROICount: 3,
        rois: [
            LightROI(name: "topLeftEdge", kind: .positive, x: 0.02, y: 0.02, width: 0.26, height: 0.22),
            LightROI(name: "topRightEdge", kind: .positive, x: 0.72, y: 0.02, width: 0.26, height: 0.22),
            LightROI(name: "bottomLeftEdge", kind: .positive, x: 0.02, y: 0.76, width: 0.26, height: 0.22),
            LightROI(name: "bottomRightEdge", kind: .positive, x: 0.72, y: 0.76, width: 0.26, height: 0.22),
            LightROI(name: "centerLeftGuard", kind: .negative, x: 0.30, y: 0.18, width: 0.16, height: 0.64),
            LightROI(name: "centerRightGuard", kind: .negative, x: 0.54, y: 0.18, width: 0.16, height: 0.64)
        ]
    )

    func normalized() -> LightWatchSettings {
        guard !rois.contains(where: { $0.kind == .negative }) else {
            return self
        }
        var settings = self
        settings.rois.append(contentsOf: Self.default.rois.filter { $0.kind == .negative })
        return settings
    }
}

struct LightROI: Codable, Equatable {
    let name: String
    let kind: ROIKind
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

enum ROIKind: String, Codable, Equatable {
    case positive
    case negative
}
