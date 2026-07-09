from __future__ import annotations

import os
import subprocess
from pathlib import Path


class PowerAssertion:
    def __init__(self) -> None:
        self.process: subprocess.Popen[bytes] | None = None

    def start(self) -> None:
        if self.process is not None and self.process.poll() is None:
            return
        self.process = subprocess.Popen(["caffeinate", "-dimsu"])

    def stop(self) -> None:
        if self.process is None:
            return
        if self.process.poll() is None:
            self.process.terminate()
        self.process = None


def set_launch_at_login(enabled: bool) -> None:
    app_path = Path(os.environ.get("LIGHTWATCH_APP_PATH", "")).expanduser()
    if not app_path.exists():
        return
    script = (
        'tell application "System Events" to make login item at end with properties '
        f'{{path:"{app_path}", hidden:false}}'
        if enabled
        else f'tell application "System Events" to delete login item "{app_path.stem}"'
    )
    subprocess.run(["osascript", "-e", script], check=True)


def open_path(path: Path) -> None:
    subprocess.run(["open", str(path)], check=False)
