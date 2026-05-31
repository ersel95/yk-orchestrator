import json
import os
from functools import lru_cache
from typing import Any

from pydantic_settings import BaseSettings, SettingsConfigDict

from app.core.paths import (
    chroma_dir,
    env_file_path,
    is_frozen,
    sqlite_path,
    user_config_path,
)


def _load_json_config() -> dict[str, Any]:
    """~/Library/Application Support/.../config.json'ı oku. Yoksa boş dict."""
    path = user_config_path()
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (json.JSONDecodeError, OSError):
        return {}


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=str(env_file_path()) if env_file_path() else None,
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    app_name: str = "YK iOS Orchestrator"
    app_env: str = "local"
    log_level: str = "INFO"
    timezone: str = "Europe/Istanbul"

    api_host: str = "127.0.0.1"
    api_port: int = 8765
    dashboard_port: int = 3000

    # Veri yolları runtime'da paths.py'den geliyor — ENV override edilebilir
    database_url: str = ""
    chroma_persist_dir: str = ""

    llm_base_url: str = "http://127.0.0.1:1234/v1"
    llm_api_key: str = "lm-studio"
    llm_model_general: str = "qwen2.5-72b-instruct"
    llm_model_code: str = "qwen2.5-coder-32b-instruct"
    llm_model_embed: str = "nomic-embed-text"
    llm_timeout_seconds: int = 300
    llm_temperature: float = 0.3

    jira_base_url: str = ""
    jira_email: str = ""
    jira_api_token: str = ""
    jira_project_keys: str = ""
    jira_current_user_account_id: str = ""

    bitbucket_base_url: str = ""
    bitbucket_username: str = ""
    bitbucket_app_password: str = ""
    bitbucket_workspace: str = ""
    bitbucket_default_repo: str = ""

    local_repo_path: str = ""
    git_default_branch: str = "develop"

    fastlane_lane: str = "beta"
    fastlane_project_dir: str = ""
    testflight_auto_submit: bool = False

    daily_fetch_hour: int = 8
    daily_fetch_minute: int = 30

    dashboard_allow_origin: str = "http://localhost:3000"

    def model_post_init(self, __context: Any) -> None:
        # Veri yolu boşsa runtime resolver'dan doldur
        if not self.database_url:
            self.database_url = f"sqlite:///{sqlite_path()}"
        if not self.chroma_persist_dir:
            self.chroma_persist_dir = str(chroma_dir())

    @property
    def jira_project_list(self) -> list[str]:
        return [p.strip() for p in self.jira_project_keys.split(",") if p.strip()]

    @property
    def is_bundled(self) -> bool:
        return is_frozen()


@lru_cache
def get_settings() -> Settings:
    """ENV > config.json > default sırası ile yükle.

    Pydantic-settings'te init kwargs en yüksek önceliklidir; bu yüzden JSON'dan
    gelen değerleri sadece ilgili ENV değişkeni TANIMLI DEĞİLSE kwarg olarak geçiyoruz.
    Böylece manuel ENV override'lar daima kazanır.
    """
    json_overrides = _load_json_config()
    effective: dict[str, Any] = {
        k: v for k, v in json_overrides.items() if k.upper() not in os.environ
    }
    return Settings(**effective)


def reload_settings() -> Settings:
    """Wizard config.json'ı yazdıktan sonra cache'i temizleyip yeniden oku."""
    get_settings.cache_clear()
    return get_settings()
