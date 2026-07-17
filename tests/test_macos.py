import plistlib
from pathlib import Path

import pytest

from lightwatch.macos import (
    LAUNCH_AGENT_LABEL,
    application_bundle_path,
    launch_agent_contents,
    launch_agent_path,
    set_launch_at_login,
)


def test_application_bundle_path_returns_containing_app() -> None:
    executable = Path("/Applications/LightWatch.app/Contents/MacOS/LightWatch")

    assert application_bundle_path(executable) == Path("/Applications/LightWatch.app")


def test_launch_agent_contents_starts_app_and_restarts_after_crash() -> None:
    executable = Path("/Applications/LightWatch.app/Contents/MacOS/LightWatch")

    assert launch_agent_contents(executable) == {
        "Label": LAUNCH_AGENT_LABEL,
        "ProgramArguments": [str(executable)],
        "RunAtLoad": True,
        "KeepAlive": {"Crashed": True},
        "ProcessType": "Background",
    }


def test_launch_agent_path_uses_current_users_library() -> None:
    assert launch_agent_path(Path("/Users/lightwatch")) == Path(
        "/Users/lightwatch/Library/LaunchAgents/dev.akaaku.LightWatch.plist"
    )


def test_set_launch_at_login_rejects_non_app_executable() -> None:
    with pytest.raises(RuntimeError, match="配布済みのLightWatch.appから設定してください。"):
        set_launch_at_login(True, executable=Path("/usr/local/bin/lightwatch"))


def test_set_launch_at_login_writes_and_loads_launch_agent(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    commands: list[list[str]] = []
    executable = Path("/Applications/LightWatch.app/Contents/MacOS/LightWatch")
    monkeypatch.setattr(
        "lightwatch.macos.subprocess.run",
        lambda command, check: commands.append(command),
    )

    set_launch_at_login(True, executable=executable, home_directory=tmp_path, user_id=501)

    plist_path = launch_agent_path(tmp_path)
    with plist_path.open("rb") as file:
        assert plistlib.load(file) == launch_agent_contents(executable)
    assert commands == [
        ["launchctl", "bootout", "gui/501", str(plist_path)],
        ["launchctl", "bootstrap", "gui/501", str(plist_path)],
    ]
