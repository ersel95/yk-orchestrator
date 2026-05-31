"""JiraAgent — Jira'dan açık + dün biten issue'ları çekip cache'e yazar.

Proje bazlı: aktif/verilen projenin `jira_project_keys` filtresi uygulanır.
"""
from __future__ import annotations

import json
from datetime import date, timedelta

from sqlmodel import Session, select

from app.core.active_project import get_project, resolve_project_id
from app.core.config import get_settings
from app.core.db import engine
from app.core.logging import get_logger
from app.integrations.jira_client import get_jira
from app.integrations.rag import get_rag
from app.models import JiraIssueCache

log = get_logger(__name__)


class JiraAgent:
    async def fetch_and_cache(self, project_id: int | None = None) -> dict:
        pid = resolve_project_id(project_id)
        proj = get_project(pid)

        s = get_settings()
        client = get_jira()

        if not await client.health():
            return {"ok": False, "error": "Jira erişilemedi (VPN açık mı?)"}

        keys = [k.strip() for k in (proj.jira_project_keys or "").split(",") if k.strip()]
        project_filter = ""
        if keys:
            project_filter = " AND project IN (" + ",".join(keys) + ")"

        yest = (date.today() - timedelta(days=1)).isoformat()
        open_jql = (
            "assignee = currentUser() AND statusCategory != Done"
            f"{project_filter} ORDER BY priority DESC, updated DESC"
        )
        done_jql = (
            f'assignee = currentUser() AND statusCategory = Done '
            f'AND updated >= "{yest} 00:00" AND updated <= "{yest} 23:59"'
            f"{project_filter}"
        )

        open_issues = await client.search_jql(open_jql)
        done_issues = await client.search_jql(done_jql)

        normalized_open = [client.normalize(i, s.jira_base_url) for i in open_issues]
        normalized_done = [client.normalize(i, s.jira_base_url) for i in done_issues]
        all_issues = list({i["issue_key"]: i for i in normalized_open + normalized_done}.values())

        with Session(engine) as session:
            for n in all_issues:
                existing = session.exec(
                    select(JiraIssueCache).where(
                        JiraIssueCache.project_id == pid,
                        JiraIssueCache.issue_key == n["issue_key"],
                    )
                ).first()
                if existing:
                    for k in (
                        "summary",
                        "status",
                        "priority",
                        "issue_type",
                        "assignee",
                        "sprint",
                        "description",
                        "url",
                        "raw_json",
                    ):
                        setattr(existing, k, n.get(k))
                    session.add(existing)
                else:
                    payload = {k: v for k, v in n.items() if k in JiraIssueCache.model_fields}
                    payload["project_id"] = pid
                    session.add(JiraIssueCache(**payload))
            session.commit()

        rag = get_rag()
        ids = [f"{pid}:{i['issue_key']}" for i in all_issues]
        docs = [
            f"{i['issue_key']} — {i['summary']}\nDurum: {i['status']}\n{i.get('description') or ''}"
            for i in all_issues
        ]
        metas = [
            {
                "project_id": pid,
                "key": i["issue_key"],
                "status": i["status"],
                "url": i["url"] or "",
            }
            for i in all_issues
        ]
        await rag.upsert("jira", ids, docs, metas)

        return {
            "ok": True,
            "project_id": pid,
            "open_count": len(normalized_open),
            "done_yesterday_count": len(normalized_done),
            "open": normalized_open,
            "done_yesterday": normalized_done,
        }
