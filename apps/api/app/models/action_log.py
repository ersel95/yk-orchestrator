from datetime import datetime
from typing import Optional

from sqlmodel import Field, SQLModel


class ActionLog(SQLModel, table=True):
    """Sistemde gerçekleşen her aksiyonu kalıcı olarak tutar.

    v1.0+ — Chat history-aware retrieval'in (v1.4) ana veri kaynağı; Aktivite
    timeline'ın ana modeli. Her router/agent log_action() helper'ı üzerinden
    kayıt yazar.

    Tasarım kararı: payload JSON string (esnek, schema'sız). Sorgu sırasında
    Python dict'e çevrilir. Bu sayede her yeni aksiyon tipi için tablo değişikliği
    gerekmiyor — sadece yeni action_type sabit eklenir.
    """

    __tablename__ = "action_log"

    id: Optional[int] = Field(default=None, primary_key=True)

    # Hangi projeye ait (NULL → genel aksiyon, ör. ayar değişimi)
    project_id: Optional[int] = Field(default=None, foreign_key="projects.id", index=True)

    created_at: datetime = Field(default_factory=datetime.utcnow, index=True)

    # 'user' (kullanıcı tetikledi) | 'ai' (Claude vb. ajan) | 'system' (otomatik)
    actor: str = Field(index=True)

    # Hiyerarşik string: 'jira.transition', 'jira.edit', 'jira.comment',
    # 'pr.approve', 'pr.needs_work', 'pr.comment.add', 'pr.comment.edit',
    # 'pr.comment.delete', 'pr.ai_suggestion.generate', 'pr.ai_suggestion.post',
    # 'branch.create', 'testflight.upload.start', 'testflight.upload.done',
    # 'agent.code_gen', 'agent.plan', 'settings.update', 'chat.ask', 'chat.answer'
    action_type: str = Field(index=True)

    # Aksiyonun bağlandığı varlık tipi: 'jira_issue' | 'pull_request' |
    # 'branch' | 'build' | 'config' | 'thread' (chat) | 'project'
    target_kind: Optional[str] = Field(default=None, index=True)

    # Varlık ID'si (string — Jira KEY veya PR slug veya integer string)
    target_id: Optional[str] = Field(default=None, index=True)

    # Aksiyona özel detay (JSON serialized). Örn pr.approve → {"from": "UNAPPROVED", "to": "APPROVED"}
    payload_json: str = Field(default="{}")

    # 'success' | 'failure' | 'partial' (kısmi başarı)
    outcome: str = Field(default="success", index=True)

    # outcome=failure ise hata mesajı (ilk 500 karakter)
    error: Optional[str] = None

    # Aksiyonun ne kadar sürdüğü
    duration_ms: Optional[int] = None

    # Kullanıcı notu (opsiyonel free-form, bazı UI'lar 'açıklama' alanı ekleyebilir)
    user_note: Optional[str] = None
