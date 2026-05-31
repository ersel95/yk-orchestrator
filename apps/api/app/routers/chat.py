import asyncio
import json

from fastapi import APIRouter
from pydantic import BaseModel
from sse_starlette.sse import EventSourceResponse

from app.agents.chat_agent import ChatAgent

router = APIRouter(prefix="/api/chat", tags=["chat"])


class AskBody(BaseModel):
    question: str
    project_id: int | None = None
    scope: str = "active"  # "active" | "all"


@router.post("/ask")
async def ask(body: AskBody) -> dict:
    pid = body.project_id if body.scope == "active" else None
    return await ChatAgent().answer(body.question, project_id=pid)


@router.get("/stream")
async def stream(question: str, project_id: int | None = None, scope: str = "active"):
    pid = project_id if scope == "active" else None
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
