"""Action log helper — her router/agent bu üzerinden DB'ye yazar.

Tasarım kriterleri:
- Asla `log_action()` çağrısı API yanıtını etkilememeli. Hata yutulur (warning'le log'a).
- Senkron çağrı (DB write çok hızlı, async overhead gereksiz). İleride performans
  sorun olursa background task queue'ya çevrilebilir.
- payload JSON-serializable olmalı — caller dict atar, biz string'e çeviririz.
- duration_ms hesaplaması için `track_action()` context manager kullan.
"""
from __future__ import annotations

import json
import time
from contextlib import contextmanager
from datetime import datetime
from typing import Any

from sqlmodel import Session

from app.core.active_project import resolve_project_id
from app.core.db import engine
from app.core.logging import get_logger
from app.models.action_log import ActionLog

log = get_logger(__name__)


def log_action(
    *,
    action_type: str,
    actor: str = "user",
    target_kind: str | None = None,
    target_id: str | None = None,
    payload: dict[str, Any] | None = None,
    outcome: str = "success",
    error: str | None = None,
    duration_ms: int | None = None,
    project_id: int | None = None,
    user_note: str | None = None,
) -> None:
    """Tek bir aksiyon kaydı yaz. Hata atmaz — sadece log'a uyarı yazar."""
    try:
        pid = resolve_project_id(project_id) if project_id is None else project_id
    except Exception:
        pid = None

    payload_str = "{}"
    if payload is not None:
        try:
            payload_str = json.dumps(payload, ensure_ascii=False, default=str)
        except Exception as e:
            payload_str = json.dumps({"_serialize_error": str(e)})

    try:
        with Session(engine) as session:
            row = ActionLog(
                project_id=pid,
                created_at=datetime.utcnow(),
                actor=actor,
                action_type=action_type,
                target_kind=target_kind,
                target_id=target_id,
                payload_json=payload_str,
                outcome=outcome,
                error=(error[:500] if error else None),
                duration_ms=duration_ms,
                user_note=user_note,
            )
            session.add(row)
            session.commit()
    except Exception as e:
        log.warning(f"action_log yazılamadı (action={action_type}): {e}")


@contextmanager
def track_action(
    action_type: str,
    *,
    actor: str = "user",
    target_kind: str | None = None,
    target_id: str | None = None,
    payload: dict[str, Any] | None = None,
    project_id: int | None = None,
):
    """Context manager — başlangıç ve bitiş süresini ölçer, otomatik yazar.

    Kullanım:
        with track_action("pr.approve", target_kind="pull_request", target_id="123",
                          payload={"from": "UNAPPROVED", "to": "APPROVED"}):
            await bb_client.approve(pr_id)

    Exception olursa outcome=failure + error otomatik kaydedilir.
    """
    t0 = time.perf_counter()
    final_payload = dict(payload or {})
    try:
        yield final_payload  # caller payload'ı in-flight güncelleyebilir
        elapsed = int((time.perf_counter() - t0) * 1000)
        log_action(
            action_type=action_type,
            actor=actor,
            target_kind=target_kind,
            target_id=target_id,
            payload=final_payload,
            outcome="success",
            duration_ms=elapsed,
            project_id=project_id,
        )
    except Exception as e:
        elapsed = int((time.perf_counter() - t0) * 1000)
        log_action(
            action_type=action_type,
            actor=actor,
            target_kind=target_kind,
            target_id=target_id,
            payload=final_payload,
            outcome="failure",
            error=str(e),
            duration_ms=elapsed,
            project_id=project_id,
        )
        raise
