"""Bitbucket Server — branch / commit / tag listeleme (v1.2).

PR ile ilgili endpoint'ler `pull_requests.py`'da kalıyor — bu router sadece repo
metadata'sı için.
"""
from __future__ import annotations

from fastapi import APIRouter, HTTPException, Query
from sqlmodel import Session

from app.core.active_project import resolve_project_id
from app.core.db import engine
from app.integrations.bitbucket_client import get_bitbucket
from app.models import Project

router = APIRouter(prefix="/api/bitbucket", tags=["bitbucket"])


def _project_repo(project_id: int | None) -> tuple[str | None, str | None]:
    pid = resolve_project_id(project_id)
    with Session(engine) as session:
        p = session.get(Project, pid)
        if not p:
            return None, None
        return p.bitbucket_workspace, p.bitbucket_repo


@router.get("/branches")
async def list_branches(
    project_id: int | None = None,
    filter: str = "",
    limit: int = Query(default=100, ge=1, le=500),
) -> list[dict]:
    ws, repo = _project_repo(project_id)
    try:
        return await get_bitbucket().get_branches(
            workspace=ws, repo=repo, filter_text=filter, limit=limit, details=True
        )
    except Exception as e:
        raise HTTPException(status_code=503, detail=str(e))


@router.get("/commits")
async def list_commits(
    project_id: int | None = None,
    branch: str | None = None,
    path: str | None = None,
    limit: int = Query(default=100, ge=1, le=500),
) -> list[dict]:
    ws, repo = _project_repo(project_id)
    try:
        return await get_bitbucket().get_commits(
            workspace=ws, repo=repo, branch=branch, path=path, limit=limit
        )
    except Exception as e:
        raise HTTPException(status_code=503, detail=str(e))


@router.get("/tags")
async def list_tags(
    project_id: int | None = None,
    limit: int = Query(default=100, ge=1, le=500),
) -> list[dict]:
    ws, repo = _project_repo(project_id)
    try:
        return await get_bitbucket().get_tags(workspace=ws, repo=repo, limit=limit)
    except Exception as e:
        raise HTTPException(status_code=503, detail=str(e))
