"""ChatAgent — RAG + history-aware (v1.4).

Bağlam kaynakları:
1) **ChromaDB vektör arama** (RAG) — semantic match → ilgili eski daily/PR/Jira
2) **Action log** — son N kullanıcı aksiyonu ("geçen Salı X için ne yaptım")
3) **PR cache** — son güncellenen PR'lar
4) **Jira cache** — son güncellenen Jira issue'ları

Bu dört kaynak prompt context'ine birleştirilir; LLM Türkçe cevap üretir.
"""
from __future__ import annotations

import json
from collections.abc import AsyncIterator

from sqlmodel import Session, select

from app.agents.prompts import CHAT_SYSTEM, CHAT_USER_TEMPLATE
from app.core.active_project import resolve_project_id
from app.core.db import engine
from app.core.logging import get_logger
from app.integrations.llm import get_llm
from app.integrations.rag import get_rag
from app.models import JiraIssueCache, PullRequestCache
from app.models.action_log import ActionLog

log = get_logger(__name__)


# ─────────────────────────────────────────────────────────────────────────
# Format helpers
# ─────────────────────────────────────────────────────────────────────────

def _format_rag(results: list[dict]) -> str:
    if not results:
        return ""
    lines = ["[İLGİLİ GEÇMİŞ KAYITLAR]"]
    for r in results[:8]:
        meta = r.get("metadata") or {}
        header = f"[{r['collection']}#{r['id']}]"
        if meta.get("date"):
            header += f" ({meta['date']})"
        lines.append(f"{header}\n{r['document']}\n")
    return "\n".join(lines)


def _format_action_log(rows: list[ActionLog]) -> str:
    if not rows:
        return ""
    lines = [f"[SON AKSİYONLAR — kullanıcının yaptığı işler, n={len(rows)}]"]
    for r in rows[:30]:
        ts = r.created_at.strftime("%Y-%m-%d %H:%M") if r.created_at else "?"
        target = f"{r.target_kind}/{r.target_id}" if r.target_id else (r.target_kind or "-")
        summary = ""
        try:
            payload = json.loads(r.payload_json or "{}")
            for k in ("from", "to", "status", "transition_id", "text_preview", "question", "branch_name"):
                if k in payload:
                    summary = f"{k}={payload[k]}"
                    break
        except Exception:
            pass
        bits = [ts, r.actor, r.action_type, target]
        if r.outcome != "success":
            bits.append(f"[{r.outcome.upper()}]")
        if summary:
            bits.append(f"({summary})")
        lines.append("  " + " ".join(bits))
    return "\n".join(lines)


def _format_pr_cache(rows: list[PullRequestCache]) -> str:
    if not rows:
        return ""
    lines = [f"[AKTİF/SON PR'LAR — n={len(rows)}]"]
    for pr in rows[:15]:
        meta_bits = [pr.state]
        if pr.is_mine:
            meta_bits.append("mine")
        if pr.needs_my_review:
            meta_bits.append("review_needed")
        lines.append(
            f"  #{pr.number} [{pr.repo}] {pr.title[:80]} · {pr.author} · "
            f"{pr.source_branch}→{pr.target_branch} · ({', '.join(meta_bits)})"
        )
    return "\n".join(lines)


def _format_jira_cache(rows: list[JiraIssueCache]) -> str:
    if not rows:
        return ""
    lines = [f"[JIRA TASK CACHE — n={len(rows)}]"]
    for j in rows[:20]:
        bits = []
        if j.assignee:
            bits.append(f"@{j.assignee}")
        if j.priority:
            bits.append(j.priority)
        if j.sprint:
            bits.append(f"sprint:{j.sprint}")
        lines.append(
            f"  {j.issue_key} [{j.status or '?'}] {(j.summary or '')[:80]}"
            + (f" · {', '.join(bits)}" if bits else "")
        )
    return "\n".join(lines)


# ─────────────────────────────────────────────────────────────────────────
# Veri toplayıcılar
# ─────────────────────────────────────────────────────────────────────────

def _fetch_recent_actions(project_id: int | None, limit: int = 30) -> list[ActionLog]:
    pid = resolve_project_id(project_id)
    with Session(engine) as session:
        return list(session.exec(
            select(ActionLog)
            .where(ActionLog.project_id == pid)
            .order_by(ActionLog.created_at.desc())
            .limit(limit)
        ).all())


def _fetch_pr_cache(project_id: int | None, limit: int = 15) -> list[PullRequestCache]:
    pid = resolve_project_id(project_id)
    with Session(engine) as session:
        return list(session.exec(
            select(PullRequestCache)
            .where(PullRequestCache.project_id == pid)
            .order_by(PullRequestCache.updated_at.desc())
            .limit(limit)
        ).all())


def _fetch_jira_cache(project_id: int | None, limit: int = 20) -> list[JiraIssueCache]:
    pid = resolve_project_id(project_id)
    with Session(engine) as session:
        return list(session.exec(
            select(JiraIssueCache)
            .where(JiraIssueCache.project_id == pid)
            .order_by(JiraIssueCache.fetched_at.desc())
            .limit(limit)
        ).all())


# ─────────────────────────────────────────────────────────────────────────
# ChatAgent
# ─────────────────────────────────────────────────────────────────────────

class ChatAgent:
    async def _build_context(self, question: str, project_id: int | None) -> tuple[str, list[dict]]:
        """RAG + history bağlamlarını birleştirir, (context_str, sources_list) döner."""
        rag = get_rag()
        try:
            rag_results = await rag.search(question, k=5, project_id=project_id)
        except Exception as e:
            log.warning(f"RAG arama başarısız: {e}")
            rag_results = []

        actions = _fetch_recent_actions(project_id, limit=30)
        prs = _fetch_pr_cache(project_id, limit=15)
        jiras = _fetch_jira_cache(project_id, limit=20)

        parts: list[str] = []
        if rag_results:
            parts.append(_format_rag(rag_results))
        if actions:
            parts.append(_format_action_log(actions))
        if prs:
            parts.append(_format_pr_cache(prs))
        if jiras:
            parts.append(_format_jira_cache(jiras))

        context = "\n\n".join(parts) if parts else "(bu projede henüz veri yok)"
        sources = [
            {"collection": r["collection"], "id": r["id"], "metadata": r["metadata"]}
            for r in rag_results
        ]
        return context, sources

    async def answer(self, question: str, project_id: int | None = None) -> dict:
        context, sources = await self._build_context(question, project_id)
        prompt = CHAT_USER_TEMPLATE.format(question=question, context=context)
        text = await get_llm().complete(prompt, system=CHAT_SYSTEM, kind="general", max_tokens=1500)
        return {"answer": text, "sources": sources}

    async def stream_answer(
        self, question: str, project_id: int | None = None
    ) -> AsyncIterator[dict]:
        context, sources = await self._build_context(question, project_id)
        yield {"type": "sources", "data": sources}
        prompt = CHAT_USER_TEMPLATE.format(question=question, context=context)
        async for chunk in get_llm().stream(
            prompt, system=CHAT_SYSTEM, kind="general", max_tokens=1500
        ):
            yield {"type": "delta", "data": chunk}
        yield {"type": "done"}
