from __future__ import annotations

import threading
import time
from collections.abc import Callable
from dataclasses import dataclass

import cv2
import numpy as np


@dataclass(frozen=True)
class CameraDeviceOption:
    id: str
    name: str


class CameraDeviceCatalog:
    @staticmethod
    def available_options(max_index: int = 8) -> list[CameraDeviceOption]:
        options: list[CameraDeviceOption] = []
        for index in range(max_index):
            capture = cv2.VideoCapture(index)
            if capture.isOpened():
                options.append(CameraDeviceOption(str(index), f"Camera {index}"))
            capture.release()
        return options


class CameraManager:
    def __init__(
        self,
        capture_interval: float,
        camera_unique_id: str,
        on_frame: Callable[[np.ndarray], None],
        on_error: Callable[[str], None],
    ) -> None:
        self.capture_interval = capture_interval
        self.camera_unique_id = camera_unique_id
        self.on_frame = on_frame
        self.on_error = on_error
        self.stop_event = threading.Event()
        self.thread: threading.Thread | None = None
        self.capture: cv2.VideoCapture | None = None

    def start(self) -> None:
        if self.thread and self.thread.is_alive():
            return
        self.stop_event.clear()
        self.thread = threading.Thread(target=self._run, name="LightWatchCamera", daemon=True)
        self.thread.start()

    def stop(self) -> None:
        self.stop_event.set()
        if self.thread and self.thread.is_alive():
            self.thread.join(timeout=2)
        if self.capture is not None:
            self.capture.release()
            self.capture = None

    def update(self, capture_interval: float, camera_unique_id: str) -> None:
        restart_required = self.camera_unique_id != camera_unique_id
        self.capture_interval = capture_interval
        self.camera_unique_id = camera_unique_id
        if restart_required:
            self.stop()
            self.start()

    def _run(self) -> None:
        camera_index = self._camera_index()
        self.capture = cv2.VideoCapture(camera_index)
        if not self.capture.isOpened():
            self.on_error("カメラ開始に失敗しました: Webカメラが見つかりません。")
            return
        while not self.stop_event.is_set():
            ok, frame = self.capture.read()
            if not ok:
                self.on_error("フレームの取得に失敗しました。")
                time.sleep(self.capture_interval)
                continue
            self.on_frame(frame)
            time.sleep(self.capture_interval)

    def _camera_index(self) -> int:
        return camera_index(self.camera_unique_id)


def camera_index(camera_unique_id: str) -> int:
    if camera_unique_id.strip() == "":
        return 0
    try:
        return int(camera_unique_id)
    except ValueError:
        return 0
