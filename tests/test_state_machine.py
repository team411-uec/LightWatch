from datetime import UTC, datetime, timedelta

from lightwatch.models import (
    LightAnalysisSnapshot,
    LightSceneLevel,
    LightWatchSettings,
    LightWatchState,
    PersonPresence,
    ROIKind,
    ROIStats,
)
from lightwatch.state_machine import StateMachine


def make_snapshot(
    timestamp: datetime, positive_median: float, state: LightWatchState
) -> LightAnalysisSnapshot:
    bright_ratio = 0.1 if positive_median >= 135 else 0
    roi_stats = [
        ROIStats("topLeftEdge", ROIKind.POSITIVE, positive_median, bright_ratio, 0, 1, True, False),
        ROIStats(
            "topRightEdge", ROIKind.POSITIVE, positive_median, bright_ratio, 0, 1, True, False
        ),
        ROIStats(
            "bottomLeftEdge", ROIKind.POSITIVE, positive_median, bright_ratio, 0, 1, True, False
        ),
        ROIStats(
            "bottomRightEdge", ROIKind.POSITIVE, positive_median, bright_ratio, 0, 1, True, False
        ),
        ROIStats(
            "centerLeftGuard", ROIKind.NEGATIVE, positive_median, bright_ratio, 0, 1, True, False
        ),
    ]
    return LightAnalysisSnapshot(
        timestamp=timestamp,
        state=state,
        roiStats=roi_stats,
        sceneLevel=LightSceneLevel.from_stats(roi_stats, PersonPresence(0)),
    )


def test_confirms_on_after_continuous_on_evidence() -> None:
    settings = LightWatchSettings.default()
    settings.onConfirmSec = 10
    state_machine = StateMachine(settings, LightWatchState.DARK)
    start = datetime(2026, 1, 1, tzinfo=UTC)

    assert state_machine.handle(make_snapshot(start, 90, LightWatchState.DARK)) == []
    first_events = state_machine.handle(
        make_snapshot(start + timedelta(seconds=1), 150, LightWatchState.DARK)
    )
    assert first_events[0].event == "on_candidate"

    state_machine.handle(
        make_snapshot(start + timedelta(seconds=5), 152, LightWatchState.ON_CANDIDATE)
    )
    state_machine.handle(
        make_snapshot(start + timedelta(seconds=8), 153, LightWatchState.ON_CANDIDATE)
    )
    final_events = state_machine.handle(
        make_snapshot(start + timedelta(seconds=12), 154, LightWatchState.ON_CANDIDATE)
    )

    assert state_machine.currentState == LightWatchState.BRIGHT
    assert final_events[0].event == "notify_on"
    assert final_events[0].notification is not None
    assert final_events[0].notification.title == "🟢人がいます"


def test_confirms_off_after_continuous_off_evidence() -> None:
    settings = LightWatchSettings.default()
    settings.offConfirmSec = 10
    state_machine = StateMachine(settings, LightWatchState.BRIGHT)
    start = datetime(2026, 1, 1, tzinfo=UTC)

    state_machine.handle(make_snapshot(start, 155, LightWatchState.BRIGHT))
    first_events = state_machine.handle(
        make_snapshot(start + timedelta(seconds=1), 90, LightWatchState.BRIGHT)
    )
    assert first_events[0].event == "off_candidate"

    state_machine.handle(
        make_snapshot(start + timedelta(seconds=5), 88, LightWatchState.OFF_CANDIDATE)
    )
    state_machine.handle(
        make_snapshot(start + timedelta(seconds=8), 87, LightWatchState.OFF_CANDIDATE)
    )
    final_events = state_machine.handle(
        make_snapshot(start + timedelta(seconds=12), 86, LightWatchState.OFF_CANDIDATE)
    )

    assert state_machine.currentState == LightWatchState.DARK
    assert final_events[0].event == "notify_off"
    assert final_events[0].notification is not None
    assert final_events[0].notification.title == "⚪人がいません"
