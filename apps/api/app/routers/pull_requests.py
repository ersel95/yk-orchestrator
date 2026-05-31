import asyncio
import json

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
from sqlmodel import Session, select
from sse_starlette.sse import EventSourceResponse

from app.agents.pr_agent import PRAuthorAgent, PRReviewerAgent
from app.core.active_project import resolve_project_id
from app.core.db import engine
from app.models import PullRequestCache

router = APIRouter(prefix="/api/pr", tags=["pull-requests"])


class DraftBody(BaseModel):
    source_branch: str
    target_branch: str | None = None
    repo: str | None = None
    project_id: int | None = None


class OpenBody(BaseModel):
    title: str
    description: str
    source_branch: str
    target_branch: str
    repo: str | None = None
    reviewers: list[str] | None = None
    project_id: int | None = None


class StatusBody(BaseModel):
    status: str  # APPROVED | NEEDS_WORK | UNAPPROVED
    project_id: int | None = None


class CommentBody(BaseModel):
    text: str
    project_id: int | None = None
    anchor: dict | None = None  # opsiyonel inline anchor


class PostSuggestionsBody(BaseModel):
    suggestions: list[dict]
    project_id: int | None = None


@router.post("/draft")
async def draft_pr(body: DraftBody) -> dict:
    return await PRAuthorAgent().draft(
        source_branch=body.source_branch,
        project_id=body.project_id,
        target_branch=body.target_branch,
        repo=body.repo,
    )


@router.post("/open")
async def open_pr(body: OpenBody) -> dict:
    res = await PRAuthorAgent().open_pr(
        title=body.title,
        description=body.description,
        source_branch=body.source_branch,
        target_branch=body.target_branch,
        project_id=body.project_id,
        repo=body.repo,
        reviewers=body.reviewers,
    )
    if not res.get("ok"):
        raise HTTPException(status_code=503, detail=res.get("error"))
    return res


@router.get("/review")
async def list_for_review(project_id: int | None = None) -> list[dict]:
    return await PRReviewerAgent().list_for_review(project_id=project_id)


@router.get("/review/{repo}/{number}/summary")
async def pr_summary(repo: str, number: int, project_id: int | None = None) -> dict:
    return await PRReviewerAgent().summarize(number, project_id=project_id, repo=repo)


@router.get("/review/{repo}/{number}/summary/stream")
async def pr_summary_stream(repo: str, number: int, project_id: int | None = None):
    agent = PRReviewerAgent()

    async def gen():
        try:
            async for ev in agent.summarize_stream(number, project_id=project_id, repo=repo):
                yield {
                    "event": ev["type"],
                    "data": json.dumps(ev.get("data", ""), ensure_ascii=False),
                }
        except asyncio.CancelledError:
            return
        except Exception as e:
            yield {"event": "error", "data": json.dumps(str(e), ensure_ascii=False)}

    return EventSourceResponse(gen())


@router.get("/review/{repo}/{number}/changes")
async def pr_changes(repo: str, number: int, project_id: int | None = None) -> list[dict]:
    return await PRReviewerAgent().get_changes(number, project_id=project_id)


@router.get("/review/{repo}/{number}/file-diff")
async def pr_file_diff(
    repo: str, number: int, path: str, project_id: int | None = None,
    context_lines: int = 10,
) -> dict:
    diff = await PRReviewerAgent().get_file_diff(
        pr_id=number, path_in_repo=path, project_id=project_id, context_lines=context_lines
    )
    return {"path": path, "diff": diff}


@router.post("/review/{repo}/{number}/status")
async def pr_set_status(repo: str, number: int, body: StatusBody) -> dict:
    if body.status not in ("APPROVED", "NEEDS_WORK", "UNAPPROVED"):
        raise HTTPException(status_code=400, detail="geçersiz status")
    res = await PRReviewerAgent().set_status(
        pr_id=number, status=body.status, project_id=body.project_id
    )
    if not res.get("ok"):
        # 409 = PR zaten kapanmış/merged → frontend listeyi yenilesin
        code = 409 if res.get("stale") else 503
        raise HTTPException(status_code=code, detail=res.get("error"))
    return res


@router.post("/review/{repo}/{number}/comment")
async def pr_comment(repo: str, number: int, body: CommentBody) -> dict:
    res = await PRReviewerAgent().add_comment(
        pr_id=number, text=body.text, project_id=body.project_id, anchor=body.anchor
    )
    if not res.get("ok"):
        raise HTTPException(status_code=503, detail=res.get("error"))
    return res


@router.get("/review/{repo}/{number}/file-comments")
async def pr_file_comments(
    repo: str, number: int, path: str, project_id: int | None = None
) -> list[dict]:
    return await PRReviewerAgent().list_file_comments(
        pr_id=number, path_in_repo=path, project_id=project_id
    )


class UpdateCommentBody(BaseModel):
    text: str
    version: int
    project_id: int | None = None


@router.patch("/review/{repo}/{number}/comment/{comment_id}")
async def pr_update_comment(
    repo: str, number: int, comment_id: int, body: UpdateCommentBody
) -> dict:
    res = await PRReviewerAgent().update_comment(
        pr_id=number,
        comment_id=comment_id,
        version=body.version,
        text=body.text,
        project_id=body.project_id,
    )
    if not res.get("ok"):
        raise HTTPException(status_code=503, detail=res.get("error"))
    return res


@router.delete("/review/{repo}/{number}/comment/{comment_id}")
async def pr_delete_comment(
    repo: str,
    number: int,
    comment_id: int,
    version: int,
    project_id: int | None = None,
) -> dict:
    res = await PRReviewerAgent().delete_comment(
        pr_id=number,
        comment_id=comment_id,
        version=version,
        project_id=project_id,
    )
    if not res.get("ok"):
        raise HTTPException(status_code=503, detail=res.get("error"))
    return res


@router.post("/review/{repo}/{number}/ai-suggestions")
async def pr_ai_suggestions(repo: str, number: int, project_id: int | None = None) -> dict:
    return await PRReviewerAgent().suggest_inline_comments(
        pr_id=number, project_id=project_id
    )


@router.post("/review/{repo}/{number}/ai-suggestions/post")
async def pr_post_suggestions(repo: str, number: int, body: PostSuggestionsBody) -> dict:
    return await PRReviewerAgent().post_inline_suggestions(
        pr_id=number, suggestions=body.suggestions, project_id=body.project_id
    )


@router.get("/cache")
async def cached_prs(project_id: int | None = None) -> list[dict]:
    pid = resolve_project_id(project_id)
    with Session(engine) as session:
        rows = session.exec(
            select(PullRequestCache)
            .where(PullRequestCache.project_id == pid)
            .order_by(PullRequestCache.updated_at.desc())
        ).all()
        return [r.model_dump() for r in rows]
