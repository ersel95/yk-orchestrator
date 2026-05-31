"""TestFlightAgent — Fastlane ile build ve TestFlight upload (proje bazlı)."""
from __future__ import annotations

from collections.abc import AsyncIterator
from pathlib import Path

from app.core.active_project import get_project, resolve_project_id
from app.core.logging import get_logger
from app.integrations.fastlane_runner import FastlaneRunner

log = get_logger(__name__)


class TestFlightAgent:
    def _runner(self, project_id: int | None = None) -> FastlaneRunner:
        pid = resolve_project_id(project_id)
        proj = get_project(pid)
        runner = FastlaneRunner()
        if proj.fastlane_project_dir:
            runner.project_dir = Path(proj.fastlane_project_dir)
        if proj.fastlane_lane:
            runner.lane = proj.fastlane_lane
        return runner

    def is_configured(self, project_id: int | None = None) -> bool:
        return self._runner(project_id).is_configured()

    async def upload(
        self, project_id: int | None = None, lane: str | None = None
    ) -> AsyncIterator[str]:
        runner = self._runner(project_id)
        async for line in runner.run_lane(lane=lane):
            yield line
