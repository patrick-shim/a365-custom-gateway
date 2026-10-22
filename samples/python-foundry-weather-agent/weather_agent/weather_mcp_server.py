"""MCP weather server backed by the public Open-Meteo APIs.

The server deliberately owns the two remote hosts it can contact. Model supplied
arguments can select a location, but cannot select a URL or HTTP method.
"""

from __future__ import annotations

import asyncio
import json
import logging
import math
import os
import re
from collections.abc import Mapping
from typing import Any, AsyncContextManager, AsyncIterator, Protocol

import httpx
from mcp.server import MCPServer
from mcp.server.mcpserver.exceptions import ToolError
from mcp.server.transport_security import TransportSecuritySettings
from starlette.requests import Request
from starlette.responses import JSONResponse


GEOCODING_URL = "https://geocoding-api.open-meteo.com/v1/search"
FORECAST_URL = "https://api.open-meteo.com/v1/forecast"
MAX_LOCATION_LENGTH = 120
MAX_RESPONSE_BYTES = 256_000
DEFAULT_REQUEST_TIMEOUT_SECONDS = 10.0

# MCP configures process logging at INFO. HTTPX otherwise records the complete
# request URL, which would expose the model-supplied location query in Docker logs.
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("httpcore").setLevel(logging.WARNING)


class WeatherServiceError(RuntimeError):
    """A safe, user-presentable weather lookup failure."""


class _HttpResponse(Protocol):
    status_code: int
    headers: Mapping[str, str]

    def aiter_bytes(self) -> AsyncIterator[bytes]: ...


class _HttpClient(Protocol):
    def stream(
        self,
        method: str,
        url: str,
        *,
        params: Mapping[str, str | int | float],
    ) -> AsyncContextManager[_HttpResponse]: ...


_CONTROL_CHARACTER = re.compile(r"[\x00-\x1f\x7f]")


def _normalize_location(location: str) -> str:
    if not isinstance(location, str):
        raise WeatherServiceError("Location must be text.")
    normalized = " ".join(location.split())
    if len(normalized) < 2 or len(normalized) > MAX_LOCATION_LENGTH:
        raise WeatherServiceError(
            f"Location must contain between 2 and {MAX_LOCATION_LENGTH} characters."
        )
    if _CONTROL_CHARACTER.search(normalized):
        raise WeatherServiceError("Location contains unsupported characters.")
    return normalized


async def _read_json(
    client: _HttpClient,
    url: str,
    params: Mapping[str, str | int | float],
) -> dict[str, Any]:
    try:
        async with client.stream("GET", url, params=params) as response:
            if response.status_code < 200 or response.status_code >= 300:
                raise WeatherServiceError(
                    "The weather service returned an unsuccessful response."
                )

            content_length = response.headers.get("content-length")
            if content_length:
                try:
                    declared_length = int(content_length)
                except ValueError as exc:
                    raise WeatherServiceError(
                        "The weather service returned an invalid response."
                    ) from exc
                if declared_length < 0:
                    raise WeatherServiceError(
                        "The weather service returned an invalid response."
                    )
                if declared_length > MAX_RESPONSE_BYTES:
                    raise WeatherServiceError("The weather service response was too large.")

            content_type = response.headers.get("content-type", "").lower()
            if content_type and "json" not in content_type:
                raise WeatherServiceError(
                    "The weather service returned an unsupported response."
                )

            body = bytearray()
            async for chunk in response.aiter_bytes():
                if len(body) + len(chunk) > MAX_RESPONSE_BYTES:
                    raise WeatherServiceError("The weather service response was too large.")
                body.extend(chunk)
    except (httpx.TimeoutException, TimeoutError) as exc:
        raise WeatherServiceError("The weather service timed out.") from exc
    except httpx.RequestError as exc:
        raise WeatherServiceError("The weather service is unavailable.") from exc
    except WeatherServiceError:
        raise
    except Exception as exc:
        raise WeatherServiceError("The weather service request failed.") from exc

    try:
        payload = json.loads(body)
    except (ValueError, json.JSONDecodeError) as exc:
        raise WeatherServiceError("The weather service returned invalid data.") from exc
    if not isinstance(payload, dict):
        raise WeatherServiceError("The weather service returned invalid data.")
    return payload


def _number(value: Any, name: str, minimum: float, maximum: float) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise WeatherServiceError(f"The weather service omitted valid {name} data.")
    parsed = float(value)
    if not math.isfinite(parsed) or parsed < minimum or parsed > maximum:
        raise WeatherServiceError(f"The weather service returned invalid {name} data.")
    return parsed


def _text(value: Any, name: str, *, maximum: int = 160) -> str:
    if not isinstance(value, str) or not value.strip() or len(value) > maximum:
        raise WeatherServiceError(f"The weather service omitted valid {name} data.")
    return value.strip()


async def fetch_current_weather(
    location: str,
    *,
    client: _HttpClient | None = None,
    timeout_seconds: float | None = None,
) -> dict[str, Any]:
    """Resolve a location and return bounded current weather data.

    ``client`` is injectable for deterministic tests. Production calls create a
    short-lived client with redirect refusal and a strict total timeout.
    """

    normalized = _normalize_location(location)
    resolved_timeout = timeout_seconds
    if resolved_timeout is None:
        try:
            resolved_timeout = float(
                os.environ.get("WEATHER_TIMEOUT_SECONDS", DEFAULT_REQUEST_TIMEOUT_SECONDS)
            )
        except ValueError as exc:
            raise WeatherServiceError("The weather timeout configuration is invalid.") from exc
    if not math.isfinite(resolved_timeout) or not 0 < resolved_timeout <= 300:
        raise WeatherServiceError("The weather timeout configuration is invalid.")
    owns_client = client is None
    http_client: _HttpClient = client or httpx.AsyncClient(
        timeout=httpx.Timeout(resolved_timeout),
        follow_redirects=False,
        headers={"Accept": "application/json", "User-Agent": "a365-weather-demo/1.0"},
    )
    try:
        async with asyncio.timeout(resolved_timeout):
            geocoding = await _read_json(
                http_client,
                GEOCODING_URL,
                {"name": normalized, "count": 1, "format": "json", "language": "en"},
            )
            results = geocoding.get("results")
            if not isinstance(results, list) or not results or not isinstance(results[0], dict):
                raise WeatherServiceError("No matching location was found.")

            match = results[0]
            latitude = _number(match.get("latitude"), "latitude", -90, 90)
            longitude = _number(match.get("longitude"), "longitude", -180, 180)
            resolved_name = _text(match.get("name"), "location name")
            timezone = _text(match.get("timezone"), "timezone")

            forecast = await _read_json(
                http_client,
                FORECAST_URL,
                {
                    "latitude": latitude,
                    "longitude": longitude,
                    "current": (
                        "temperature_2m,apparent_temperature,relative_humidity_2m,"
                        "precipitation,weather_code,wind_speed_10m"
                    ),
                    "timezone": "auto",
                    "forecast_days": 1,
                },
            )
            current = forecast.get("current")
            units = forecast.get("current_units")
            if not isinstance(current, dict) or not isinstance(units, dict):
                raise WeatherServiceError("The weather service omitted current conditions.")

            observed_at = _text(current.get("time"), "observation time", maximum=64)
            temperature = _number(current.get("temperature_2m"), "temperature", -120, 80)
            apparent = _number(
                current.get("apparent_temperature"), "apparent temperature", -150, 100
            )
            humidity = _number(current.get("relative_humidity_2m"), "humidity", 0, 100)
            precipitation = _number(
                current.get("precipitation"), "precipitation", 0, 10_000
            )
            weather_code = _number(current.get("weather_code"), "weather code", 0, 999)
            wind_speed = _number(current.get("wind_speed_10m"), "wind speed", 0, 1_000)

            def optional_text(value: Any) -> str | None:
                return (
                    value.strip()
                    if isinstance(value, str) and 0 < len(value.strip()) <= 160
                    else None
                )

            def unit(name: str) -> str:
                return _text(units.get(name), f"{name} unit", maximum=24)

            return {
                "source": "Open-Meteo",
                "location": {
                    "name": resolved_name,
                    "admin1": optional_text(match.get("admin1")),
                    "country": optional_text(match.get("country")),
                    "country_code": optional_text(match.get("country_code")),
                    "latitude": latitude,
                    "longitude": longitude,
                    "timezone": timezone,
                },
                "observed_at": observed_at,
                "conditions": {
                    "temperature": temperature,
                    "apparent_temperature": apparent,
                    "relative_humidity": humidity,
                    "precipitation": precipitation,
                    "weather_code": int(weather_code),
                    "wind_speed": wind_speed,
                },
                "units": {
                    "temperature": unit("temperature_2m"),
                    "apparent_temperature": unit("apparent_temperature"),
                    "relative_humidity": unit("relative_humidity_2m"),
                    "precipitation": unit("precipitation"),
                    "wind_speed": unit("wind_speed_10m"),
                },
            }
    except TimeoutError as exc:
        raise WeatherServiceError("The weather service timed out.") from exc
    finally:
        if owns_client:
            await http_client.aclose()  # type: ignore[attr-defined]


def create_server() -> MCPServer:
    server = MCPServer("open-meteo-weather")

    @server.custom_route("/health", methods=["GET"], include_in_schema=False)
    async def health(_: Request) -> JSONResponse:
        return JSONResponse({"status": "healthy"})

    @server.tool()
    async def get_current_weather(location: str) -> dict[str, Any]:
        """Get current weather for a city, region, or postal code."""

        try:
            return await fetch_current_weather(location)
        except WeatherServiceError as exc:
            # Expected lookup failures are safe tool outcomes. MCP logs ToolError
            # without the crash traceback that could otherwise expose internals.
            raise ToolError(str(exc)) from exc

    return server


mcp = create_server()


if __name__ == "__main__":
    host = os.environ.get("MCP_HOST", "0.0.0.0").strip() or "0.0.0.0"
    try:
        port = int(os.environ.get("MCP_PORT", "5091"))
    except ValueError as exc:
        raise SystemExit("MCP_PORT must be an integer.") from exc
    if not 1 <= port <= 65_535:
        raise SystemExit("MCP_PORT must be between 1 and 65535.")
    mcp.run(
        transport="streamable-http",
        host=host,
        port=port,
        streamable_http_path="/mcp",
        json_response=True,
        stateless_http=True,
        max_request_body_size=64 * 1024,
        max_sessions=100,
        transport_security=TransportSecuritySettings(
            enable_dns_rebinding_protection=True,
            allowed_hosts=["127.0.0.1:*", "localhost:*", "weather-mcp:*"],
            allowed_origins=[],
        ),
    )
