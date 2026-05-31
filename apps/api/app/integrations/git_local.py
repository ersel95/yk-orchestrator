"""Lokal git repo işlemleri (git log, branch, diff)."""
from __future__ import annotations

from datetime import date, datetime, timedelta
from pathlib import Path

from git import Repo

from app.core.config import get_settings
from app.core.logging import get_logger

log = get_logger(__name__)


class GitLocal:
    def __init__(self, repo_path: str | None = None) -> None:
        s = get_settings()
        self.repo_path = Path(repo_path or s.local_repo_path)
        self._repo: Repo | None = None

    @property
    def repo(self) -> Repo:
        if self._repo is None:
            if not self.repo_path.exists():
                raise FileNotFoundError(f"Git repo bulunamadı: {self.repo_path}")
            self._repo = Repo(str(self.repo_path))
        return self._repo

    def current_branch(self) -> str:
        return self.repo.active_branch.name

    def list_branches(self) -> list[str]:
        return [b.name for b in self.repo.branches]

    def commits_on(self, target_date: date, author: str | None = None) -> list[dict]:
        since = datetime.combine(target_date, datetime.min.time())
        until = since + timedelta(days=1)
        kwargs = {"since": since.isoformat(), "until": until.isoformat()}
        if author:
            kwargs["author"] = author
        result = []
        try:
            for c in self.repo.iter_commits(all=True, **kwargs):
                result.append(
                    {
                        "sha": c.hexsha[:8],
                        "author": c.author.name,
                        "email": c.author.email,
                        "message": c.message.strip(),
                        "date": c.committed_datetime.isoformat(),
                        "branch": getattr(c, "branch_name", None),
                    }
                )
        except Exception as e:
            log.warning(f"Git log hatası: {e}")
        return result

    def my_commits_on(self, target_date: date) -> list[dict]:
        try:
            email = self.repo.config_reader().get_value("user", "email", "")
        except Exception:
            email = ""
        return self.commits_on(target_date, author=email)

    def diff_between(self, base: str, head: str) -> str:
        try:
            return self.repo.git.diff(f"{base}...{head}", "--stat")
        except Exception as e:
            log.warning(f"Diff alınamadı: {e}")
            return ""

    def diff_full(self, base: str, head: str, max_chars: int = 60000) -> str:
        try:
            out = self.repo.git.diff(f"{base}...{head}")
            return out[:max_chars]
        except Exception as e:
            log.warning(f"Full diff alınamadı: {e}")
            return ""


def get_git(repo_path: str | None = None) -> GitLocal:
    return GitLocal(repo_path)
