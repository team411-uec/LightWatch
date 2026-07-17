from __future__ import annotations

import os
import plistlib
import subprocess
import sys
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


LAUNCH_AGENT_LABEL = "dev.akaaku.LightWatch"


def application_bundle_path(executable: Path) -> Path | None:
    for parent in executable.resolve().parents:
        if parent.suffix == ".app":
            return parent
    return None


def launch_agent_path(home_directory: Path) -> Path:
    return home_directory / "Library" / "LaunchAgents" / f"{LAUNCH_AGENT_LABEL}.plist"


def launch_agent_contents(executable: Path) -> dict[str, object]:
    return {
        "Label": LAUNCH_AGENT_LABEL,
        "ProgramArguments": [str(executable)],
        "RunAtLoad": True,
        "KeepAlive": {"Crashed": True},
        "ProcessType": "Background",
    }


def set_launch_at_login(
    enabled: bool,
    executable: Path | None = None,
    home_directory: Path | None = None,
    user_id: int | None = None,
) -> None:
    current_executable = executable or Path(sys.executable)
    app_path = application_bundle_path(current_executable)
    if app_path is None:
        raise RuntimeError("配布済みのLightWatch.appから設定してください。")

    plist_path = launch_agent_path(home_directory or Path.home())
    if not enabled:
        domain = f"gui/{user_id if user_id is not None else os.getuid()}"
        subprocess.run(["launchctl", "bootout", domain, str(plist_path)], check=False)
        plist_path.unlink(missing_ok=True)
        return

    plist_path.parent.mkdir(parents=True, exist_ok=True)
    with plist_path.open("wb") as file:
        plistlib.dump(launch_agent_contents(current_executable), file)


def open_path(path: Path) -> None:
    subprocess.run(["open", str(path)], check=False)
