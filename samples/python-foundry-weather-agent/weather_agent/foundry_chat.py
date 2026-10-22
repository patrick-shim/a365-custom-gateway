"""Microsoft Foundry chat-completions orchestration with MCP tool calling."""

from __future__ import annotations

import inspect
import json
import time
from collections.abc import AsyncIterator, Callable, Mapping, Sequence
from contextlib import asynccontextmanager
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlsplit, urlunsplit

from .mcp_client import McpSession, McpToolDefinition, McpWeatherClient


MAX_MODEL_INPUT_CHARS = 32_768
MAX_MODEL_RESPONSE_CHARS = 32_768
MAX_TOOL_ARGUMENT_BYTES = 8_192
MAX_TOOL_RESULT_BYTES = 32_768
ALLOWED_MCP_TOOLS = frozenset({"get_current_weather"})
_FOUNDRY_HOST_SUFFIXES = (
    ".cognitiveservices.azure.com",
    ".openai.azure.com",
)


class FoundryChatError(RuntimeError):
    """A sanitized model or orchestration failure."""


@dataclass(frozen=True)
class ToolEvent:
    name: str
    arguments: dict[str, Any]
    result: dict[str, Any]
    duration_ms: int


@dataclass(frozen=True)
class FoundryChatResult:
    candidate_text: str
    model: str
    tool_events: tuple[ToolEvent, ...]


@dataclass(frozen=True, slots=True)
class FoundryMessage:
    role: str
    content: str


@dataclass(frozen=True, slots=True)
class FoundryModelInput:
    """One immutable message set and its exact Gateway protection envelope."""

    messages: tuple[FoundryMessage, ...]
    protection_text: str

    @classmethod
    def create(cls, messages: Sequence[FoundryMessage]) -> "FoundryModelInput":
        frozen = tuple(messages)
        if (
            not frozen
            or not isinstance(frozen[0], FoundryMessage)
            or frozen[0].role != "system"
        ):
            raise ValueError("The model input must begin with a system message.")
        encoded_messages: list[dict[str, str]] = []
        for message in frozen:
            if not isinstance(message, FoundryMessage):
                raise ValueError("The model input contains an invalid message.")
            if message.role not in {"system", "user", "assistant"}:
                raise ValueError("The model input contains an unsupported role.")
            if not isinstance(message.content, str) or not message.content.strip():
                raise ValueError("The model input contains an empty message.")
            encoded_messages.append(
                {"role": message.role, "content": message.content.strip()}
            )
        protection_text = json.dumps(
            {"schema": "a365.foundry-chat.v1", "messages": encoded_messages},
            ensure_ascii=False,
            separators=(",", ":"),
        )
        if len(protection_text) > MAX_MODEL_INPUT_CHARS:
            raise ValueError(
                f"model_input cannot exceed {MAX_MODEL_INPUT_CHARS} characters."
            )
        return cls(
            tuple(
                FoundryMessage(item["role"], item["content"])
                for item in encoded_messages
            ),
            protection_text,
        )


def _normalize_endpoint(value: str) -> str:
    try:
        parsed = urlsplit(value.strip())
        port = parsed.port
    except ValueError as exc:
        raise ValueError("Foundry endpoint must be a public Azure resource root URL.") from exc
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username
        or parsed.password
        or not parsed.hostname.lower().endswith(_FOUNDRY_HOST_SUFFIXES)
        or port not in {None, 443}
    ):
        raise ValueError("Foundry endpoint must be a plain HTTPS URL.")
    if parsed.query or parsed.fragment:
        raise ValueError("Foundry endpoint cannot contain a query or fragment.")
    if parsed.path not in {"", "/"}:
        raise ValueError("Foundry endpoint must be the Azure resource root URL.")
    return urlunsplit((parsed.scheme, parsed.netloc, "/", "", ""))


def _reject_duplicate_keys(pairs: Sequence[tuple[str, Any]]) -> dict[str, Any]:
    output: dict[str, Any] = {}
    for key, value in pairs:
        if key in output:
            raise ValueError("duplicate JSON key")
        output[key] = value
    return output


def _parse_arguments(value: str) -> dict[str, Any]:
    if not isinstance(value, str) or len(value.encode("utf-8")) > MAX_TOOL_ARGUMENT_BYTES:
        raise FoundryChatError("The model returned invalid tool arguments.")
    try:
        parsed = json.loads(value, object_pairs_hook=_reject_duplicate_keys)
    except (json.JSONDecodeError, ValueError) as exc:
        raise FoundryChatError("The model returned invalid tool arguments.") from exc
    if not isinstance(parsed, dict):
        raise FoundryChatError("The model returned invalid tool arguments.")
    return parsed


def _attribute(value: Any, name: str, default: Any = None) -> Any:
    if isinstance(value, Mapping):
        return value.get(name, default)
    return getattr(value, name, default)


def _assistant_message(message: Any, tool_calls: Sequence[Any]) -> dict[str, Any]:
    calls: list[dict[str, Any]] = []
    for tool_call in tool_calls:
        function = _attribute(tool_call, "function")
        calls.append(
            {
                "id": _attribute(tool_call, "id"),
                "type": "function",
                "function": {
                    "name": _attribute(function, "name"),
                    "arguments": _attribute(function, "arguments"),
                },
            }
        )
    return {"role": "assistant", "content": _attribute(message, "content"), "tool_calls": calls}


class FoundryChat:
    def __init__(
        self,
        *,
        azure_endpoint: str,
        model_deployment: str,
        api_version: str = "2024-12-01-preview",
        mcp_client: McpWeatherClient | None = None,
        completion_create: Callable[..., Any] | None = None,
        request_timeout_seconds: float = 45.0,
        max_tool_rounds: int = 3,
        max_tool_calls: int = 3,
        max_response_chars: int = MAX_MODEL_RESPONSE_CHARS,
    ) -> None:
        if not model_deployment or len(model_deployment) > 200:
            raise ValueError("A valid Foundry model deployment is required.")
        if not 1 <= max_tool_rounds <= 3:
            raise ValueError("max_tool_rounds must be between 1 and 3.")
        if not 1 <= max_tool_calls <= 3:
            raise ValueError("max_tool_calls must be between 1 and 3.")
        if not 1 <= max_response_chars <= MAX_MODEL_RESPONSE_CHARS:
            raise ValueError("max_response_chars is invalid.")

        if not api_version or len(api_version) > 64:
            raise ValueError("A valid Azure OpenAI API version is required.")
        self.azure_endpoint = _normalize_endpoint(azure_endpoint)
        self.model_deployment = model_deployment
        self._api_version = api_version
        self._request_timeout_seconds = request_timeout_seconds
        self._mcp_client = mcp_client or McpWeatherClient()
        self._max_tool_rounds = max_tool_rounds
        self._max_tool_calls = max_tool_calls
        self._max_response_chars = max_response_chars
        self._injected_completion_create = completion_create

    @staticmethod
    async def _close_resource(resource: Any) -> None:
        close = getattr(resource, "close", None)
        if close is None:
            return
        result = close()
        if inspect.isawaitable(result):
            await result

    @asynccontextmanager
    async def _completion_for_turn(self) -> AsyncIterator[Callable[..., Any]]:
        """Create async Azure transports inside the active request event loop."""

        if self._injected_completion_create is not None:
            yield self._injected_completion_create
            return

        try:
            from openai import AsyncAzureOpenAI
        except ImportError as exc:  # pragma: no cover - dependency installation failure
            raise RuntimeError("The openai package is required.") from exc

        try:
            from azure.identity.aio import (
                DefaultAzureCredential,
                get_bearer_token_provider,
            )
        except ImportError as exc:  # pragma: no cover - dependency installation failure
            raise RuntimeError("azure-identity is required for Foundry authentication.") from exc

        credential = DefaultAzureCredential()
        client: Any | None = None
        try:
            token_provider = get_bearer_token_provider(
                credential,
                "https://cognitiveservices.azure.com/.default",
            )
            client = AsyncAzureOpenAI(
                api_version=self._api_version,
                azure_endpoint=self.azure_endpoint,
                azure_ad_token_provider=token_provider,
                timeout=self._request_timeout_seconds,
                max_retries=0,
            )
            yield client.chat.completions.create
        finally:
            try:
                if client is not None:
                    await self._close_resource(client)
            finally:
                await self._close_resource(credential)

    async def _complete(
        self,
        completion_create: Callable[..., Any],
        *,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]],
    ) -> Any:
        try:
            result = completion_create(
                model=self.model_deployment,
                messages=messages,
                tools=tools,
                tool_choice="auto",
            )
            if inspect.isawaitable(result):
                return await result
            return result
        except FoundryChatError:
            raise
        except Exception as exc:
            raise FoundryChatError("Microsoft Foundry could not generate a response.") from exc

    @staticmethod
    def _openai_tools(definitions: Sequence[McpToolDefinition]) -> tuple[list[dict[str, Any]], set[str]]:
        tools: list[dict[str, Any]] = []
        advertised: set[str] = set()
        for definition in definitions:
            if definition.name not in ALLOWED_MCP_TOOLS:
                continue
            if definition.name in advertised:
                raise FoundryChatError("The MCP server advertised a duplicate tool.")
            advertised.add(definition.name)
            tools.append(
                {
                    "type": "function",
                    "function": {
                        "name": definition.name,
                        "description": definition.description,
                        "parameters": definition.input_schema,
                    },
                }
            )
        if "get_current_weather" not in advertised:
            raise FoundryChatError("The MCP weather tool is unavailable.")
        return tools, advertised

    async def generate(self, model_input: FoundryModelInput) -> FoundryChatResult:
        if not isinstance(model_input, FoundryModelInput):
            raise ValueError("A bound model input is required.")

        messages: list[dict[str, Any]] = [
            {"role": message.role, "content": message.content}
            for message in model_input.messages
        ]
        events: list[ToolEvent] = []
        async with self._mcp_client.session() as mcp_session:
            definitions = await mcp_session.list_tools()
            tools, advertised = self._openai_tools(definitions)
            async with self._completion_for_turn() as completion_create:
                for round_index in range(self._max_tool_rounds + 1):
                    completion = await self._complete(
                        completion_create,
                        messages=messages,
                        tools=tools,
                    )
                    choices = _attribute(completion, "choices")
                    if not isinstance(choices, (list, tuple)) or not choices:
                        raise FoundryChatError("Microsoft Foundry returned an invalid response.")
                    message = _attribute(choices[0], "message")
                    if message is None:
                        raise FoundryChatError("Microsoft Foundry returned an invalid response.")
                    tool_calls = _attribute(message, "tool_calls", None) or []
                    if not isinstance(tool_calls, (list, tuple)):
                        raise FoundryChatError("Microsoft Foundry returned invalid tool calls.")

                    if not tool_calls:
                        content = _attribute(message, "content")
                        if not isinstance(content, str) or not content.strip():
                            raise FoundryChatError("Microsoft Foundry returned an empty response.")
                        candidate = content.strip()
                        if len(candidate) > self._max_response_chars:
                            raise FoundryChatError("Microsoft Foundry returned a response that was too large.")
                        return FoundryChatResult(candidate, self.model_deployment, tuple(events))

                    if round_index >= self._max_tool_rounds:
                        raise FoundryChatError("Microsoft Foundry exceeded the allowed tool-call rounds.")
                    if len(events) + len(tool_calls) > self._max_tool_calls:
                        raise FoundryChatError("Microsoft Foundry exceeded the allowed number of tool calls.")

                    messages.append(_assistant_message(message, tool_calls))
                    for tool_call in tool_calls:
                        tool_call_id = _attribute(tool_call, "id")
                        function = _attribute(tool_call, "function")
                        name = _attribute(function, "name")
                        raw_arguments = _attribute(function, "arguments")
                        if not isinstance(tool_call_id, str) or not tool_call_id:
                            raise FoundryChatError("Microsoft Foundry returned an invalid tool call.")
                        if not isinstance(name, str) or name not in advertised:
                            raise FoundryChatError("Microsoft Foundry requested an unadvertised tool.")
                        arguments = _parse_arguments(raw_arguments)

                        started = time.perf_counter()
                        result = await mcp_session.call_tool(name, arguments)
                        duration_ms = max(0, round((time.perf_counter() - started) * 1000))
                        encoded_result = json.dumps(
                            result.structured_content,
                            ensure_ascii=False,
                            separators=(",", ":"),
                        )
                        if len(encoded_result.encode("utf-8")) > MAX_TOOL_RESULT_BYTES:
                            raise FoundryChatError("The MCP tool result was too large.")
                        events.append(
                            ToolEvent(name, dict(arguments), result.structured_content, duration_ms)
                        )
                        messages.append(
                            {
                                "role": "tool",
                                "tool_call_id": tool_call_id,
                                "content": encoded_result,
                            }
                        )

        raise FoundryChatError("Microsoft Foundry did not produce a response.")
