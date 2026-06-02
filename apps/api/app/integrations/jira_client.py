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

    # ─────────────────────────────────────────────────────────────────────
    # CRUD + transitions (v1.1)
    # ─────────────────────────────────────────────────────────────────────

    async def get_issue(self, key: str, *, expand: list[str] | None = None) -> dict[str, Any]:
        params: dict[str, Any] = {}
        if expand:
            params["expand"] = ",".join(expand)
        # transitions + renderedFields(HTML) + names + changelog(history) yararlı
        params.setdefault("expand", "transitions,renderedFields,names,schema,changelog")
        r = await self._client.get(f"/rest/api/2/issue/{key}", params=params)
        r.raise_for_status()
        return r.json()

    async def get_transitions(self, key: str) -> list[dict[str, Any]]:
        r = await self._client.get(f"/rest/api/2/issue/{key}/transitions")
        r.raise_for_status()
        return r.json().get("transitions", [])

    async def do_transition(
        self, key: str, transition_id: str, *, comment: str | None = None,
        fields: dict[str, Any] | None = None,
    ) -> None:
        body: dict[str, Any] = {"transition": {"id": transition_id}}
        if comment:
            body["update"] = {"comment": [{"add": {"body": comment}}]}
        if fields:
            body["fields"] = fields
        r = await self._client.post(f"/rest/api/2/issue/{key}/transitions", json=body)
        if r.status_code >= 400:
            log.warning(f"Jira transition hatası ({r.status_code}): {r.text[:300]}")
        r.raise_for_status()

    async def update_issue(self, key: str, fields: dict[str, Any]) -> None:
        """Issue field'larını günceller.

        `fields` direkt Jira REST format'ında (örn {"summary": "...", "assignee": {"name": "U0T..."}}).
        Custom field'lar customfield_XXXXX key'leriyle.
        """
        r = await self._client.put(f"/rest/api/2/issue/{key}", json={"fields": fields})
        if r.status_code >= 400:
            log.warning(f"Jira update hatası ({r.status_code}): {r.text[:300]}")
        r.raise_for_status()

    async def add_comment(self, key: str, body: str) -> dict[str, Any]:
        r = await self._client.post(
            f"/rest/api/2/issue/{key}/comment", json={"body": body}
        )
        r.raise_for_status()
        return r.json()

    async def assignable_users(
        self, *, project_key: str | None = None, issue_key: str | None = None,
        query: str = "", max_results: int = 50
    ) -> list[dict[str, Any]]:
        """Issue'ye atanabilir kullanıcılar.

        Jira Server'da ya `project` ya da `issueKey` parametresi gerekli.
        """
        params: dict[str, Any] = {"maxResults": max_results}
        if query:
            # Server kabul ediyor: 'username' veya 'query' parametresi (sürüm farkı)
            params["username"] = query
            params["query"] = query
        if issue_key:
            params["issueKey"] = issue_key
        elif project_key:
            params["project"] = project_key
        r = await self._client.get("/rest/api/2/user/assignable/search", params=params)
        r.raise_for_status()
        return r.json()

    async def status_categories(self) -> list[dict[str, Any]]:
        r = await self._client.get("/rest/api/2/statuscategory")
        r.raise_for_status()
        return r.json()

    # ─────────────────────────────────────────────────────────────────────
    # Priority / fix version / sprint seçenek listeleri + sprint atama (v1.7)
    # ─────────────────────────────────────────────────────────────────────

    async def priorities(self) -> list[dict[str, Any]]:
        """Global priority şeması — [{id, name, ...}]."""
        r = await self._client.get("/rest/api/2/priority")
        r.raise_for_status()
        return r.json()

    async def project_versions(self, project_key: str) -> list[dict[str, Any]]:
        """Proje fix version'ları — released/archived bilgisiyle."""
        r = await self._client.get(f"/rest/api/2/project/{project_key}/versions")
        r.raise_for_status()
        return r.json()

    async def boards(self, project_key: str) -> list[dict[str, Any]]:
        """Projeye bağlı Agile board'lar."""
        r = await self._client.get(
            "/rest/agile/1.0/board", params={"projectKeyOrId": project_key, "maxResults": 50}
        )
        r.raise_for_status()
        return r.json().get("values", [])

    async def sprints(
        self, project_key: str, *, states: str = "active,future"
    ) -> list[dict[str, Any]]:
        """Projenin board'larındaki active+future sprint'leri (id'ye göre tekilleştirilmiş)."""
        seen: dict[int, dict[str, Any]] = {}
        for board in await self.boards(project_key):
            board_id = board.get("id")
            if board_id is None:
                continue
            try:
                r = await self._client.get(
                    f"/rest/agile/1.0/board/{board_id}/sprint",
                    params={"state": states, "maxResults": 50},
                )
                if r.status_code >= 400:
                    # Kanban board'larda sprint endpoint'i 400 döner — atla
                    continue
                for sp in r.json().get("values", []):
                    sid = sp.get("id")
                    if sid is not None and sid not in seen:
                        seen[sid] = sp
            except Exception as e:
                log.warning(f"Sprint listesi alınamadı (board={board_id}): {e}")
        return list(seen.values())

    async def move_to_sprint(self, sprint_id: int, key: str) -> None:
        """Issue'yu sprint'e taşır (Agile API — customfield id'sinden bağımsız)."""
        r = await self._client.post(
            f"/rest/agile/1.0/sprint/{sprint_id}/issue", json={"issues": [key]}
        )
        if r.status_code >= 400:
            log.warning(f"Sprint atama hatası ({r.status_code}): {r.text[:300]}")
        r.raise_for_status()

    async def label_suggestions(self, query: str) -> list[str]:
        """Mevcut etiketler arasında autocomplete (Server + Cloud uyumlu)."""
        r = await self._client.get(
            "/rest/api/2/jql/autocompletedata/suggestions",
            params={"fieldName": "labels", "fieldValue": query},
        )
        if r.status_code >= 400:
            return []
        results = r.json().get("results", [])
        return [s.get("value", "") for s in results if s.get("value")]

    async def move_to_backlog(self, key: str) -> None:
        """Issue'yu sprint'ten çıkarıp backlog'a alır."""
        r = await self._client.post(
            "/rest/agile/1.0/backlog/issue", json={"issues": [key]}
        )
        if r.status_code >= 400:
            log.warning(f"Backlog'a taşıma hatası ({r.status_code}): {r.text[:300]}")
        r.raise_for_status()

    async def myself(self) -> dict[str, Any]:
        r = await self._client.get("/rest/api/2/myself")
        r.raise_for_status()
        return r.json()

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
