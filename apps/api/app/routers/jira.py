"""Jira router — v1.1 ile genişletildi.

Eski endpoint'ler:
  POST /api/jira/refresh    — cache yenile
  GET  /api/jira/issues     — cached issues

Yeni endpoint'ler (v1.1):
  GET  /api/jira/tasks                  — canlı liste (JQL)
  GET  /api/jira/task/{key}             — detay (transitions + fields)
  GET  /api/jira/task/{key}/transitions — available transitions
  POST /api/jira/task/{key}/transition  — status değiştir
  PATCH /api/jira/task/{key}            — field edit
  POST /api/jira/task/{key}/comment     — comment ekle
  GET  /api/jira/assignable             — atanabilir kullanıcılar
  POST /api/jira/task/{key}/branch      — Bitbucket'ta branch yarat
  GET  /api/jira/myself                 — current user
"""
from __future__ import annotations

import re
import unicodedata
from typing import Any

from fastapi import APIRouter, HTTPException, Query
from pydantic import BaseModel
from sqlmodel import Session, select

from app.agents.jira_agent import JiraAgent
from app.core.action_log import log_action
from app.core.active_project import resolve_project_id
from app.core.db import engine
from app.integrations.bitbucket_client import get_bitbucket
from app.integrations.jira_client import get_jira
from app.models import JiraIssueCache, Project

router = APIRouter(prefix="/api/jira", tags=["jira"])


# ─────────────────────────────────────────────────────────────────────────
# Cache yenileme + cached listeleme (mevcut)
# ─────────────────────────────────────────────────────────────────────────

@router.post("/refresh")
async def refresh_jira(project_id: int | None = None) -> dict:
    res = await JiraAgent().fetch_and_cache(project_id=project_id)
    ok = bool(res.get("ok"))
    log_action(
        action_type="jira.refresh",
        target_kind="project",
        payload={"count": res.get("count") if ok else None},
        outcome="success" if ok else "failure",
        error=res.get("error") if not ok else None,
        project_id=project_id,
    )
    if not ok:
        raise HTTPException(status_code=503, detail=res.get("error"))
    return res


@router.get("/issues")
async def list_cached_issues(project_id: int | None = None) -> list[dict]:
    pid = resolve_project_id(project_id)
    with Session(engine) as session:
        rows = session.exec(
            select(JiraIssueCache)
            .where(JiraIssueCache.project_id == pid)
            .order_by(JiraIssueCache.fetched_at.desc())
        ).all()
        return [r.model_dump(exclude={"raw_json"}) for r in rows]


# ─────────────────────────────────────────────────────────────────────────
# Live listeleme + filtre (v1.1)
# ─────────────────────────────────────────────────────────────────────────

def _project_jira_keys(project_id: int | None) -> str:
    """Aktif (ya da verilen) projenin Jira project key listesini (virgüllü) döner."""
    pid = resolve_project_id(project_id)
    with Session(engine) as session:
        p = session.get(Project, pid)
        return (p.jira_project_keys or "").strip() if p else ""


def _jql_escape(value: str) -> str:
    """JQL string literal escape — backslash + double-quote."""
    return value.replace("\\", "\\\\").replace('"', '\\"')


@router.get("/tasks")
async def list_tasks(
    project_id: int | None = None,
    jql: str | None = None,
    assignee: str | None = Query(default=None, description="'me' veya kullanıcı adı; 'unassigned' = atanmamış"),
    status_category: str | None = Query(default=None, description="To Do | In Progress | Done"),
    status: str | None = Query(default=None, description="Tam status adı (örn 'In Review')"),
    text: str | None = Query(default=None, description="Summary/description'da arar"),
    label: str | None = None,
    issue_type: str | None = None,
    max_results: int = Query(default=100, ge=1, le=500),
    order_by: str = Query(default="updated DESC"),
) -> list[dict]:
    """Aktif projenin Jira key'leriyle (config) sınırlı, filtreli canlı task listesi.

    `jql` verilirse diğer filtreler ignored; aksi halde filtreler AND ile birleşir.
    """
    keys_csv = _project_jira_keys(project_id)
    keys = [k.strip() for k in keys_csv.split(",") if k.strip()]

    jql_parts: list[str] = []
    if not jql:
        if keys:
            jql_parts.append(f"project in ({','.join(keys)})")
        if assignee:
            if assignee == "me":
                jql_parts.append("assignee = currentUser()")
            elif assignee == "unassigned":
                jql_parts.append("assignee is EMPTY")
            else:
                jql_parts.append(f'assignee = "{_jql_escape(assignee)}"')
        if status_category:
            cats = [c.strip() for c in status_category.split(",") if c.strip()]
            if len(cats) == 1:
                jql_parts.append(f'statusCategory = "{_jql_escape(cats[0])}"')
            elif len(cats) > 1:
                quoted = ",".join(f'"{_jql_escape(c)}"' for c in cats)
                jql_parts.append(f"statusCategory in ({quoted})")
        if status:
            jql_parts.append(f'status = "{_jql_escape(status)}"')
        if text:
            jql_parts.append(f'(summary ~ "{_jql_escape(text)}" OR description ~ "{_jql_escape(text)}")')
        if label:
            jql_parts.append(f'labels = "{_jql_escape(label)}"')
        if issue_type:
            jql_parts.append(f'issuetype = "{_jql_escape(issue_type)}"')

        # Hiç kısıt yoksa (proje key'i tanımsız + filtre yok) sınırsız tarama
        # yapma — Jira'yı timeout'a sokar. Güvenli default: kullanıcının kendi işleri.
        if not jql_parts:
            jql_parts.append("assignee = currentUser()")
        final_jql = " AND ".join(jql_parts) + f" ORDER BY {order_by}"
    else:
        final_jql = jql

    try:
        issues = await get_jira().search_jql(final_jql, max_results=max_results)
        return [get_jira().normalize(issue, get_jira().base) for issue in issues]
    except Exception as e:
        raise HTTPException(status_code=503, detail=f"Jira'ya erişilemedi: {type(e).__name__}: {e}")


@router.get("/task/{key}")
async def get_task(key: str) -> dict:
    try:
        return await get_jira().get_issue(key)
    except Exception as e:
        raise HTTPException(status_code=503, detail=f"Jira'ya erişilemedi: {type(e).__name__}: {e}")


@router.get("/task/{key}/transitions")
async def list_transitions(key: str) -> list[dict]:
    try:
        return await get_jira().get_transitions(key)
    except Exception as e:
        raise HTTPException(status_code=503, detail=f"Jira'ya erişilemedi: {e}")


# ─────────────────────────────────────────────────────────────────────────
# Mutating endpoint'ler — log_action ile birlikte
# ─────────────────────────────────────────────────────────────────────────

class TransitionBody(BaseModel):
    transition_id: str
    comment: str | None = None
    project_id: int | None = None


@router.post("/task/{key}/transition")
async def transition_task(key: str, body: TransitionBody) -> dict:
    try:
        # Önce mevcut durumu kaydet (log payload için)
        before = await get_jira().get_issue(key)
        before_status = (before.get("fields", {}).get("status") or {}).get("name", "")

        await get_jira().do_transition(
            key, body.transition_id, comment=body.comment
        )

        # Yeni durumu çek
        after = await get_jira().get_issue(key)
        after_status = (after.get("fields", {}).get("status") or {}).get("name", "")

        log_action(
            action_type="jira.transition",
            target_kind="jira_issue",
            target_id=key,
            payload={
                "transition_id": body.transition_id,
                "from": before_status,
                "to": after_status,
                "comment": (body.comment or "")[:200],
            },
            project_id=body.project_id,
        )
        return {"ok": True, "from": before_status, "to": after_status}
    except Exception as e:
        log_action(
            action_type="jira.transition",
            target_kind="jira_issue",
            target_id=key,
            payload={"transition_id": body.transition_id},
            outcome="failure",
            error=str(e),
            project_id=body.project_id,
        )
        raise HTTPException(status_code=503, detail=str(e))


class UpdateTaskBody(BaseModel):
    # Direkt Jira REST fields formatı — frontend payload'ı bilinçli kuruyor
    fields: dict[str, Any]
    project_id: int | None = None


@router.patch("/task/{key}")
async def update_task(key: str, body: UpdateTaskBody) -> dict:
    try:
        await get_jira().update_issue(key, body.fields)
        log_action(
            action_type="jira.edit",
            target_kind="jira_issue",
            target_id=key,
            payload={"fields_changed": list(body.fields.keys())},
            project_id=body.project_id,
        )
        return {"ok": True}
    except Exception as e:
        log_action(
            action_type="jira.edit",
            target_kind="jira_issue",
            target_id=key,
            payload={"fields_changed": list(body.fields.keys())},
            outcome="failure",
            error=str(e),
            project_id=body.project_id,
        )
        raise HTTPException(status_code=503, detail=str(e))


class CommentBody(BaseModel):
    body: str
    project_id: int | None = None


@router.post("/task/{key}/comment")
async def add_comment(key: str, body: CommentBody) -> dict:
    try:
        res = await get_jira().add_comment(key, body.body)
        log_action(
            action_type="jira.comment",
            target_kind="jira_issue",
            target_id=key,
            payload={"text_preview": body.body[:200]},
            project_id=body.project_id,
        )
        return {"ok": True, "comment": res}
    except Exception as e:
        log_action(
            action_type="jira.comment",
            target_kind="jira_issue",
            target_id=key,
            payload={"text_preview": body.body[:200]},
            outcome="failure",
            error=str(e),
            project_id=body.project_id,
        )
        raise HTTPException(status_code=503, detail=str(e))


# ─────────────────────────────────────────────────────────────────────────
# Atanabilir kullanıcılar
# ─────────────────────────────────────────────────────────────────────────

@router.get("/assignable")
async def assignable_users(
    project: str | None = None,
    issue_key: str | None = None,
    q: str = "",
) -> list[dict]:
    try:
        users = await get_jira().assignable_users(
            project_key=project, issue_key=issue_key, query=q, max_results=50
        )
        return users
    except Exception as e:
        raise HTTPException(status_code=503, detail=str(e))


@router.get("/myself")
async def me() -> dict:
    try:
        return await get_jira().myself()
    except Exception as e:
        raise HTTPException(status_code=503, detail=str(e))


# ─────────────────────────────────────────────────────────────────────────
# Priority / fix version / sprint seçenekleri + sprint atama (v1.7)
# ─────────────────────────────────────────────────────────────────────────

def _project_key_from(issue_key: str | None, project_key: str | None) -> str:
    """Verilen project_key yoksa issue_key prefix'inden türet (örn ABC-123 → ABC)."""
    if project_key:
        return project_key
    if issue_key and "-" in issue_key:
        return issue_key.split("-", 1)[0]
    return issue_key or ""


@router.get("/priorities")
async def list_priorities() -> list[dict]:
    try:
        return await get_jira().priorities()
    except Exception as e:
        raise HTTPException(status_code=503, detail=str(e))


@router.get("/versions")
async def list_versions(
    project_key: str | None = None, issue_key: str | None = None
) -> list[dict]:
    pk = _project_key_from(issue_key, project_key)
    if not pk:
        raise HTTPException(status_code=400, detail="project_key veya issue_key gerekli")
    try:
        return await get_jira().project_versions(pk)
    except Exception as e:
        raise HTTPException(status_code=503, detail=str(e))


@router.get("/sprints")
async def list_sprints(
    project_key: str | None = None, issue_key: str | None = None
) -> list[dict]:
    pk = _project_key_from(issue_key, project_key)
    if not pk:
        raise HTTPException(status_code=400, detail="project_key veya issue_key gerekli")
    try:
        return await get_jira().sprints(pk)
    except Exception as e:
        raise HTTPException(status_code=503, detail=str(e))


class SprintBody(BaseModel):
    sprint_id: int | None = None  # None → backlog'a al
    project_id: int | None = None


@router.post("/task/{key}/sprint")
async def assign_sprint(key: str, body: SprintBody) -> dict:
    try:
        if body.sprint_id is None:
            await get_jira().move_to_backlog(key)
        else:
            await get_jira().move_to_sprint(body.sprint_id, key)
        log_action(
            action_type="jira.sprint",
            target_kind="jira_issue",
            target_id=key,
            payload={"sprint_id": body.sprint_id},
            project_id=body.project_id,
        )
        return {"ok": True, "sprint_id": body.sprint_id}
    except Exception as e:
        log_action(
            action_type="jira.sprint",
            target_kind="jira_issue",
            target_id=key,
            payload={"sprint_id": body.sprint_id},
            outcome="failure",
            error=str(e),
            project_id=body.project_id,
        )
        raise HTTPException(status_code=503, detail=str(e))


# ─────────────────────────────────────────────────────────────────────────
# Branch oluşturma — Jira task'tan Bitbucket'a
# ─────────────────────────────────────────────────────────────────────────

class CreateBranchBody(BaseModel):
    repo: str | None = None
    workspace: str | None = None
    source_branch: str | None = None  # None → projenin git_default_branch
    branch_prefix: str = "feature"
    project_id: int | None = None


def _slugify(text: str, max_len: int = 50) -> str:
    """Türkçe-uyumlu basit slug."""
    text = unicodedata.normalize("NFKD", text)
    text = "".join(c for c in text if not unicodedata.combining(c))
    text = text.lower()
    text = re.sub(r"[^a-z0-9]+", "-", text)
    text = text.strip("-")
    if len(text) > max_len:
        text = text[:max_len].rstrip("-")
    return text or "task"


@router.post("/task/{key}/branch")
async def create_branch_from_task(key: str, body: CreateBranchBody) -> dict:
    """Jira task'tan branch yaratır.

    1. Jira'dan task'ı çek (summary'yi slugify için)
    2. Bitbucket'ta `{prefix}/{KEY}-{summary-slug}` adıyla branch yarat
    3. Action log + comment olarak Jira'ya bağlantıyı yaz
    """
    try:
        issue = await get_jira().get_issue(key)
        summary = (issue.get("fields") or {}).get("summary") or ""
        slug = _slugify(summary)
        branch_name = f"{body.branch_prefix}/{key}-{slug}".lower()

        # Workspace/repo/source: body verirse onu, yoksa aktif projenin ayarı
        ws = body.workspace
        repo = body.repo
        src = body.source_branch
        if not ws or not repo or not src:
            pid = resolve_project_id(body.project_id)
            with Session(engine) as session:
                p = session.get(Project, pid)
                ws = ws or (p.bitbucket_workspace if p else None)
                repo = repo or (p.bitbucket_repo if p else None)
                if not src:
                    src = (p.git_default_branch if p else None) or "develop"

        res = await get_bitbucket().create_branch(
            branch_name=branch_name,
            source_branch=src,
            workspace=ws,
            repo=repo,
        )
        ok = bool(res.get("ok"))

        log_action(
            action_type="branch.create",
            target_kind="branch",
            target_id=branch_name,
            payload={
                "jira_key": key,
                "repo": repo,
                "workspace": ws,
                "source_branch": src,
                "branch_name": branch_name,
            },
            outcome="success" if ok else "failure",
            error=res.get("error") if not ok else None,
            project_id=body.project_id,
        )

        if not ok:
            raise HTTPException(status_code=503, detail=res.get("error"))

        # Bonus: Jira'ya yorum olarak branch'ı düş
        try:
            comment_body = (
                f"🌿 Branch oluşturuldu: `{branch_name}` "
                f"(repo: `{ws}/{repo}`, source: `{src}`)"
            )
            await get_jira().add_comment(key, comment_body)
        except Exception:
            pass  # comment fail'i critical değil

        return {
            "ok": True,
            "branch": branch_name,
            "repo": repo,
            "workspace": ws,
            "source_branch": src,
        }
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=503, detail=str(e))
