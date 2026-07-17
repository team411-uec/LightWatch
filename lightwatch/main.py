from __future__ import annotations

import sys
import traceback

from lightwatch.logger import EventLogger
from lightwatch.settings import default_application_support_directory


def log_startup_failure() -> None:
    logger = EventLogger(default_application_support_directory())
    logger.log_error(f"起動に失敗しました。\n{traceback.format_exc()}")


def main() -> None:
    try:
        if sys.platform == "darwin":
            from lightwatch.app import main as run
        elif sys.platform.startswith("linux"):
            from lightwatch.headless import main as run
        else:
            raise RuntimeError(f"未対応のOSです: {sys.platform}")
        run()
    except Exception:
        log_startup_failure()
        raise


if __name__ == "__main__":
    main()
