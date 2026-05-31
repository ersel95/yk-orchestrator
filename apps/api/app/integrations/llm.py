"""Yerel LLM client (LM Studio / Ollama OpenAI-uyumlu API)."""
from __future__ import annotations

import time
from collections.abc import AsyncIterator
from typing import Literal

from openai import AsyncOpenAI
from tenacity import AsyncRetrying, stop_after_attempt, wait_exponential

from app.core.config import get_settings
from app.core.logging import get_logger

log = get_logger(__name__)


def _approx_tokens(text: str) -> int:
    """Çok kaba token tahmini (~4 char/token, Türkçe için ~3.5)."""
    return max(1, len(text) // 4)

ModelKind = Literal["general", "code", "embed"]


class LocalLLM:
    """Yerel LLM ile konuşur. Üç model rolü vardır:
    - general: günlük metin, daily, chat
    - code: PR diff özeti, kod analizi
    - embed: vektör arama
    """

    def __init__(self) -> None:
        s = get_settings()
        self._client = AsyncOpenAI(
            base_url=s.llm_base_url,
            api_key=s.llm_api_key,
            timeout=s.llm_timeout_seconds,
        )
        self._models = {
            "general": s.llm_model_general,
            "code": s.llm_model_code,
            "embed": s.llm_model_embed,
        }
        self._temperature = s.llm_temperature

    def model_for(self, kind: ModelKind) -> str:
        return self._models[kind]

    async def health(self) -> bool:
        try:
            models = await self._client.models.list()
            return len(models.data) >= 0
        except Exception as e:
            log.warning(f"LLM erişilemedi: {e}")
            return False

    async def complete(
        self,
        prompt: str,
        *,
        kind: ModelKind = "general",
        system: str | None = None,
        temperature: float | None = None,
        max_tokens: int = 2048,
        label: str = "complete",
        enable_thinking: bool | None = None,
    ) -> str:
        messages = []
        if system:
            messages.append({"role": "system", "content": system})
        messages.append({"role": "user", "content": prompt})

        prompt_chars = (len(system) if system else 0) + len(prompt)
        prompt_tok_est = _approx_tokens((system or "") + prompt)
        model = self.model_for(kind)
        log.info(
            f"[LLM:{label}] →  model={model} kind={kind} "
            f"prompt={prompt_chars}ch (~{prompt_tok_est}t) max_out={max_tokens}t "
            f"thinking={enable_thinking}"
        )
        t0 = time.perf_counter()

        extra: dict = {}
        if enable_thinking is not None:
            extra["extra_body"] = {"chat_template_kwargs": {"enable_thinking": enable_thinking}}

        async for attempt in AsyncRetrying(
            stop=stop_after_attempt(2),
            wait=wait_exponential(multiplier=1, min=1, max=8),
            reraise=True,
        ):
            with attempt:
                resp = await self._client.chat.completions.create(
                    model=model,
                    messages=messages,
                    temperature=temperature if temperature is not None else self._temperature,
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
                        f"[LLM:{label}] ←  {elapsed:.1f}s "
                        f"prompt={u.prompt_tokens}t out={u.completion_tokens}t "
                        f"total={u.total_tokens}t speed={speed:.1f}t/s finish={finish}"
                    )
                else:
                    log.info(
                        f"[LLM:{label}] ←  {elapsed:.1f}s out_chars={len(content)} finish={finish}"
                    )
                if finish == "length":
                    log.warning(
                        f"[LLM:{label}] çıktı max_tokens'a takıldı (finish_reason=length) — "
                        f"yarım kalmış olabilir, max_tokens veya context artırılmalı"
                    )
                return content
        return ""

    async def stream(
        self,
        prompt: str,
        *,
        kind: ModelKind = "general",
        system: str | None = None,
        temperature: float | None = None,
        max_tokens: int = 2048,
        label: str = "stream",
        enable_thinking: bool | None = None,
    ) -> AsyncIterator[str]:
        messages = []
        if system:
            messages.append({"role": "system", "content": system})
        messages.append({"role": "user", "content": prompt})

        prompt_chars = (len(system) if system else 0) + len(prompt)
        prompt_tok_est = _approx_tokens((system or "") + prompt)
        model = self.model_for(kind)
        log.info(
            f"[LLM:{label}] →  model={model} kind={kind} STREAM "
            f"prompt={prompt_chars}ch (~{prompt_tok_est}t) max_out={max_tokens}t "
            f"thinking={enable_thinking}"
        )
        t0 = time.perf_counter()
        first_token_t: float | None = None
        out_chars = 0

        extra: dict = {}
        if enable_thinking is not None:
            extra["extra_body"] = {"chat_template_kwargs": {"enable_thinking": enable_thinking}}

        stream = await self._client.chat.completions.create(
            model=model,
            messages=messages,
            temperature=temperature if temperature is not None else self._temperature,
            max_tokens=max_tokens,
            stream=True,
            **extra,
        )
        finish_reason: str | None = None
        chunk_count = 0
        reasoning_chars = 0
        first_reasoning_logged = False
        async for chunk in stream:
            chunk_count += 1
            if not chunk.choices:
                continue
            choice = chunk.choices[0]
            if choice.finish_reason:
                finish_reason = choice.finish_reason
            d = choice.delta
            if d is None:
                continue
            reasoning = getattr(d, "reasoning_content", None) or getattr(d, "reasoning", None)
            if reasoning:
                reasoning_chars += len(reasoning)
                if not first_reasoning_logged:
                    log.info(
                        f"[LLM:{label}]    reasoning_content kanalı aktif "
                        f"(ilk chunk {len(reasoning)}ch) — model thinking üretiyor"
                    )
                    first_reasoning_logged = True
            delta = d.content
            if delta:
                if first_token_t is None:
                    first_token_t = time.perf_counter()
                    log.info(f"[LLM:{label}]    first token in {first_token_t - t0:.1f}s")
                out_chars += len(delta)
                yield delta

        elapsed = time.perf_counter() - t0
        out_tok_est = _approx_tokens(" " * out_chars)
        ttft = (first_token_t - t0) if first_token_t else 0
        gen_time = max(elapsed - ttft, 0.01)
        speed = out_tok_est / gen_time
        log.info(
            f"[LLM:{label}] ←  {elapsed:.1f}s ttft={ttft:.1f}s "
            f"out={out_chars}ch (~{out_tok_est}t) speed≈{speed:.1f}t/s "
            f"chunks={chunk_count} reasoning={reasoning_chars}ch finish={finish_reason}"
        )
        if finish_reason == "length":
            log.warning(
                f"[LLM:{label}] çıktı max_tokens'a takıldı (finish_reason=length) — "
                f"yarım kalmış olabilir, max_tokens veya context artırılmalı"
            )
        if out_chars == 0 and reasoning_chars > 0:
            log.warning(
                f"[LLM:{label}] content boş, sadece reasoning üretildi ({reasoning_chars}ch) — "
                f"thinking modu aktif, /no_think veya model ayarı kontrol edilmeli"
            )

    async def embed(self, texts: list[str]) -> list[list[float]]:
        if not texts:
            return []
        resp = await self._client.embeddings.create(
            model=self.model_for("embed"),
            input=texts,
        )
        return [d.embedding for d in resp.data]

    async def unload(self, model: str | None = None) -> dict:
        """LM Studio'nun /api/v1/models/unload endpoint'ini çağırır.

        model verilmezse şu an ana modeli boşaltır.
        """
        import httpx

        target = model or self.model_for("general")
        base = str(self._client.base_url).replace("/v1", "")
        async with httpx.AsyncClient(timeout=15) as c:
            try:
                r = await c.post(f"{base}/api/v1/models/unload", json={"model": target})
                return {"ok": r.is_success, "status": r.status_code, "model": target}
            except Exception as e:
                return {"ok": False, "error": str(e), "model": target}


_llm: LocalLLM | None = None


def get_llm() -> LocalLLM:
    global _llm
    if _llm is None:
        _llm = LocalLLM()
    return _llm
