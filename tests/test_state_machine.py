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
    timestamp: datetime,
    positive_median: float,
    state: LightWatchState,
    person_masked_ratio: float = 0,
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
        sceneLevel=LightSceneLevel.from_stats(roi_stats, PersonPresence(person_masked_ratio)),
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

    final_events = []
    for second in range(2, 12):
        final_events = state_machine.handle(
            make_snapshot(start + timedelta(seconds=second), 152, LightWatchState.ON_CANDIDATE)
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

    final_events = []
    for second in range(2, 12):
        final_events = state_machine.handle(
            make_snapshot(start + timedelta(seconds=second), 88, LightWatchState.OFF_CANDIDATE)
        )

    assert state_machine.currentState == LightWatchState.DARK
    assert final_events[0].event == "notify_off"
    assert final_events[0].notification is not None
    assert final_events[0].notification.title == "⚪人がいません"


def test_bright_scene_at_start_is_not_missed() -> None:
    state_machine = StateMachine(LightWatchSettings.default(), LightWatchState.DARK)
    start = datetime(2026, 1, 1, tzinfo=UTC)

    events = state_machine.handle(make_snapshot(start, 150, LightWatchState.DARK))

    assert state_machine.currentState == LightWatchState.ON_CANDIDATE
    assert events[0].event == "on_candidate"
    assert events[0].values["bootstrap_on_evidence"] == 1


def test_exact_on_delta_is_not_absorbed_into_reference() -> None:
    settings = LightWatchSettings.default()
    state_machine = StateMachine(settings, LightWatchState.DARK)
    start = datetime(2026, 1, 1, tzinfo=UTC)
    state_machine.handle(make_snapshot(start, 130, LightWatchState.DARK))

    events = state_machine.handle(
        make_snapshot(start + timedelta(seconds=1), 148, LightWatchState.DARK)
    )

    assert state_machine.currentState == LightWatchState.ON_CANDIDATE
    assert events[0].event == "on_candidate"


def test_exact_off_delta_is_not_absorbed_into_reference() -> None:
    settings = LightWatchSettings.default()
    state_machine = StateMachine(settings, LightWatchState.BRIGHT)
    start = datetime(2026, 1, 1, tzinfo=UTC)
    state_machine.handle(make_snapshot(start, 148, LightWatchState.BRIGHT))

    events = state_machine.handle(
        make_snapshot(start + timedelta(seconds=1), 130, LightWatchState.BRIGHT)
    )

    assert state_machine.currentState == LightWatchState.OFF_CANDIDATE
    assert events[0].event == "off_candidate"


def test_person_presence_prevents_off_candidate() -> None:
    state_machine = StateMachine(LightWatchSettings.default(), LightWatchState.BRIGHT)
    start = datetime(2026, 1, 1, tzinfo=UTC)
    state_machine.handle(make_snapshot(start, 150, LightWatchState.BRIGHT))

    events = state_machine.handle(
        make_snapshot(
            start + timedelta(seconds=1),
            90,
            LightWatchState.BRIGHT,
            person_masked_ratio=0.02,
        )
    )

    assert events == []
    assert state_machine.currentState == LightWatchState.BRIGHT


def test_does_not_confirm_on_across_frame_gap() -> None:
    settings = LightWatchSettings.default()
    settings.onConfirmSec = 10
    state_machine = StateMachine(settings, LightWatchState.DARK)
    start = datetime(2026, 1, 1, tzinfo=UTC)
    state_machine.handle(make_snapshot(start, 90, LightWatchState.DARK))
    state_machine.handle(make_snapshot(start + timedelta(seconds=1), 150, LightWatchState.DARK))
    state_machine.handle(
        make_snapshot(start + timedelta(seconds=2), 150, LightWatchState.ON_CANDIDATE)
    )
    state_machine.handle(
        make_snapshot(start + timedelta(seconds=3), 150, LightWatchState.ON_CANDIDATE)
    )

    events = state_machine.handle(
        make_snapshot(start + timedelta(seconds=11), 150, LightWatchState.ON_CANDIDATE)
    )

    assert events == []
    assert state_machine.currentState == LightWatchState.ON_CANDIDATE
