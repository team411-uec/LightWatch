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
    private var stableReferenceMedian: Double?
    private var candidateReferenceMedian: Double?

    init(settings: LightWatchSettings, initialState: LightWatchState) {
        self.settings = settings
        currentState = initialState
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
        updateStableReference(with: snapshot)
        guard isBright(snapshot) else {
            return []
        }
        return startOnCandidate(snapshot)
    }

    private func handleOnCandidate(_ snapshot: LightAnalysisSnapshot) -> [LightEvent] {
        guard isOnCandidateValid(snapshot) else {
            currentState = .dark
            clearCandidate()
            stableReferenceMedian = snapshot.sceneLevel.positiveMedian
            return [LightEvent(event: "on_candidate_cancelled", state: currentState.rawValue, reason: "signal_lost", values: [:])]
        }

        guard let candidateStartedAt else {
            self.candidateStartedAt = snapshot.timestamp
            return []
        }

        let elapsed = snapshot.timestamp.timeIntervalSince(candidateStartedAt)
        guard elapsed >= effectiveOnConfirmSec else {
            return []
        }

        currentState = .bright
        stableReferenceMedian = snapshot.sceneLevel.positiveMedian
        clearCandidate()
        let notification = DiscordNotification(
            eventName: "notify_on",
            title: "🟢人がいます",
            state: .bright,
            reason: "監視領域の明るい状態が\(Int(effectiveOnConfirmSec))秒継続",
            confirmSeconds: Int(effectiveOnConfirmSec)
        )
        return [makeNotificationEvent(notification)]
    }

    private func handleBright(_ snapshot: LightAnalysisSnapshot) -> [LightEvent] {
        updateStableReference(with: snapshot)
        guard isDark(snapshot) else {
            return []
        }
        return startOffCandidate(snapshot)
    }

    private func handleOffCandidate(_ snapshot: LightAnalysisSnapshot) -> [LightEvent] {
        guard isOffCandidateValid(snapshot) else {
            currentState = .bright
            clearCandidate()
            stableReferenceMedian = snapshot.sceneLevel.positiveMedian
            return [LightEvent(event: "off_candidate_cancelled", state: currentState.rawValue, reason: "signal_lost", values: [:])]
        }

        guard let candidateStartedAt else {
            self.candidateStartedAt = snapshot.timestamp
            return []
        }

        let elapsed = snapshot.timestamp.timeIntervalSince(candidateStartedAt)
        guard elapsed >= effectiveOffConfirmSec else {
            return []
        }

        currentState = .dark
        stableReferenceMedian = snapshot.sceneLevel.positiveMedian
        clearCandidate()
        let notification = DiscordNotification(
            eventName: "notify_off",
            title: "⚪人がいません",
            state: .dark,
            reason: "監視領域の暗い状態が\(Int(effectiveOffConfirmSec))秒継続",
            confirmSeconds: Int(effectiveOffConfirmSec)
        )
        return [makeNotificationEvent(notification)]
    }

    private func startOnCandidate(_ snapshot: LightAnalysisSnapshot) -> [LightEvent] {
        currentState = .onCandidate
        candidateStartedAt = snapshot.timestamp
        candidateReferenceMedian = snapshot.sceneLevel.positiveMedian
        return [
            LightEvent(
                event: "on_candidate",
                state: currentState.rawValue,
                reason: "brightness_above_reference",
                values: numericValues(snapshot.sceneLevel.values)
            )
        ]
    }

    private func startOffCandidate(_ snapshot: LightAnalysisSnapshot) -> [LightEvent] {
        currentState = .offCandidate
        candidateStartedAt = snapshot.timestamp
        candidateReferenceMedian = snapshot.sceneLevel.positiveMedian
        return [
            LightEvent(
                event: "off_candidate",
                state: currentState.rawValue,
                reason: "brightness_below_reference",
                values: numericValues(snapshot.sceneLevel.values)
            )
        ]
    }

    private func isBright(_ snapshot: LightAnalysisSnapshot) -> Bool {
        let level = snapshot.sceneLevel
        if let stableReferenceMedian, level.positiveMedian >= stableReferenceMedian + settings.minDeltaOn {
            return true
        }
        return level.positiveMedian >= 135 || level.positiveBrightRatio >= 0.04
    }

    private func isDark(_ snapshot: LightAnalysisSnapshot) -> Bool {
        let level = snapshot.sceneLevel
        if let stableReferenceMedian, level.positiveMedian <= stableReferenceMedian + settings.minDeltaOff {
            return true
        }
        return level.positiveMedian <= 130 && level.positiveBrightRatio <= 0.02
    }

    private func isOnCandidateValid(_ snapshot: LightAnalysisSnapshot) -> Bool {
        guard isBright(snapshot) else {
            return false
        }
        guard let candidateReferenceMedian else {
            return true
        }
        return snapshot.sceneLevel.positiveMedian >= candidateReferenceMedian - settings.minDeltaOn / 2
    }

    private func isOffCandidateValid(_ snapshot: LightAnalysisSnapshot) -> Bool {
        guard isDark(snapshot) else {
            return false
        }
        guard let candidateReferenceMedian else {
            return true
        }
        return snapshot.sceneLevel.positiveMedian <= candidateReferenceMedian + abs(settings.minDeltaOff) / 2
    }

    private func updateStableReference(with snapshot: LightAnalysisSnapshot) {
        let currentMedian = snapshot.sceneLevel.positiveMedian
        guard let stableReferenceMedian else {
            self.stableReferenceMedian = currentMedian
            return
        }
        self.stableReferenceMedian = stableReferenceMedian * 0.9 + currentMedian * 0.1
    }

    private func clearCandidate() {
        candidateStartedAt = nil
        candidateReferenceMedian = nil
    }

    private func makeNotificationEvent(_ notification: DiscordNotification) -> LightEvent {
        LightEvent(
            event: notification.eventName,
            state: notification.state.rawValue,
            reason: notification.reason,
            values: ["confirm_sec": .number(Double(notification.confirmSeconds))],
            notification: notification
        )
    }

    private func numericValues(_ values: [String: Double]) -> [String: LogValue] {
        values.mapValues { .number($0) }
    }

    private var effectiveOnConfirmSec: TimeInterval {
        max(10, settings.onConfirmSec)
    }

    private var effectiveOffConfirmSec: TimeInterval {
        max(10, settings.offConfirmSec)
    }
}

struct DiscordNotification {
    let eventName: String
    let title: String
    let state: LightWatchState
    let reason: String
    let confirmSeconds: Int
}
