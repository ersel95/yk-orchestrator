"""Bitbucket Server / Cloud REST entegrasyonu (VPN gerektirir).

Yapı Kredi'nin self-hosted Bitbucket Server (Stash) kullandığını varsayıyoruz.
Cloud kullanılıyorsa BITBUCKET_BASE_URL=https://api.bitbucket.org/2.0 yap.
"""
from __future__ import annotations

from typing import Any

import httpx

from app.core.config import get_settings
from app.core.logging import get_logger

log = get_logger(__name__)


class BitbucketClient:
    """Self-hosted Bitbucket Server (Stash) odaklı.

    Endpoint'ler:
      /rest/api/1.0/projects/{project}/repos/{repo}/pull-requests
    """

    def __init__(self) -> None:
        s = get_settings()
        self.base = s.bitbucket_base_url.rstrip("/")
        self.workspace = s.bitbucket_workspace
        self.default_repo = s.bitbucket_default_repo
        self.username = s.bitbucket_username

        headers = {"Accept": "application/json"}
        auth: tuple[str, str] | None = None
        if s.bitbucket_app_password:
            if s.bitbucket_username:
                auth = (s.bitbucket_username, s.bitbucket_app_password)
            else:
                # Sadece HTTP access token verildi → Bearer
                headers["Authorization"] = f"Bearer {s.bitbucket_app_password}"

        self._client = httpx.AsyncClient(
            base_url=self.base,
            auth=auth,
            timeout=45.0,
            headers=headers,
        )

    async def aclose(self) -> None:
        await self._client.aclose()

    async def health(self) -> bool:
        if not self.base:
            return False
        try:
            r = await self._client.get(
                "/rest/api/1.0/application-properties"
            )
            return r.status_code == 200
        except Exception as e:
            log.warning(f"Bitbucket erişilemedi: {e}")
            return False

    def _ws(self, workspace: str | None) -> str:
        return workspace or self.workspace

    def _pr_path(self, workspace: str | None = None, repo: str | None = None) -> str:
        repo = repo or self.default_repo
        return f"/rest/api/1.0/projects/{self._ws(workspace)}/repos/{repo}/pull-requests"

    async def list_prs(
        self,
        workspace: str | None = None,
        repo: str | None = None,
        state: str = "OPEN",
        role: str | None = None,
        limit: int = 50,
    ) -> list[dict[str, Any]]:
        params: dict[str, Any] = {"state": state, "limit": limit, "withProperties": "false"}
        if role:
            params["role.1"] = role
            if self.username:
                params["username.1"] = self.username
        r = await self._client.get(self._pr_path(workspace, repo), params=params)
        r.raise_for_status()
        return r.json().get("values", [])

    async def my_open_prs(
        self, workspace: str | None = None, repo: str | None = None
    ) -> list[dict[str, Any]]:
        return await self.list_prs(workspace=workspace, repo=repo, role="AUTHOR")

    async def prs_for_my_review(
        self, workspace: str | None = None, repo: str | None = None
    ) -> list[dict[str, Any]]:
        return await self.list_prs(workspace=workspace, repo=repo, role="REVIEWER")

    async def get_diff(
        self,
        pr_id: int,
        workspace: str | None = None,
        repo: str | None = None,
        context_lines: int = 3,
    ) -> str:
        """Unified plain-text diff döner (`+`/`-` satırlı klasik format)."""
        repo = repo or self.default_repo
        path = f"/rest/api/1.0/projects/{self._ws(workspace)}/repos/{repo}/pull-requests/{pr_id}/diff"
        # Default Accept: application/json bizim için Stash'ten JSON döndürür.
        # Burada raw unified diff istiyoruz → text/plain.
        r = await self._client.get(
            path,
            params={"contextLines": context_lines},
            headers={"Accept": "text/plain"},
        )
        r.raise_for_status()
        return r.text

    async def create_pr(
        self,
        title: str,
        description: str,
        source_branch: str,
        target_branch: str,
        workspace: str | None = None,
        repo: str | None = None,
        reviewers: list[str] | None = None,
    ) -> dict[str, Any]:
        repo = repo or self.default_repo
        ws = self._ws(workspace)
        body = {
            "title": title,
            "description": description,
            "fromRef": {
                "id": f"refs/heads/{source_branch}",
                "repository": {"slug": repo, "project": {"key": ws}},
            },
            "toRef": {
                "id": f"refs/heads/{target_branch}",
                "repository": {"slug": repo, "project": {"key": ws}},
            },
            "reviewers": [{"user": {"name": u}} for u in (reviewers or [])],
        }
        r = await self._client.post(self._pr_path(workspace, repo), json=body)
        r.raise_for_status()
        return r.json()

    async def get_pr(
        self, pr_id: int, workspace: str | None = None, repo: str | None = None
    ) -> dict[str, Any]:
        repo = repo or self.default_repo
        r = await self._client.get(f"{self._pr_path(workspace, repo)}/{pr_id}")
        r.raise_for_status()
        return r.json()

    async def get_pr_activities(
        self, pr_id: int, workspace: str | None = None, repo: str | None = None
    ) -> list[dict[str, Any]]:
        repo = repo or self.default_repo
        r = await self._client.get(f"{self._pr_path(workspace, repo)}/{pr_id}/activities")
        r.raise_for_status()
        return r.json().get("values", [])

    async def get_pr_commits(
        self,
        pr_id: int,
        workspace: str | None = None,
        repo: str | None = None,
        limit: int = 50,
    ) -> list[dict[str, Any]]:
        url = f"{self._pr_path(workspace, repo)}/{pr_id}/commits"
        r = await self._client.get(url, params={"limit": limit})
        if r.status_code >= 400:
            return []
        return r.json().get("values", [])

    # ----- Aksiyonlar -----

    async def set_participant_status(
        self,
        pr_id: int,
        status: str,
        workspace: str | None = None,
        repo: str | None = None,
        user_slug: str | None = None,
    ) -> dict[str, Any]:
        """status: APPROVED | UNAPPROVED | NEEDS_WORK"""
        slug = user_slug or self.username
        if not slug:
            raise ValueError(
                "Bitbucket kullanıcı adı (BITBUCKET_USERNAME) tanımlı değil — approve için lazım"
            )
        path = f"{self._pr_path(workspace, repo)}/{pr_id}/participants/{slug}"
        body = {"user": {"name": slug}, "status": status}
        r = await self._client.put(path, json=body)
        r.raise_for_status()
        return r.json()

    async def add_pr_comment(
        self,
        pr_id: int,
        text: str,
        workspace: str | None = None,
        repo: str | None = None,
        anchor: dict | None = None,
    ) -> dict[str, Any]:
        path = f"{self._pr_path(workspace, repo)}/{pr_id}/comments"
        body: dict[str, Any] = {"text": text}
        if anchor:
            body["anchor"] = anchor
        r = await self._client.post(path, json=body)
        r.raise_for_status()
        return r.json()

    async def list_pr_comments(
        self,
        pr_id: int,
        workspace: str | None = None,
        repo: str | None = None,
        path_in_repo: str | None = None,
        limit: int = 200,
    ) -> list[dict[str, Any]]:
        """Belirtilen dosyadaki anchored yorumları çek (yoksa tümünü)."""
        url = f"{self._pr_path(workspace, repo)}/{pr_id}/comments"
        params: dict[str, Any] = {"limit": limit}
        if path_in_repo:
            params["path"] = path_in_repo
        r = await self._client.get(url, params=params)
        r.raise_for_status()
        return r.json().get("values", [])

    async def update_comment(
        self,
        pr_id: int,
        comment_id: int,
        version: int,
        text: str,
        workspace: str | None = None,
        repo: str | None = None,
    ) -> dict[str, Any]:
        url = f"{self._pr_path(workspace, repo)}/{pr_id}/comments/{comment_id}"
        r = await self._client.put(url, json={"version": version, "text": text})
        r.raise_for_status()
        return r.json()

    async def delete_comment(
        self,
        pr_id: int,
        comment_id: int,
        version: int,
        workspace: str | None = None,
        repo: str | None = None,
    ) -> None:
        url = f"{self._pr_path(workspace, repo)}/{pr_id}/comments/{comment_id}"
        r = await self._client.delete(url, params={"version": version})
        r.raise_for_status()

    async def get_pr_changes(
        self,
        pr_id: int,
        workspace: str | None = None,
        repo: str | None = None,
        limit: int = 250,
    ) -> list[dict[str, Any]]:
        path = f"{self._pr_path(workspace, repo)}/{pr_id}/changes"
        r = await self._client.get(path, params={"limit": limit})
        r.raise_for_status()
        return r.json().get("values", [])

    async def get_pr_file_diff(
        self,
        pr_id: int,
        path_in_repo: str,
        workspace: str | None = None,
        repo: str | None = None,
        context_lines: int = 10,
    ) -> dict:
        """Bitbucket Server'ın yapılı JSON diff formatını döner.

        Yapı:
          {
            "diffs": [
              {
                "source": {"toString": "old/path"},
                "destination": {"toString": "new/path"},
                "hunks": [
                  {
                    "sourceLine": 10, "sourceSpan": 5,
                    "destinationLine": 10, "destinationSpan": 7,
                    "segments": [
                      {"type": "CONTEXT|ADDED|REMOVED", "lines": [{"source": N, "destination": N, "line": "..."}]}
                    ]
                  }
                ]
              }
            ]
          }
        """
        repo = repo or self.default_repo
        ws = self._ws(workspace)
        encoded_path = path_in_repo.lstrip("/")
        url = (
            f"/rest/api/1.0/projects/{ws}/repos/{repo}/pull-requests/{pr_id}/diff/"
            f"{encoded_path}"
        )
        r = await self._client.get(url, params={"contextLines": context_lines})
        if r.status_code >= 400:
            return {"diffs": [], "error": f"{r.status_code}: {r.text[:200]}"}
        try:
            return r.json()
        except Exception:
            return {"diffs": [], "raw_text": r.text[:5000]}

    # ─────────────────────────────────────────────────────────────────────
    # Branch oluşturma (v1.1 — Jira'dan tetikleniyor)
    # ─────────────────────────────────────────────────────────────────────

    async def create_branch(
        self,
        *,
        branch_name: str,
        source_branch: str = "develop",
        workspace: str | None = None,
        repo: str | None = None,
    ) -> dict[str, Any]:
        """Bitbucket Server'da yeni bir branch yaratır.

        Endpoint: POST /rest/branch-utils/1.0/projects/{KEY}/repos/{slug}/branches
        Body: {"name": "feature/X-1234", "startPoint": "refs/heads/develop"}
        Cevap: {"id": "refs/heads/feature/...", "displayId": "feature/...", "latestCommit": "..."}
        """
        ws = self._ws(workspace)
        repo = repo or self.default_repo
        if not repo:
            return {"ok": False, "error": "repo belirtilmedi"}
        url = f"/rest/branch-utils/1.0/projects/{ws}/repos/{repo}/branches"
        body = {"name": branch_name, "startPoint": f"refs/heads/{source_branch}"}
        r = await self._client.post(url, json=body)
        if r.status_code >= 400:
            return {
                "ok": False,
                "error": f"HTTP {r.status_code}: {r.text[:300]}",
            }
        return {"ok": True, **r.json()}

    async def delete_branch(
        self,
        *,
        branch_name: str,
        workspace: str | None = None,
        repo: str | None = None,
    ) -> dict[str, Any]:
        """Branch siler (Bitbucket Server branch-utils).

        Endpoint: DELETE /rest/branch-utils/1.0/projects/{KEY}/repos/{slug}/branches
        Body: {"name": "refs/heads/feature/X", "dryRun": false}
        """
        ws = self._ws(workspace)
        repo = repo or self.default_repo
        if not repo:
            return {"ok": False, "error": "repo belirtilmedi"}
        ref = branch_name if branch_name.startswith("refs/heads/") else f"refs/heads/{branch_name}"
        url = f"/rest/branch-utils/1.0/projects/{ws}/repos/{repo}/branches"
        r = await self._client.request("DELETE", url, json={"name": ref, "dryRun": False})
        if r.status_code >= 400:
            return {"ok": False, "error": f"HTTP {r.status_code}: {r.text[:300]}"}
        return {"ok": True}

    async def get_branches(
        self,
        *,
        workspace: str | None = None,
        repo: str | None = None,
        filter_text: str = "",
        limit: int = 100,
        details: bool = True,
    ) -> list[dict[str, Any]]:
        """Repo'daki branch listesini döner.

        details=True ile her branch için ahead/behind ve son commit dahil olur.
        """
        ws = self._ws(workspace)
        repo = repo or self.default_repo
        url = f"/rest/api/1.0/projects/{ws}/repos/{repo}/branches"
        params: dict[str, Any] = {"limit": limit}
        if filter_text:
            params["filterText"] = filter_text
        if details:
            params["details"] = "true"
        r = await self._client.get(url, params=params)
        r.raise_for_status()
        return r.json().get("values", [])

    async def get_commits(
        self,
        *,
        workspace: str | None = None,
        repo: str | None = None,
        branch: str | None = None,
        since: str | None = None,
        until: str | None = None,
        path: str | None = None,
        limit: int = 100,
    ) -> list[dict[str, Any]]:
        """Repo commit listesi. branch='refs/heads/develop' veya sadece 'develop'."""
        ws = self._ws(workspace)
        repo = repo or self.default_repo
        url = f"/rest/api/1.0/projects/{ws}/repos/{repo}/commits"
        params: dict[str, Any] = {"limit": limit}
        if branch:
            params["until"] = branch if branch.startswith("refs/") else f"refs/heads/{branch}"
        if since:
            params["since"] = since
        if path:
            params["path"] = path
        r = await self._client.get(url, params=params)
        r.raise_for_status()
        return r.json().get("values", [])

    async def get_tags(
        self,
        *,
        workspace: str | None = None,
        repo: str | None = None,
        limit: int = 100,
    ) -> list[dict[str, Any]]:
        ws = self._ws(workspace)
        repo = repo or self.default_repo
        url = f"/rest/api/1.0/projects/{ws}/repos/{repo}/tags"
        r = await self._client.get(url, params={"limit": limit})
        r.raise_for_status()
        return r.json().get("values", [])

    @staticmethod
    def normalize(pr: dict[str, Any], my_username: str) -> dict[str, Any]:
        from datetime import datetime, timezone

        from_ref = pr.get("fromRef", {}) or {}
        to_ref = pr.get("toRef", {}) or {}
        repo = (from_ref.get("repository") or {}).get("slug") or ""
        author_user = (pr.get("author") or {}).get("user") or {}
        author_name = author_user.get("name") or ""
        author_display = author_user.get("displayName") or author_name
        my = (my_username or "").lower()
        is_mine = author_name.lower() == my

        reviewers_info: list[dict[str, Any]] = []
        my_status = None
        for r in pr.get("reviewers") or []:
            user = r.get("user") or {}
            uname = user.get("name") or ""
            status = r.get("status") or "UNAPPROVED"
            reviewers_info.append(
                {
                    "name": uname,
                    "display_name": user.get("displayName") or uname,
                    "status": status,
                    "approved": bool(r.get("approved", False)),
                }
            )
            if uname.lower() == my:
                my_status = status

        approved_count = sum(1 for r in reviewers_info if r["status"] == "APPROVED")
        needs_work_count = sum(1 for r in reviewers_info if r["status"] == "NEEDS_WORK")

        needs_my_review = False
        if my and not is_mine:
            for r in reviewers_info:
                if r["name"].lower() == my and r["status"] not in ("APPROVED",):
                    needs_my_review = True

        def _to_dt(v: Any) -> datetime | None:
            if v is None:
                return None
            if isinstance(v, datetime):
                return v
            try:
                return datetime.fromtimestamp(int(v) / 1000, tz=timezone.utc)
            except (TypeError, ValueError):
                return None

        return {
            "pr_id": f"{repo}:{pr['id']}",
            "repo": repo,
            "number": pr["id"],
            "title": pr.get("title") or "",
            "description": pr.get("description"),
            "author": author_name,
            "author_display": author_display,
            "source_branch": (from_ref.get("displayId") or ""),
            "target_branch": (to_ref.get("displayId") or ""),
            "state": pr.get("state") or "",
            "is_mine": is_mine,
            "needs_my_review": needs_my_review,
            "my_status": my_status,  # APPROVED | NEEDS_WORK | UNAPPROVED | None (reviewer değilim)
            "approved_count": approved_count,
            "needs_work_count": needs_work_count,
            "reviewers": reviewers_info,
            "url": ((pr.get("links") or {}).get("self") or [{}])[0].get("href", ""),
            "created_at": _to_dt(pr.get("createdDate")),
            "updated_at": _to_dt(pr.get("updatedDate")),
        }


_client: BitbucketClient | None = None


def get_bitbucket() -> BitbucketClient:
    global _client
    if _client is None:
        _client = BitbucketClient()
    return _client
