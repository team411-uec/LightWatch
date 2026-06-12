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
    private var candidateSamples: [CandidateEvidenceSample] = []
    private var stableReference: LightReference?

    init(settings: LightWatchSettings, initialState: LightWatchState) {
        self.settings = settings
        currentState = initialState
    }

    func update(settings: LightWatchSettings) {
        self.settings = settings
        pruneCandidateSamples(olderThan: Date().addingTimeInterval(-max(effectiveOnConfirmSec, effectiveOffConfirmSec)))
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
        guard isObservable(snapshot) else {
            return []
        }

        updateStableReference(with: snapshot)
        let signal = evaluateSignal(snapshot)
        guard signal.onEvidence else {
            return []
        }
        return startOnCandidate(snapshot, signal: signal)
    }

    private func handleOnCandidate(_ snapshot: LightAnalysisSnapshot) -> [LightEvent] {
        let signal = evaluateSignal(snapshot)
        let assessment = appendCandidateSample(signal: signal, timestamp: snapshot.timestamp, confirmSec: effectiveOnConfirmSec)

        if assessment.shouldConfirmOn {
            return confirmOn(snapshot, assessment: assessment)
        }

        if assessment.shouldCancelOn {
            currentState = .dark
            clearCandidate()
            if isObservable(snapshot) {
                stableReference = LightReference(snapshot: snapshot)
            }
            return [
                LightEvent(
                    event: "on_candidate_cancelled",
                    state: currentState.rawValue,
                    reason: "evidence_ratio_too_low",
                    values: numericValues(signal.values.merging(assessment.values) { _, new in new })
                )
            ]
        }

        return []
    }

    private func handleBright(_ snapshot: LightAnalysisSnapshot) -> [LightEvent] {
        let signal = evaluateSignal(snapshot)
        guard !signal.weakPersonPresent else {
            clearCandidate()
            return []
        }
        guard isObservable(snapshot) else {
            return []
        }

        updateStableReference(with: snapshot)
        guard signal.offEvidence else {
            return []
        }
        return startOffCandidate(snapshot, signal: signal)
    }

    private func handleOffCandidate(_ snapshot: LightAnalysisSnapshot) -> [LightEvent] {
        let signal = evaluateSignal(snapshot)
        guard !signal.weakPersonPresent else {
            currentState = .bright
            clearCandidate()
            return [
                LightEvent(
                    event: "off_candidate_cancelled",
                    state: currentState.rawValue,
                    reason: "person_present",
                    values: numericValues(signal.values)
                )
            ]
        }

        let assessment = appendCandidateSample(signal: signal, timestamp: snapshot.timestamp, confirmSec: effectiveOffConfirmSec)
        if assessment.shouldConfirmOff {
            return confirmOff(snapshot, assessment: assessment)
        }

        if assessment.shouldCancelOff {
            currentState = .bright
            clearCandidate()
            if isObservable(snapshot) {
                stableReference = LightReference(snapshot: snapshot)
            }
            return [
                LightEvent(
                    event: "off_candidate_cancelled",
                    state: currentState.rawValue,
                    reason: "evidence_ratio_too_low",
                    values: numericValues(signal.values.merging(assessment.values) { _, new in new })
                )
            ]
        }

        return []
    }

    private func startOnCandidate(_ snapshot: LightAnalysisSnapshot, signal: SignalEvidence) -> [LightEvent] {
        currentState = .onCandidate
        candidateStartedAt = snapshot.timestamp
        candidateSamples = [CandidateEvidenceSample(timestamp: snapshot.timestamp, signal: signal)]
        return [
            LightEvent(
                event: "on_candidate",
                state: currentState.rawValue,
                reason: signal.onReason,
                values: numericValues(signal.values)
            )
        ]
    }

    private func startOffCandidate(_ snapshot: LightAnalysisSnapshot, signal: SignalEvidence) -> [LightEvent] {
        currentState = .offCandidate
        candidateStartedAt = snapshot.timestamp
        candidateSamples = [CandidateEvidenceSample(timestamp: snapshot.timestamp, signal: signal)]
        return [
            LightEvent(
                event: "off_candidate",
                state: currentState.rawValue,
                reason: signal.offReason,
                values: numericValues(signal.values)
            )
        ]
    }

    private func confirmOn(_ snapshot: LightAnalysisSnapshot, assessment: CandidateAssessment) -> [LightEvent] {
        currentState = .bright
        if isObservable(snapshot) {
            stableReference = LightReference(snapshot: snapshot)
        }
        clearCandidate()
        let notification = DiscordNotification(
            eventName: "notify_on",
            title: "🟢人がいます",
            state: .bright,
            reason: "ON証拠が直近\(Int(effectiveOnConfirmSec))秒の\(percentage(assessment.onRatio))で継続",
            confirmSeconds: Int(effectiveOnConfirmSec)
        )
        return [makeNotificationEvent(notification, values: assessment.values)]
    }

    private func confirmOff(_ snapshot: LightAnalysisSnapshot, assessment: CandidateAssessment) -> [LightEvent] {
        currentState = .dark
        if isObservable(snapshot) {
            stableReference = LightReference(snapshot: snapshot)
        }
        clearCandidate()
        let notification = DiscordNotification(
            eventName: "notify_off",
            title: "⚪人がいません",
            state: .dark,
            reason: "OFF証拠が直近\(Int(effectiveOffConfirmSec))秒の\(percentage(assessment.offRatio))で継続",
            confirmSeconds: Int(effectiveOffConfirmSec)
        )
        return [makeNotificationEvent(notification, values: assessment.values)]
    }

    private func evaluateSignal(_ snapshot: LightAnalysisSnapshot) -> SignalEvidence {
        let reference = stableReference
        let requiredCount = requiredPositiveCount(for: snapshot)
        let positiveStats = snapshot.roiStats.filter { $0.kind == .positive && $0.isObservable }
        let positiveOnCount = positiveStats.filter { stat in
            guard let baseline = reference?.positiveMedians[stat.name] else {
                return false
            }
            return stat.medianLuma >= baseline + settings.minDeltaOn
        }.count
        let positiveOffCount = positiveStats.filter { stat in
            guard let baseline = reference?.positiveMedians[stat.name] else {
                return false
            }
            return stat.medianLuma <= baseline + settings.minDeltaOff
        }.count

        let medianDelta = reference.map { snapshot.sceneLevel.positiveMedian - $0.positiveMedian }
        let guardDelta: Double? = {
            guard let currentGuard = snapshot.sceneLevel.guardMedian,
                  let referenceGuard = reference?.guardMedian else {
                return nil
            }
            return currentGuard - referenceGuard
        }()

        let weakPersonPresent = snapshot.sceneLevel.personMaskedRatio >= 0.02
        let strongPersonPresent = snapshot.sceneLevel.personMaskedRatio >= 0.08
        let hasRequiredPositiveOnROIs = positiveOnCount >= requiredCount
        let hasRequiredPositiveOffROIs = positiveOffCount >= requiredCount
        let aggregateOn = medianDelta.map { $0 >= settings.minDeltaOn } ?? false
        let aggregateOff = medianDelta.map { $0 <= settings.minDeltaOff } ?? false
        let absoluteOn = snapshot.sceneLevel.positiveMedian >= 135 || snapshot.sceneLevel.positiveBrightRatio >= 0.04
        let absoluteOff = snapshot.sceneLevel.positiveMedian <= 130 && snapshot.sceneLevel.positiveBrightRatio <= 0.02

        let guardMovedOn = guardDelta.map { $0 >= settings.minDeltaOn } ?? false
        let guardMovedOff = guardDelta.map { $0 <= settings.minDeltaOff } ?? false
        let positiveMoveIsStrongOn = medianDelta.map { $0 >= settings.minDeltaOn * 1.5 } ?? false
        let positiveMoveIsStrongOff = medianDelta.map { $0 <= settings.minDeltaOff * 1.5 } ?? false
        let rejectWeakGlobalOnShift = guardMovedOn && !positiveMoveIsStrongOn && positiveOnCount < requiredCount
        let rejectWeakGlobalOffShift = guardMovedOff && !positiveMoveIsStrongOff && positiveOffCount < requiredCount

        let lightOnEvidence = isObservable(snapshot)
            && (hasRequiredPositiveOnROIs || aggregateOn)
            && absoluteOn
            && !rejectWeakGlobalOnShift
        let lightOffEvidence = isObservable(snapshot)
            && !weakPersonPresent
            && (hasRequiredPositiveOffROIs || aggregateOff)
            && absoluteOff
            && !rejectWeakGlobalOffShift

        let weakLightSupportForPerson = isObservable(snapshot)
            && !rejectWeakGlobalOnShift
            && (
                positiveOnCount >= max(1, requiredCount - 1)
                || (medianDelta.map { $0 >= settings.minDeltaOn * 0.5 } ?? false)
                || snapshot.sceneLevel.positiveBrightRatio >= 0.03
            )
        let personBackedOnEvidence = strongPersonPresent && weakLightSupportForPerson
        let onEvidence = lightOnEvidence || personBackedOnEvidence
        let offEvidence = lightOffEvidence

        let onReason: String
        if lightOnEvidence {
            onReason = "positive_roi_light_delta"
        } else if personBackedOnEvidence {
            onReason = "strong_person_with_light_support"
        } else {
            onReason = "no_on_evidence"
        }

        let offReason: String
        if lightOffEvidence {
            offReason = "positive_roi_light_drop"
        } else if weakPersonPresent {
            offReason = "person_present"
        } else {
            offReason = "no_off_evidence"
        }

        var values = snapshot.sceneLevel.values
        values["required_positive_roi_count"] = Double(requiredCount)
        values["positive_on_roi_count"] = Double(positiveOnCount)
        values["positive_off_roi_count"] = Double(positiveOffCount)
        values["weak_person_present"] = weakPersonPresent ? 1 : 0
        values["strong_person_present"] = strongPersonPresent ? 1 : 0
        values["on_evidence"] = onEvidence ? 1 : 0
        values["off_evidence"] = offEvidence ? 1 : 0
        values["light_on_evidence"] = lightOnEvidence ? 1 : 0
        values["person_backed_on_evidence"] = personBackedOnEvidence ? 1 : 0
        values["light_off_evidence"] = lightOffEvidence ? 1 : 0
        values["reject_weak_global_on_shift"] = rejectWeakGlobalOnShift ? 1 : 0
        values["reject_weak_global_off_shift"] = rejectWeakGlobalOffShift ? 1 : 0
        if let medianDelta {
            values["positive_median_delta"] = medianDelta
        }
        if let guardDelta {
            values["guard_delta"] = guardDelta
        }

        return SignalEvidence(
            onEvidence: onEvidence,
            offEvidence: offEvidence,
            weakPersonPresent: weakPersonPresent,
            strongPersonPresent: strongPersonPresent,
            onReason: onReason,
            offReason: offReason,
            values: values
        )
    }

    private func appendCandidateSample(signal: SignalEvidence, timestamp: Date, confirmSec: TimeInterval) -> CandidateAssessment {
        let sample = CandidateEvidenceSample(timestamp: timestamp, signal: signal)
        candidateSamples.append(sample)
        let cutoff = sample.timestamp.addingTimeInterval(-confirmSec)
        pruneCandidateSamples(olderThan: cutoff)
        return assessCandidate(at: sample.timestamp, confirmSec: confirmSec)
    }

    private func assessCandidate(at timestamp: Date, confirmSec: TimeInterval) -> CandidateAssessment {
        guard let candidateStartedAt else {
            return CandidateAssessment.empty
        }

        let elapsed = timestamp.timeIntervalSince(candidateStartedAt)
        let relevantSamples = candidateSamples.filter { $0.timestamp >= timestamp.addingTimeInterval(-confirmSec) }
        guard !relevantSamples.isEmpty else {
            return CandidateAssessment.empty
        }

        let total = Double(relevantSamples.count)
        let onRatio = Double(relevantSamples.filter(\.onEvidence).count) / total
        let offRatio = Double(relevantSamples.filter(\.offEvidence).count) / total
        let weakPersonRatio = Double(relevantSamples.filter(\.weakPersonPresent).count) / total
        let strongPersonRatio = Double(relevantSamples.filter(\.strongPersonPresent).count) / total
        let enoughTime = elapsed >= confirmSec
        let enoughSamples = relevantSamples.count >= 3
        let cancelGraceSec = min(45, max(15, confirmSec / 4))
        let cancelAllowed = elapsed >= cancelGraceSec && enoughSamples

        let shouldConfirmOn = enoughTime && enoughSamples && onRatio >= 0.80 && offRatio <= 0.10
        let shouldConfirmOff = enoughTime && enoughSamples && offRatio >= 0.80 && onRatio <= 0.15 && weakPersonRatio <= 0.05
        let shouldCancelOn = cancelAllowed && onRatio < 0.20 && strongPersonRatio < 0.20
        let shouldCancelOff = cancelAllowed && (offRatio < 0.20 || weakPersonRatio > 0.10)

        return CandidateAssessment(
            elapsed: elapsed,
            sampleCount: relevantSamples.count,
            onRatio: onRatio,
            offRatio: offRatio,
            weakPersonRatio: weakPersonRatio,
            strongPersonRatio: strongPersonRatio,
            shouldConfirmOn: shouldConfirmOn,
            shouldConfirmOff: shouldConfirmOff,
            shouldCancelOn: shouldCancelOn,
            shouldCancelOff: shouldCancelOff
        )
    }

    private func pruneCandidateSamples(olderThan cutoff: Date) {
        candidateSamples.removeAll { $0.timestamp < cutoff }
    }

    private func updateStableReference(with snapshot: LightAnalysisSnapshot) {
        guard isObservable(snapshot) else {
            return
        }
        guard var reference = stableReference else {
            stableReference = LightReference(snapshot: snapshot)
            return
        }
        reference.blend(with: snapshot, alpha: 0.1)
        stableReference = reference
    }

    private func isObservable(_ snapshot: LightAnalysisSnapshot) -> Bool {
        snapshot.sceneLevel.observablePositiveCount >= requiredPositiveCount(for: snapshot)
    }

    private func requiredPositiveCount(for snapshot: LightAnalysisSnapshot) -> Int {
        let configuredCount = max(1, settings.requiredPositiveROICount)
        let totalPositiveCount = max(1, snapshot.roiStats.filter { $0.kind == .positive }.count)
        return min(configuredCount, totalPositiveCount)
    }

    private func clearCandidate() {
        candidateStartedAt = nil
        candidateSamples.removeAll()
    }

    private func makeNotificationEvent(_ notification: DiscordNotification, values: [String: Double] = [:]) -> LightEvent {
        var eventValues = values.mapValues { LogValue.number($0) }
        eventValues["confirm_sec"] = .number(Double(notification.confirmSeconds))
        return LightEvent(
            event: notification.eventName,
            state: notification.state.rawValue,
            reason: notification.reason,
            values: eventValues,
            notification: notification
        )
    }

    private func numericValues(_ values: [String: Double]) -> [String: LogValue] {
        values.mapValues { .number($0) }
    }

    private func percentage(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private var effectiveOnConfirmSec: TimeInterval {
        max(10, settings.onConfirmSec)
    }

    private var effectiveOffConfirmSec: TimeInterval {
        max(10, settings.offConfirmSec)
    }
}

private struct LightReference {
    var positiveMedians: [String: Double]
    var positiveMedian: Double
    var guardMedian: Double?

    init(snapshot: LightAnalysisSnapshot) {
        positiveMedians = Dictionary(
            uniqueKeysWithValues: snapshot.roiStats
                .filter { $0.kind == .positive && $0.isObservable }
                .map { ($0.name, $0.medianLuma) }
        )
        positiveMedian = snapshot.sceneLevel.positiveMedian
        guardMedian = snapshot.sceneLevel.guardMedian
    }

    mutating func blend(with snapshot: LightAnalysisSnapshot, alpha: Double) {
        let boundedAlpha = min(1, max(0, alpha))
        for stat in snapshot.roiStats where stat.kind == .positive && stat.isObservable {
            if let previous = positiveMedians[stat.name] {
                positiveMedians[stat.name] = previous * (1 - boundedAlpha) + stat.medianLuma * boundedAlpha
            } else {
                positiveMedians[stat.name] = stat.medianLuma
            }
        }
        positiveMedian = positiveMedian * (1 - boundedAlpha) + snapshot.sceneLevel.positiveMedian * boundedAlpha
        if let currentGuardMedian = snapshot.sceneLevel.guardMedian {
            if let previousGuardMedian = guardMedian {
                guardMedian = previousGuardMedian * (1 - boundedAlpha) + currentGuardMedian * boundedAlpha
            } else {
                guardMedian = currentGuardMedian
            }
        }
    }
}

private struct SignalEvidence {
    let onEvidence: Bool
    let offEvidence: Bool
    let weakPersonPresent: Bool
    let strongPersonPresent: Bool
    let onReason: String
    let offReason: String
    let values: [String: Double]
}

private struct CandidateEvidenceSample {
    let timestamp: Date
    let onEvidence: Bool
    let offEvidence: Bool
    let weakPersonPresent: Bool
    let strongPersonPresent: Bool

    init(timestamp: Date, signal: SignalEvidence) {
        self.timestamp = timestamp
        onEvidence = signal.onEvidence
        offEvidence = signal.offEvidence
        weakPersonPresent = signal.weakPersonPresent
        strongPersonPresent = signal.strongPersonPresent
    }
}

private struct CandidateAssessment {
    let elapsed: TimeInterval
    let sampleCount: Int
    let onRatio: Double
    let offRatio: Double
    let weakPersonRatio: Double
    let strongPersonRatio: Double
    let shouldConfirmOn: Bool
    let shouldConfirmOff: Bool
    let shouldCancelOn: Bool
    let shouldCancelOff: Bool

    static let empty = CandidateAssessment(
        elapsed: 0,
        sampleCount: 0,
        onRatio: 0,
        offRatio: 0,
        weakPersonRatio: 0,
        strongPersonRatio: 0,
        shouldConfirmOn: false,
        shouldConfirmOff: false,
        shouldCancelOn: false,
        shouldCancelOff: false
    )

    var values: [String: Double] {
        [
            "candidate_elapsed_sec": elapsed,
            "candidate_sample_count": Double(sampleCount),
            "candidate_on_ratio": onRatio,
            "candidate_off_ratio": offRatio,
            "candidate_weak_person_ratio": weakPersonRatio,
            "candidate_strong_person_ratio": strongPersonRatio
        ]
    }
}

struct DiscordNotification {
    let eventName: String
    let title: String
    let state: LightWatchState
    let reason: String
    let confirmSeconds: Int
}
