from __future__ import annotations

import subprocess
from collections.abc import Callable

from AppKit import (
    NSBackingStoreBuffered,
    NSButton,
    NSControlStateValueOff,
    NSControlStateValueOn,
    NSMakeRect,
    NSTextField,
    NSWindow,
    NSWindowStyleMaskClosable,
    NSWindowStyleMaskTitled,
)
from Foundation import NSObject

from lightwatch.macos import set_launch_at_login
from lightwatch.models import LightWatchSettings
from lightwatch.settings import SettingsValidationError, apply_number_fields


class SettingsWindow(NSObject):
    def initWithSettings_onSave_(self, settings, on_save):
        self = super().init()
        if self is None:
            return None
        self.settings = settings
        self.on_save = on_save
        self.window = None
        self.fields = {}
        self.errorLabel = None
        self.launchCheckbox = None
        return self

    @classmethod
    def create(
        cls, settings: LightWatchSettings, on_save: Callable[[LightWatchSettings], None]
    ) -> SettingsWindow:
        return cls.alloc().initWithSettings_onSave_(settings, on_save)

    def open(self) -> None:
        if self.window is not None:
            self.window.makeKeyAndOrderFront_(None)
            return
        self.window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            NSMakeRect(0, 0, 700, 520),
            NSWindowStyleMaskTitled | NSWindowStyleMaskClosable,
            NSBackingStoreBuffered,
            False,
        )
        self.window.setTitle_("LightWatch設定")
        self.window.center()
        content_view = self.window.contentView()
        self._build_form(content_view)
        self.window.makeKeyAndOrderFront_(None)

    def _build_form(self, content_view) -> None:
        rows = [
            ("Webhook URL", "discordWebhookURL", self.settings.discordWebhookURL),
            ("カメラ番号", "cameraUniqueID", self.settings.cameraUniqueID),
            ("取得間隔", "captureIntervalSec", str(int(self.settings.captureIntervalSec))),
            ("ON確認", "onConfirmSec", str(int(self.settings.onConfirmSec))),
            ("OFF確認", "offConfirmSec", str(int(self.settings.offConfirmSec))),
            ("ON差分しきい値", "minDeltaOn", str(int(self.settings.minDeltaOn))),
            ("OFF差分しきい値", "minDeltaOff", str(int(self.settings.minDeltaOff))),
            (
                "必要positive ROI数",
                "requiredPositiveROICount",
                str(self.settings.requiredPositiveROICount),
            ),
        ]
        y = 456
        for label_text, key, value in rows:
            label = self._label(label_text, 24, y)
            field = self._field(value, 180, y - 4, 440)
            content_view.addSubview_(label)
            content_view.addSubview_(field)
            self.fields[key] = field
            y -= 42

        self.launchCheckbox = NSButton.alloc().initWithFrame_(NSMakeRect(180, y - 2, 220, 24))
        self.launchCheckbox.setButtonType_(3)
        self.launchCheckbox.setTitle_("ログイン時に常駐")
        self.launchCheckbox.setState_(
            NSControlStateValueOn if self.settings.launchAtLogin else NSControlStateValueOff
        )
        content_view.addSubview_(self.launchCheckbox)

        self.errorLabel = self._label("", 24, 42)
        content_view.addSubview_(self.errorLabel)

        save_button = NSButton.alloc().initWithFrame_(NSMakeRect(580, 24, 88, 32))
        save_button.setTitle_("保存")
        save_button.setBezelStyle_(1)
        save_button.setTarget_(self)
        save_button.setAction_("save:")
        content_view.addSubview_(save_button)

    def _label(self, value: str, x: int, y: int):
        label = NSTextField.alloc().initWithFrame_(NSMakeRect(x, y, 140, 24))
        label.setStringValue_(value)
        label.setEditable_(False)
        label.setBordered_(False)
        label.setDrawsBackground_(False)
        return label

    def _field(self, value: str, x: int, y: int, width: int):
        field = NSTextField.alloc().initWithFrame_(NSMakeRect(x, y, width, 28))
        field.setStringValue_(value)
        return field

    def save_(self, _sender) -> None:
        try:
            updated_settings = apply_number_fields(
                LightWatchSettings(
                    discordWebhookURL=self.fields["discordWebhookURL"].stringValue(),
                    cameraUniqueID=self.fields["cameraUniqueID"].stringValue(),
                    launchAtLogin=self.launchCheckbox.state() == NSControlStateValueOn,
                    rois=self.settings.rois,
                ),
                {
                    "captureIntervalSec": self.fields["captureIntervalSec"].stringValue(),
                    "onConfirmSec": self.fields["onConfirmSec"].stringValue(),
                    "offConfirmSec": self.fields["offConfirmSec"].stringValue(),
                    "minDeltaOn": self.fields["minDeltaOn"].stringValue(),
                    "minDeltaOff": self.fields["minDeltaOff"].stringValue(),
                    "requiredPositiveROICount": self.fields[
                        "requiredPositiveROICount"
                    ].stringValue(),
                },
            )
            set_launch_at_login(updated_settings.launchAtLogin)
            self.settings = updated_settings
            self.errorLabel.setStringValue_("")
            self.on_save(updated_settings)
        except SettingsValidationError as error:
            self.errorLabel.setStringValue_(str(error))
        except (RuntimeError, subprocess.CalledProcessError) as error:
            self.errorLabel.setStringValue_(f"常駐設定に失敗しました: {error}")
