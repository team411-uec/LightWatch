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
        let settings = try decoder.decode(LightWatchSettings.self, from: data)
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
    var onConfirmSec: TimeInterval
    var offConfirmSec: TimeInterval
    var minDeltaOn: Double
    var minDeltaOff: Double
    var requiredPositiveROICount: Int
    var darkReferenceProfile: LightReferenceProfile?
    var brightReferenceProfile: LightReferenceProfile?
    var rois: [LightROI]

    enum CodingKeys: String, CodingKey {
        case discordWebhookURL
        case cameraUniqueID
        case launchAtLogin
        case captureIntervalSec
        case shortDiffSec
        case onConfirmSec
        case offConfirmSec
        case minDeltaOn
        case minDeltaOff
        case requiredPositiveROICount
        case darkReferenceProfile
        case brightReferenceProfile
        case rois
    }

    init(
        discordWebhookURL: String,
        cameraUniqueID: String,
        launchAtLogin: Bool,
        captureIntervalSec: TimeInterval,
        shortDiffSec: TimeInterval,
        onConfirmSec: TimeInterval,
        offConfirmSec: TimeInterval,
        minDeltaOn: Double,
        minDeltaOff: Double,
        requiredPositiveROICount: Int,
        darkReferenceProfile: LightReferenceProfile?,
        brightReferenceProfile: LightReferenceProfile?,
        rois: [LightROI]
    ) {
        self.discordWebhookURL = discordWebhookURL
        self.cameraUniqueID = cameraUniqueID
        self.launchAtLogin = launchAtLogin
        self.captureIntervalSec = captureIntervalSec
        self.shortDiffSec = shortDiffSec
        self.onConfirmSec = onConfirmSec
        self.offConfirmSec = offConfirmSec
        self.minDeltaOn = minDeltaOn
        self.minDeltaOff = minDeltaOff
        self.requiredPositiveROICount = requiredPositiveROICount
        self.darkReferenceProfile = darkReferenceProfile
        self.brightReferenceProfile = brightReferenceProfile
        self.rois = rois
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        discordWebhookURL = try container.decode(String.self, forKey: .discordWebhookURL)
        cameraUniqueID = try container.decodeIfPresent(String.self, forKey: .cameraUniqueID) ?? ""
        launchAtLogin = try container.decode(Bool.self, forKey: .launchAtLogin)
        captureIntervalSec = try container.decode(TimeInterval.self, forKey: .captureIntervalSec)
        shortDiffSec = try container.decode(TimeInterval.self, forKey: .shortDiffSec)
        onConfirmSec = try container.decode(TimeInterval.self, forKey: .onConfirmSec)
        offConfirmSec = try container.decode(TimeInterval.self, forKey: .offConfirmSec)
        minDeltaOn = try container.decode(Double.self, forKey: .minDeltaOn)
        minDeltaOff = try container.decode(Double.self, forKey: .minDeltaOff)
        requiredPositiveROICount = try container.decode(Int.self, forKey: .requiredPositiveROICount)
        darkReferenceProfile = try container.decodeIfPresent(LightReferenceProfile.self, forKey: .darkReferenceProfile)
        brightReferenceProfile = try container.decodeIfPresent(LightReferenceProfile.self, forKey: .brightReferenceProfile)
        rois = try container.decode([LightROI].self, forKey: .rois)
    }

    static let `default` = LightWatchSettings(
        discordWebhookURL: "",
        cameraUniqueID: "",
        launchAtLogin: false,
        captureIntervalSec: 1,
        shortDiffSec: 5,
        onConfirmSec: 60,
        offConfirmSec: 600,
        minDeltaOn: 18,
        minDeltaOff: -18,
        requiredPositiveROICount: 2,
        darkReferenceProfile: nil,
        brightReferenceProfile: nil,
        rois: [
            LightROI(name: "topLeftEdge", kind: .positive, x: 0.02, y: 0.02, width: 0.26, height: 0.22),
            LightROI(name: "topRightEdge", kind: .positive, x: 0.72, y: 0.02, width: 0.26, height: 0.22),
            LightROI(name: "bottomLeftEdge", kind: .positive, x: 0.02, y: 0.76, width: 0.26, height: 0.22),
            LightROI(name: "bottomRightEdge", kind: .positive, x: 0.72, y: 0.76, width: 0.26, height: 0.22)
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
