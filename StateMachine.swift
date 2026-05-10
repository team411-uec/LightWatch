import Foundation

enum LightWatchState: String, Codable {
    case dark = "DARK"
    case onCandidate = "ON_CANDIDATE"
    case bright = "BRIGHT"
    case offCandidate = "OFF_CANDIDATE"

    var displayName: String {
        switch self {
        case .dark:
            return "消灯中"
        case .onCandidate:
            return "点灯確認中"
        case .bright:
            return "点灯中"
        case .offCandidate:
            return "消灯確認中"
        }
    }
}

final class StateMachine {
    private(set) var currentState: LightWatchState
    private var settings: LightWatchSettings
    private var candidateStartedAt: Date?
    private var candidateROIReference: [String: Double] = [:]
    private var lastNotificationAt: Date?

    init(settings: LightWatchSettings, initialState: LightWatchState) {
        self.settings = settings
        self.currentState = initialState
    }

    func update(settings: LightWatchSettings) {
        self.settings = settings
    }

    func handle(snapshot: LightAnalysisSnapshot) -> [LightEvent] {
        switch currentState {
        case .dark:
            return handleDark(snapshot)
        case .onCandidate:
            return handleOnCandidate(snapshot)
        case .bright:
            return handleBright(snapshot)
        case .offCandidate:
            return handleOffCandidate(snapshot)
        }
    }

    private func handleDark(_ snapshot: LightAnalysisSnapshot) -> [LightEvent] {
        guard snapshot.onSignal.isChanged else {
            return []
        }
        currentState = .onCandidate
        candidateStartedAt = snapshot.timestamp
        candidateROIReference = referenceMedians(for: snapshot.onSignal.roiNames, in: snapshot)
        return [
            LightEvent(
                event: "on_candidate",
                state: currentState.rawValue,
                reason: snapshot.onSignal.reason,
                values: numericValues(snapshot.onSignal.deltas)
            )
        ]
    }

    private func handleOnCandidate(_ snapshot: LightAnalysisSnapshot) -> [LightEvent] {
        guard isOnCandidateStillBright(snapshot) else {
            currentState = .dark
            candidateStartedAt = nil
            candidateROIReference = [:]
            return [
                LightEvent(event: "on_candidate_cancelled", state: currentState.rawValue, reason: "signal_lost", values: [:])
            ]
        }

        guard let candidateStartedAt else {
            self.candidateStartedAt = snapshot.timestamp
            return []
        }

        let elapsed = snapshot.timestamp.timeIntervalSince(candidateStartedAt)
        guard elapsed >= settings.onConfirmSec else {
            return []
        }

        currentState = .bright
        self.candidateStartedAt = nil
        candidateROIReference = [:]
        guard canNotify(at: snapshot.timestamp) else {
            return [
                LightEvent(event: "bright_confirmed_cooldown", state: currentState.rawValue, reason: "cooldown", values: [:])
            ]
        }
        lastNotificationAt = snapshot.timestamp
        let notification = DiscordNotification(
            eventName: "notify_on",
            title: "🟢人がいます",
            state: .bright,
            reason: "複数ROIの輝度上昇が\(Int(settings.onConfirmSec))秒継続",
            confirmSeconds: Int(settings.onConfirmSec)
        )
        return [
            LightEvent(
                event: "notify_on",
                state: currentState.rawValue,
                reason: notification.reason,
                values: ["confirm_sec": .number(settings.onConfirmSec)],
                notification: notification
            )
        ]
    }

    private func handleBright(_ snapshot: LightAnalysisSnapshot) -> [LightEvent] {
        guard snapshot.offSignal.isChanged else {
            return []
        }
        currentState = .offCandidate
        candidateStartedAt = snapshot.timestamp
        candidateROIReference = referenceMedians(for: snapshot.offSignal.roiNames, in: snapshot)
        return [
            LightEvent(
                event: "off_candidate",
                state: currentState.rawValue,
                reason: snapshot.offSignal.reason,
                values: numericValues(snapshot.offSignal.deltas)
            )
        ]
    }

    private func handleOffCandidate(_ snapshot: LightAnalysisSnapshot) -> [LightEvent] {
        guard isOffCandidateStillDark(snapshot) else {
            currentState = .bright
            candidateStartedAt = nil
            candidateROIReference = [:]
            return [
                LightEvent(event: "off_candidate_cancelled", state: currentState.rawValue, reason: "signal_lost", values: [:])
            ]
        }

        guard let candidateStartedAt else {
            self.candidateStartedAt = snapshot.timestamp
            return []
        }

        let elapsed = snapshot.timestamp.timeIntervalSince(candidateStartedAt)
        guard elapsed >= settings.offConfirmSec else {
            return []
        }

        currentState = .dark
        self.candidateStartedAt = nil
        candidateROIReference = [:]
        guard canNotify(at: snapshot.timestamp) else {
            return [
                LightEvent(event: "dark_confirmed_cooldown", state: currentState.rawValue, reason: "cooldown", values: [:])
            ]
        }
        lastNotificationAt = snapshot.timestamp
        let notification = DiscordNotification(
            eventName: "notify_off",
            title: "⚪人がいません",
            state: .dark,
            reason: "複数ROIの輝度低下が\(Int(settings.offConfirmSec))秒継続",
            confirmSeconds: Int(settings.offConfirmSec)
        )
        return [
            LightEvent(
                event: "notify_off",
                state: currentState.rawValue,
                reason: notification.reason,
                values: ["confirm_sec": .number(settings.offConfirmSec)],
                notification: notification
            )
        ]
    }

    private func canNotify(at date: Date) -> Bool {
        guard let lastNotificationAt else {
            return true
        }
        return date.timeIntervalSince(lastNotificationAt) >= settings.cooldownSec
    }

    private func numericValues(_ values: [String: Double]) -> [String: LogValue] {
        values.mapValues { .number($0) }
    }

    private func referenceMedians(for roiNames: [String], in snapshot: LightAnalysisSnapshot) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: roiNames.compactMap { roiName in
            guard let median = snapshot.stat(named: roiName)?.medianLuma else {
                return nil
            }
            return (roiName, median)
        })
    }

    private func isOnCandidateStillBright(_ snapshot: LightAnalysisSnapshot) -> Bool {
        guard candidateROIReference.count >= settings.requiredPositiveROICount else {
            return false
        }
        let tolerance = settings.minDeltaOn / 2
        let stableCount = candidateROIReference.filter { roiName, referenceMedian in
            guard let current = snapshot.stat(named: roiName) else {
                return false
            }
            return current.medianLuma >= referenceMedian - tolerance
        }.count
        return stableCount >= settings.requiredPositiveROICount
    }

    private func isOffCandidateStillDark(_ snapshot: LightAnalysisSnapshot) -> Bool {
        guard candidateROIReference.count >= settings.requiredPositiveROICount else {
            return false
        }
        let tolerance = abs(settings.minDeltaOff) / 2
        let stableCount = candidateROIReference.filter { roiName, referenceMedian in
            guard let current = snapshot.stat(named: roiName) else {
                return false
            }
            return current.medianLuma <= referenceMedian + tolerance
        }.count
        return stableCount >= settings.requiredPositiveROICount
    }
}

struct DiscordNotification {
    let eventName: String
    let title: String
    let state: LightWatchState
    let reason: String
    let confirmSeconds: Int
}
