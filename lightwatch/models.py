from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum


class LightWatchState(str, Enum):
    DARK = "DARK"
    ON_CANDIDATE = "ON_CANDIDATE"
    BRIGHT = "BRIGHT"
    OFF_CANDIDATE = "OFF_CANDIDATE"

    @property
    def display_name(self) -> str:
        return {
            LightWatchState.DARK: "消灯中",
            LightWatchState.ON_CANDIDATE: "点灯確認中",
            LightWatchState.BRIGHT: "点灯中",
            LightWatchState.OFF_CANDIDATE: "消灯確認中",
        }[self]


class ROIKind(str, Enum):
    POSITIVE = "positive"
    NEGATIVE = "negative"


@dataclass(frozen=True)
class LightROI:
    name: str
    kind: ROIKind
    x: float
    y: float
    width: float
    height: float


@dataclass
class LightWatchSettings:
    discordWebhookURL: str = ""
    cameraUniqueID: str = ""
    launchAtLogin: bool = False
    captureIntervalSec: float = 1
    onConfirmSec: float = 45
    offConfirmSec: float = 45
    minDeltaOn: float = 18
    minDeltaOff: float = -18
    requiredPositiveROICount: int = 3
    rois: list[LightROI] = field(default_factory=list)

    @classmethod
    def default(cls) -> LightWatchSettings:
        return cls(
            rois=[
                LightROI("topLeftEdge", ROIKind.POSITIVE, 0.02, 0.02, 0.26, 0.22),
                LightROI("topRightEdge", ROIKind.POSITIVE, 0.72, 0.02, 0.26, 0.22),
                LightROI("bottomLeftEdge", ROIKind.POSITIVE, 0.02, 0.76, 0.26, 0.22),
                LightROI("bottomRightEdge", ROIKind.POSITIVE, 0.72, 0.76, 0.26, 0.22),
                LightROI("centerLeftGuard", ROIKind.NEGATIVE, 0.30, 0.18, 0.16, 0.64),
                LightROI("centerRightGuard", ROIKind.NEGATIVE, 0.54, 0.18, 0.16, 0.64),
            ]
        )

    def normalized(self) -> LightWatchSettings:
        if any(roi.kind == ROIKind.NEGATIVE for roi in self.rois):
            return self
        self.rois.extend(roi for roi in self.default().rois if roi.kind == ROIKind.NEGATIVE)
        return self


@dataclass(frozen=True)
class ROIStats:
    name: str
    kind: ROIKind
    medianLuma: float
    brightRatio: float
    darkRatio: float
    observableRatio: float
    isObservable: bool
    isDark: bool


@dataclass(frozen=True)
class PersonPresence:
    maskedRatio: float

    @property
    def isPresent(self) -> bool:
        return self.maskedRatio >= 0.02


@dataclass(frozen=True)
class LightSceneLevel:
    positiveMedian: float
    guardMedian: float | None
    positiveDarkRatio: float
    positiveBrightRatio: float
    observablePositiveCount: int
    isObservable: bool
    personMaskedRatio: float
    isPersonPresent: bool
    positiveROINames: list[str]

    @classmethod
    def from_stats(cls, stats: list[ROIStats], person_presence: PersonPresence) -> LightSceneLevel:
        positive_stats = [
            stat for stat in stats if stat.kind == ROIKind.POSITIVE and stat.isObservable
        ]
        guard_stats = [
            stat for stat in stats if stat.kind == ROIKind.NEGATIVE and stat.isObservable
        ]
        return cls(
            positiveMedian=median([stat.medianLuma for stat in positive_stats]),
            guardMedian=None
            if not guard_stats
            else median([stat.medianLuma for stat in guard_stats]),
            positiveDarkRatio=average([stat.darkRatio for stat in positive_stats]),
            positiveBrightRatio=average([stat.brightRatio for stat in positive_stats]),
            observablePositiveCount=len(positive_stats),
            isObservable=len(positive_stats) >= 3,
            personMaskedRatio=person_presence.maskedRatio,
            isPersonPresent=person_presence.isPresent,
            positiveROINames=[stat.name for stat in positive_stats],
        )

    @property
    def values(self) -> dict[str, float]:
        values = {
            "positive_median": self.positiveMedian,
            "positive_dark_ratio": self.positiveDarkRatio,
            "positive_bright_ratio": self.positiveBrightRatio,
            "observable_positive_count": float(self.observablePositiveCount),
            "person_masked_ratio": self.personMaskedRatio,
        }
        if self.guardMedian is not None:
            values["guard_median"] = self.guardMedian
        return values


@dataclass(frozen=True)
class LightAnalysisSnapshot:
    timestamp: datetime
    state: LightWatchState
    roiStats: list[ROIStats]
    sceneLevel: LightSceneLevel


@dataclass(frozen=True)
class DiscordNotification:
    eventName: str
    title: str
    state: LightWatchState
    reason: str
    confirmSeconds: int


@dataclass(frozen=True)
class LightEvent:
    event: str
    state: str | None
    reason: str | None
    values: dict[str, str | float | bool]
    notification: DiscordNotification | None = None


def median(values: list[float]) -> float:
    if not values:
        return 0
    sorted_values = sorted(values)
    middle_index = len(sorted_values) // 2
    if len(sorted_values) % 2 == 0:
        return (sorted_values[middle_index - 1] + sorted_values[middle_index]) / 2
    return sorted_values[middle_index]


def average(values: list[float]) -> float:
    if not values:
        return 0
    return sum(values) / len(values)
