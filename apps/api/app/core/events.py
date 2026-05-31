"""Basit pub/sub — agent çıktılarını dashboard'a SSE/WebSocket ile akıtmak için."""
from __future__ import annotations

import asyncio
from collections import defaultdict
from typing import Any


class EventBus:
    def __init__(self) -> None:
        self._subscribers: dict[str, list[asyncio.Queue]] = defaultdict(list)

    def subscribe(self, channel: str) -> asyncio.Queue:
        queue: asyncio.Queue = asyncio.Queue(maxsize=256)
        self._subscribers[channel].append(queue)
        return queue

    def unsubscribe(self, channel: str, queue: asyncio.Queue) -> None:
        if queue in self._subscribers.get(channel, []):
            self._subscribers[channel].remove(queue)

    async def publish(self, channel: str, payload: dict[str, Any]) -> None:
        for q in list(self._subscribers.get(channel, [])):
            try:
                q.put_nowait(payload)
            except asyncio.QueueFull:
                pass


bus = EventBus()
