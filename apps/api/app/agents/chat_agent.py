"""ChatAgent — RAG destekli soru-cevap. Proje filtresi opsiyonel."""
from __future__ import annotations

from collections.abc import AsyncIterator

from app.agents.prompts import CHAT_SYSTEM, CHAT_USER_TEMPLATE
from app.core.logging import get_logger
from app.integrations.llm import get_llm
from app.integrations.rag import get_rag

log = get_logger(__name__)


def _format_context(results: list[dict]) -> str:
    lines: list[str] = []
    for r in results[:8]:
        meta = r.get("metadata") or {}
        header = f"[{r['collection']}#{r['id']}]"
        if meta.get("date"):
            header += f" ({meta['date']})"
        lines.append(f"{header}\n{r['document']}\n")
    return "\n".join(lines) or "(eşleşen kayıt yok)"


class ChatAgent:
    async def answer(self, question: str, project_id: int | None = None) -> dict:
        rag = get_rag()
        results = await rag.search(question, k=5, project_id=project_id)
        context = _format_context(results)
        prompt = CHAT_USER_TEMPLATE.format(question=question, context=context)
        llm = get_llm()
        text = await llm.complete(prompt, system=CHAT_SYSTEM, kind="general", max_tokens=1500)
        return {
            "answer": text,
            "sources": [
                {"collection": r["collection"], "id": r["id"], "metadata": r["metadata"]}
                for r in results
            ],
        }

    async def stream_answer(
        self, question: str, project_id: int | None = None
    ) -> AsyncIterator[dict]:
        rag = get_rag()
        results = await rag.search(question, k=5, project_id=project_id)
        context = _format_context(results)

        yield {
            "type": "sources",
            "data": [
                {"collection": r["collection"], "id": r["id"], "metadata": r["metadata"]}
                for r in results
            ],
        }

        prompt = CHAT_USER_TEMPLATE.format(question=question, context=context)
        llm = get_llm()
        async for chunk in llm.stream(prompt, system=CHAT_SYSTEM, kind="general", max_tokens=1500):
            yield {"type": "delta", "data": chunk}
        yield {"type": "done"}
