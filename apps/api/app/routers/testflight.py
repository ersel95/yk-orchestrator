import asyncio
import json

from fastapi import APIRouter
from pydantic import BaseModel
from sse_starlette.sse import EventSourceResponse

from app.agents.testflight_agent import TestFlightAgent

router = APIRouter(prefix="/api/testflight", tags=["testflight"])


class UploadBody(BaseModel):
    project_id: int | None = None
    lane: str | None = None


@router.get("/status")
async def status(project_id: int | None = None) -> dict:
    return {"configured": TestFlightAgent().is_configured(project_id=project_id)}


@router.post("/upload")
async def upload(body: UploadBody):
    agent = TestFlightAgent()

    async def event_gen():
        try:
            async for line in agent.upload(project_id=body.project_id, lane=body.lane):
                yield {"event": "line", "data": json.dumps(line, ensure_ascii=False)}
            yield {"event": "done", "data": "{}"}
        except asyncio.CancelledError:
            return

    return EventSourceResponse(event_gen())
