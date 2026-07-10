from __future__ import annotations

from pathlib import Path

import numpy as np

from lightwatch.analyzer import LightAnalyzer
from lightwatch.logger import EventLogger
from lightwatch.models import LightWatchSettings, LightWatchState
from lightwatch.state_machine import StateMachine
from lightwatch.webhook import DiscordWebhookClient


class FrameProcessor:
    def __init__(self, settings: LightWatchSettings, application_support_directory: Path) -> None:
        self.settings = settings
        self.logger = EventLogger(application_support_directory)
        self.analyzer = LightAnalyzer(settings.rois)
        self.stateMachine = StateMachine(settings, LightWatchState.DARK)
        self.webhookClient = DiscordWebhookClient(lambda: self.settings)

    def update(self, settings: LightWatchSettings) -> None:
        self.settings = settings
        self.analyzer = LightAnalyzer(settings.rois)
        self.stateMachine.update(settings)

    def handle_frame(self, frame: np.ndarray) -> None:
        try:
            snapshot = self.analyzer.analyze(frame, self.stateMachine.currentState)
            self.logger.log_snapshot(snapshot)
            events = self.stateMachine.handle(snapshot)
        except Exception as error:
            self.logger.log_error(f"フレーム解析に失敗しました: {error}")
            return
        for event in events:
            self.logger.log_event(event)
            if event.notification is None:
                continue
            try:
                self.webhookClient.send(event.notification)
            except Exception as error:
                self.logger.log_error(f"Discord Webhook送信に失敗しました: {error}")
