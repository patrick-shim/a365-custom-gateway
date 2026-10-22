from __future__ import annotations

import asyncio
import json
import logging
import os
import socket
import subprocess
import sys
import time
import urllib.request
from contextlib import asynccontextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import httpx
import pytest
from mcp.server.mcpserver.exceptions import ToolError

from weather_agent.mcp_client import McpWeatherClient
from weather_agent.weather_mcp_server import (
    FORECAST_URL,
    GEOCODING_URL,
    MAX_RESPONSE_BYTES,
    WeatherServiceError,
    create_server,
    fetch_current_weather,
)


@dataclass
class FakeResponse:
    payload: Any
    status_code: int = 200
    content_type: str = "application/json"
    raw_content: bytes | None = None
    content_length: str | None = None
    chunks: list[bytes] | None = None
    delay_seconds: float = 0
    streamed_chunks: int = 0

    @property
    def headers(self) -> dict[str, str]:
        values = {"content-type": self.content_type}
        if self.content_length is not None:
            values["content-length"] = self.content_length
        return values

    async def aiter_bytes(self):
        content = self.raw_content or json.dumps(self.payload).encode("utf-8")
        for chunk in self.chunks or [content]:
            if self.delay_seconds:
                await asyncio.sleep(self.delay_seconds)
            self.streamed_chunks += 1
            yield chunk


class FakeHttpClient:
    def __init__(self, responses: list[FakeResponse]) -> None:
        self.responses = list(responses)
        self.calls: list[tuple[str, dict[str, Any]]] = []

    @asynccontextmanager
    async def stream(
        self, method: str, url: str, *, params: dict[str, Any]
    ):
        assert method == "GET"
        self.calls.append((url, dict(params)))
        yield self.responses.pop(0)


def test_fetch_current_weather_uses_only_fixed_hosts_and_returns_structured_data() -> None:
    client = FakeHttpClient(
        [
            FakeResponse(
                {
                    "results": [
                        {
                            "name": "Seoul",
                            "admin1": "Seoul",
                            "country": "South Korea",
                            "country_code": "KR",
                            "latitude": 37.566,
                            "longitude": 126.9784,
                            "timezone": "Asia/Seoul",
                        }
                    ]
                }
            ),
            FakeResponse(
                {
                    "current": {
                        "time": "2026-10-21T12:00",
                        "temperature_2m": 18.2,
                        "apparent_temperature": 17.4,
                        "relative_humidity_2m": 55,
                        "precipitation": 0,
                        "weather_code": 1,
                        "wind_speed_10m": 7.1,
                    },
                    "current_units": {
                        "temperature_2m": "°C",
                        "apparent_temperature": "°C",
                        "relative_humidity_2m": "%",
                        "precipitation": "mm",
                        "wind_speed_10m": "km/h",
                    },
                }
            ),
        ]
    )

    result = asyncio.run(fetch_current_weather("  Seoul, Korea ", client=client))

    assert [call[0] for call in client.calls] == [GEOCODING_URL, FORECAST_URL]
    assert client.calls[0][1]["name"] == "Seoul, Korea"
    assert result["source"] == "Open-Meteo"
    assert result["location"]["name"] == "Seoul"
    assert result["conditions"]["temperature"] == 18.2
    assert result["units"]["temperature"] == "°C"


def test_fetch_current_weather_rejects_invalid_location_before_network() -> None:
    client = FakeHttpClient([])

    with pytest.raises(WeatherServiceError, match="between 2 and 120"):
        asyncio.run(fetch_current_weather("x", client=client))

    assert client.calls == []


def test_fetch_current_weather_rejects_oversized_remote_response_without_body_details() -> None:
    client = FakeHttpClient(
        [FakeResponse({}, raw_content=b"x" * (MAX_RESPONSE_BYTES + 1))]
    )

    with pytest.raises(WeatherServiceError, match="response was too large") as failure:
        asyncio.run(fetch_current_weather("Seoul", client=client))

    assert "x" * 100 not in str(failure.value)


def test_fetch_current_weather_rejects_declared_oversize_before_streaming() -> None:
    response = FakeResponse({}, content_length=str(MAX_RESPONSE_BYTES + 1))
    client = FakeHttpClient([response])

    with pytest.raises(WeatherServiceError, match="response was too large"):
        asyncio.run(fetch_current_weather("Seoul", client=client))

    assert response.streamed_chunks == 0


def test_fetch_current_weather_counts_decompressed_stream_bytes() -> None:
    response = FakeResponse(
        {},
        chunks=[b"x" * MAX_RESPONSE_BYTES, b"x"],
    )
    client = FakeHttpClient([response])

    with pytest.raises(WeatherServiceError, match="response was too large"):
        asyncio.run(fetch_current_weather("Seoul", client=client))

    assert response.streamed_chunks == 2


def test_fetch_current_weather_enforces_one_overall_deadline() -> None:
    client = FakeHttpClient(
        [
            FakeResponse(
                {
                    "results": [
                        {
                            "name": "Seoul",
                            "latitude": 37.566,
                            "longitude": 126.9784,
                            "timezone": "Asia/Seoul",
                        }
                    ]
                },
                delay_seconds=0.1,
            )
        ]
    )

    with pytest.raises(WeatherServiceError, match="timed out"):
        asyncio.run(
            fetch_current_weather("Seoul", client=client, timeout_seconds=0.01)
        )

    assert len(client.calls) == 1


def test_http_client_does_not_log_user_derived_location(
    caplog: pytest.LogCaptureFixture,
) -> None:
    sensitive_location = "Private Home 123"

    async def handler(request: httpx.Request) -> httpx.Response:
        if request.url.host == "geocoding-api.open-meteo.com":
            return httpx.Response(
                200,
                json={
                    "results": [
                        {
                            "name": "Private Home",
                            "latitude": 37.566,
                            "longitude": 126.9784,
                            "timezone": "Asia/Seoul",
                        }
                    ]
                },
            )
        return httpx.Response(
            200,
            json={
                "current": {
                    "time": "2026-10-21T12:00",
                    "temperature_2m": 18.2,
                    "apparent_temperature": 17.4,
                    "relative_humidity_2m": 55,
                    "precipitation": 0,
                    "weather_code": 1,
                    "wind_speed_10m": 7.1,
                },
                "current_units": {
                    "temperature_2m": "°C",
                    "apparent_temperature": "°C",
                    "relative_humidity_2m": "%",
                    "precipitation": "mm",
                    "wind_speed_10m": "km/h",
                },
            },
        )

    async def run_lookup() -> None:
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            await fetch_current_weather(sensitive_location, client=client)

    caplog.set_level(logging.INFO)
    asyncio.run(run_lookup())

    rendered = "\n".join(record.getMessage() for record in caplog.records)
    assert sensitive_location not in rendered
    assert "latitude=37.566" not in rendered


def test_mcp_server_advertises_only_weather_tool() -> None:
    tools = asyncio.run(create_server().list_tools())

    assert [tool.name for tool in tools] == ["get_current_weather"]
    assert tools[0].input_schema["properties"]["location"]["type"] == "string"


def test_mcp_server_classifies_expected_lookup_failure_as_safe_tool_error() -> None:
    with pytest.raises(ToolError, match="between 2 and 120") as failure:
        asyncio.run(
            create_server().call_tool(
                "get_current_weather",
                {"location": "x"},
            )
        )

    assert isinstance(failure.value.__cause__, ToolError)
    assert isinstance(failure.value.__cause__.__cause__, WeatherServiceError)


def test_streamable_http_boundary_lists_weather_tool() -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]

    sample_root = Path(__file__).resolve().parents[1]
    environment = {
        **os.environ,
        "MCP_HOST": "127.0.0.1",
        "MCP_PORT": str(port),
        "PYTHONDONTWRITEBYTECODE": "1",
    }
    process = subprocess.Popen(
        [sys.executable, "-m", "weather_agent.weather_mcp_server"],
        cwd=sample_root,
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    try:
        health_url = f"http://127.0.0.1:{port}/health"
        deadline = time.monotonic() + 30
        while True:
            if process.poll() is not None:
                output = process.stdout.read() if process.stdout else ""
                pytest.fail(f"MCP server exited before readiness: {output[-1000:]}")
            try:
                with urllib.request.urlopen(health_url, timeout=0.5) as response:
                    if response.status == 200:
                        break
            except OSError:
                if time.monotonic() >= deadline:
                    pytest.fail("MCP server did not become ready within 30 seconds.")
                time.sleep(0.05)

        tools = asyncio.run(
            McpWeatherClient(
                server_url=f"http://127.0.0.1:{port}/mcp",
                mcp_timeout_seconds=5,
            ).list_tools()
        )
        assert [tool.name for tool in tools] == ["get_current_weather"]
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
