"""LLM router — rol bazlı provider/model çözümlemesi.

Agent'lar `get_router().complete(prompt, role="daily_writer")` ile çağırır.
Router:
1) settings.model_roles[role]'den (provider_id, model) okur
2) settings.providers içinden ilgili ProviderConfig'i bulur
3) İlgili provider instance'ını (cache'li) yaratır
4) provider.complete(model=..., ...) → string döner

Backward compat: eski `kind="general"|"code"|"embed"` parametresi de
desteklenir; LEGACY_KIND_TO_ROLE ile role'e map edilir.
"""
from __future__ import annotations

from collections.abc import AsyncIterator
from functools import lru_cache
from typing import Any

from app.core.config import (
    KNOWN_ROLES,
    LEGACY_KIND_TO_ROLE,
    ProviderConfig,
    get_settings,
)
from app.core.logging import get_logger
from app.integrations.providers import (
    AnthropicProvider,
    ClaudeCodeProvider,
    LLMProvider,
    OpenAICompatibleProvider,
)

log = get_logger(__name__)


def _build_provider(cfg: ProviderConfig) -> LLMProvider:
    if cfg.kind == "openai_compatible":
        # OpenAI'a doğrudan gidiyorsak base_url verilmemişse default'la
        base = cfg.base_url or "https://api.openai.com/v1"
        return OpenAICompatibleProvider(
            id=cfg.id,
            base_url=base,
            api_key=cfg.api_key or "noop",
            timeout=cfg.timeout_seconds,
        )
    if cfg.kind == "anthropic":
        if not cfg.api_key:
            raise RuntimeError(f"Provider {cfg.id}: api_key boş, çağrı yapılamaz")
        return AnthropicProvider(id=cfg.id, api_key=cfg.api_key, timeout=cfg.timeout_seconds)
    if cfg.kind == "claude_code":
        # API key gerekmez; `claude login` ile OAuth alınmış olmalı.
        # cli_path config'te base_url alanında verilebilir (özel kurulum), yoksa
        # PATH'ten `claude` aranır.
        cli = cfg.base_url or "claude"
        return ClaudeCodeProvider(id=cfg.id, cli_path=cli, timeout=cfg.timeout_seconds)
    raise ValueError(f"Bilinmeyen provider kind: {cfg.kind}")


class LLMRouter:
    def __init__(self) -> None:
        self._provider_cache: dict[str, LLMProvider] = {}

    def _resolve_role(self, role: str | None, kind: str | None) -> tuple[LLMProvider, str]:
        """role veya legacy kind'tan (provider_instance, model_name) döner."""
        s = get_settings()
        eff_role = role
        if not eff_role and kind:
            eff_role = LEGACY_KIND_TO_ROLE.get(kind, kind)
        if not eff_role:
            eff_role = "daily_writer"
        if eff_role not in KNOWN_ROLES:
            log.warning(f"Tanımsız rol '{eff_role}' — daily_writer'a düşürülüyor")
            eff_role = "daily_writer"

        assignment = s.model_roles.get(eff_role)
        if not assignment:
            # Hiç haritalanmamışsa ilk provider + default model
            p = s.providers[0]
            log.warning(f"Rol '{eff_role}' için atama yok — fallback {p.id}/{s.llm_model_general}")
            return self._get_provider(p.id), s.llm_model_general

        pcfg = s.provider_by_id(assignment.provider)
        if not pcfg:
            raise RuntimeError(
                f"Rol '{eff_role}' provider '{assignment.provider}' tanımlı değil"
            )
        return self._get_provider(pcfg.id), assignment.model

    def _get_provider(self, pid: str) -> LLMProvider:
        if pid in self._provider_cache:
            return self._provider_cache[pid]
        s = get_settings()
        cfg = s.provider_by_id(pid)
        if not cfg:
            raise RuntimeError(f"Provider '{pid}' tanımlı değil")
        inst = _build_provider(cfg)
        self._provider_cache[pid] = inst
        return inst

    # ── Public API (mevcut LocalLLM ile birebir aynı imza, backward compat) ──

    async def health(self) -> bool:
        """Tüm provider'lar üzerinden mantıksal OR — biri sağlıklıysa OK."""
        s = get_settings()
        any_ok = False
        for cfg in s.providers:
            try:
                p = self._get_provider(cfg.id)
                if await p.health():
                    any_ok = True
            except Exception as e:
                log.warning(f"Provider {cfg.id} health hatası: {e}")
        return any_ok

    async def complete(
        self,
        prompt: str,
        *,
        role: str | None = None,
        kind: str | None = None,   # backward compat
        system: str | None = None,
        temperature: float | None = None,
        max_tokens: int = 2048,
        label: str = "complete",
        enable_thinking: bool | None = None,
    ) -> str:
        provider, model = self._resolve_role(role, kind)
        s = get_settings()
        temp = temperature if temperature is not None else s.llm_temperature
        return await provider.complete(
            prompt,
            model=model,
            system=system,
            temperature=temp,
            max_tokens=max_tokens,
            label=label,
            enable_thinking=enable_thinking,
        )

    async def stream(
        self,
        prompt: str,
        *,
        role: str | None = None,
        kind: str | None = None,
        system: str | None = None,
        temperature: float | None = None,
        max_tokens: int = 2048,
        label: str = "stream",
        enable_thinking: bool | None = None,
    ) -> AsyncIterator[str]:
        provider, model = self._resolve_role(role, kind)
        s = get_settings()
        temp = temperature if temperature is not None else s.llm_temperature
        async for chunk in provider.stream(
            prompt,
            model=model,
            system=system,
            temperature=temp,
            max_tokens=max_tokens,
            label=label,
            enable_thinking=enable_thinking,
        ):
            yield chunk

    async def embed(self, texts: list[str]) -> list[list[float]]:
        provider, model = self._resolve_role("embed", None)
        return await provider.embed(texts, model=model)

    def model_for(self, kind_or_role: str) -> str:
        """Legacy API — sadece model id'sini döner. Eski kod hâlâ çağırıyor."""
        _, model = self._resolve_role(None, kind_or_role)
        return model

    async def unload(self, model: str | None = None) -> dict[str, Any]:
        """LM Studio'nun unload endpoint'ini çağırır (sadece openai_compatible localhost)."""
        import httpx
        s = get_settings()
        # İlk openai_compatible localhost provider'ını bul
        target_provider = None
        for cfg in s.providers:
            if cfg.kind == "openai_compatible" and "127.0.0.1" in cfg.base_url:
                target_provider = cfg
                break
        if not target_provider:
            return {"ok": False, "error": "uygun lokal provider yok"}
        base = target_provider.base_url.replace("/v1", "")
        target_model = model or s.model_roles.get("daily_writer", None)
        if isinstance(target_model, dict):
            target_model = target_model.get("model")
        if hasattr(target_model, "model"):
            target_model = target_model.model
        async with httpx.AsyncClient(timeout=15) as c:
            try:
                r = await c.post(f"{base}/api/v1/models/unload", json={"model": target_model})
                return {"ok": r.is_success, "status": r.status_code, "model": target_model}
            except Exception as e:
                return {"ok": False, "error": str(e), "model": target_model}


@lru_cache
def get_router() -> LLMRouter:
    return LLMRouter()


def reload_router() -> LLMRouter:
    """Config değiştiğinde router cache'ini sıfırla."""
    get_router.cache_clear()
    return get_router()
