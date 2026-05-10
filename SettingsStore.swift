import Foundation

final class SettingsStore {
    let applicationSupportDirectory: URL
    let logsDirectory: URL

    private let configURL: URL
    private let stateURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) {
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LightWatch", isDirectory: true)
        applicationSupportDirectory = baseDirectory
        logsDirectory = baseDirectory.appendingPathComponent("logs", isDirectory: true)
        configURL = baseDirectory.appendingPathComponent("config.json")
        stateURL = baseDirectory.appendingPathComponent("state.json")
    }

    func load() throws -> LightWatchSettings {
        try ensureDirectories()
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            let settings = LightWatchSettings.default
            save(settings)
            return settings
        }
        let data = try Data(contentsOf: configURL)
        return try decoder.decode(LightWatchSettings.self, from: data)
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

    func loadState() -> LightWatchState {
        guard FileManager.default.fileExists(atPath: stateURL.path),
              let data = try? Data(contentsOf: stateURL),
              let state = try? decoder.decode(LightWatchState.self, from: data) else {
            return .dark
        }
        return state
    }

    func saveState(_ state: LightWatchState) {
        do {
            try ensureDirectories()
            let data = try encoder.encode(state)
            try data.write(to: stateURL, options: .atomic)
        } catch {
            NSLog("LightWatch状態保存に失敗しました: \(error.localizedDescription)")
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
    var shortDiffSec: TimeInterval
    var noiseWindowSec: TimeInterval
    var onConfirmSec: TimeInterval
    var offConfirmSec: TimeInterval
    var cooldownSec: TimeInterval
    var minDeltaOn: Double
    var minDeltaOff: Double
    var requiredPositiveROICount: Int
    var noiseMultiplier: Double
    var rois: [LightROI]

    enum CodingKeys: String, CodingKey {
        case discordWebhookURL
        case cameraUniqueID
        case launchAtLogin
        case captureIntervalSec
        case shortDiffSec
        case noiseWindowSec
        case onConfirmSec
        case offConfirmSec
        case cooldownSec
        case minDeltaOn
        case minDeltaOff
        case requiredPositiveROICount
        case noiseMultiplier
        case rois
    }

    init(
        discordWebhookURL: String,
        cameraUniqueID: String,
        launchAtLogin: Bool,
        captureIntervalSec: TimeInterval,
        shortDiffSec: TimeInterval,
        noiseWindowSec: TimeInterval,
        onConfirmSec: TimeInterval,
        offConfirmSec: TimeInterval,
        cooldownSec: TimeInterval,
        minDeltaOn: Double,
        minDeltaOff: Double,
        requiredPositiveROICount: Int,
        noiseMultiplier: Double,
        rois: [LightROI]
    ) {
        self.discordWebhookURL = discordWebhookURL
        self.cameraUniqueID = cameraUniqueID
        self.launchAtLogin = launchAtLogin
        self.captureIntervalSec = captureIntervalSec
        self.shortDiffSec = shortDiffSec
        self.noiseWindowSec = noiseWindowSec
        self.onConfirmSec = onConfirmSec
        self.offConfirmSec = offConfirmSec
        self.cooldownSec = cooldownSec
        self.minDeltaOn = minDeltaOn
        self.minDeltaOff = minDeltaOff
        self.requiredPositiveROICount = requiredPositiveROICount
        self.noiseMultiplier = noiseMultiplier
        self.rois = rois
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        discordWebhookURL = try container.decode(String.self, forKey: .discordWebhookURL)
        cameraUniqueID = try container.decodeIfPresent(String.self, forKey: .cameraUniqueID) ?? ""
        launchAtLogin = try container.decode(Bool.self, forKey: .launchAtLogin)
        captureIntervalSec = try container.decode(TimeInterval.self, forKey: .captureIntervalSec)
        shortDiffSec = try container.decode(TimeInterval.self, forKey: .shortDiffSec)
        noiseWindowSec = try container.decode(TimeInterval.self, forKey: .noiseWindowSec)
        onConfirmSec = try container.decode(TimeInterval.self, forKey: .onConfirmSec)
        offConfirmSec = try container.decode(TimeInterval.self, forKey: .offConfirmSec)
        cooldownSec = try container.decode(TimeInterval.self, forKey: .cooldownSec)
        minDeltaOn = try container.decode(Double.self, forKey: .minDeltaOn)
        minDeltaOff = try container.decode(Double.self, forKey: .minDeltaOff)
        requiredPositiveROICount = try container.decode(Int.self, forKey: .requiredPositiveROICount)
        noiseMultiplier = try container.decode(Double.self, forKey: .noiseMultiplier)
        rois = try container.decode([LightROI].self, forKey: .rois)
    }

    static let `default` = LightWatchSettings(
        discordWebhookURL: "",
        cameraUniqueID: "",
        launchAtLogin: false,
        captureIntervalSec: 1,
        shortDiffSec: 5,
        noiseWindowSec: 300,
        onConfirmSec: 60,
        offConfirmSec: 600,
        cooldownSec: 600,
        minDeltaOn: 18,
        minDeltaOff: -18,
        requiredPositiveROICount: 2,
        noiseMultiplier: 5.0,
        rois: [
            LightROI(name: "wall", kind: .positive, x: 0.05, y: 0.10, width: 0.35, height: 0.35),
            LightROI(name: "desk", kind: .positive, x: 0.25, y: 0.55, width: 0.35, height: 0.30),
            LightROI(name: "floor", kind: .positive, x: 0.55, y: 0.55, width: 0.35, height: 0.30),
            LightROI(name: "window", kind: .negative, x: 0.60, y: 0.05, width: 0.35, height: 0.35),
            LightROI(name: "monitor", kind: .negative, x: 0.05, y: 0.45, width: 0.20, height: 0.25)
        ]
    )
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
