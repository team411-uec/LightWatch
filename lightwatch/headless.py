from __future__ import annotations

import signal
import threading
from types import FrameType

import cv2
import numpy as np

from lightwatch.camera import camera_index
from lightwatch.processor import FrameProcessor
from lightwatch.settings import SettingsStore


class HeadlessLightWatch:
    def __init__(self) -> None:
        self.settingsStore = SettingsStore()
        self.settings = self.settingsStore.load()
        self.processor = FrameProcessor(
            self.settings, self.settingsStore.applicationSupportDirectory
        )
        self.stopEvent = threading.Event()

    def run(self) -> None:
        capture = cv2.VideoCapture(camera_index(self.settings.cameraUniqueID))
        if not capture.isOpened():
            raise RuntimeError("カメラ開始に失敗しました: Webカメラが見つかりません。")
        try:
            while not self.stopEvent.is_set():
                ok, frame = capture.read()
                if not ok:
                    self.processor.logger.log_error("フレームの取得に失敗しました。")
                else:
                    self.handle_frame(frame)
                self.stopEvent.wait(self.settings.captureIntervalSec)
        finally:
            capture.release()

    def stop(self, _signal_number: int, _frame: FrameType | None) -> None:
        self.stopEvent.set()

    def handle_frame(self, frame: np.ndarray) -> None:
        self.processor.handle_frame(frame)


def main() -> None:
    app = HeadlessLightWatch()
    signal.signal(signal.SIGINT, app.stop)
    signal.signal(signal.SIGTERM, app.stop)
    app.run()


if __name__ == "__main__":
    main()
