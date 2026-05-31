from datetime import datetime
from typing import Optional

from sqlmodel import Field, SQLModel, UniqueConstraint


class PullRequestCache(SQLModel, table=True):
    __tablename__ = "pull_request_cache"
    __table_args__ = (UniqueConstraint("project_id", "pr_id", name="uq_pr_project_id"),)

    id: Optional[int] = Field(default=None, primary_key=True)
    project_id: int = Field(foreign_key="projects.id", index=True)
    pr_id: str = Field(index=True)
    repo: str
    number: int
    title: str
    description: Optional[str] = None
    author: str
    source_branch: str
    target_branch: str
    state: str
    is_mine: bool = False
    needs_my_review: bool = False
    has_my_unread_comment: bool = False
    url: str
    diff_summary: Optional[str] = None
    created_at: datetime
    updated_at: datetime
    fetched_at: datetime = Field(default_factory=datetime.utcnow)
