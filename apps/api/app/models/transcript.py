from datetime import date, datetime
from typing import Optional

from sqlmodel import Field, SQLModel


class Transcript(SQLModel, table=True):
    __tablename__ = "transcripts"

    id: Optional[int] = Field(default=None, primary_key=True)
    project_id: int = Field(foreign_key="projects.id", index=True)
    meeting_date: date = Field(index=True)
    title: str = "Daily Standup"
    raw_text: str
    summary: Optional[str] = None
    action_items: Optional[str] = None  # JSON string
    created_at: datetime = Field(default_factory=datetime.utcnow)


class TranscriptUtterance(SQLModel, table=True):
    __tablename__ = "transcript_utterances"

    id: Optional[int] = Field(default=None, primary_key=True)
    transcript_id: int = Field(foreign_key="transcripts.id", index=True)
    speaker: str
    text: str
    order: int = 0
