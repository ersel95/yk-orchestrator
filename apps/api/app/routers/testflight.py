import asyncio
import json

from fastapi import APIRouter
from pydantic import BaseModel
from sse_starlette.sse import EventSourceResponse

from app.agents.testflight_agent import TestFlightAgent
from app.core.action_log import log_action

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
    log_action(
        action_type="testflight.upload.start",
        target_kind="build",
        payload={"lane": body.lane},
        project_id=body.project_id,
    )

    async def event_gen():
        success = False
        try:
            async for line in agent.upload(project_id=body.project_id, lane=body.lane):
                yield {"event": "line", "data": json.dumps(line, ensure_ascii=False)}
            yield {"event": "done", "data": "{}"}
            success = True
        except asyncio.CancelledError:
            return
        finally:
            log_action(
                action_type="testflight.upload.done",
                target_kind="build",
                payload={"lane": body.lane, "completed": success},
                outcome="success" if success else "failure",
                project_id=body.project_id,
            )

    return EventSourceResponse(event_gen())
