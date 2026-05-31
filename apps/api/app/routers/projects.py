from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
from sqlmodel import Session, select

from app.core.active_project import (
    get_active_project_id,
    set_active_project_id,
)
from app.core.db import engine
from app.models import Project

router = APIRouter(prefix="/api/projects", tags=["projects"])


class ProjectIn(BaseModel):
    name: str
    slug: str
    color: str = "#60A5FA"
    jira_project_keys: str = ""
    bitbucket_workspace: str = ""
    bitbucket_repo: str = ""
    local_repo_path: str = ""
    git_default_branch: str = "develop"
    fastlane_project_dir: str = ""
    fastlane_lane: str = "beta"


class ProjectPatch(BaseModel):
    name: str | None = None
    slug: str | None = None
    color: str | None = None
    jira_project_keys: str | None = None
    bitbucket_workspace: str | None = None
    bitbucket_repo: str | None = None
    local_repo_path: str | None = None
    git_default_branch: str | None = None
    fastlane_project_dir: str | None = None
    fastlane_lane: str | None = None
    is_archived: bool | None = None
    sort_order: int | None = None


@router.get("")
async def list_projects() -> dict:
    with Session(engine) as session:
        rows = session.exec(
            select(Project).order_by(Project.sort_order, Project.id)
        ).all()
        return {
            "projects": [r.model_dump() for r in rows],
            "active_id": get_active_project_id(),
        }


@router.post("")
async def create_project(body: ProjectIn) -> dict:
    with Session(engine) as session:
        existing = session.exec(select(Project).where(Project.slug == body.slug)).first()
        if existing:
            raise HTTPException(status_code=400, detail="bu slug ile proje zaten var")
        proj = Project(**body.model_dump())
        session.add(proj)
        session.commit()
        session.refresh(proj)
        return proj.model_dump()


@router.patch("/{project_id}")
async def update_project(project_id: int, body: ProjectPatch) -> dict:
    with Session(engine) as session:
        proj = session.get(Project, project_id)
        if not proj:
            raise HTTPException(status_code=404, detail="proje yok")
        data = body.model_dump(exclude_unset=True)
        for k, v in data.items():
            setattr(proj, k, v)
        session.add(proj)
        session.commit()
        session.refresh(proj)
        return proj.model_dump()


@router.delete("/{project_id}")
async def delete_project(project_id: int) -> dict:
    with Session(engine) as session:
        proj = session.get(Project, project_id)
        if not proj:
            raise HTTPException(status_code=404, detail="proje yok")
        # Hard delete yerine arşivle
        proj.is_archived = True
        session.add(proj)
        session.commit()
        return {"ok": True, "archived": True}


@router.post("/{project_id}/activate")
async def activate(project_id: int) -> dict:
    with Session(engine) as session:
        proj = session.get(Project, project_id)
        if not proj:
            raise HTTPException(status_code=404, detail="proje yok")
        set_active_project_id(project_id)
        return {"ok": True, "active_id": project_id}


@router.get("/active")
async def active_project() -> dict:
    pid = get_active_project_id()
    if pid is None:
        return {"project": None}
    with Session(engine) as session:
        proj = session.get(Project, pid)
        return {"project": proj.model_dump() if proj else None}
