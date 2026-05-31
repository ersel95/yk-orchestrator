from fastapi import APIRouter, HTTPException
from sqlmodel import Session, select

from app.agents.jira_agent import JiraAgent
from app.core.active_project import resolve_project_id
from app.core.db import engine
from app.models import JiraIssueCache

router = APIRouter(prefix="/api/jira", tags=["jira"])


@router.post("/refresh")
async def refresh_jira(project_id: int | None = None) -> dict:
    res = await JiraAgent().fetch_and_cache(project_id=project_id)
    if not res.get("ok"):
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
