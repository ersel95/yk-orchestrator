"""Claude agent step-by-step endpoint'leri (v1.5)."""
from __future__ import annotations

import asyncio
import json

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
from sse_starlette.sse import EventSourceResponse

from app.agents.code_agent import (
    commit_changes, generate_code, generate_code_stream, get_diff,
    make_plan, make_plan_stream, prepare_branch,
)

router = APIRouter(prefix="/api/agent", tags=["agent"])


def _sse(gen) -> EventSourceResponse:
    """Bir AsyncIterator[{type,data}]'yı SSE response'a sarar; hatayı error event'i yapar."""
    async def event_gen():
        try:
            async for ev in gen:
                yield {
                    "event": ev.get("type", "message"),
                    "data": json.dumps(ev.get("data", ""), ensure_ascii=False),
                }
        except asyncio.CancelledError:
            return
        except Exception as e:
            yield {"event": "error", "data": json.dumps(str(e), ensure_ascii=False)}
    return EventSourceResponse(event_gen())


class PlanBody(BaseModel):
    jira_key: str
    project_id: int | None = None


@router.post("/plan")
async def plan_for_task(body: PlanBody) -> dict:
    try:
        return await make_plan(jira_key=body.jira_key, project_id=body.project_id)
    except Exception as e:
        raise HTTPException(status_code=503, detail=str(e))


@router.get("/plan/stream")
async def plan_stream(jira_key: str, project_id: int | None = None):
    return _sse(make_plan_stream(jira_key=jira_key, project_id=project_id))


class PrepareBody(BaseModel):
    jira_key: str
    branch_name: str
    source_branch: str = "develop"
    project_id: int | None = None


@router.post("/prepare")
async def prepare(body: PrepareBody) -> dict:
    try:
        return await prepare_branch(
            jira_key=body.jira_key, branch_name=body.branch_name,
            source_branch=body.source_branch, project_id=body.project_id,
        )
    except Exception as e:
        raise HTTPException(status_code=503, detail=str(e))


class CodeBody(BaseModel):
    jira_key: str
    plan: str
    project_id: int | None = None


@router.post("/code")
async def code(body: CodeBody) -> dict:
    try:
        return await generate_code(
            jira_key=body.jira_key, plan=body.plan, project_id=body.project_id,
        )
    except Exception as e:
        raise HTTPException(status_code=503, detail=str(e))


@router.get("/code/stream")
async def code_stream(jira_key: str, plan: str, project_id: int | None = None):
    return _sse(generate_code_stream(jira_key=jira_key, plan=plan, project_id=project_id))


@router.get("/diff")
async def diff(project_id: int | None = None) -> dict:
    try:
        return await get_diff(project_id=project_id)
    except Exception as e:
        raise HTTPException(status_code=503, detail=str(e))


class CommitBody(BaseModel):
    message: str
    push: bool = True
    project_id: int | None = None


@router.post("/commit")
async def commit(body: CommitBody) -> dict:
    try:
        return await commit_changes(
            message=body.message, push=body.push, project_id=body.project_id,
        )
    except Exception as e:
        raise HTTPException(status_code=503, detail=str(e))
