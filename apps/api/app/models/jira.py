from datetime import datetime
from typing import Optional

from sqlmodel import Field, SQLModel, UniqueConstraint


class JiraIssueCache(SQLModel, table=True):
    __tablename__ = "jira_issue_cache"
    __table_args__ = (UniqueConstraint("project_id", "issue_key", name="uq_jira_project_issue"),)

    id: Optional[int] = Field(default=None, primary_key=True)
    project_id: int = Field(foreign_key="projects.id", index=True)
    issue_key: str = Field(index=True)
    summary: str
    status: str
    priority: Optional[str] = None
    issue_type: Optional[str] = None
    assignee: Optional[str] = None
    sprint: Optional[str] = None
    description: Optional[str] = None
    url: Optional[str] = None
    raw_json: Optional[str] = None
    fetched_at: datetime = Field(default_factory=datetime.utcnow)
