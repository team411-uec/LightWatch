from __future__ import annotations

import json
from datetime import datetime
from pathlib import Path

from lightwatch.models import LightAnalysisSnapshot, LightEvent


class EventLogger:
    def __init__(self, application_support_directory: Path) -> None:
        logs_directory = application_support_directory / "logs"
        logs_directory.mkdir(parents=True, exist_ok=True)
        self.samplesPath = logs_directory / "samples.jsonl"
        self.eventsPath = logs_directory / "events.jsonl"
        self.errorsPath = logs_directory / "errors.log"

    def log_snapshot(self, snapshot: LightAnalysisSnapshot) -> None:
        scene_values: dict[str, object] = dict(snapshot.sceneLevel.values)
        scene_values["positive_roi_names"] = snapshot.sceneLevel.positiveROINames
        self._append_json(
            {
                "timestamp": snapshot.timestamp.isoformat(),
                "state": snapshot.state.value,
                "scene": scene_values,
                "rois": [
                    {
                        "name": stat.name,
                        "kind": stat.kind.value,
                        "median_luma": stat.medianLuma,
                        "bright_ratio": stat.brightRatio,
                        "dark_ratio": stat.darkRatio,
                        "observable_ratio": stat.observableRatio,
                        "is_observable": stat.isObservable,
                        "is_dark": stat.isDark,
                    }
                    for stat in snapshot.roiStats
                ],
            },
            self.samplesPath,
        )

    def log_event(self, event: LightEvent) -> None:
        event_object: dict[str, object] = {
            "timestamp": datetime.now().astimezone().isoformat(),
            "event": event.event,
            "values": event.values,
        }
        if event.state is not None:
            event_object["state"] = event.state
        if event.reason is not None:
            event_object["reason"] = event.reason
        if event.notification is not None:
            event_object["notification"] = {
                "event_name": event.notification.eventName,
                "title": event.notification.title,
                "state": event.notification.state.value,
                "reason": event.notification.reason,
                "confirm_seconds": event.notification.confirmSeconds,
            }
        self._append_json(event_object, self.eventsPath)

    def log_error(self, message: str) -> None:
        with self.errorsPath.open("a", encoding="utf-8") as file:
            file.write(f"{datetime.now().astimezone().isoformat()} {message}\n")

    def _append_json(self, value: dict[str, object], path: Path) -> None:
        with path.open("a", encoding="utf-8") as file:
            file.write(json.dumps(value, ensure_ascii=False, sort_keys=True) + "\n")
