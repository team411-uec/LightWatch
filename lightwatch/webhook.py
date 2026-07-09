from __future__ import annotations

from collections.abc import Callable
from urllib.parse import urlparse

import requests

from lightwatch.models import DiscordNotification, LightWatchSettings


class DiscordWebhookError(ValueError):
    pass


class DiscordWebhookClient:
    suppressNotificationsFlag = 1 << 12

    def __init__(self, settings_provider: Callable[[], LightWatchSettings]) -> None:
        self.settings_provider = settings_provider

    def send(self, notification: DiscordNotification) -> None:
        settings = self.settings_provider()
        parsed_url = urlparse(settings.discordWebhookURL)
        if parsed_url.scheme != "https" or not parsed_url.netloc:
            raise DiscordWebhookError("Discord Webhook URLが未設定またはHTTPSではありません。")
        response = requests.post(
            settings.discordWebhookURL,
            json={"content": notification.title, "flags": self.suppressNotificationsFlag},
            timeout=10,
        )
        if not 200 <= response.status_code <= 299:
            raise DiscordWebhookError("Discord Webhookが成功以外のHTTPステータスを返しました。")
