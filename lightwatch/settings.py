from __future__ import annotations

import json
from dataclasses import asdict
from pathlib import Path

from lightwatch.models import LightROI, LightWatchSettings, ROIKind


class SettingsValidationError(ValueError):
    pass


class SettingsStore:
    def __init__(self) -> None:
        self.applicationSupportDirectory = (
            Path.home() / "Library" / "Application Support" / "LightWatch"
        )
        self.logsDirectory = self.applicationSupportDirectory / "logs"
        self.configPath = self.applicationSupportDirectory / "config.json"

    def load(self) -> LightWatchSettings:
        self.ensure_directories()
        if not self.configPath.exists():
            settings = LightWatchSettings.default()
            self.save(settings)
            return settings
        with self.configPath.open(encoding="utf-8") as file:
            raw_settings = json.load(file)
        settings = settings_from_json(raw_settings).normalized()
        self.save(settings)
        return settings

    def save(self, settings: LightWatchSettings) -> None:
        self.ensure_directories()
        with self.configPath.open("w", encoding="utf-8") as file:
            json.dump(
                settings_to_json(settings), file, ensure_ascii=False, indent=2, sort_keys=True
            )
            file.write("\n")

    def ensure_directories(self) -> None:
        self.applicationSupportDirectory.mkdir(parents=True, exist_ok=True)
        self.logsDirectory.mkdir(parents=True, exist_ok=True)


def settings_from_json(raw_settings: dict[str, object]) -> LightWatchSettings:
    default = LightWatchSettings.default()
    rois = [
        LightROI(
            name=str(raw_roi["name"]),
            kind=ROIKind(str(raw_roi["kind"])),
            x=float(raw_roi["x"]),
            y=float(raw_roi["y"]),
            width=float(raw_roi["width"]),
            height=float(raw_roi["height"]),
        )
        for raw_roi in raw_settings.get("rois", [])
        if isinstance(raw_roi, dict)
    ]
    return LightWatchSettings(
        discordWebhookURL=str(raw_settings.get("discordWebhookURL", default.discordWebhookURL)),
        cameraUniqueID=str(raw_settings.get("cameraUniqueID", default.cameraUniqueID)),
        launchAtLogin=bool(raw_settings.get("launchAtLogin", default.launchAtLogin)),
        captureIntervalSec=float(
            raw_settings.get("captureIntervalSec", default.captureIntervalSec)
        ),
        onConfirmSec=float(raw_settings.get("onConfirmSec", default.onConfirmSec)),
        offConfirmSec=float(raw_settings.get("offConfirmSec", default.offConfirmSec)),
        minDeltaOn=float(raw_settings.get("minDeltaOn", default.minDeltaOn)),
        minDeltaOff=float(raw_settings.get("minDeltaOff", default.minDeltaOff)),
        requiredPositiveROICount=int(
            raw_settings.get("requiredPositiveROICount", default.requiredPositiveROICount)
        ),
        rois=rois or default.rois,
    )


def settings_to_json(settings: LightWatchSettings) -> dict[str, object]:
    raw_settings = asdict(settings)
    raw_settings["rois"] = [
        {
            "name": roi.name,
            "kind": roi.kind.value,
            "x": roi.x,
            "y": roi.y,
            "width": roi.width,
            "height": roi.height,
        }
        for roi in settings.rois
    ]
    return raw_settings


def apply_number_fields(settings: LightWatchSettings, fields: dict[str, str]) -> LightWatchSettings:
    updated = LightWatchSettings(
        discordWebhookURL=settings.discordWebhookURL,
        cameraUniqueID=settings.cameraUniqueID,
        launchAtLogin=settings.launchAtLogin,
        captureIntervalSec=validated_float(fields["captureIntervalSec"], "取得間隔", 1, 30),
        onConfirmSec=validated_float(fields["onConfirmSec"], "ON確認", 1, 900),
        offConfirmSec=validated_float(fields["offConfirmSec"], "OFF確認", 1, 1800),
        minDeltaOn=validated_float(fields["minDeltaOn"], "ON差分しきい値", 1, 80),
        minDeltaOff=validated_float(fields["minDeltaOff"], "OFF差分しきい値", -80, -1),
        requiredPositiveROICount=validated_int(
            fields["requiredPositiveROICount"], "必要positive ROI数", 1, 5
        ),
        rois=settings.rois,
    )
    return updated


def validated_float(text: str, name: str, lower: float, upper: float) -> float:
    try:
        value = float(text.strip())
    except ValueError as error:
        raise SettingsValidationError(f"{name}は数値で入力してください。") from error
    if not lower <= value <= upper:
        raise SettingsValidationError(
            f"{name}は{format_number(lower)}から{format_number(upper)}の範囲で入力してください。"
        )
    return value


def validated_int(text: str, name: str, lower: int, upper: int) -> int:
    try:
        value = int(text.strip())
    except ValueError as error:
        raise SettingsValidationError(f"{name}は数値で入力してください。") from error
    if not lower <= value <= upper:
        raise SettingsValidationError(f"{name}は{lower}から{upper}の範囲で入力してください。")
    return value


def format_number(value: float) -> str:
    return str(int(value)) if value == int(value) else str(value)
