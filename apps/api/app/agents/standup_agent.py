"""StandupAgent — Dün+bugün+blocker bilgisinden daily metni üretir (proje bazlı)."""
from __future__ import annotations

from datetime import date, datetime
from typing import Any

from sqlmodel import Session, select

from app.agents.jira_agent import JiraAgent
from app.agents.prompts import STANDUP_SYSTEM, STANDUP_USER_TEMPLATE
from app.agents.yesterday_agent import YesterdayAgent
from app.core.active_project import get_project, resolve_project_id
from app.core.db import engine
from app.core.logging import get_logger
from app.integrations.llm import get_llm
from app.integrations.rag import get_rag
from app.models import DailyStandup

log = get_logger(__name__)


def _shorten(text: str | None, limit: int = 400) -> str:
    if not text:
        return ""
    text = text.strip()
    if len(text) <= limit:
        return text
    return text[:limit].rsplit(" ", 1)[0] + "…"


def _format_yesterday_jira(issues: list[dict]) -> str:
    if not issues:
        return "(yok)"
    rows: list[str] = []
    for i in issues:
        desc = _shorten(i.get("description_short") or i.get("description"), 300)
        line = f"• [{i['issue_key']}] {i['summary']}"
        if desc:
            line += f"\n  Açıklama: {desc}"
        rows.append(line)
    return "\n".join(rows)


def _format_yesterday_prs(prs: list[dict]) -> str:
    if not prs:
        return "(yok)"
    rows: list[str] = []
    for p in prs:
        line = f"• PR #{p['number']}: {p['title']}"
        if p.get("description_short"):
            line += f"\n  Açıklama: {p['description_short']}"
        commits = p.get("commit_messages") or []
        if commits:
            joined = "\n    ".join(f"- {m}" for m in commits[:8])
            line += f"\n  Commit'ler:\n    {joined}"
        rows.append(line)
    return "\n".join(rows)


def _format_yesterday_commits(commits: list[dict]) -> str:
    if not commits:
        return "(yok)"
    return "\n".join(f"• {c['message'][:120]}" for c in commits[:8])


def _format_today(open_issues: list[dict]) -> str:
    if not open_issues:
        return "(atanmış açık iş yok)"

    def _prio(s: str) -> int:
        s = (s or "").lower()
        if "progress" in s:
            return 0
        if "review" in s:
            return 1
        if "to do" in s or "todo" in s or "open" in s:
            return 2
        return 3

    # Önceliğe göre sırala
    sorted_issues = sorted(open_issues, key=lambda i: _prio(i.get("status", "")))
    # Sadece In Progress + Review + To Do — "Hold" / "Blocked" / "Backlog" alt'ta gösterilmesin
    primary = [i for i in sorted_issues if _prio(i.get("status", "")) <= 2]
    if not primary:
        primary = sorted_issues  # Hiç primary yoksa hepsini göster

    rows: list[str] = []
    for i in primary[:8]:
        desc = _shorten(i.get("description"), 250)
        line = f"• [{i['issue_key']}] {i['summary']} ({i['status']})"
        if desc:
            line += f"\n  Açıklama: {desc}"
        rows.append(line)
    return "\n".join(rows)


class StandupAgent:
    async def generate(
        self,
        project_id: int | None = None,
        for_date: date | None = None,
        manual_blockers: str = "",
    ) -> dict:
        pid = resolve_project_id(project_id)
        proj = get_project(pid)
        for_date = for_date or date.today()

        jira = JiraAgent()
        jira_data = await jira.fetch_and_cache(project_id=pid)

        yesterday = YesterdayAgent()
        y_data = await yesterday.collect(project_id=pid)

        yesterday_jira = _format_yesterday_jira(y_data.get("jira_done", []))
        yesterday_prs = _format_yesterday_prs(y_data.get("merged_prs", []))
        yesterday_commits = _format_yesterday_commits(y_data.get("commits", []))
        today_text = _format_today(jira_data.get("open", []) if jira_data.get("ok") else [])
        blockers_text = manual_blockers.strip() or "Yok"

        # Cache için combined "yesterday_text"
        yesterday_text = (
            f"Jira:\n{yesterday_jira}\n\nPR:\n{yesterday_prs}\n\nCommits:\n{yesterday_commits}"
        )

        # Tarih bağlamı: bugün ve "dün" aralığı (Türkçe günlü)
        TR_DAYS = ["Pazartesi", "Salı", "Çarşamba", "Perşembe", "Cuma", "Cumartesi", "Pazar"]
        TR_MONTHS = [
            "Ocak", "Şubat", "Mart", "Nisan", "Mayıs", "Haziran",
            "Temmuz", "Ağustos", "Eylül", "Ekim", "Kasım", "Aralık",
        ]

        def _tr(d: date) -> str:
            return f"{d.day} {TR_MONTHS[d.month - 1]} ({TR_DAYS[d.weekday()]})"

        ds = y_data.get("date_start") or ""
        de = y_data.get("date_end") or ""
        try:
            ds_d = date.fromisoformat(ds) if ds else for_date
            de_d = date.fromisoformat(de) if de else for_date
            yesterday_label = _tr(ds_d) if ds_d == de_d else f"{_tr(ds_d)} – {_tr(de_d)}"
        except Exception:
            yesterday_label = ds + (f" – {de}" if de and de != ds else "")

        date_context = (
            f"Bugün: {_tr(for_date)}\n"
            f"\"Dün\" için baktığımız aralık: {yesterday_label}\n"
            f"(Pazartesi atılırsa Cuma'dan itibaren tarihler dahil edilir)"
        )

        prompt = STANDUP_USER_TEMPLATE.format(
            today_date=for_date.isoformat(),
            project_name=proj.name,
            date_context=date_context,
            yesterday_jira=yesterday_jira,
            yesterday_prs=yesterday_prs,
            yesterday_commits=yesterday_commits,
            today_tasks=today_text,
            blockers=blockers_text,
        )

        llm = get_llm()
        text = await llm.complete(
            prompt,
            system=STANDUP_SYSTEM,
            kind="general",
            max_tokens=1100,
            label="daily-standup",
        )

        with Session(engine) as session:
            existing = session.exec(
                select(DailyStandup).where(
                    DailyStandup.project_id == pid,
                    DailyStandup.standup_date == for_date,
                )
            ).first()
            if existing:
                existing.yesterday_summary = yesterday_text
                existing.today_plan = today_text
                existing.blockers = blockers_text
                existing.final_text = text
                existing.updated_at = datetime.utcnow()
                session.add(existing)
                row = existing
            else:
                row = DailyStandup(
                    project_id=pid,
                    standup_date=for_date,
                    yesterday_summary=yesterday_text,
                    today_plan=today_text,
                    blockers=blockers_text,
                    final_text=text,
                )
                session.add(row)
            session.commit()
            session.refresh(row)

        rag = get_rag()
        await rag.upsert(
            "daily",
            ids=[f"daily-{pid}-{for_date.isoformat()}"],
            documents=[f"[{proj.name}] {for_date.isoformat()}\n{text}"],
            metadatas=[{"project_id": pid, "date": for_date.isoformat()}],
        )

        return {
            "id": row.id,
            "project_id": pid,
            "project_name": proj.name,
            "date": for_date.isoformat(),
            "yesterday": yesterday_text,
            "today": today_text,
            "blockers": blockers_text,
            "text": text,
            "source_data": {
                "jira_done": y_data.get("jira_done", []),
                "merged_prs": y_data.get("merged_prs", []),
                "commits": y_data.get("commits", []),
                "open_issues": jira_data.get("open", []) if jira_data.get("ok") else [],
            },
            "errors": y_data.get("errors", []),
        }

    async def finalize(self, project_id: int | None, for_date: date, edited_text: str) -> dict:
        pid = resolve_project_id(project_id)
        with Session(engine) as session:
            row = session.exec(
                select(DailyStandup).where(
                    DailyStandup.project_id == pid,
                    DailyStandup.standup_date == for_date,
                )
            ).first()
            if not row:
                return {"ok": False, "error": "kayıt bulunamadı"}
            row.final_text = edited_text
            row.is_finalized = True
            row.updated_at = datetime.utcnow()
            session.add(row)
            session.commit()

        rag = get_rag()
        await rag.upsert(
            "daily",
            ids=[f"daily-{pid}-{for_date.isoformat()}"],
            documents=[f"{for_date.isoformat()}\n{edited_text}"],
            metadatas=[{"project_id": pid, "date": for_date.isoformat(), "finalized": True}],
        )
        return {"ok": True}
