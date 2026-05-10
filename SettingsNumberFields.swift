import Foundation

struct SettingsNumberFields: Equatable {
    var captureIntervalSec: String
    var onConfirmSec: String
    var offConfirmSec: String
    var minDeltaOn: String
    var minDeltaOff: String
    var requiredPositiveROICount: String

    init(settings: LightWatchSettings) {
        captureIntervalSec = Self.integerString(settings.captureIntervalSec)
        onConfirmSec = Self.integerString(settings.onConfirmSec)
        offConfirmSec = Self.integerString(settings.offConfirmSec)
        minDeltaOn = Self.integerString(settings.minDeltaOn)
        minDeltaOff = Self.integerString(settings.minDeltaOff)
        requiredPositiveROICount = String(settings.requiredPositiveROICount)
    }

    init(
        captureIntervalSec: Int,
        onConfirmSec: Int,
        offConfirmSec: Int,
        minDeltaOn: Int,
        minDeltaOff: Int,
        requiredPositiveROICount: Int
    ) {
        self.captureIntervalSec = String(captureIntervalSec)
        self.onConfirmSec = String(onConfirmSec)
        self.offConfirmSec = String(offConfirmSec)
        self.minDeltaOn = String(minDeltaOn)
        self.minDeltaOff = String(minDeltaOff)
        self.requiredPositiveROICount = String(requiredPositiveROICount)
    }

    func applied(to settings: LightWatchSettings) throws -> LightWatchSettings {
        var updatedSettings = settings
        updatedSettings.captureIntervalSec = try validatedDouble(captureIntervalSec, name: "取得間隔", range: 1...30)
        updatedSettings.onConfirmSec = try validatedDouble(onConfirmSec, name: "ON確認", range: 1...900)
        updatedSettings.offConfirmSec = try validatedDouble(offConfirmSec, name: "OFF確認", range: 1...1800)
        updatedSettings.minDeltaOn = try validatedDouble(minDeltaOn, name: "ON差分しきい値", range: 1...80)
        updatedSettings.minDeltaOff = try validatedDouble(minDeltaOff, name: "OFF差分しきい値", range: -80 ... -1)
        updatedSettings.requiredPositiveROICount = try validatedInt(requiredPositiveROICount, name: "必要positive ROI数", range: 1...5)
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
