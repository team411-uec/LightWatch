from __future__ import annotations

import sys


def main() -> None:
    if sys.platform == "darwin":
        from lightwatch.app import main as run
    elif sys.platform.startswith("linux"):
        from lightwatch.headless import main as run
    else:
        raise RuntimeError(f"未対応のOSです: {sys.platform}")
    run()


if __name__ == "__main__":
    main()
