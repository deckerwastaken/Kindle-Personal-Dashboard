"""
Tracks connected WebSocket clients (the Kindle daemon, and anything else
that connects to /ws) and broadcasts state updates to all of them.
"""

import asyncio
import json
import logging
from typing import List

from fastapi import WebSocket

logger = logging.getLogger("kindle_dashboard.ws")


class ConnectionManager:
    def __init__(self):
        self._connections: List[WebSocket] = []
        self._lock = asyncio.Lock()

    async def connect(self, websocket: WebSocket) -> None:
        await websocket.accept()
        async with self._lock:
            self._connections.append(websocket)
        logger.info("Client connected (%d total)", len(self._connections))

    async def disconnect(self, websocket: WebSocket) -> None:
        async with self._lock:
            if websocket in self._connections:
                self._connections.remove(websocket)
        logger.info("Client disconnected (%d total)", len(self._connections))

    async def broadcast(self, data: dict) -> None:
        message = json.dumps(data)
        async with self._lock:
            targets = list(self._connections)
        dead: List[WebSocket] = []
        for ws in targets:
            try:
                await ws.send_text(message)
            except Exception as e:
                logger.warning("Failed to send to a client, will drop it: %s", e)
                dead.append(ws)
        if dead:
            async with self._lock:
                for ws in dead:
                    if ws in self._connections:
                        self._connections.remove(ws)
