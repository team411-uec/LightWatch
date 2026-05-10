import Foundation

struct SettingsNumberFields: Equatable {
    var captureIntervalSec: String
    var shortDiffSec: String
    var noiseWindowSec: String
    var onConfirmSec: String
    var offConfirmSec: String
    var cooldownSec: String
    var minDeltaOn: String
    var minDeltaOff: String
    var requiredPositiveROICount: String
    var noiseMultiplier: String

    init(settings: LightWatchSettings) {
        captureIntervalSec = Self.integerString(settings.captureIntervalSec)
        shortDiffSec = Self.integerString(settings.shortDiffSec)
        noiseWindowSec = Self.integerString(settings.noiseWindowSec)
        onConfirmSec = Self.integerString(settings.onConfirmSec)
        offConfirmSec = Self.integerString(settings.offConfirmSec)
        cooldownSec = Self.integerString(settings.cooldownSec)
        minDeltaOn = Self.integerString(settings.minDeltaOn)
        minDeltaOff = Self.integerString(settings.minDeltaOff)
        requiredPositiveROICount = String(settings.requiredPositiveROICount)
        noiseMultiplier = Self.decimalString(settings.noiseMultiplier)
    }

    init(
        captureIntervalSec: Int,
        shortDiffSec: Int,
        noiseWindowSec: Int,
        onConfirmSec: Int,
        offConfirmSec: Int,
        cooldownSec: Int,
        minDeltaOn: Int,
        minDeltaOff: Int,
        requiredPositiveROICount: Int,
        noiseMultiplier: Double
    ) {
        self.captureIntervalSec = String(captureIntervalSec)
        self.shortDiffSec = String(shortDiffSec)
        self.noiseWindowSec = String(noiseWindowSec)
        self.onConfirmSec = String(onConfirmSec)
        self.offConfirmSec = String(offConfirmSec)
        self.cooldownSec = String(cooldownSec)
        self.minDeltaOn = String(minDeltaOn)
        self.minDeltaOff = String(minDeltaOff)
        self.requiredPositiveROICount = String(requiredPositiveROICount)
        self.noiseMultiplier = Self.decimalString(noiseMultiplier)
    }

    func applied(to settings: LightWatchSettings) throws -> LightWatchSettings {
        var updatedSettings = settings
        updatedSettings.captureIntervalSec = try validatedDouble(captureIntervalSec, name: "取得間隔", range: 1...30)
        updatedSettings.shortDiffSec = try validatedDouble(shortDiffSec, name: "短期比較", range: 1...30)
        updatedSettings.noiseWindowSec = try validatedDouble(noiseWindowSec, name: "ノイズ計測", range: 60...1800)
        updatedSettings.onConfirmSec = try validatedDouble(onConfirmSec, name: "ON確認", range: 30...900)
        updatedSettings.offConfirmSec = try validatedDouble(offConfirmSec, name: "OFF確認", range: 300...1800)
        updatedSettings.cooldownSec = try validatedDouble(cooldownSec, name: "クールダウン", range: 60...1800)
        updatedSettings.minDeltaOn = try validatedDouble(minDeltaOn, name: "ON差分しきい値", range: 1...80)
        updatedSettings.minDeltaOff = try validatedDouble(minDeltaOff, name: "OFF差分しきい値", range: -80 ... -1)
        updatedSettings.requiredPositiveROICount = try validatedInt(requiredPositiveROICount, name: "必要positive ROI数", range: 1...5)
        updatedSettings.noiseMultiplier = try validatedDouble(noiseMultiplier, name: "ノイズ倍率", range: 1...10)
        return updatedSettings
    }

    private static func integerString(_ value: Double) -> String {
        String(Int(value))
    }

    private static func decimalString(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    private func validatedDouble(_ text: String, name: String, range: ClosedRange<Double>) throws -> Double {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmedText), value.isFinite else {
            throw SettingsValidationError.invalidNumber(name)
        }
        guard range.contains(value) else {
            throw SettingsValidationError.outOfRange(name, lower: range.lowerBound, upper: range.upperBound)
        }
        return value
    }

    private func validatedInt(_ text: String, name: String, range: ClosedRange<Int>) throws -> Int {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmedText) else {
            throw SettingsValidationError.invalidNumber(name)
        }
        guard range.contains(value) else {
            throw SettingsValidationError.outOfRange(name, lower: Double(range.lowerBound), upper: Double(range.upperBound))
        }
        return value
    }
}

struct DetectionPreset: Identifiable, Equatable {
    let id: String
    let name: String
    let hint: String
    let numberFields: SettingsNumberFields

    static let standard = DetectionPreset(
        id: "standard",
        name: "標準",
        hint: "通常の常駐監視向けです。",
        numberFields: SettingsNumberFields(
            captureIntervalSec: 1,
            shortDiffSec: 5,
            noiseWindowSec: 300,
            onConfirmSec: 60,
            offConfirmSec: 600,
            cooldownSec: 600,
            minDeltaOn: 18,
            minDeltaOff: -18,
            requiredPositiveROICount: 2,
            noiseMultiplier: 5.0
        )
    )

    static let quickCheck = DetectionPreset(
        id: "quickCheck",
        name: "すばやく確認",
        hint: "短い確認時間と低めのしきい値で反応を見ます。",
        numberFields: SettingsNumberFields(
            captureIntervalSec: 1,
            shortDiffSec: 3,
            noiseWindowSec: 60,
            onConfirmSec: 30,
            offConfirmSec: 300,
            cooldownSec: 60,
            minDeltaOn: 12,
            minDeltaOff: -12,
            requiredPositiveROICount: 1,
            noiseMultiplier: 2.0
        )
    )

    static let darkRoom = DetectionPreset(
        id: "darkRoom",
        name: "暗めの部屋",
        hint: "暗い映像でも変化を拾うため、しきい値を低めにします。",
        numberFields: SettingsNumberFields(
            captureIntervalSec: 1,
            shortDiffSec: 5,
            noiseWindowSec: 300,
            onConfirmSec: 60,
            offConfirmSec: 600,
            cooldownSec: 600,
            minDeltaOn: 12,
            minDeltaOff: -12,
            requiredPositiveROICount: 2,
            noiseMultiplier: 3.0
        )
    )

    static let brightRoom = DetectionPreset(
        id: "brightRoom",
        name: "明るい部屋",
        hint: "外光などの揺れを避けるため、しきい値と確認時間を上げます。",
        numberFields: SettingsNumberFields(
            captureIntervalSec: 1,
            shortDiffSec: 8,
            noiseWindowSec: 600,
            onConfirmSec: 90,
            offConfirmSec: 900,
            cooldownSec: 600,
            minDeltaOn: 24,
            minDeltaOff: -24,
            requiredPositiveROICount: 3,
            noiseMultiplier: 6.0
        )
    )

    static let presets = [
        standard,
        quickCheck,
        darkRoom,
        brightRoom
    ]

    static func find(id: String) -> DetectionPreset? {
        presets.first { $0.id == id }
    }
}

enum SettingsValidationError: LocalizedError {
    case invalidNumber(String)
    case outOfRange(String, lower: Double, upper: Double)

    var errorDescription: String? {
        switch self {
        case .invalidNumber(let name):
            return "\(name)は数値で入力してください。"
        case .outOfRange(let name, let lower, let upper):
            return "\(name)は\(format(lower))から\(format(upper))の範囲で入力してください。"
        }
    }

    private func format(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return value.formatted(.number.precision(.fractionLength(1)))
    }
}
