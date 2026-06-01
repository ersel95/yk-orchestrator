import asyncio
import json

from fastapi import APIRouter
from pydantic import BaseModel
from sse_starlette.sse import EventSourceResponse

from app.agents.chat_agent import ChatAgent
from app.core.action_log import log_action

router = APIRouter(prefix="/api/chat", tags=["chat"])


class AskBody(BaseModel):
    question: str
    project_id: int | None = None
    scope: str = "active"  # "active" | "all"


@router.post("/ask")
async def ask(body: AskBody) -> dict:
    pid = body.project_id if body.scope == "active" else None
    log_action(
        action_type="chat.ask",
        target_kind="thread",
        payload={"question": body.question[:200], "scope": body.scope},
        project_id=body.project_id,
    )
    return await ChatAgent().answer(body.question, project_id=pid)


@router.get("/stream")
async def stream(question: str, project_id: int | None = None, scope: str = "active"):
    pid = project_id if scope == "active" else None
    log_action(
        action_type="chat.ask",
        target_kind="thread",
        payload={"question": question[:200], "scope": scope, "stream": True},
        project_id=project_id,
    )
    agent = ChatAgent()

    async def event_gen():
        try:
            async for ev in agent.stream_answer(question, project_id=pid):
                yield {
                    "event": ev["type"],
                    "data": json.dumps(ev.get("data", ""), ensure_ascii=False),
                }
        except asyncio.CancelledError:
            return

    return EventSourceResponse(event_gen())
