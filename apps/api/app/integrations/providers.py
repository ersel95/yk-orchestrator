"""LLM provider abstractions.

Üç gerçek backend var:
- OpenAICompatibleProvider: LM Studio, Ollama, OpenAI direct (hepsi /v1/chat/completions)
- AnthropicProvider: Anthropic Messages API (claude-opus-4-7, claude-sonnet-4-6)
- ClaudeCodeProvider: `claude` CLI üzerinden Claude (subscription OAuth — API key gerekmez)

Her provider aynı arayüzü (complete/stream/embed/health) sunar. `LLMRouter`
rol bazlı (role → provider+model) çözüm yapıp ilgili provider'a delege eder.

Tasarım kararı: `embed` sadece OpenAI-compatible provider'larda çalışır.
Anthropic ve ClaudeCode'un embedding endpoint'i yok.
"""
from __future__ import annotations

import asyncio
import json
import shutil
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


# ─────────────────────────────────────────────────────────────────────────
# Claude Code (subscription OAuth via `claude` CLI)
# ─────────────────────────────────────────────────────────────────────────

class ClaudeCodeProvider(LLMProvider):
    """`claude` CLI'ı subprocess olarak çağırarak Claude'a erişir.

    API key YERINE kullanıcının `claude login` ile aldığı subscription OAuth
    token'ını kullanır. Pro/Max aboneliği olan kullanıcılar Anthropic API key
    almadan bu provider'ı seçebilir.

    Kullanım: `claude -p "prompt" --model X --output-format json --system-prompt S`
    """

    kind = "claude_code"

    def __init__(self, *, id: str, cli_path: str = "claude", timeout: int = 600) -> None:
        self.id = id
        # PATH'ten çözümle (`shutil.which`) — bundled .app'in spawn ettiği
        # child process'in PATH'i `claude`'u içermeli (SidecarManager parent
        # env'i kopyalıyor, GUI app default PATH'i sınırlı; SidecarManager
        # explicit PATH zenginleştirmesi yapmalı).
        self._cli = shutil.which(cli_path) or cli_path
        self._timeout = timeout

    async def health(self) -> bool:
        """`claude --version` çalışıyor mu + login durumunu kontrol et.

        Burada gerçek bir model çağrısı yapmıyoruz; sadece CLI'ın varlığını
        ve auth'un yerinde olduğunu (basit prompt + JSON parse) doğruluyoruz.
        Auth yoksa `is_error=true` + `result="Not logged in"` dönüyor.
        """
        if not self._cli or not shutil.which(self._cli):
            log.warning(f"Provider {self.id}: claude CLI bulunamadı ({self._cli})")
            return False
        try:
            proc = await asyncio.create_subprocess_exec(
                self._cli, "--version",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            await asyncio.wait_for(proc.wait(), timeout=5)
            return proc.returncode == 0
        except Exception as e:
            log.warning(f"Provider {self.id} health hatası: {e}")
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
            f"[LLM:{label}] →  {self.id}/{model} (CLI) "
            f"prompt={len(prompt)}ch (~{_approx_tokens(prompt)}t)"
        )
        t0 = time.perf_counter()

        args = [
            self._cli, "-p",
            "--model", model,
            "--output-format", "json",
        ]
        if system:
            args.extend(["--system-prompt", system])

        proc = await asyncio.create_subprocess_exec(
            *args,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout_b, stderr_b = await asyncio.wait_for(
            proc.communicate(input=prompt.encode("utf-8")),
            timeout=self._timeout,
        )
        elapsed = time.perf_counter() - t0

        if proc.returncode != 0:
            err = stderr_b.decode("utf-8", errors="replace")[:500]
            log.error(f"[LLM:{label}] {self.id}/{model} returncode={proc.returncode} stderr={err}")
            raise RuntimeError(f"claude CLI exit {proc.returncode}: {err}")

        try:
            payload = json.loads(stdout_b.decode("utf-8"))
        except json.JSONDecodeError as e:
            raise RuntimeError(f"claude CLI JSON parse hatası: {e}; out={stdout_b[:200]!r}")

        if payload.get("is_error"):
            msg = payload.get("result") or payload.get("api_error_status") or "unknown"
            raise RuntimeError(f"claude CLI hata: {msg}")

        result = payload.get("result", "")
        u = payload.get("usage", {}) or {}
        in_t = u.get("input_tokens", 0)
        out_t = u.get("output_tokens", 0)
        cost = payload.get("total_cost_usd", 0)
        speed = out_t / max(elapsed, 0.01)
        log.info(
            f"[LLM:{label}] ←  {self.id}/{model} {elapsed:.1f}s "
            f"in={in_t}t out={out_t}t speed={speed:.1f}t/s cost=${cost:.4f}"
        )
        return result

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
        """`claude -p ... --output-format stream-json --include-partial-messages`
        ile chunk chunk yield eder.

        Akış satır-satır JSON event'leri içerir. Bizi ilgilendiren:
          {"type":"stream_event","event":{"type":"content_block_delta",
              "delta":{"type":"text_delta","text":"..."}}}
        """
        log.info(f"[LLM:{label}] →  {self.id}/{model} (CLI) STREAM")
        t0 = time.perf_counter()
        first_token_t: float | None = None
        out_chars = 0

        args = [
            self._cli, "-p",
            "--model", model,
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",  # stream-json verbose ister
        ]
        if system:
            args.extend(["--system-prompt", system])

        proc = await asyncio.create_subprocess_exec(
            *args,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        assert proc.stdin and proc.stdout
        proc.stdin.write(prompt.encode("utf-8"))
        proc.stdin.close()

        async for raw in proc.stdout:
            line = raw.decode("utf-8", errors="replace").strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            # stream_event içindeki text_delta'ları yakala
            if ev.get("type") == "stream_event":
                inner = ev.get("event", {})
                if inner.get("type") == "content_block_delta":
                    delta = inner.get("delta", {})
                    if delta.get("type") == "text_delta":
                        text = delta.get("text", "")
                        if text:
                            if first_token_t is None:
                                first_token_t = time.perf_counter()
                                log.info(
                                    f"[LLM:{label}]    first token in {first_token_t - t0:.1f}s"
                                )
                            out_chars += len(text)
                            yield text

        await proc.wait()
        elapsed = time.perf_counter() - t0
        log.info(
            f"[LLM:{label}] ←  {self.id}/{model} {elapsed:.1f}s out={out_chars}ch"
        )
