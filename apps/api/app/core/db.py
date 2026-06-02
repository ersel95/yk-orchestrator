from collections.abc import Iterator
from pathlib import Path

from sqlmodel import Session, SQLModel, create_engine

from app.core.config import get_settings

_settings = get_settings()

_db_path = _settings.database_url.replace("sqlite:///", "")
Path(_db_path).parent.mkdir(parents=True, exist_ok=True)

engine = create_engine(
    _settings.database_url,
    echo=False,
    connect_args={"check_same_thread": False},
)


def init_db() -> None:
    from app import models  # noqa: F401  — modelleri yükle

    SQLModel.metadata.create_all(engine)
    with engine.connect() as conn:
        conn.exec_driver_sql("PRAGMA journal_mode=WAL")
        conn.exec_driver_sql("PRAGMA foreign_keys=ON")

    # create_all var olan tabloya kolon EKLEMEZ — eksik kolonları idempotent ekle
    _ensure_columns()

    # En az bir proje olduğundan emin ol
    _ensure_default_project()


def _ensure_columns() -> None:
    """Modele sonradan eklenen kolonları mevcut DB'ye ALTER ile ekler (veri korunur).

    SQLite `ADD COLUMN` mevcut satırlara DEFAULT uygular; idempotent (PRAGMA ile kontrol).
    """
    # tablo -> {kolon: SQL DDL}
    required: dict[str, dict[str, str]] = {
        "projects": {
            "xcode_container_path": "VARCHAR NOT NULL DEFAULT ''",
            "xcode_scheme": "VARCHAR NOT NULL DEFAULT ''",
            "xcode_configuration": "VARCHAR NOT NULL DEFAULT ''",
            "xcode_bundle_id": "VARCHAR NOT NULL DEFAULT ''",
            "xcode_team_id": "VARCHAR NOT NULL DEFAULT ''",
            "xcode_environments": "VARCHAR NOT NULL DEFAULT ''",
        },
    }
    with engine.connect() as conn:
        for table, cols in required.items():
            existing = {row[1] for row in conn.exec_driver_sql(f"PRAGMA table_info({table})")}
            for col, ddl in cols.items():
                if col not in existing:
                    conn.exec_driver_sql(f"ALTER TABLE {table} ADD COLUMN {col} {ddl}")
        conn.commit()


def _ensure_default_project() -> None:
    from sqlmodel import Session, select

    from app.core.config import get_settings
    from app.models import Project, SettingKV

    s = get_settings()
    with Session(engine) as session:
        existing = session.exec(select(Project)).first()
        if existing:
            # Active project key yoksa ilkini ata
            if not session.get(SettingKV, "active_project_id"):
                session.add(SettingKV(key="active_project_id", value=str(existing.id)))
                session.commit()
            return

        # .env'deki global tek-proje varsayılanlarını ilk projeye seed et
        proj = Project(
            name="Varsayılan Proje",
            slug="default",
            jira_project_keys=s.jira_project_keys,
            bitbucket_workspace=s.bitbucket_workspace,
            bitbucket_repo=s.bitbucket_default_repo,
            local_repo_path=s.local_repo_path,
            git_default_branch=s.git_default_branch,
            fastlane_project_dir=s.fastlane_project_dir,
            fastlane_lane=s.fastlane_lane,
        )
        session.add(proj)
        session.commit()
        session.refresh(proj)
        session.add(SettingKV(key="active_project_id", value=str(proj.id)))
        session.commit()


def get_session() -> Iterator[Session]:
    with Session(engine) as session:
        yield session
