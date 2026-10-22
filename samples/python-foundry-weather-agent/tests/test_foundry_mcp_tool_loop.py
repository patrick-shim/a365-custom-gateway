from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
from types import SimpleNamespace
from typing import Any

import pytest
import azure.identity.aio
import openai

from weather_agent.foundry_chat import (
    FoundryChat,
    FoundryChatError,
    FoundryMessage,
    FoundryModelInput,
)
from weather_agent.mcp_client import McpToolDefinition, McpToolResult


def tool_call(name: str, arguments: str, call_id: str = "call-weather") -> Any:
    return SimpleNamespace(
        id=call_id,
        function=SimpleNamespace(name=name, arguments=arguments),
    )


def completion(*, content: str | None = None, tool_calls: list[Any] | None = None) -> Any:
    return SimpleNamespace(
        choices=[SimpleNamespace(message=SimpleNamespace(content=content, tool_calls=tool_calls))]
    )


class FakeMcpSession:
    def __init__(self) -> None:
        self.calls: list[tuple[str, dict[str, Any]]] = []

    async def list_tools(self) -> list[McpToolDefinition]:
        return [
            McpToolDefinition(
                "get_current_weather",
                "Get current weather for a location.",
                {
                    "type": "object",
                    "properties": {"location": {"type": "string"}},
                    "required": ["location"],
                },
            )
        ]

    async def call_tool(self, name: str, arguments: dict[str, Any]) -> McpToolResult:
        self.calls.append((name, arguments))
        return McpToolResult(
            {
                "source": "Open-Meteo",
                "location": {"name": "Seoul"},
                "conditions": {"temperature": 18.2},
            }
        )


class FakeMcpClient:
    def __init__(self, session: FakeMcpSession) -> None:
        self.connected = session

    @asynccontextmanager
    async def session(self):
        yield self.connected


def bound_input(text: str) -> FoundryModelInput:
    return FoundryModelInput.create(
        (
            FoundryMessage("system", "Use tools for live weather."),
            FoundryMessage("user", text),
        )
    )


def test_foundry_tool_loop_calls_advertised_mcp_tool_and_returns_candidate() -> None:
    session = FakeMcpSession()
    requests: list[dict[str, Any]] = []
    responses = iter(
        [
            completion(tool_calls=[tool_call("get_current_weather", '{"location":"Seoul"}')]),
            completion(content="Seoul is currently 18.2 °C."),
        ]
    )

    def create(**kwargs: Any) -> Any:
        requests.append(kwargs)
        return next(responses)

    chat = FoundryChat(
        azure_endpoint="https://sample.openai.azure.com/",
        model_deployment="demo-model",
        mcp_client=FakeMcpClient(session),  # type: ignore[arg-type]
        completion_create=create,
    )
    result = asyncio.run(chat.generate(bound_input("What is the weather in Seoul?")))

    assert result.candidate_text == "Seoul is currently 18.2 °C."
    assert result.model == "demo-model"
    assert len(result.tool_events) == 1
    assert result.tool_events[0].name == "get_current_weather"
    assert session.calls == [("get_current_weather", {"location": "Seoul"})]
    assert requests[0]["tools"][0]["function"]["name"] == "get_current_weather"
    assert requests[0]["messages"][0] == {
        "role": "system",
        "content": "Use tools for live weather.",
    }
    assert requests[0]["messages"][1]["role"] == "user"
    assert requests[1]["messages"][-1]["role"] == "tool"
    assert '"source":"Open-Meteo"' in requests[1]["messages"][-1]["content"]


def test_foundry_rejects_unadvertised_tool_without_invoking_mcp() -> None:
    session = FakeMcpSession()

    chat = FoundryChat(
        azure_endpoint="https://sample.openai.azure.com/",
        model_deployment="demo-model",
        mcp_client=FakeMcpClient(session),  # type: ignore[arg-type]
        completion_create=lambda **_: completion(
            tool_calls=[tool_call("read_private_file", "{}")]
        ),
    )

    with pytest.raises(FoundryChatError, match="unadvertised tool"):
        asyncio.run(chat.generate(bound_input("Use a tool.")))

    assert session.calls == []


def test_foundry_stops_after_three_tool_rounds() -> None:
    session = FakeMcpSession()
    call_number = 0

    def create(**_: Any) -> Any:
        nonlocal call_number
        call_number += 1
        return completion(
            tool_calls=[
                tool_call(
                    "get_current_weather",
                    '{"location":"Seoul"}',
                    f"call-{call_number}",
                )
            ]
        )

    chat = FoundryChat(
        azure_endpoint="https://sample.openai.azure.com/",
        model_deployment="demo-model",
        mcp_client=FakeMcpClient(session),  # type: ignore[arg-type]
        completion_create=create,
        max_tool_rounds=3,
    )

    with pytest.raises(FoundryChatError, match="exceeded"):
        asyncio.run(chat.generate(bound_input("Keep checking.")))

    assert len(session.calls) == 3
    assert call_number == 4


def test_foundry_limits_parallel_tool_calls_before_invoking_mcp() -> None:
    session = FakeMcpSession()
    calls = [
        tool_call("get_current_weather", '{"location":"Seoul"}', f"call-{index}")
        for index in range(4)
    ]
    chat = FoundryChat(
        azure_endpoint="https://sample.openai.azure.com/",
        model_deployment="demo-model",
        mcp_client=FakeMcpClient(session),  # type: ignore[arg-type]
        completion_create=lambda **_: completion(tool_calls=calls),
    )

    with pytest.raises(FoundryChatError, match="number of tool calls"):
        asyncio.run(chat.generate(bound_input("Compare several cities.")))

    assert session.calls == []


def test_foundry_creates_and_closes_async_auth_and_client_per_event_loop(
    monkeypatch,
) -> None:
    credentials: list[Any] = []
    clients: list[Any] = []
    providers: list[tuple[Any, str]] = []

    class FakeCredential:
        def __init__(self) -> None:
            self.loop = asyncio.get_running_loop()
            self.closed = False

        async def close(self) -> None:
            assert asyncio.get_running_loop() is self.loop
            self.closed = True

    class FakeClient:
        def __init__(self, **kwargs: Any) -> None:
            self.loop = asyncio.get_running_loop()
            self.kwargs = kwargs
            self.closed = False
            self.requests: list[dict[str, Any]] = []
            self.tokens: list[str] = []
            self.chat = SimpleNamespace(
                completions=SimpleNamespace(create=self.create)
            )

        async def create(self, **kwargs: Any) -> Any:
            assert asyncio.get_running_loop() is self.loop
            self.requests.append(kwargs)
            token_provider = self.kwargs["azure_ad_token_provider"]
            self.tokens.append(await token_provider())
            return completion(content="ok")

        async def close(self) -> None:
            assert asyncio.get_running_loop() is self.loop
            self.closed = True

    def fake_credential() -> FakeCredential:
        credential = FakeCredential()
        credentials.append(credential)
        return credential

    def fake_token_provider(received_credential: Any, scope: str):
        providers.append((received_credential, scope))

        async def provide_token() -> str:
            assert asyncio.get_running_loop() is received_credential.loop
            return "synthetic-token"

        return provide_token

    def fake_azure_openai(**kwargs: Any) -> FakeClient:
        client = FakeClient(**kwargs)
        clients.append(client)
        return client

    monkeypatch.setattr(openai, "AsyncAzureOpenAI", fake_azure_openai)
    monkeypatch.setattr(
        azure.identity.aio, "DefaultAzureCredential", fake_credential
    )
    monkeypatch.setattr(
        azure.identity.aio, "get_bearer_token_provider", fake_token_provider
    )

    chat = FoundryChat(
        azure_endpoint="https://sample.openai.azure.com/",
        model_deployment="gpt-5.6-sol",
        api_version="2024-12-01-preview",
        mcp_client=FakeMcpClient(FakeMcpSession()),  # type: ignore[arg-type]
    )

    first = asyncio.run(chat.generate(bound_input("first turn")))
    second = asyncio.run(chat.generate(bound_input("second turn")))

    assert first.candidate_text == second.candidate_text == "ok"
    assert len(credentials) == len(clients) == len(providers) == 2
    assert credentials[0] is not credentials[1]
    assert clients[0] is not clients[1]
    assert credentials[0].loop is not credentials[1].loop
    assert clients[0].loop is credentials[0].loop
    assert clients[1].loop is credentials[1].loop
    assert all(credential.closed for credential in credentials)
    assert all(client.closed for client in clients)
    assert all(client.tokens == ["synthetic-token"] for client in clients)
    assert [scope for _, scope in providers] == [
        "https://cognitiveservices.azure.com/.default",
        "https://cognitiveservices.azure.com/.default",
    ]
    assert [credential for credential, _ in providers] == credentials
    assert all(
        client.kwargs["azure_endpoint"] == "https://sample.openai.azure.com/"
        and client.kwargs["api_version"] == "2024-12-01-preview"
        and "api_key" not in client.kwargs
        for client in clients
    )


def test_foundry_closes_credential_when_client_cleanup_fails(monkeypatch) -> None:
    credential_closed = False

    class FakeCredential:
        async def close(self) -> None:
            nonlocal credential_closed
            credential_closed = True

    class FakeClient:
        def __init__(self, **_: Any) -> None:
            self.chat = SimpleNamespace(
                completions=SimpleNamespace(
                    create=lambda **__: completion(content="ok")
                )
            )

        async def close(self) -> None:
            raise RuntimeError("synthetic client cleanup failure")

    monkeypatch.setattr(openai, "AsyncAzureOpenAI", FakeClient)
    monkeypatch.setattr(
        azure.identity.aio, "DefaultAzureCredential", FakeCredential
    )
    monkeypatch.setattr(
        azure.identity.aio,
        "get_bearer_token_provider",
        lambda *_: (lambda: "synthetic-token"),
    )

    chat = FoundryChat(
        azure_endpoint="https://sample.openai.azure.com/",
        model_deployment="demo-model",
        mcp_client=FakeMcpClient(FakeMcpSession()),  # type: ignore[arg-type]
    )

    with pytest.raises(RuntimeError, match="synthetic client cleanup failure"):
        asyncio.run(chat.generate(bound_input("weather")))

    assert credential_closed is True


def test_foundry_awaits_async_completion_create() -> None:
    session = FakeMcpSession()

    async def create(**_: Any) -> Any:
        await asyncio.sleep(0)
        return completion(content="async response")

    chat = FoundryChat(
        azure_endpoint="https://sample.openai.azure.com/",
        model_deployment="demo-model",
        mcp_client=FakeMcpClient(session),  # type: ignore[arg-type]
        completion_create=create,
    )

    result = asyncio.run(chat.generate(bound_input("Use async completion.")))

    assert result.candidate_text == "async response"


@pytest.mark.parametrize(
    "endpoint",
    [
        "https://foundry.example/",
        "https://sample.openai.azure.com:444/",
        "http://sample.openai.azure.com/",
    ],
)
def test_foundry_rejects_non_public_azure_resource_endpoints(endpoint: str) -> None:
    with pytest.raises(ValueError, match="Foundry endpoint"):
        FoundryChat(
            azure_endpoint=endpoint,
            model_deployment="demo-model",
            mcp_client=FakeMcpClient(FakeMcpSession()),  # type: ignore[arg-type]
            completion_create=lambda **_: completion(content="unused"),
        )
