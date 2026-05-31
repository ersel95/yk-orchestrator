from datetime import datetime
from typing import Optional

from sqlmodel import Field, SQLModel


class ChatThread(SQLModel, table=True):
    __tablename__ = "chat_threads"

    id: Optional[int] = Field(default=None, primary_key=True)
    title: str = "Yeni sohbet"
    created_at: datetime = Field(default_factory=datetime.utcnow)
    updated_at: datetime = Field(default_factory=datetime.utcnow)


class ChatMessage(SQLModel, table=True):
    __tablename__ = "chat_messages"

    id: Optional[int] = Field(default=None, primary_key=True)
    thread_id: int = Field(foreign_key="chat_threads.id", index=True)
    role: str  # user | assistant | system
    content: str
    sources: Optional[str] = None  # JSON; RAG'tan gelen kaynaklar
    created_at: datetime = Field(default_factory=datetime.utcnow)
