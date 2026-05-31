from datetime import datetime
from typing import Optional

from sqlmodel import Field, SQLModel


class Project(SQLModel, table=True):
    __tablename__ = "projects"

    id: Optional[int] = Field(default=None, primary_key=True)
    name: str  # Görüntü adı, ör. "Mobile Banking iOS"
    slug: str = Field(index=True, unique=True)  # ör. "mobile-banking"
    color: str = "#60A5FA"

    # Per-project Jira/Bitbucket alanları (hesap globalindir, sadece key/repo değişir)
    jira_project_keys: str = ""  # CSV: "IOS,MOB"
    bitbucket_workspace: str = ""  # Stash'te project key
    bitbucket_repo: str = ""  # Repo slug

    # Lokal repo
    local_repo_path: str = ""
    git_default_branch: str = "develop"

    # Fastlane / TestFlight
    fastlane_project_dir: str = ""
    fastlane_lane: str = "beta"

    is_archived: bool = False
    sort_order: int = 0
    created_at: datetime = Field(default_factory=datetime.utcnow)
    updated_at: datetime = Field(default_factory=datetime.utcnow)
