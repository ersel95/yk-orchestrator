from datetime import date

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
from sqlmodel import Session, select

from app.agents.transcript_agent import TranscriptIngestAgent
from app.core.active_project import resolve_project_id
from app.core.db import engine
from app.models import Transcript, TranscriptUtterance

router = APIRouter(prefix="/api/transcript", tags=["transcript"])


class IngestBody(BaseModel):
    raw_text: str
    project_id: int | None = None
    meeting_date: date | None = None
    title: str = "Daily Standup"


@router.post("/ingest")
async def ingest(body: IngestBody) -> dict:
    return await TranscriptIngestAgent().ingest(
        raw_text=body.raw_text,
        project_id=body.project_id,
        meeting_date=body.meeting_date,
        title=body.title,
    )


@router.get("/list")
async def list_transcripts(project_id: int | None = None, limit: int = 30) -> list[dict]:
    pid = resolve_project_id(project_id)
    with Session(engine) as session:
        rows = session.exec(
            select(Transcript)
            .where(Transcript.project_id == pid)
            .order_by(Transcript.meeting_date.desc())
            .limit(limit)
        ).all()
        return [r.model_dump(exclude={"raw_text"}) for r in rows]


@router.get("/{transcript_id}")
async def detail(transcript_id: int) -> dict:
    with Session(engine) as session:
        row = session.get(Transcript, transcript_id)
        if not row:
            raise HTTPException(status_code=404, detail="kayıt yok")
        utts = session.exec(
            select(TranscriptUtterance)
            .where(TranscriptUtterance.transcript_id == transcript_id)
            .order_by(TranscriptUtterance.order)
        ).all()
        return {
            "transcript": row.model_dump(),
            "utterances": [u.model_dump() for u in utts],
        }
