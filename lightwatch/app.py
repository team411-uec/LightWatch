from __future__ import annotations

import threading

import rumps

from lightwatch.analyzer import LightAnalyzer
from lightwatch.camera import CameraManager
from lightwatch.logger import EventLogger
from lightwatch.macos import PowerAssertion, open_path
from lightwatch.models import LightWatchSettings, LightWatchState
from lightwatch.settings import SettingsStore
from lightwatch.settings_window import SettingsWindow
from lightwatch.state_machine import StateMachine
from lightwatch.webhook import DiscordWebhookClient


class LightWatchApp(rumps.App):
    def __init__(self) -> None:
        super().__init__("LightWatch", icon=None, quit_button=None)
        self.settingsStore = SettingsStore()
        self.settings = self.settingsStore.load()
        self.logger = EventLogger(self.settingsStore.applicationSupportDirectory)
        self.analyzer = LightAnalyzer(self.settings.rois)
        self.stateMachine = StateMachine(self.settings, LightWatchState.DARK)
        self.webhookClient = DiscordWebhookClient(lambda: self.settings)
        self.powerAssertion = PowerAssertion()
        self.stateMenuItem = rumps.MenuItem("状態: 消灯中", callback=None)
        self.cameraManager = CameraManager(
            self.settings.captureIntervalSec,
            self.settings.cameraUniqueID,
            self.handle_frame,
            self.logger.log_error,
        )
        self.paused = False
        self.menu = [
            self.stateMenuItem,
            None,
            rumps.MenuItem("一時停止", callback=self.pause),
            rumps.MenuItem("再開", callback=self.resume),
            None,
            rumps.MenuItem("ログを開く", callback=self.open_logs),
            rumps.MenuItem("設定を開く", callback=self.open_settings),
            None,
            rumps.MenuItem("終了", callback=rumps.quit_application),
        ]
        if not self.settings.discordWebhookURL.strip():
            self.logger.log_error("Discord Webhook URLが未設定です。通知は送信されません。")

    def start_monitoring(self) -> None:
        self.powerAssertion.start()
        self.cameraManager.start()

    def handle_frame(self, frame) -> None:
        try:
            snapshot = self.analyzer.analyze(frame, self.stateMachine.currentState)
            self.logger.log_snapshot(snapshot)
            events = self.stateMachine.handle(snapshot)
            self.update_state_menu()
            for event in events:
                self.logger.log_event(event)
                if event.notification is not None:
                    self.send_notification(event.notification)
        except Exception as error:
            self.logger.log_error(f"フレーム解析に失敗しました: {error}")

    def send_notification(self, notification) -> None:
        try:
            self.webhookClient.send(notification)
        except Exception as error:
            self.logger.log_error(f"Discord Webhook送信に失敗しました: {error}")

    def update_state_menu(self) -> None:
        state_title = (
            "状態: 一時停止中"
            if self.paused
            else f"状態: {self.stateMachine.currentState.display_name}"
        )
        self.stateMenuItem.title = state_title

    def pause(self, _sender) -> None:
        self.paused = True
        self.cameraManager.stop()
        self.powerAssertion.stop()
        self.update_state_menu()

    def resume(self, _sender) -> None:
        self.paused = False
        self.start_monitoring()
        self.update_state_menu()

    def open_logs(self, _sender) -> None:
        open_path(self.settingsStore.logsDirectory)

    def open_settings(self, _sender) -> None:
        window = SettingsWindow(self.settings, self.apply_settings)
        threading.Thread(target=window.open, name="LightWatchSettings", daemon=True).start()

    def apply_settings(self, updated_settings: LightWatchSettings) -> None:
        self.settings = updated_settings
        self.settingsStore.save(updated_settings)
        if not updated_settings.discordWebhookURL.strip():
            self.logger.log_error("Discord Webhook URLが未設定です。通知は送信されません。")
        self.analyzer = LightAnalyzer(updated_settings.rois)
        self.stateMachine.update(updated_settings)
        self.cameraManager.update(
            updated_settings.captureIntervalSec, updated_settings.cameraUniqueID
        )


def main() -> None:
    app = LightWatchApp()
    app.start_monitoring()
    app.run()


if __name__ == "__main__":
    main()
