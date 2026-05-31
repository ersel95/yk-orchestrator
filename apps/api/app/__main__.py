"""
PyInstaller binary entry point.

Swift kabuk bunu şu şekilde çağıracak:
    ykorch-api --port 49152 --host 127.0.0.1

Dev modunda hâlâ `python -m app` veya `uvicorn app.main:app` çalışır.
"""

from __future__ import annotations

import argparse
import sys

import uvicorn

from app.core.paths import is_frozen, user_log_dir


def _parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(prog="ykorch-api")
    p.add_argument("--host", default=None, help="Bind host (default: settings.api_host)")
    p.add_argument("--port", type=int, default=None, help="Bind port (default: settings.api_port)")
    p.add_argument("--version", action="store_true", help="Print version and exit")
    return p.parse_args()


def main() -> int:
    args = _parse_args()

    if args.version:
        from app.main import app

        print(app.version)
        return 0

    # Settings'i argv'den önce yükleme — pydantic-settings ENV'i okurken
    # log dizininin var olduğundan emin olalım
    user_log_dir()

    from app.core.config import get_settings

    s = get_settings()
    host = args.host or s.api_host
    port = args.port or s.api_port

    if is_frozen():
        # Frozen binary: doğrudan app instance, reload kapalı (string import yok)
        from app.main import app

        uvicorn.run(app, host=host, port=port, log_level=s.log_level.lower())
    else:
        # Dev mode: string import, reload açık olabilir
        uvicorn.run(
            "app.main:app",
            host=host,
            port=port,
            reload=s.app_env == "local",
            log_level=s.log_level.lower(),
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
