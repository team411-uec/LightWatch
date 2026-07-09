from __future__ import annotations

import subprocess
import tkinter as tk
from collections.abc import Callable
from tkinter import ttk

from lightwatch.camera import CameraDeviceCatalog
from lightwatch.macos import set_launch_at_login
from lightwatch.models import LightWatchSettings
from lightwatch.settings import SettingsValidationError, apply_number_fields


class SettingsWindow:
    def __init__(
        self, settings: LightWatchSettings, on_save: Callable[[LightWatchSettings], None]
    ) -> None:
        self.settings = settings
        self.on_save = on_save
        self.window: tk.Tk | None = None

    def open(self) -> None:
        if self.window is not None and self.window.winfo_exists():
            self.window.lift()
            return
        self.window = tk.Tk()
        self.window.title("LightWatch設定")
        self.window.geometry("700x520")
        self.window.resizable(False, False)

        notebook = ttk.Notebook(self.window)
        general_frame = ttk.Frame(notebook, padding=24)
        detection_frame = ttk.Frame(notebook, padding=24)
        notebook.add(general_frame, text="一般")
        notebook.add(detection_frame, text="判定")
        notebook.pack(fill="both", expand=True)

        webhook_var = tk.StringVar(value=self.settings.discordWebhookURL)
        camera_var = tk.StringVar(value=self.settings.cameraUniqueID)
        launch_var = tk.BooleanVar(value=self.settings.launchAtLogin)
        number_vars = {
            "captureIntervalSec": tk.StringVar(value=str(int(self.settings.captureIntervalSec))),
            "onConfirmSec": tk.StringVar(value=str(int(self.settings.onConfirmSec))),
            "offConfirmSec": tk.StringVar(value=str(int(self.settings.offConfirmSec))),
            "minDeltaOn": tk.StringVar(value=str(int(self.settings.minDeltaOn))),
            "minDeltaOff": tk.StringVar(value=str(int(self.settings.minDeltaOff))),
            "requiredPositiveROICount": tk.StringVar(
                value=str(self.settings.requiredPositiveROICount)
            ),
        }
        error_var = tk.StringVar(value="")

        self._row(
            general_frame,
            "Webhook URL",
            ttk.Entry(general_frame, textvariable=webhook_var, width=58),
            0,
        )
        camera_box = ttk.Combobox(general_frame, textvariable=camera_var, width=28)
        camera_box["values"] = [""] + [
            option.id for option in CameraDeviceCatalog.available_options()
        ]
        self._row(general_frame, "カメラ", camera_box, 1)
        ttk.Checkbutton(general_frame, text="ログイン時に起動", variable=launch_var).grid(
            row=2, column=1, sticky="w", pady=12
        )

        labels = [
            ("取得間隔", "captureIntervalSec", "秒"),
            ("ON確認", "onConfirmSec", "秒"),
            ("OFF確認", "offConfirmSec", "秒"),
            ("ON差分しきい値", "minDeltaOn", ""),
            ("OFF差分しきい値", "minDeltaOff", ""),
            ("必要positive ROI数", "requiredPositiveROICount", ""),
        ]
        for row_index, (label, key, suffix) in enumerate(labels):
            entry = ttk.Entry(detection_frame, textvariable=number_vars[key], width=12)
            self._row(detection_frame, f"{label}{suffix}", entry, row_index)

        footer = ttk.Frame(self.window, padding=(24, 12))
        footer.pack(fill="x")
        ttk.Label(footer, textvariable=error_var, foreground="red").pack(side="left")

        def save() -> None:
            try:
                updated_settings = apply_number_fields(
                    LightWatchSettings(
                        discordWebhookURL=webhook_var.get(),
                        cameraUniqueID=camera_var.get(),
                        launchAtLogin=launch_var.get(),
                        rois=self.settings.rois,
                    ),
                    {key: value.get() for key, value in number_vars.items()},
                )
                set_launch_at_login(updated_settings.launchAtLogin)
                self.settings = updated_settings
                error_var.set("")
                self.on_save(updated_settings)
            except SettingsValidationError as error:
                error_var.set(str(error))
            except subprocess.CalledProcessError as error:
                error_var.set(f"ログイン項目設定に失敗しました: {error}")

        ttk.Button(footer, text="保存", command=save).pack(side="right")
        self.window.mainloop()

    def _row(self, parent: ttk.Frame, title: str, widget: ttk.Widget, row: int) -> None:
        ttk.Label(parent, text=title, width=20, anchor="e").grid(
            row=row, column=0, sticky="e", padx=(0, 16), pady=8
        )
        widget.grid(row=row, column=1, sticky="w", pady=8)
