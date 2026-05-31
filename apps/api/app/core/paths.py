"""
Runtime path resolver.

İki çalışma modu:
- Dev: kaynak ağacı içinden çalışıyor → veri/log/config repo'daki `apps/api/data/...`
- Bundled: PyInstaller tek-dosya binary → `~/Library/Application Support/YK Orchestrator/`

Algılama: `sys.frozen` (PyInstaller'ın işaretlediği) + `YKORCH_DEV` ENV override.
"""

from __future__ import annotations

import os
import sys
from functools import lru_cache
from pathlib import Path

APP_BUNDLE_ID = "com.yapikredi.ykorchestrator"
APP_NAME = "YK Orchestrator"


def is_frozen() -> bool:
    if os.environ.get("YKORCH_DEV") == "1":
        return False
    return getattr(sys, "frozen", False)


@lru_cache
def repo_root() -> Path:
    """Dev modunda repo kökü (apps/api/app/core/paths.py → 4 yukarı)."""
    return Path(__file__).resolve().parents[3].parent


@lru_cache
def user_data_dir() -> Path:
    """Bundled modda Application Support, dev modda repo data/."""
    if is_frozen():
        base = Path.home() / "Library" / "Application Support" / APP_NAME
    else:
        base = repo_root() / "apps" / "api" / "data"
    base.mkdir(parents=True, exist_ok=True)
    return base


@lru_cache
def user_log_dir() -> Path:
    if is_frozen():
        base = Path.home() / "Library" / "Logs" / APP_NAME
    else:
        base = repo_root() / "logs"
    base.mkdir(parents=True, exist_ok=True)
    return base


@lru_cache
def user_config_path() -> Path:
    """config.json yolu — wizard tarafından üretilir, runtime'da okunur."""
    return user_data_dir() / "config.json"


@lru_cache
def sqlite_path() -> Path:
    return user_data_dir() / "orchestrator.db"


@lru_cache
def chroma_dir() -> Path:
    p = user_data_dir() / "chroma"
    p.mkdir(parents=True, exist_ok=True)
    return p


@lru_cache
def env_file_path() -> Path | None:
    """Dev modda repo'daki .env (varsa). Bundled modda yok."""
    if is_frozen():
        return None
    candidate = repo_root() / ".env"
    return candidate if candidate.exists() else None
