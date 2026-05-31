"""Jira REST entegrasyonu (VPN gerektirir)."""
from __future__ import annotations

import json
from datetime import date, datetime, timedelta
from typing import Any

import httpx

from app.core.config import get_settings
from app.core.logging import get_logger

log = get_logger(__name__)


class JiraClient:
    """Self-hosted Jira Server (PAT/Bearer) ve Cloud (email+token/Basic) destekler.

    Otomatik tespit:
      - JIRA_EMAIL doluysa → Basic Auth (Cloud / Atlassian)
      - JIRA_EMAIL boşsa  → Bearer Token (Server/DC PAT)
    """

    def __init__(self) -> None:
        s = get_settings()
        self.base = s.jira_base_url.rstrip("/")
        headers = {"Accept": "application/json"}
        auth: tuple[str, str] | None = None

        if s.jira_api_token:
            if s.jira_email:
                auth = (s.jira_email, s.jira_api_token)
            else:
                headers["Authorization"] = f"Bearer {s.jira_api_token}"

        self._client = httpx.AsyncClient(
            base_url=self.base,
            auth=auth,
            timeout=30.0,
            headers=headers,
        )
        self.account_id = s.jira_current_user_account_id

    async def aclose(self) -> None:
        await self._client.aclose()

    async def health(self) -> bool:
        if not self.base:
            return False
        try:
            r = await self._client.get("/rest/api/2/myself")
            return r.status_code == 200
        except Exception as e:
            log.warning(f"Jira erişilemedi: {e}")
            return False

    async def search_jql(
        self, jql: str, fields: list[str] | None = None, max_results: int = 50
    ) -> list[dict[str, Any]]:
        body: dict[str, Any] = {"jql": jql, "maxResults": max_results}
        if fields is not None:
            body["fields"] = fields
        else:
            # "*navigable" güvenli wildcard — bu Jira'nın bilinmeyen custom field'larında 400 vermez
            body["fields"] = ["*navigable"]
        r = await self._client.post("/rest/api/2/search", json=body)
        if r.status_code >= 400:
            log.warning(f"Jira JQL hatası ({r.status_code}): jql={jql!r} body={r.text[:300]}")
        r.raise_for_status()
        return r.json().get("issues", [])

    async def my_open_issues(self) -> list[dict[str, Any]]:
        jql = "assignee = currentUser() AND statusCategory != Done ORDER BY priority DESC, updated DESC"
        return await self.search_jql(jql)

    async def my_done_yesterday(self, target_date: date | None = None) -> list[dict[str, Any]]:
        d = target_date or (date.today() - timedelta(days=1))
        # Jira Server bazen DURING formatına nazlı; updated >= "tarih" + status terminal pattern'i
        jql = (
            f'assignee = currentUser() AND statusCategory = Done '
            f'AND updated >= "{d.isoformat()} 00:00" AND updated <= "{d.isoformat()} 23:59"'
        )
        return await self.search_jql(jql)

    @staticmethod
    def normalize(issue: dict[str, Any], base_url: str) -> dict[str, Any]:
        f = issue.get("fields", {})
        sprint_field = f.get("customfield_10020") or []
        sprint_name = None
        if isinstance(sprint_field, list) and sprint_field:
            first = sprint_field[0]
            if isinstance(first, dict):
                sprint_name = first.get("name")
            elif isinstance(first, str) and "name=" in first:
                # Eski Jira string formatı
                for part in first.split(","):
                    if part.strip().startswith("name="):
                        sprint_name = part.split("=", 1)[1]

        return {
            "issue_key": issue["key"],
            "summary": f.get("summary") or "",
            "status": (f.get("status") or {}).get("name") or "",
            "priority": (f.get("priority") or {}).get("name"),
            "issue_type": (f.get("issuetype") or {}).get("name"),
            "assignee": (f.get("assignee") or {}).get("displayName"),
            "sprint": sprint_name,
            "description": f.get("description"),
            "url": f"{base_url.rstrip('/')}/browse/{issue['key']}",
            "raw_json": json.dumps(issue, ensure_ascii=False),
            "updated": f.get("updated"),
            # NOTE: fetched_at SQLAlchemy default'una bırakılır (datetime obje)
        }


_client: JiraClient | None = None


def get_jira() -> JiraClient:
    global _client
    if _client is None:
        _client = JiraClient()
    return _client
