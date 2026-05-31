"""Aktif proje yönetimi.

Aktif proje id'si SQLite'taki settings_kv tablosunda key="active_project_id" altında saklanır.
Her endpoint çağrısı opsiyonel olarak ?project_id=N alabilir; gelmezse aktif proje kullanılır.
"""
from __future__ import annotations

from sqlmodel import Session, select

from app.core.db import engine
from app.models import Project, SettingKV

ACTIVE_KEY = "active_project_id"


def get_active_project_id() -> int | None:
    with Session(engine) as session:
        row = session.get(SettingKV, ACTIVE_KEY)
        if not row:
            return None
        try:
            return int(row.value)
        except ValueError:
            return None


def set_active_project_id(project_id: int) -> None:
    with Session(engine) as session:
        row = session.get(SettingKV, ACTIVE_KEY)
        if row:
            row.value = str(project_id)
            session.add(row)
        else:
            session.add(SettingKV(key=ACTIVE_KEY, value=str(project_id)))
        session.commit()


def resolve_project_id(provided: int | None) -> int:
    """Endpoint'lerin başında çağrılır: query param > active > 404"""
    if provided is not None:
        return provided
    pid = get_active_project_id()
    if pid is not None:
        return pid
    # Hiç proje yoksa default oluşturulmuş olmalı (init_db'de)
    with Session(engine) as session:
        first = session.exec(select(Project).order_by(Project.id)).first()
        if first:
            set_active_project_id(first.id)
            return first.id
    raise RuntimeError("Hiç proje yok. Önce bir proje oluştur.")


def get_project(project_id: int) -> Project:
    with Session(engine) as session:
        proj = session.get(Project, project_id)
        if not proj:
            raise RuntimeError(f"Proje bulunamadı: {project_id}")
        return proj
