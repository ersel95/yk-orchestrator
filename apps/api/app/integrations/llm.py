"""Backward-compat shim — LocalLLM artık ince bir LLMRouter wrapper'ı.

Eski kod (`get_llm().complete(prompt, kind="general")`) hiç değişmeden çalışır.
Yeni kod doğrudan `app.core.llm_router.get_router()` kullanmalı.
"""
from __future__ import annotations

from collections.abc import AsyncIterator
from typing import Literal

from app.core.llm_router import get_router

ModelKind = Literal["general", "code", "embed"]


class LocalLLM:
    """LLMRouter'ın eski LocalLLM API'sine adaptörü.

    Yeni multi-provider mimaride agent'lar ya bu shim'i (eski yol) ya da
    doğrudan get_router() (yeni yol, role= parametresiyle) kullanabilir.
    """

    def __init__(self) -> None:
        self._router = get_router()

    async def health(self) -> bool:
        return await self._router.health()

    def model_for(self, kind: ModelKind) -> str:
        return self._router.model_for(kind)

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
        return await self._router.complete(
            prompt,
            kind=kind,
            system=system,
            temperature=temperature,
            max_tokens=max_tokens,
            label=label,
            enable_thinking=enable_thinking,
        )

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
        async for chunk in self._router.stream(
            prompt,
            kind=kind,
            system=system,
            temperature=temperature,
            max_tokens=max_tokens,
            label=label,
            enable_thinking=enable_thinking,
        ):
            yield chunk

    async def embed(self, texts: list[str]) -> list[list[float]]:
        return await self._router.embed(texts)

    async def unload(self, model: str | None = None) -> dict:
        return await self._router.unload(model)


_llm: LocalLLM | None = None


def get_llm() -> LocalLLM:
    global _llm
    if _llm is None:
        _llm = LocalLLM()
    return _llm
