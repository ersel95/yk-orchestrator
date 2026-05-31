from datetime import date

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
from sqlmodel import Session, select

from app.agents.standup_agent import StandupAgent
from app.core.active_project import resolve_project_id
from app.core.db import engine
from app.models import DailyStandup

router = APIRouter(prefix="/api/standup", tags=["standup"])


class GenerateBody(BaseModel):
    project_id: int | None = None
    for_date: date | None = None
    blockers: str = ""


class FinalizeBody(BaseModel):
    project_id: int | None = None
    for_date: date
    text: str


@router.post("/generate")
async def generate(body: GenerateBody) -> dict:
    return await StandupAgent().generate(
        project_id=body.project_id, for_date=body.for_date, manual_blockers=body.blockers
    )


@router.post("/finalize")
async def finalize(body: FinalizeBody) -> dict:
    res = await StandupAgent().finalize(body.project_id, body.for_date, body.text)
    if not res.get("ok"):
        raise HTTPException(status_code=400, detail=res.get("error"))
    return res


@router.get("/history")
async def history(project_id: int | None = None, limit: int = 30) -> list[dict]:
    pid = resolve_project_id(project_id)
    with Session(engine) as session:
        rows = session.exec(
            select(DailyStandup)
            .where(DailyStandup.project_id == pid)
            .order_by(DailyStandup.standup_date.desc())
            .limit(limit)
        ).all()
        return [r.model_dump() for r in rows]


@router.get("/by-date/{for_date}")
async def by_date(for_date: date, project_id: int | None = None) -> dict:
    pid = resolve_project_id(project_id)
    with Session(engine) as session:
        row = session.exec(
            select(DailyStandup).where(
                DailyStandup.project_id == pid,
                DailyStandup.standup_date == for_date,
            )
        ).first()
        if not row:
            raise HTTPException(status_code=404, detail="kayıt yok")
        return row.model_dump()
