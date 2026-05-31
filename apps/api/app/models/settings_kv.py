from datetime import datetime
from typing import Optional

from sqlmodel import Field, SQLModel


class SettingKV(SQLModel, table=True):
    __tablename__ = "settings_kv"

    key: str = Field(primary_key=True)
    value: str
    updated_at: datetime = Field(default_factory=datetime.utcnow)
