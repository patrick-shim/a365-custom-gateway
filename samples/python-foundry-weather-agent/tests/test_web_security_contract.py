from __future__ import annotations

import asyncio
from dataclasses import replace
from uuid import UUID

import pytest

from weather_agent.config import AppConfig
from weather_agent.web import create_app
from weather_agent.workflow import ChatResult, Stage


KEY = "a365gw_v1_" + ("4" * 32) + "." + ("D" * 43)


def config() -> AppConfig:
    return AppConfig(
        gateway_base_url="http://127.0.0.1:5080",
        gateway_tenant_user_id=UUID("11111111-2222-4333-8444-555555555555"),
        foundry_endpoint="https://sample.cognitiveservices.azure.com",
        foundry_model="gpt-5.6-sol",
        foundry_api_version="2024-12-01-preview",
        mcp_server_url="http://127.0.0.1:5091/mcp",
    )


class FakeWorkflow:
    def __init__(self) -> None:
        self.external_agent_ids: list[str] = []
        self.gateway_keys: list[str] = []
        self.evaluation_modes: list[tuple[bool, bool]] = []

    async def service_status(self):
        return {
            "services": {
                "gateway": {"status": "Ready", "detail": "Ready"},
                "foundry": {"status": "Configured", "detail": "Configured"},
                "mcp": {"status": "Ready", "detail": "Ready"},
            },
        }

    async def run_chat(
        self,
        *,
        message,
        history,
        session_id,
        external_agent_id,
        gateway_agent_key,
        prompt_evaluation_enabled=True,
        response_evaluation_enabled=True,
    ):
        self.external_agent_ids.append(external_agent_id)
        self.gateway_keys.append(gateway_agent_key)
        self.evaluation_modes.append(
            (prompt_evaluation_enabled, response_evaluation_enabled)
        )
        return ChatResult(
            "allowed",
            "Accepted by the Gateway.",
            (Stage("interaction", "Gateway interaction", "accepted", "Accepted."),),
            session_id,
            answer="Safe answer",
        )


class SlowWorkflow(FakeWorkflow):
    def __init__(self) -> None:
        super().__init__()
        self.started = False
        self.cancelled = False
        self.completed = False

    async def run_chat(
        self,
        *,
        message,
        history,
        session_id,
        external_agent_id,
        gateway_agent_key,
        prompt_evaluation_enabled=True,
        response_evaluation_enabled=True,
    ):
        self.started = True
        try:
            await asyncio.sleep(0.2)
            self.completed = True
            return await super().run_chat(
                message=message,
                history=history,
                session_id=session_id,
                external_agent_id=external_agent_id,
                gateway_agent_key=gateway_agent_key,
                prompt_evaluation_enabled=prompt_evaluation_enabled,
                response_evaluation_enabled=response_evaluation_enabled,
            )
        except asyncio.CancelledError:
            self.cancelled = True
            raise


def test_status_and_page_never_expose_server_credentials() -> None:
    app = create_app(config(), workflow=FakeWorkflow())  # type: ignore[arg-type]
    client = app.test_client()

    page = client.get("/")
    status = client.get("/api/status")
    combined = page.get_data(as_text=True) + status.get_data(as_text=True)

    assert page.status_code == 200
    assert status.status_code == 200
    assert KEY not in combined
    assert "11111111-2222-4333-8444-555555555555" not in combined
    assert "no-store" in status.headers["Cache-Control"]
    assert "agentId" not in status.json
    assert set(status.json) == {"services"}


def test_chat_requires_same_origin_json_and_returns_safe_contract() -> None:
    workflow = FakeWorkflow()
    app = create_app(config(), workflow=workflow)  # type: ignore[arg-type]
    client = app.test_client()
    body = {
        "message": "Weather in Seoul?",
        "history": [],
        "sessionId": "59b7d10b-0785-4b43-a532-6f0c7a253855",
        "gatewayAgentKey": KEY,
        "externalAgentId": "demo-01",
    }

    rejected = client.post(
        "/api/chat",
        json=body,
        headers={"Origin": "https://untrusted.example"},
    )
    accepted = client.post(
        "/api/chat",
        json=body,
        headers={"Origin": "http://localhost"},
    )

    assert rejected.status_code == 403
    assert accepted.status_code == 200
    assert accepted.json["outcome"] == "allowed"
    assert accepted.json["answer"] == "Safe answer"
    assert KEY not in accepted.get_data(as_text=True)
    assert workflow.external_agent_ids == ["demo-01"]
    assert workflow.gateway_keys == [KEY]
    assert workflow.evaluation_modes == [(True, True)]


@pytest.mark.parametrize(
    ("prompt_enabled", "response_enabled"),
    [(True, True), (True, False), (False, False)],
)
def test_chat_dispatches_explicit_valid_evaluation_modes(
    prompt_enabled: bool, response_enabled: bool
) -> None:
    workflow = FakeWorkflow()
    app = create_app(config(), workflow=workflow)  # type: ignore[arg-type]
    client = app.test_client()

    response = client.post(
        "/api/chat",
        json={
            "message": "Weather in Seoul?",
            "history": [],
            "sessionId": "59b7d10b-0785-4b43-a532-6f0c7a253855",
            "gatewayAgentKey": KEY,
            "externalAgentId": "demo-01",
            "promptEvaluationEnabled": prompt_enabled,
            "responseEvaluationEnabled": response_enabled,
        },
        headers={"Origin": "http://localhost"},
    )

    assert response.status_code == 200
    assert workflow.gateway_keys == [KEY]
    assert workflow.evaluation_modes == [(prompt_enabled, response_enabled)]
    assert KEY not in response.get_data(as_text=True)


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("promptEvaluationEnabled", None),
        ("promptEvaluationEnabled", "false"),
        ("promptEvaluationEnabled", 0),
        ("responseEvaluationEnabled", None),
        ("responseEvaluationEnabled", "true"),
        ("responseEvaluationEnabled", 1),
    ],
)
def test_chat_requires_actual_json_booleans_for_evaluation_controls(
    field: str, value: object
) -> None:
    workflow = FakeWorkflow()
    app = create_app(config(), workflow=workflow)  # type: ignore[arg-type]
    client = app.test_client()

    response = client.post(
        "/api/chat",
        json={
            "message": "Weather in Seoul?",
            "history": [],
            "sessionId": "59b7d10b-0785-4b43-a532-6f0c7a253855",
            "gatewayAgentKey": KEY,
            "externalAgentId": "demo-01",
            field: value,
        },
        headers={"Origin": "http://localhost"},
    )

    assert response.status_code == 400
    assert response.json["stages"][0]["id"] == "request-validation"
    assert field in response.json["stages"][0]["detail"]
    assert workflow.gateway_keys == []
    assert workflow.evaluation_modes == []
    assert KEY not in response.get_data(as_text=True)


def test_chat_rejects_response_on_prompt_off_before_workflow_dispatch() -> None:
    workflow = FakeWorkflow()
    app = create_app(config(), workflow=workflow)  # type: ignore[arg-type]
    client = app.test_client()

    response = client.post(
        "/api/chat",
        json={
            "message": "Weather in Seoul?",
            "history": [],
            "sessionId": "59b7d10b-0785-4b43-a532-6f0c7a253855",
            "gatewayAgentKey": KEY,
            "externalAgentId": "demo-01",
            "promptEvaluationEnabled": False,
            "responseEvaluationEnabled": True,
        },
        headers={"Origin": "http://localhost"},
    )

    assert response.status_code == 400
    assert response.json["stages"][0]["id"] == "request-validation"
    assert "response" in response.json["stages"][0]["detail"].lower()
    assert "prompt" in response.json["stages"][0]["detail"].lower()
    assert workflow.gateway_keys == []
    assert workflow.evaluation_modes == []
    assert KEY not in response.get_data(as_text=True)


def test_chat_rejects_missing_or_invalid_key_before_workflow_dispatch() -> None:
    workflow = FakeWorkflow()
    app = create_app(config(), workflow=workflow)  # type: ignore[arg-type]
    client = app.test_client()
    base_body = {
        "message": "Weather in Seoul?",
        "history": [],
        "sessionId": "59b7d10b-0785-4b43-a532-6f0c7a253855",
        "externalAgentId": "demo-01",
    }

    missing = client.post("/api/chat", json=base_body)
    invalid = client.post(
        "/api/chat",
        json={**base_body, "gatewayAgentKey": "not-a-real-secret"},
    )

    assert missing.status_code == 400
    assert invalid.status_code == 400
    assert workflow.gateway_keys == []
    assert "gatewayAgentKey is required" in missing.get_data(as_text=True)
    assert "not-a-real-secret" not in invalid.get_data(as_text=True)


@pytest.mark.parametrize("external_agent_id", [None, "", "ab", "-invalid", 123])
def test_chat_requires_a_valid_external_agent_id_before_workflow_dispatch(
    external_agent_id: object,
) -> None:
    workflow = FakeWorkflow()
    app = create_app(config(), workflow=workflow)  # type: ignore[arg-type]
    client = app.test_client()
    body = {
        "message": "Weather in Seoul?",
        "history": [],
        "sessionId": "59b7d10b-0785-4b43-a532-6f0c7a253855",
        "gatewayAgentKey": KEY,
    }
    if external_agent_id is not None:
        body["externalAgentId"] = external_agent_id

    response = client.post("/api/chat", json=body)

    assert response.status_code == 400
    assert response.json["stages"][0]["id"] == "request-validation"
    assert "externalAgentId" in response.json["stages"][0]["detail"]
    assert workflow.external_agent_ids == []
    assert workflow.gateway_keys == []
    assert KEY not in response.get_data(as_text=True)


def test_agent_ids_and_keys_are_isolated_to_each_request_and_never_echoed() -> None:
    second_key = "a365gw_v1_" + ("5" * 32) + "." + ("E" * 43)
    workflow = FakeWorkflow()
    app = create_app(config(), workflow=workflow)  # type: ignore[arg-type]
    client = app.test_client()
    base_body = {
        "message": "Weather in Seoul?",
        "history": [],
        "sessionId": "59b7d10b-0785-4b43-a532-6f0c7a253855",
    }

    first = client.post(
        "/api/chat",
        json={
            **base_body,
            "externalAgentId": "  Demo.Agent-01  ",
            "gatewayAgentKey": KEY,
        },
    )
    second = client.post(
        "/api/chat",
        json={
            **base_body,
            "externalAgentId": "demo-agent-02",
            "gatewayAgentKey": second_key,
        },
    )
    combined = first.get_data(as_text=True) + second.get_data(as_text=True)

    assert first.status_code == 200
    assert second.status_code == 200
    assert workflow.external_agent_ids == ["Demo.Agent-01", "demo-agent-02"]
    assert workflow.gateway_keys == [KEY, second_key]
    assert KEY not in combined
    assert second_key not in combined


def test_every_route_rejects_a_non_loopback_host_before_workflow_dispatch() -> None:
    app = create_app(config(), workflow=FakeWorkflow())  # type: ignore[arg-type]
    client = app.test_client()

    page = client.get("/", headers={"Host": "attacker.example"})
    api = client.post(
        "/api/chat",
        json={
            "message": "Weather in Seoul?",
            "history": [],
            "sessionId": "59b7d10b-0785-4b43-a532-6f0c7a253855",
            "gatewayAgentKey": KEY,
            "externalAgentId": "demo-01",
        },
        headers={
            "Host": "attacker.example",
            "Origin": "http://attacker.example",
        },
    )

    assert page.status_code == 403
    assert api.status_code == 403
    assert page.json["stages"][0]["id"] == "request-host"
    assert api.json["stages"][0]["id"] == "request-host"


def test_whole_turn_deadline_cancels_work_and_returns_unconfirmed_without_answer() -> None:
    workflow = SlowWorkflow()
    deadline_config = replace(config(), chat_turn_timeout_seconds=0.02)
    app = create_app(deadline_config, workflow=workflow)  # type: ignore[arg-type]
    client = app.test_client()

    response = client.post(
        "/api/chat",
        json={
            "message": "Weather in Seoul?",
            "history": [],
            "sessionId": "59b7d10b-0785-4b43-a532-6f0c7a253855",
            "gatewayAgentKey": KEY,
            "externalAgentId": "demo-01",
        },
        headers={"Origin": "http://localhost"},
    )

    assert response.status_code == 503
    assert response.json["outcome"] == "unconfirmed"
    assert "answer" not in response.json
    assert response.json["stages"][0]["id"] == "turn-timeout"
    assert workflow.started is True
    assert workflow.cancelled is True
    assert workflow.completed is False
