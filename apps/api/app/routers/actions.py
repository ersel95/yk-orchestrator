"""Action log read API.

Frontend ActivityView burayı kullanır. Yazma helper `app.core.action_log`.
"""
from __future__ import annotations

import json
from datetime import datetime, timedelta

from fastapi import APIRouter, Query
from sqlmodel import Session, select

from app.core.active_project import resolve_project_id
from app.core.db import engine
from app.models.action_log import ActionLog

router = APIRouter(prefix="/api/actions", tags=["actions"])


def _serialize(row: ActionLog) -> dict:
    payload = {}
    try:
        payload = json.loads(row.payload_json or "{}")
    except Exception:
        payload = {"_raw": row.payload_json}
    return {
        "id": row.id,
        "project_id": row.project_id,
        "created_at": row.created_at.isoformat() if row.created_at else None,
        "actor": row.actor,
        "action_type": row.action_type,
        "target_kind": row.target_kind,
        "target_id": row.target_id,
        "payload": payload,
        "outcome": row.outcome,
        "error": row.error,
        "duration_ms": row.duration_ms,
        "user_note": row.user_note,
    }


@router.get("")
async def list_actions(
    project_id: int | None = None,
    limit: int = Query(default=100, ge=1, le=1000),
    actor: str | None = None,
    action_type: str | None = None,
    target_kind: str | None = None,
    target_id: str | None = None,
    since_hours: int | None = Query(default=None, description="Son N saat"),
    only_failures: bool = False,
) -> list[dict]:
    pid = resolve_project_id(project_id)
    with Session(engine) as session:
        stmt = select(ActionLog).where(ActionLog.project_id == pid)
        if actor:
            stmt = stmt.where(ActionLog.actor == actor)
        if action_type:
            stmt = stmt.where(ActionLog.action_type == action_type)
        if target_kind:
            stmt = stmt.where(ActionLog.target_kind == target_kind)
        if target_id:
            stmt = stmt.where(ActionLog.target_id == target_id)
        if since_hours:
            cutoff = datetime.utcnow() - timedelta(hours=since_hours)
            stmt = stmt.where(ActionLog.created_at >= cutoff)
        if only_failures:
            stmt = stmt.where(ActionLog.outcome == "failure")
        stmt = stmt.order_by(ActionLog.created_at.desc()).limit(limit)
        rows = session.exec(stmt).all()
        return [_serialize(r) for r in rows]


@router.get("/by-target")
async def actions_by_target(target_kind: str, target_id: str) -> list[dict]:
    """Belirli bir target için tüm aksiyonlar (PR detay sayfasında 'bu PR için ne yaptım' tarihçesi)."""
    with Session(engine) as session:
        stmt = (
            select(ActionLog)
            .where(ActionLog.target_kind == target_kind)
            .where(ActionLog.target_id == target_id)
            .order_by(ActionLog.created_at.desc())
        )
        rows = session.exec(stmt).all()
        return [_serialize(r) for r in rows]


@router.get("/stats")
async def stats(project_id: int | None = None, since_hours: int = 24) -> dict:
    """Özet istatistikler — son N saat (default 24)."""
    pid = resolve_project_id(project_id)
    cutoff = datetime.utcnow() - timedelta(hours=since_hours)
    with Session(engine) as session:
        rows = session.exec(
            select(ActionLog)
            .where(ActionLog.project_id == pid)
            .where(ActionLog.created_at >= cutoff)
        ).all()
        by_type: dict[str, int] = {}
        failures = 0
        for r in rows:
            by_type[r.action_type] = by_type.get(r.action_type, 0) + 1
            if r.outcome == "failure":
                failures += 1
        return {
            "total": len(rows),
            "failures": failures,
            "by_type": by_type,
            "since_hours": since_hours,
        }
