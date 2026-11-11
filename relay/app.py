"""Internal, fixed-destination relay for the Tanzu Hub MCP endpoint.

The relay exists only to let MCP Gateway apply its supported on-platform route
authentication to an external MCP server. It is mapped exclusively to an
apps.internal route and can forward requests only to HUB_MCP_URL.
"""

from __future__ import annotations

import os
from contextlib import asynccontextmanager
from typing import AsyncIterator

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse
from starlette.background import BackgroundTask


UPSTREAM_URL = os.getenv("HUB_MCP_URL", "https://hub.tas06.ylhomelab.com/hub/mcp")
HOP_BY_HOP_HEADERS = {
    "connection",
    "content-length",
    "host",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
}


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    app.state.http = httpx.AsyncClient(
        follow_redirects=False,
        timeout=httpx.Timeout(120.0, connect=15.0),
    )
    try:
        yield
    finally:
        await app.state.http.aclose()


app = FastAPI(title="Tanzu Hub MCP internal relay", lifespan=lifespan)


@app.get("/health")
async def health() -> JSONResponse:
    return JSONResponse({"status": "UP"})


@app.api_route("/mcp", methods=["GET", "POST", "DELETE", "OPTIONS"])
async def relay_mcp(request: Request) -> StreamingResponse:
    request_headers = {
        name: value
        for name, value in request.headers.items()
        if name.lower() not in HOP_BY_HOP_HEADERS
    }
    upstream_request = request.app.state.http.build_request(
        request.method,
        UPSTREAM_URL,
        headers=request_headers,
        content=request.stream(),
    )
    upstream_response = await request.app.state.http.send(upstream_request, stream=True)

    response_headers = {
        name: value
        for name, value in upstream_response.headers.items()
        if name.lower() not in HOP_BY_HOP_HEADERS
    }
    return StreamingResponse(
        upstream_response.aiter_raw(),
        status_code=upstream_response.status_code,
        headers=response_headers,
        background=BackgroundTask(upstream_response.aclose),
    )
