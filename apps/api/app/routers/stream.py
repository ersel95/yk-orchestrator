"""Genel SSE event stream — agent çıktılarını dashboard'a iletir."""
import asyncio
import json

from fastapi import APIRouter
from sse_starlette.sse import EventSourceResponse

from app.core.events import bus

router = APIRouter(prefix="/api/stream", tags=["stream"])


@router.get("/{channel}")
async def subscribe(channel: str):
    queue = bus.subscribe(channel)

    async def event_gen():
        try:
            while True:
                payload = await queue.get()
                yield {"event": "message", "data": json.dumps(payload, ensure_ascii=False)}
        except asyncio.CancelledError:
            return
        finally:
            bus.unsubscribe(channel, queue)

    return EventSourceResponse(event_gen())
