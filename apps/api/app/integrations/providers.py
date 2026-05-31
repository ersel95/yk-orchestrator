"""LLM provider abstractions.

İki gerçek backend var:
- OpenAICompatibleProvider: LM Studio, Ollama, OpenAI direct (hepsi /v1/chat/completions)
- AnthropicProvider: Anthropic Messages API (claude-opus-4-7, claude-sonnet-4-6)

Her provider aynı arayüzü (complete/stream/embed/health) sunar. `LLMRouter`
rol bazlı (role → provider+model) çözüm yapıp ilgili provider'a delege eder.

Tasarım kararı: `embed` sadece OpenAI-compatible provider'larda çalışır.
Anthropic'in embedding endpoint'i yok; embed rolü mutlaka OAI-compat
provider'a maplenmeli (config validation seviyesinde uyarı).
"""
from __future__ import annotations

import time
from abc import ABC, abstractmethod
from collections.abc import AsyncIterator
from typing import Any

from app.core.logging import get_logger

log = get_logger(__name__)


def _approx_tokens(text: str) -> int:
    return max(1, len(text) // 4)


# ─────────────────────────────────────────────────────────────────────────
# Abstract base
# ─────────────────────────────────────────────────────────────────────────

class LLMProvider(ABC):
    id: str  # config'deki provider id (örn "lm_studio", "anthropic")
    kind: str  # "openai_compatible" | "anthropic"

    @abstractmethod
    async def health(self) -> bool: ...

    @abstractmethod
    async def complete(
        self,
        prompt: str,
        *,
        model: str,
        system: str | None = None,
        temperature: float = 0.3,
        max_tokens: int = 2048,
        label: str = "complete",
        enable_thinking: bool | None = None,
    ) -> str: ...

    @abstractmethod
    def stream(
        self,
        prompt: str,
        *,
        model: str,
        system: str | None = None,
        temperature: float = 0.3,
        max_tokens: int = 2048,
        label: str = "stream",
        enable_thinking: bool | None = None,
    ) -> AsyncIterator[str]: ...

    async def embed(self, texts: list[str], *, model: str) -> list[list[float]]:
        raise NotImplementedError(f"{self.id}: embed desteklenmiyor")


# ─────────────────────────────────────────────────────────────────────────
# OpenAI-compatible (LM Studio / Ollama / OpenAI direct)
# ─────────────────────────────────────────────────────────────────────────

class OpenAICompatibleProvider(LLMProvider):
    """OpenAI Chat Completions API uyumlu endpoint'ler.

    LM Studio (http://127.0.0.1:1234/v1), Ollama (http://127.0.0.1:11434/v1),
    OpenAI (https://api.openai.com/v1) hepsi aynı kalıba sığar.
    """

    kind = "openai_compatible"

    def __init__(self, *, id: str, base_url: str, api_key: str, timeout: int = 300) -> None:
        from openai import AsyncOpenAI

        self.id = id
        self._client = AsyncOpenAI(base_url=base_url, api_key=api_key or "noop", timeout=timeout)

    async def health(self) -> bool:
        try:
            models = await self._client.models.list()
            return len(models.data) >= 0
        except Exception as e:
            log.warning(f"Provider {self.id} erişilemedi: {e}")
            return False

    async def complete(
        self,
        prompt: str,
        *,
        model: str,
        system: str | None = None,
        temperature: float = 0.3,
        max_tokens: int = 2048,
        label: str = "complete",
        enable_thinking: bool | None = None,
    ) -> str:
        messages: list[dict[str, Any]] = []
        if system:
            messages.append({"role": "system", "content": system})
        messages.append({"role": "user", "content": prompt})

        prompt_chars = (len(system) if system else 0) + len(prompt)
        log.info(
            f"[LLM:{label}] →  {self.id}/{model} "
            f"prompt={prompt_chars}ch (~{_approx_tokens((system or '') + prompt)}t) "
            f"max_out={max_tokens}t thinking={enable_thinking}"
        )
        t0 = time.perf_counter()

        extra: dict[str, Any] = {}
        if enable_thinking is not None:
            extra["extra_body"] = {"chat_template_kwargs": {"enable_thinking": enable_thinking}}

        resp = await self._client.chat.completions.create(
            model=model,
            messages=messages,
            temperature=temperature,
            max_tokens=max_tokens,
            **extra,
        )
        elapsed = time.perf_counter() - t0
        content = resp.choices[0].message.content or ""
        finish = resp.choices[0].finish_reason
        u = resp.usage
        if u:
            speed = (u.completion_tokens or 0) / max(elapsed, 0.01)
            log.info(
                f"[LLM:{label}] ←  {self.id}/{model} {elapsed:.1f}s "
                f"prompt={u.prompt_tokens}t out={u.completion_tokens}t "
                f"speed={speed:.1f}t/s finish={finish}"
            )
        return content

    async def stream(
        self,
        prompt: str,
        *,
        model: str,
        system: str | None = None,
        temperature: float = 0.3,
        max_tokens: int = 2048,
        label: str = "stream",
        enable_thinking: bool | None = None,
    ) -> AsyncIterator[str]:
        messages: list[dict[str, Any]] = []
        if system:
            messages.append({"role": "system", "content": system})
        messages.append({"role": "user", "content": prompt})

        log.info(f"[LLM:{label}] →  {self.id}/{model} STREAM max_out={max_tokens}t")
        t0 = time.perf_counter()
        first_token_t: float | None = None
        out_chars = 0

        extra: dict[str, Any] = {}
        if enable_thinking is not None:
            extra["extra_body"] = {"chat_template_kwargs": {"enable_thinking": enable_thinking}}

        stream = await self._client.chat.completions.create(
            model=model,
            messages=messages,
            temperature=temperature,
            max_tokens=max_tokens,
            stream=True,
            **extra,
        )
        finish_reason: str | None = None
        async for chunk in stream:
            if not chunk.choices:
                continue
            choice = chunk.choices[0]
            if choice.finish_reason:
                finish_reason = choice.finish_reason
            d = choice.delta
            if d is None:
                continue
            delta = d.content
            if delta:
                if first_token_t is None:
                    first_token_t = time.perf_counter()
                    log.info(f"[LLM:{label}]    first token in {first_token_t - t0:.1f}s")
                out_chars += len(delta)
                yield delta
        elapsed = time.perf_counter() - t0
        log.info(
            f"[LLM:{label}] ←  {self.id}/{model} {elapsed:.1f}s "
            f"out={out_chars}ch finish={finish_reason}"
        )

    async def embed(self, texts: list[str], *, model: str) -> list[list[float]]:
        if not texts:
            return []
        resp = await self._client.embeddings.create(model=model, input=texts)
        return [d.embedding for d in resp.data]


# ─────────────────────────────────────────────────────────────────────────
# Anthropic
# ─────────────────────────────────────────────────────────────────────────

class AnthropicProvider(LLMProvider):
    """Anthropic Messages API.

    Modeller: claude-opus-4-7, claude-sonnet-4-6, claude-haiku-4-5-20251001
    """

    kind = "anthropic"

    def __init__(self, *, id: str, api_key: str, timeout: int = 300) -> None:
        from anthropic import AsyncAnthropic

        self.id = id
        self._client = AsyncAnthropic(api_key=api_key, timeout=timeout)

    async def health(self) -> bool:
        # Anthropic'in /models endpoint'i var (recent SDK). Minimal sağlık:
        # tek-token bir mesaj göndermek pahalı; bunun yerine modelleri çek.
        try:
            await self._client.models.list(limit=1)
            return True
        except Exception as e:
            log.warning(f"Provider {self.id} erişilemedi: {e}")
            return False

    async def complete(
        self,
        prompt: str,
        *,
        model: str,
        system: str | None = None,
        temperature: float = 0.3,
        max_tokens: int = 2048,
        label: str = "complete",
        enable_thinking: bool | None = None,
    ) -> str:
        log.info(
            f"[LLM:{label}] →  {self.id}/{model} "
            f"prompt={len(prompt)}ch (~{_approx_tokens(prompt)}t) max_out={max_tokens}t"
        )
        t0 = time.perf_counter()

        kwargs: dict[str, Any] = {
            "model": model,
            "max_tokens": max_tokens,
            "messages": [{"role": "user", "content": prompt}],
            "temperature": temperature,
        }
        if system:
            kwargs["system"] = system
        if enable_thinking:
            # Claude'un extended thinking modu (opus 4.x'te destekli)
            kwargs["thinking"] = {"type": "enabled", "budget_tokens": 4096}

        resp = await self._client.messages.create(**kwargs)
        elapsed = time.perf_counter() - t0

        # content bloklarını birleştir (text type olanları)
        parts = []
        for block in resp.content:
            btype = getattr(block, "type", None)
            if btype == "text":
                parts.append(block.text)
        content = "".join(parts)

        u = resp.usage
        speed = (u.output_tokens or 0) / max(elapsed, 0.01)
        log.info(
            f"[LLM:{label}] ←  {self.id}/{model} {elapsed:.1f}s "
            f"in={u.input_tokens}t out={u.output_tokens}t "
            f"speed={speed:.1f}t/s stop={resp.stop_reason}"
        )
        return content

    async def stream(
        self,
        prompt: str,
        *,
        model: str,
        system: str | None = None,
        temperature: float = 0.3,
        max_tokens: int = 2048,
        label: str = "stream",
        enable_thinking: bool | None = None,
    ) -> AsyncIterator[str]:
        log.info(f"[LLM:{label}] →  {self.id}/{model} STREAM max_out={max_tokens}t")
        t0 = time.perf_counter()
        first_token_t: float | None = None
        out_chars = 0

        kwargs: dict[str, Any] = {
            "model": model,
            "max_tokens": max_tokens,
            "messages": [{"role": "user", "content": prompt}],
            "temperature": temperature,
        }
        if system:
            kwargs["system"] = system
        if enable_thinking:
            kwargs["thinking"] = {"type": "enabled", "budget_tokens": 4096}

        async with self._client.messages.stream(**kwargs) as stream:
            async for text in stream.text_stream:
                if first_token_t is None:
                    first_token_t = time.perf_counter()
                    log.info(f"[LLM:{label}]    first token in {first_token_t - t0:.1f}s")
                out_chars += len(text)
                yield text
        elapsed = time.perf_counter() - t0
        log.info(f"[LLM:{label}] ←  {self.id}/{model} {elapsed:.1f}s out={out_chars}ch")
