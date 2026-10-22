"""Bounded MCP v2 HTTP client used by the Foundry chat orchestrator."""

from __future__ import annotations

import json
from collections.abc import AsyncIterator, Callable, Mapping
from contextlib import asynccontextmanager
from dataclasses import dataclass
from typing import Any, Protocol

from mcp import Client


MAX_TOOL_SCHEMA_BYTES = 32_768
MAX_TOOL_RESULT_BYTES = 32_768


class McpClientError(RuntimeError):
    """A sanitized MCP connection or tool failure."""


@dataclass(frozen=True)
class McpToolDefinition:
    name: str
    description: str
    input_schema: dict[str, Any]


@dataclass(frozen=True)
class McpToolResult:
    structured_content: dict[str, Any]


class McpSession(Protocol):
    async def list_tools(self) -> list[McpToolDefinition]: ...

    async def call_tool(self, name: str, arguments: Mapping[str, Any]) -> McpToolResult: ...


class _SdkClient(Protocol):
    async def list_tools(self) -> Any: ...

    async def call_tool(self, name: str, arguments: Mapping[str, Any]) -> Any: ...


class _SessionAdapter:
    def __init__(self, client: _SdkClient) -> None:
        self._client = client

    async def list_tools(self) -> list[McpToolDefinition]:
        try:
            listed = await self._client.list_tools()
        except Exception as exc:
            raise McpClientError("The weather tool catalog is unavailable.") from exc

        raw_tools = getattr(listed, "tools", listed)
        if not isinstance(raw_tools, (list, tuple)):
            raise McpClientError("The weather tool catalog was invalid.")

        definitions: list[McpToolDefinition] = []
        seen: set[str] = set()
        for tool in raw_tools:
            name = getattr(tool, "name", None)
            description = getattr(tool, "description", None) or ""
            schema = getattr(tool, "input_schema", None)
            if schema is None:
                schema = getattr(tool, "inputSchema", None)
            if not isinstance(name, str) or not name or name in seen:
                raise McpClientError("The weather tool catalog contained an invalid name.")
            if not isinstance(description, str) or not isinstance(schema, dict):
                raise McpClientError("The weather tool catalog contained an invalid definition.")
            if len(json.dumps(schema, separators=(",", ":"), ensure_ascii=False).encode("utf-8")) > MAX_TOOL_SCHEMA_BYTES:
                raise McpClientError("The weather tool definition was too large.")
            seen.add(name)
            definitions.append(McpToolDefinition(name, description, schema))
        return definitions

    async def call_tool(self, name: str, arguments: Mapping[str, Any]) -> McpToolResult:
        if name != "get_current_weather":
            raise McpClientError("The requested tool is not allowed.")
        if not isinstance(arguments, Mapping):
            raise McpClientError("The weather tool arguments were invalid.")
        try:
            result = await self._client.call_tool(name, dict(arguments))
        except Exception as exc:
            raise McpClientError("The weather tool failed.") from exc
        if bool(getattr(result, "is_error", False)):
            raise McpClientError("The weather tool failed.")

        structured = getattr(result, "structured_content", None)
        if structured is None:
            structured = getattr(result, "structuredContent", None)
        if not isinstance(structured, dict):
            raise McpClientError("The weather tool returned an invalid result.")
        encoded = json.dumps(structured, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        if len(encoded) > MAX_TOOL_RESULT_BYTES:
            raise McpClientError("The weather tool result was too large.")
        return McpToolResult(structured)


class McpWeatherClient:
    """Connect to the separately supervised weather MCP HTTP service."""

    def __init__(
        self,
        *,
        server_url: str = "http://127.0.0.1:5091/mcp",
        mcp_timeout_seconds: float = 15.0,
        client_context_factory: Callable[[], Any] | None = None,
    ) -> None:
        if not 0 < mcp_timeout_seconds <= 300:
            raise ValueError("mcp_timeout_seconds must be greater than 0 and at most 300.")
        if not isinstance(server_url, str) or not server_url:
            raise ValueError("server_url is required.")
        self._server_url = server_url
        self._mcp_timeout_seconds = mcp_timeout_seconds
        self._client_context_factory = client_context_factory

    def _create_context(self) -> Any:
        if self._client_context_factory is not None:
            return self._client_context_factory()
        return Client(
            self._server_url,
            read_timeout_seconds=self._mcp_timeout_seconds,
            mode="auto",
        )

    @asynccontextmanager
    async def session(self) -> AsyncIterator[McpSession]:
        try:
            async with self._create_context() as client:
                yield _SessionAdapter(client)
        except McpClientError:
            raise
        except Exception as exc:
            raise McpClientError("The weather MCP server is unavailable.") from exc

    async def list_tools(self) -> list[McpToolDefinition]:
        async with self.session() as session:
            return await session.list_tools()

    async def call_tool(self, name: str, arguments: Mapping[str, Any]) -> McpToolResult:
        async with self.session() as session:
            advertised = {tool.name for tool in await session.list_tools()}
            if name not in advertised:
                raise McpClientError("The requested tool was not advertised by the MCP server.")
            return await session.call_tool(name, arguments)
