import json
import os
from functools import lru_cache
from typing import Any, Literal

from pydantic import BaseModel, Field
from pydantic_settings import BaseSettings, SettingsConfigDict

from app.core.paths import (
    chroma_dir,
    env_file_path,
    is_frozen,
    sqlite_path,
    user_config_path,
)


# ─────────────────────────────────────────────────────────────────────────
# Provider + Role config nested modelleri
# ─────────────────────────────────────────────────────────────────────────

ProviderKind = Literal["openai_compatible", "anthropic"]


class ProviderConfig(BaseModel):
    """Tek bir LLM provider tanımı (config.json'daki bir item).

    `kind=openai_compatible` LM Studio/Ollama/OpenAI için (base_url farklı).
    `kind=anthropic` Anthropic Messages API için (base_url ignored).
    """
    id: str                          # "lm_studio" | "anthropic" | "openai" | ...
    kind: ProviderKind
    base_url: str = ""               # openai_compatible için zorunlu
    api_key: str = ""                # ENV ile inject edilir; config.json'da boş tutulabilir
    api_key_env: str = ""            # bu provider'ın api_key'ini hangi ENV'den oku (alternatif)
    timeout_seconds: int = 300


class RoleAssignment(BaseModel):
    """Bir rolü bir (provider, model) çiftine bağlar."""
    provider: str                    # ProviderConfig.id'lerinden biri
    model: str                       # Provider'a göre model id


# Tüm sistemin desteklediği roller. Wizard ve agent'lar bunlardan birine bağlanır.
KNOWN_ROLES = (
    "daily_writer",     # Bugün/dün metin üretimi
    "pr_summarizer",    # PR diff özeti
    "pr_commenter",     # PR inline yorum önerileri
    "code_reviewer",    # Daha derin kod review
    "transcript",       # Daily toplantı transkript özeti
    "chat",             # RAG chat
    "embed",            # Vektör embedding (sadece openai_compatible)
)

# Geriye dönük "kind" parametresinden role'e map
LEGACY_KIND_TO_ROLE: dict[str, str] = {
    "general": "daily_writer",
    "code": "pr_summarizer",
    "embed": "embed",
}


def _load_json_config() -> dict[str, Any]:
    path = user_config_path()
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (json.JSONDecodeError, OSError):
        return {}


# ─────────────────────────────────────────────────────────────────────────
# Settings
# ─────────────────────────────────────────────────────────────────────────

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

    database_url: str = ""
    chroma_persist_dir: str = ""

    # ── Yeni multi-provider şeması ─────────────────────────────────────
    providers: list[ProviderConfig] = Field(default_factory=list)
    model_roles: dict[str, RoleAssignment] = Field(default_factory=dict)

    # ── Eski tek-provider alanları (backward compat) ──────────────────
    # providers boşsa bu alanlardan tek provider otomatik üretilir.
    llm_base_url: str = "http://127.0.0.1:1234/v1"
    llm_api_key: str = "lm-studio"
    llm_model_general: str = "qwen2.5-72b-instruct"
    llm_model_code: str = "qwen2.5-coder-32b-instruct"
    llm_model_embed: str = "nomic-embed-text"
    llm_timeout_seconds: int = 300
    llm_temperature: float = 0.3

    # ── Provider-özel API key ENV girişleri (KeychainStore tarafından inject) ──
    anthropic_api_key: str = ""
    openai_api_key: str = ""

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
        if not self.database_url:
            self.database_url = f"sqlite:///{sqlite_path()}"
        if not self.chroma_persist_dir:
            self.chroma_persist_dir = str(chroma_dir())

        # providers boşsa eski tek-provider config'ten LM Studio üret
        if not self.providers:
            self.providers = [
                ProviderConfig(
                    id="lm_studio",
                    kind="openai_compatible",
                    base_url=self.llm_base_url,
                    api_key=self.llm_api_key,
                    timeout_seconds=self.llm_timeout_seconds,
                )
            ]

        # ENV / api_key_env üzerinden api_key inject (config.json'a token yazılmaz)
        env_map = {
            "anthropic": self.anthropic_api_key,
            "openai": self.openai_api_key,
            "lm_studio": self.llm_api_key,
        }
        for p in self.providers:
            if not p.api_key:
                # api_key_env varsa onu kullan
                if p.api_key_env and os.environ.get(p.api_key_env):
                    p.api_key = os.environ[p.api_key_env]
                # provider id'ye göre default ENV
                elif env_map.get(p.id):
                    p.api_key = env_map[p.id]

        # model_roles boşsa eski 3-rol mantığından (general/code/embed) türet
        if not self.model_roles:
            default_provider = self.providers[0].id
            defaults: dict[str, RoleAssignment] = {
                "daily_writer":  RoleAssignment(provider=default_provider, model=self.llm_model_general),
                "pr_summarizer": RoleAssignment(provider=default_provider, model=self.llm_model_code),
                "pr_commenter":  RoleAssignment(provider=default_provider, model=self.llm_model_code),
                "code_reviewer": RoleAssignment(provider=default_provider, model=self.llm_model_code),
                "transcript":    RoleAssignment(provider=default_provider, model=self.llm_model_general),
                "chat":          RoleAssignment(provider=default_provider, model=self.llm_model_general),
                "embed":         RoleAssignment(provider=default_provider, model=self.llm_model_embed),
            }
            self.model_roles = defaults

    @property
    def jira_project_list(self) -> list[str]:
        return [p.strip() for p in self.jira_project_keys.split(",") if p.strip()]

    @property
    def is_bundled(self) -> bool:
        return is_frozen()

    def provider_by_id(self, pid: str) -> ProviderConfig | None:
        for p in self.providers:
            if p.id == pid:
                return p
        return None


@lru_cache
def get_settings() -> Settings:
    """ENV > config.json > default sırası ile yükle."""
    json_overrides = _load_json_config()
    effective: dict[str, Any] = {
        k: v for k, v in json_overrides.items() if k.upper() not in os.environ
    }
    return Settings(**effective)


def reload_settings() -> Settings:
    get_settings.cache_clear()
    return get_settings()
