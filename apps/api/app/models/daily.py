from datetime import date, datetime
from typing import Optional

from sqlmodel import Field, SQLModel, UniqueConstraint


class DailyStandup(SQLModel, table=True):
    __tablename__ = "daily_standups"
    __table_args__ = (UniqueConstraint("project_id", "standup_date", name="uq_daily_project_date"),)

    id: Optional[int] = Field(default=None, primary_key=True)
    project_id: int = Field(foreign_key="projects.id", index=True)
    standup_date: date = Field(index=True)
    yesterday_summary: str = ""
    today_plan: str = ""
    blockers: str = ""
    final_text: str = ""
    is_finalized: bool = False
    created_at: datetime = Field(default_factory=datetime.utcnow)
    updated_at: datetime = Field(default_factory=datetime.utcnow)


class DailyTask(SQLModel, table=True):
    __tablename__ = "daily_tasks"

    id: Optional[int] = Field(default=None, primary_key=True)
    project_id: int = Field(foreign_key="projects.id", index=True)
    standup_date: date = Field(index=True)
    source: str  # "jira" | "manual" | "pr"
    external_id: Optional[str] = None
    title: str
    status: str = "pending"
    priority: Optional[str] = None
    note: Optional[str] = None
    created_at: datetime = Field(default_factory=datetime.utcnow)
