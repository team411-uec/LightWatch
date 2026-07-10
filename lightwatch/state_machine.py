from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta

from lightwatch.models import (
    DiscordNotification,
    LightAnalysisSnapshot,
    LightEvent,
    LightWatchSettings,
    LightWatchState,
    ROIKind,
)


class StateMachine:
    def __init__(self, settings: LightWatchSettings, initial_state: LightWatchState) -> None:
        self.settings = settings
        self.currentState = initial_state
        self.candidateStartedAt: datetime | None = None
        self.candidateSamples: list[CandidateEvidenceSample] = []
        self.stableReference: LightReference | None = None

    def update(self, settings: LightWatchSettings) -> None:
        self.settings = settings
        now = datetime.now().astimezone()
        self.prune_candidate_samples(
            now - timedelta(seconds=max(self.effectiveOnConfirmSec, self.effectiveOffConfirmSec))
        )

    def handle(self, snapshot: LightAnalysisSnapshot) -> list[LightEvent]:
        if self.currentState == LightWatchState.DARK:
            return self.handle_dark(snapshot)
        if self.currentState == LightWatchState.ON_CANDIDATE:
            return self.handle_on_candidate(snapshot)
        if self.currentState == LightWatchState.BRIGHT:
            return self.handle_bright(snapshot)
        return self.handle_off_candidate(snapshot)

    def handle_dark(self, snapshot: LightAnalysisSnapshot) -> list[LightEvent]:
        if not self.is_observable(snapshot):
            return []
        signal = self.evaluate_signal(snapshot)
        if not signal.onEvidence:
            self.update_stable_reference(snapshot)
            return []
        return self.start_on_candidate(snapshot, signal)

    def handle_on_candidate(self, snapshot: LightAnalysisSnapshot) -> list[LightEvent]:
        signal = self.evaluate_signal(snapshot)
        assessment = self.append_candidate_sample(
            signal, snapshot.timestamp, self.effectiveOnConfirmSec
        )
        if assessment.shouldConfirmOn:
            return self.confirm_on(snapshot, assessment)
        if assessment.shouldCancelOn:
            self.currentState = LightWatchState.DARK
            self.clear_candidate()
            if self.is_observable(snapshot):
                self.stableReference = LightReference.from_snapshot(snapshot)
            return [
                LightEvent(
                    "on_candidate_cancelled",
                    self.currentState.value,
                    "evidence_ratio_too_low",
                    signal.values | assessment.values,
                )
            ]
        return []

    def handle_bright(self, snapshot: LightAnalysisSnapshot) -> list[LightEvent]:
        signal = self.evaluate_signal(snapshot)
        if signal.weakPersonPresent:
            self.clear_candidate()
            return []
        if not self.is_observable(snapshot):
            return []
        if not signal.offEvidence:
            self.update_stable_reference(snapshot)
            return []
        return self.start_off_candidate(snapshot, signal)

    def handle_off_candidate(self, snapshot: LightAnalysisSnapshot) -> list[LightEvent]:
        signal = self.evaluate_signal(snapshot)
        if signal.weakPersonPresent:
            self.currentState = LightWatchState.BRIGHT
            self.clear_candidate()
            return [
                LightEvent(
                    "off_candidate_cancelled",
                    self.currentState.value,
                    "person_present",
                    signal.values,
                )
            ]
        assessment = self.append_candidate_sample(
            signal, snapshot.timestamp, self.effectiveOffConfirmSec
        )
        if assessment.shouldConfirmOff:
            return self.confirm_off(snapshot, assessment)
        if assessment.shouldCancelOff:
            self.currentState = LightWatchState.BRIGHT
            self.clear_candidate()
            if self.is_observable(snapshot):
                self.stableReference = LightReference.from_snapshot(snapshot)
            return [
                LightEvent(
                    "off_candidate_cancelled",
                    self.currentState.value,
                    "evidence_ratio_too_low",
                    signal.values | assessment.values,
                )
            ]
        return []

    def start_on_candidate(
        self, snapshot: LightAnalysisSnapshot, signal: SignalEvidence
    ) -> list[LightEvent]:
        self.currentState = LightWatchState.ON_CANDIDATE
        self.candidateStartedAt = snapshot.timestamp
        self.candidateSamples = [CandidateEvidenceSample.from_signal(snapshot.timestamp, signal)]
        return [LightEvent("on_candidate", self.currentState.value, signal.onReason, signal.values)]

    def start_off_candidate(
        self, snapshot: LightAnalysisSnapshot, signal: SignalEvidence
    ) -> list[LightEvent]:
        self.currentState = LightWatchState.OFF_CANDIDATE
        self.candidateStartedAt = snapshot.timestamp
        self.candidateSamples = [CandidateEvidenceSample.from_signal(snapshot.timestamp, signal)]
        return [
            LightEvent("off_candidate", self.currentState.value, signal.offReason, signal.values)
        ]

    def confirm_on(
        self, snapshot: LightAnalysisSnapshot, assessment: CandidateAssessment
    ) -> list[LightEvent]:
        self.currentState = LightWatchState.BRIGHT
        if self.is_observable(snapshot):
            self.stableReference = LightReference.from_snapshot(snapshot)
        self.clear_candidate()
        notification = DiscordNotification(
            "notify_on",
            "🟢人がいます",
            LightWatchState.BRIGHT,
            f"ON証拠が直近{int(self.effectiveOnConfirmSec)}秒の{percentage(assessment.onRatio)}で継続",
            int(self.effectiveOnConfirmSec),
        )
        return [self.make_notification_event(notification, assessment.values)]

    def confirm_off(
        self, snapshot: LightAnalysisSnapshot, assessment: CandidateAssessment
    ) -> list[LightEvent]:
        self.currentState = LightWatchState.DARK
        if self.is_observable(snapshot):
            self.stableReference = LightReference.from_snapshot(snapshot)
        self.clear_candidate()
        notification = DiscordNotification(
            "notify_off",
            "⚪人がいません",
            LightWatchState.DARK,
            f"OFF証拠が直近{int(self.effectiveOffConfirmSec)}秒の{percentage(assessment.offRatio)}で継続",
            int(self.effectiveOffConfirmSec),
        )
        return [self.make_notification_event(notification, assessment.values)]

    def evaluate_signal(self, snapshot: LightAnalysisSnapshot) -> SignalEvidence:
        reference = self.stableReference
        required_count = self.required_positive_count(snapshot)
        positive_stats = [
            stat
            for stat in snapshot.roiStats
            if stat.kind == ROIKind.POSITIVE and stat.isObservable
        ]
        positive_on_count = (
            sum(
                stat.medianLuma
                >= reference.positiveMedians.get(stat.name, float("inf")) + self.settings.minDeltaOn
                for stat in positive_stats
            )
            if reference
            else 0
        )
        positive_off_count = (
            sum(
                stat.medianLuma
                <= reference.positiveMedians.get(stat.name, float("-inf"))
                + self.settings.minDeltaOff
                for stat in positive_stats
            )
            if reference
            else 0
        )
        median_delta = (
            None
            if reference is None
            else snapshot.sceneLevel.positiveMedian - reference.positiveMedian
        )
        guard_delta = (
            None
            if reference is None
            or reference.guardMedian is None
            or snapshot.sceneLevel.guardMedian is None
            else snapshot.sceneLevel.guardMedian - reference.guardMedian
        )
        weak_person_present = snapshot.sceneLevel.personMaskedRatio >= 0.02
        strong_person_present = snapshot.sceneLevel.personMaskedRatio >= 0.08
        aggregate_on = median_delta is not None and median_delta >= self.settings.minDeltaOn
        aggregate_off = median_delta is not None and median_delta <= self.settings.minDeltaOff
        absolute_on = (
            snapshot.sceneLevel.positiveMedian >= 135
            or snapshot.sceneLevel.positiveBrightRatio >= 0.04
        )
        absolute_off = (
            snapshot.sceneLevel.positiveMedian <= 130
            and snapshot.sceneLevel.positiveBrightRatio <= 0.02
        )
        bootstrap_on = reference is None and absolute_on
        guard_moved_on = guard_delta is not None and guard_delta >= self.settings.minDeltaOn
        guard_moved_off = guard_delta is not None and guard_delta <= self.settings.minDeltaOff
        positive_move_is_strong_on = (
            median_delta is not None and median_delta >= self.settings.minDeltaOn * 1.5
        )
        positive_move_is_strong_off = (
            median_delta is not None and median_delta <= self.settings.minDeltaOff * 1.5
        )
        reject_weak_global_on_shift = (
            guard_moved_on and not positive_move_is_strong_on and positive_on_count < required_count
        )
        reject_weak_global_off_shift = (
            guard_moved_off
            and not positive_move_is_strong_off
            and positive_off_count < required_count
        )
        light_on_evidence = (
            self.is_observable(snapshot)
            and (positive_on_count >= required_count or aggregate_on or bootstrap_on)
            and absolute_on
            and not reject_weak_global_on_shift
        )
        light_off_evidence = (
            self.is_observable(snapshot)
            and not weak_person_present
            and (positive_off_count >= required_count or aggregate_off)
            and absolute_off
            and not reject_weak_global_off_shift
        )
        weak_light_support_for_person = (
            self.is_observable(snapshot)
            and not reject_weak_global_on_shift
            and (
                positive_on_count >= max(1, required_count - 1)
                or (median_delta is not None and median_delta >= self.settings.minDeltaOn * 0.5)
                or snapshot.sceneLevel.positiveBrightRatio >= 0.03
            )
        )
        person_backed_on_evidence = strong_person_present and weak_light_support_for_person
        on_evidence = light_on_evidence or person_backed_on_evidence
        values = snapshot.sceneLevel.values | {
            "required_positive_roi_count": float(required_count),
            "positive_on_roi_count": float(positive_on_count),
            "positive_off_roi_count": float(positive_off_count),
            "weak_person_present": 1 if weak_person_present else 0,
            "strong_person_present": 1 if strong_person_present else 0,
            "on_evidence": 1 if on_evidence else 0,
            "off_evidence": 1 if light_off_evidence else 0,
            "light_on_evidence": 1 if light_on_evidence else 0,
            "person_backed_on_evidence": 1 if person_backed_on_evidence else 0,
            "light_off_evidence": 1 if light_off_evidence else 0,
            "bootstrap_on_evidence": 1 if bootstrap_on else 0,
            "reject_weak_global_on_shift": 1 if reject_weak_global_on_shift else 0,
            "reject_weak_global_off_shift": 1 if reject_weak_global_off_shift else 0,
        }
        if median_delta is not None:
            values["positive_median_delta"] = median_delta
        if guard_delta is not None:
            values["guard_delta"] = guard_delta
        return SignalEvidence(
            onEvidence=on_evidence,
            offEvidence=light_off_evidence,
            weakPersonPresent=weak_person_present,
            strongPersonPresent=strong_person_present,
            onReason="positive_roi_light_delta"
            if light_on_evidence
            else "strong_person_with_light_support"
            if person_backed_on_evidence
            else "no_on_evidence",
            offReason="positive_roi_light_drop"
            if light_off_evidence
            else "person_present"
            if weak_person_present
            else "no_off_evidence",
            values=values,
        )

    def append_candidate_sample(
        self, signal: SignalEvidence, timestamp: datetime, confirm_sec: float
    ) -> CandidateAssessment:
        self.candidateSamples.append(CandidateEvidenceSample.from_signal(timestamp, signal))
        self.prune_candidate_samples(timestamp - timedelta(seconds=confirm_sec))
        return self.assess_candidate(timestamp, confirm_sec)

    def assess_candidate(self, timestamp: datetime, confirm_sec: float) -> CandidateAssessment:
        if self.candidateStartedAt is None:
            return CandidateAssessment.empty()
        elapsed = (timestamp - self.candidateStartedAt).total_seconds()
        cutoff = timestamp - timedelta(seconds=confirm_sec)
        relevant_samples = [
            sample for sample in self.candidateSamples if sample.timestamp >= cutoff
        ]
        if not relevant_samples:
            return CandidateAssessment.empty()
        total = len(relevant_samples)
        on_ratio = sum(sample.onEvidence for sample in relevant_samples) / total
        off_ratio = sum(sample.offEvidence for sample in relevant_samples) / total
        weak_person_ratio = sum(sample.weakPersonPresent for sample in relevant_samples) / total
        strong_person_ratio = sum(sample.strongPersonPresent for sample in relevant_samples) / total
        maximum_sample_gap = max(
            (
                (current.timestamp - previous.timestamp).total_seconds()
                for previous, current in zip(relevant_samples, relevant_samples[1:], strict=False)
            ),
            default=0,
        )
        samples_are_continuous = maximum_sample_gap <= max(3, self.settings.captureIntervalSec * 3)
        enough_time = elapsed >= confirm_sec
        enough_samples = total >= 3
        cancel_grace_sec = min(45, max(15, confirm_sec / 4))
        cancel_allowed = elapsed >= cancel_grace_sec and enough_samples
        return CandidateAssessment(
            elapsed,
            total,
            on_ratio,
            off_ratio,
            weak_person_ratio,
            strong_person_ratio,
            maximum_sample_gap,
            enough_time
            and enough_samples
            and samples_are_continuous
            and on_ratio >= 0.80
            and off_ratio <= 0.10,
            enough_time
            and enough_samples
            and samples_are_continuous
            and off_ratio >= 0.80
            and on_ratio <= 0.15
            and weak_person_ratio <= 0.05,
            cancel_allowed and on_ratio < 0.20 and strong_person_ratio < 0.20,
            cancel_allowed and (off_ratio < 0.20 or weak_person_ratio > 0.10),
        )

    def prune_candidate_samples(self, cutoff: datetime) -> None:
        self.candidateSamples = [
            sample for sample in self.candidateSamples if sample.timestamp >= cutoff
        ]

    def update_stable_reference(self, snapshot: LightAnalysisSnapshot) -> None:
        if not self.is_observable(snapshot):
            return
        if self.stableReference is None:
            self.stableReference = LightReference.from_snapshot(snapshot)
            return
        self.stableReference.blend(snapshot, 0.1)

    def is_observable(self, snapshot: LightAnalysisSnapshot) -> bool:
        return snapshot.sceneLevel.observablePositiveCount >= self.required_positive_count(snapshot)

    def required_positive_count(self, snapshot: LightAnalysisSnapshot) -> int:
        configured_count = max(1, self.settings.requiredPositiveROICount)
        total_positive_count = max(
            1, sum(stat.kind == ROIKind.POSITIVE for stat in snapshot.roiStats)
        )
        return min(configured_count, total_positive_count)

    def clear_candidate(self) -> None:
        self.candidateStartedAt = None
        self.candidateSamples = []

    def make_notification_event(
        self, notification: DiscordNotification, values: dict[str, float]
    ) -> LightEvent:
        return LightEvent(
            notification.eventName,
            notification.state.value,
            notification.reason,
            values | {"confirm_sec": float(notification.confirmSeconds)},
            notification,
        )

    @property
    def effectiveOnConfirmSec(self) -> float:
        return max(10, self.settings.onConfirmSec)

    @property
    def effectiveOffConfirmSec(self) -> float:
        return max(10, self.settings.offConfirmSec)


@dataclass
class LightReference:
    positiveMedians: dict[str, float]
    positiveMedian: float
    guardMedian: float | None

    @classmethod
    def from_snapshot(cls, snapshot: LightAnalysisSnapshot) -> LightReference:
        return cls(
            {
                stat.name: stat.medianLuma
                for stat in snapshot.roiStats
                if stat.kind == ROIKind.POSITIVE and stat.isObservable
            },
            snapshot.sceneLevel.positiveMedian,
            snapshot.sceneLevel.guardMedian,
        )

    def blend(self, snapshot: LightAnalysisSnapshot, alpha: float) -> None:
        bounded_alpha = min(1, max(0, alpha))
        for stat in snapshot.roiStats:
            if stat.kind == ROIKind.POSITIVE and stat.isObservable:
                previous = self.positiveMedians.get(stat.name, stat.medianLuma)
                self.positiveMedians[stat.name] = (
                    previous * (1 - bounded_alpha) + stat.medianLuma * bounded_alpha
                )
        self.positiveMedian = (
            self.positiveMedian * (1 - bounded_alpha)
            + snapshot.sceneLevel.positiveMedian * bounded_alpha
        )
        if snapshot.sceneLevel.guardMedian is not None:
            self.guardMedian = (
                snapshot.sceneLevel.guardMedian
                if self.guardMedian is None
                else self.guardMedian * (1 - bounded_alpha)
                + snapshot.sceneLevel.guardMedian * bounded_alpha
            )


@dataclass(frozen=True)
class SignalEvidence:
    onEvidence: bool
    offEvidence: bool
    weakPersonPresent: bool
    strongPersonPresent: bool
    onReason: str
    offReason: str
    values: dict[str, float]


@dataclass(frozen=True)
class CandidateEvidenceSample:
    timestamp: datetime
    onEvidence: bool
    offEvidence: bool
    weakPersonPresent: bool
    strongPersonPresent: bool

    @classmethod
    def from_signal(cls, timestamp: datetime, signal: SignalEvidence) -> CandidateEvidenceSample:
        return cls(
            timestamp,
            signal.onEvidence,
            signal.offEvidence,
            signal.weakPersonPresent,
            signal.strongPersonPresent,
        )


@dataclass(frozen=True)
class CandidateAssessment:
    elapsed: float
    sampleCount: int
    onRatio: float
    offRatio: float
    weakPersonRatio: float
    strongPersonRatio: float
    maximumSampleGap: float
    shouldConfirmOn: bool
    shouldConfirmOff: bool
    shouldCancelOn: bool
    shouldCancelOff: bool

    @classmethod
    def empty(cls) -> CandidateAssessment:
        return cls(0, 0, 0, 0, 0, 0, 0, False, False, False, False)

    @property
    def values(self) -> dict[str, float]:
        return {
            "candidate_elapsed_sec": self.elapsed,
            "candidate_sample_count": float(self.sampleCount),
            "candidate_on_ratio": self.onRatio,
            "candidate_off_ratio": self.offRatio,
            "candidate_weak_person_ratio": self.weakPersonRatio,
            "candidate_strong_person_ratio": self.strongPersonRatio,
            "candidate_maximum_sample_gap_sec": self.maximumSampleGap,
        }


def percentage(value: float) -> str:
    return f"{round(value * 100):.0f}%"
