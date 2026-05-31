"""TranscriptIngestAgent — Daily transkriptini parse eder, özetler, aksiyon çıkarır.

Proje bazlı.
"""
from __future__ import annotations

import json
import re
from datetime import date

from sqlmodel import Session

from app.agents.prompts import TRANSCRIPT_PARSE_SYSTEM, TRANSCRIPT_PARSE_USER
from app.core.active_project import get_project, resolve_project_id
from app.core.db import engine
from app.core.logging import get_logger
from app.integrations.llm import get_llm
from app.integrations.rag import get_rag
from app.models import Transcript, TranscriptUtterance

log = get_logger(__name__)

UTTERANCE_RE = re.compile(r"^\s*([A-Za-zÇĞİÖŞÜçğıöşü .'-]{2,40}):\s*(.+)$")


def _parse_utterances(raw: str) -> list[tuple[str, str]]:
    out: list[tuple[str, str]] = []
    current_speaker: str | None = None
    buffer: list[str] = []
    for line in raw.splitlines():
        m = UTTERANCE_RE.match(line)
        if m:
            if current_speaker is not None and buffer:
                out.append((current_speaker, " ".join(buffer).strip()))
            current_speaker = m.group(1).strip()
            buffer = [m.group(2).strip()]
        else:
            if current_speaker is not None:
                buffer.append(line.strip())
    if current_speaker is not None and buffer:
        out.append((current_speaker, " ".join(buffer).strip()))
    return out


def _extract_json(text: str) -> dict | None:
    text = text.strip()
    if text.startswith("```"):
        text = re.sub(r"^```(?:json)?", "", text).strip()
        text = re.sub(r"```$", "", text).strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        m = re.search(r"\{.*\}", text, re.DOTALL)
        if m:
            try:
                return json.loads(m.group(0))
            except json.JSONDecodeError:
                return None
        return None


class TranscriptIngestAgent:
    async def ingest(
        self,
        raw_text: str,
        project_id: int | None = None,
        meeting_date: date | None = None,
        title: str = "Daily Standup",
    ) -> dict:
        pid = resolve_project_id(project_id)
        proj = get_project(pid)
        meeting_date = meeting_date or date.today()
        utterances = _parse_utterances(raw_text)

        prompt = TRANSCRIPT_PARSE_USER.format(meeting_date=meeting_date.isoformat(), raw=raw_text[:20000])
        llm = get_llm()
        ai_raw = await llm.complete(
            prompt,
            system=TRANSCRIPT_PARSE_SYSTEM,
            kind="general",
            max_tokens=2200,
            temperature=0.1,
        )
        parsed = _extract_json(ai_raw) or {}

        with Session(engine) as session:
            transcript = Transcript(
                project_id=pid,
                meeting_date=meeting_date,
                title=title,
                raw_text=raw_text,
                summary=json.dumps(parsed.get("speakers") or [], ensure_ascii=False),
                action_items=json.dumps(
                    {
                        "action_items": parsed.get("action_items", []),
                        "blockers": parsed.get("blockers", []),
                        "decisions": parsed.get("decisions", []),
                    },
                    ensure_ascii=False,
                ),
            )
            session.add(transcript)
            session.commit()
            session.refresh(transcript)

            for i, (speaker, text) in enumerate(utterances):
                session.add(
                    TranscriptUtterance(
                        transcript_id=transcript.id,
                        speaker=speaker,
                        text=text,
                        order=i,
                    )
                )
            session.commit()
            tid = transcript.id

        rag = get_rag()
        ids = [f"transcript-{pid}-{tid}-{i}" for i, _ in enumerate(utterances)] or [
            f"transcript-{pid}-{tid}-full"
        ]
        docs = [f"[{proj.name}] {sp}: {tx}" for sp, tx in utterances] or [raw_text[:2000]]
        metas = [
            {
                "project_id": pid,
                "transcript_id": tid,
                "speaker": sp,
                "date": meeting_date.isoformat(),
            }
            for sp, _ in utterances
        ] or [{"project_id": pid, "transcript_id": tid, "date": meeting_date.isoformat()}]
        await rag.upsert("transcript", ids, docs, metas)

        return {
            "id": tid,
            "project_id": pid,
            "meeting_date": meeting_date.isoformat(),
            "utterance_count": len(utterances),
            "parsed": parsed,
            "raw_ai_output": ai_raw if not parsed else None,
        }
