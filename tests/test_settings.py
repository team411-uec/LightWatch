from lightwatch.models import LightWatchSettings, ROIKind
from lightwatch.settings import (
    SettingsValidationError,
    apply_number_fields,
    settings_from_json,
    settings_to_json,
)


def test_settings_json_keeps_existing_keys() -> None:
    settings = LightWatchSettings.default()

    raw_settings = settings_to_json(settings)
    restored = settings_from_json(raw_settings)

    assert restored.discordWebhookURL == settings.discordWebhookURL
    assert restored.requiredPositiveROICount == settings.requiredPositiveROICount
    assert restored.rois[0].kind == ROIKind.POSITIVE


def test_settings_normalized_adds_guard_rois_for_old_config() -> None:
    settings = LightWatchSettings.default()
    settings.rois = [roi for roi in settings.rois if roi.kind == ROIKind.POSITIVE]

    normalized = settings.normalized()

    assert any(roi.kind == ROIKind.NEGATIVE for roi in normalized.rois)


def test_number_fields_reject_out_of_range_value() -> None:
    settings = LightWatchSettings.default()

    try:
        apply_number_fields(
            settings,
            {
                "captureIntervalSec": "0",
                "onConfirmSec": "45",
                "offConfirmSec": "45",
                "minDeltaOn": "18",
                "minDeltaOff": "-18",
                "requiredPositiveROICount": "3",
            },
        )
    except SettingsValidationError as error:
        assert str(error) == "取得間隔は1から30の範囲で入力してください。"
    else:
        raise AssertionError("SettingsValidationErrorが発生しませんでした。")
