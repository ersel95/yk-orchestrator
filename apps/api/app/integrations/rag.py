"""ChromaDB tabanlı yerel RAG katmanı.

Koleksiyonlar:
- daily       : daily metinler (final_text)
- transcript  : daily transkriptlerden parçalar
- pull_request: PR başlık + açıklama + özet
- jira        : Jira issue özetleri
"""
from __future__ import annotations

from pathlib import Path
from typing import Iterable

import chromadb
from chromadb.config import Settings as ChromaSettings

from app.core.config import get_settings
from app.core.logging import get_logger
from app.integrations.llm import get_llm

log = get_logger(__name__)

COLLECTIONS = ("daily", "transcript", "pull_request", "jira")


class RAGStore:
    def __init__(self) -> None:
        s = get_settings()
        Path(s.chroma_persist_dir).mkdir(parents=True, exist_ok=True)
        self._client = chromadb.PersistentClient(
            path=s.chroma_persist_dir,
            settings=ChromaSettings(anonymized_telemetry=False),
        )
        self._llm = get_llm()
        self._collections = {
            name: self._client.get_or_create_collection(name=name) for name in COLLECTIONS
        }

    async def upsert(
        self,
        collection: str,
        ids: list[str],
        documents: list[str],
        metadatas: list[dict] | None = None,
    ) -> None:
        if not ids:
            return
        embeddings = await self._llm.embed(documents)
        self._collections[collection].upsert(
            ids=ids,
            documents=documents,
            metadatas=metadatas or [{} for _ in ids],
            embeddings=embeddings,
        )

    async def search(
        self,
        query: str,
        *,
        collections: Iterable[str] = COLLECTIONS,
        k: int = 5,
        project_id: int | None = None,
    ) -> list[dict]:
        if not query.strip():
            return []
        embed = (await self._llm.embed([query]))[0]
        where = {"project_id": project_id} if project_id is not None else None
        results: list[dict] = []
        for name in collections:
            coll = self._collections[name]
            try:
                res = coll.query(query_embeddings=[embed], n_results=k, where=where)
            except Exception as e:
                log.warning(f"RAG sorgu hatası ({name}): {e}")
                continue
            ids = (res.get("ids") or [[]])[0]
            docs = (res.get("documents") or [[]])[0]
            metas = (res.get("metadatas") or [[]])[0]
            dists = (res.get("distances") or [[]])[0]
            for i, doc, meta, dist in zip(ids, docs, metas, dists):
                results.append(
                    {
                        "collection": name,
                        "id": i,
                        "document": doc,
                        "metadata": meta or {},
                        "score": float(dist),
                    }
                )
        results.sort(key=lambda r: r["score"])
        return results[: k * 2]

    def count(self, collection: str) -> int:
        return self._collections[collection].count()


_store: RAGStore | None = None


def get_rag() -> RAGStore:
    global _store
    if _store is None:
        _store = RAGStore()
    return _store
