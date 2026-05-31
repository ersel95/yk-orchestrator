"""Fastlane ile TestFlight upload runner.

Beklenen lane (örn): `bundle exec fastlane beta`
"""
from __future__ import annotations

import asyncio
import os
from collections.abc import AsyncIterator
from pathlib import Path

from app.core.config import get_settings
from app.core.logging import get_logger

log = get_logger(__name__)


class FastlaneRunner:
    def __init__(self) -> None:
        s = get_settings()
        self.project_dir = Path(s.fastlane_project_dir or s.local_repo_path)
        self.lane = s.fastlane_lane

    def is_configured(self) -> bool:
        return self.project_dir.exists() and (self.project_dir / "fastlane").exists()

    async def run_lane(self, lane: str | None = None, env: dict[str, str] | None = None) -> AsyncIterator[str]:
        lane = lane or self.lane
        if not self.is_configured():
            yield f"[ERR] Fastlane bulunamadı: {self.project_dir}"
            return

        cmd = ["bundle", "exec", "fastlane", lane]
        log.info(f"Fastlane çalıştırılıyor: {' '.join(cmd)} cwd={self.project_dir}")

        process_env = os.environ.copy()
        if env:
            process_env.update(env)

        proc = await asyncio.create_subprocess_exec(
            *cmd,
            cwd=str(self.project_dir),
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            env=process_env,
        )
        assert proc.stdout is not None
        async for line in proc.stdout:
            yield line.decode("utf-8", errors="replace").rstrip()
        rc = await proc.wait()
        yield f"[EXIT] {rc}"


def get_fastlane() -> FastlaneRunner:
    return FastlaneRunner()
