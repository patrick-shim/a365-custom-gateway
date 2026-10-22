from __future__ import annotations

import asyncio
import json
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from uuid import UUID

import pytest

from weather_agent.config import AppConfig
from weather_agent.foundry_chat import FoundryChatResult
from weather_agent.foundry_chat import FoundryModelInput
from weather_agent.foundry_chat import ToolEvent
from weather_agent.gateway_client import (
    GATEWAY_ACTIVITY_ENDPOINT,
    GATEWAY_INTERACTION_ENDPOINT,
    GATEWAY_PROMPT_EVALUATION_ENDPOINT,
    GATEWAY_READINESS_ENDPOINT,
    GatewayRequestError,
    GatewayTransportError,
    PROMPT_EVALUATION_INVALID_ERROR_CODE,
)
from weather_agent.mcp_client import McpToolDefinition
from weather_agent.workflow import AgentWorkflow, ChatMessage


KEY = "a365gw_v1_" + ("3" * 32) + "." + ("C" * 43)


def config() -> AppConfig:
    return AppConfig(
        gateway_base_url="http://127.0.0.1:5080",
        gateway_tenant_user_id=UUID("11111111-2222-4333-8444-555555555555"),
        foundry_endpoint="https://sample.cognitiveservices.azure.com",
        foundry_model="gpt-5.6-sol",
        foundry_api_version="2024-12-01-preview",
        mcp_server_url="http://127.0.0.1:5091/mcp",
    )


class FakeGateway:
    def __init__(
        self,
        *,
        allowed: bool = True,
        response_blocked: bool = False,
        response_purview_processing: str = "Allowed",
        readiness_error: Exception | None = None,
        evaluation_error: Exception | None = None,
        activity_error: Exception | None = None,
        interaction_error: Exception | None = None,
        receipt_lifetime_seconds: float = 300,
    ) -> None:
        self.allowed = allowed
        self.response_blocked = response_blocked
        self.response_purview_processing = response_purview_processing
        self.readiness_error = readiness_error
        self.evaluation_error = evaluation_error
        self.activity_error = activity_error
        self.interaction_error = interaction_error
        self.receipt_lifetime_seconds = receipt_lifetime_seconds
        self.evaluated_prompt: str | None = None
        self.submitted_prompt: str | None = None
        self.activities: list[str] = []
        self.external_agent_ids: list[str] = []
        self.gateway_keys: list[str] = []
        self.readiness_calls = 0
        self.evaluation_calls = 0
        self.interaction_calls = 0

    def __enter__(self):
        return self

    def __exit__(self, *_: object) -> None:
        return None

    def readiness(self) -> None:
        self.readiness_calls += 1
        if self.readiness_error is not None:
            raise self.readiness_error
        return None

    def evaluate_prompt(self, *, interaction_id: str, prompt: str):
        self.evaluation_calls += 1
        if self.evaluation_error is not None:
            raise self.evaluation_error
        self.evaluated_prompt = prompt
        return SimpleNamespace(
            allowed=self.allowed,
            user_message="Blocked by the configured protection policy.",
            correlation_id="11111111-1111-4111-8111-111111111111",
            expires_at_utc=(
                datetime.now(timezone.utc)
                + timedelta(seconds=self.receipt_lifetime_seconds)
                if self.allowed
                else None
            ),
        )

    def submit_activity(self, **kwargs):
        if self.activity_error is not None:
            raise self.activity_error
        self.activities.append(kwargs["activity_type"])
        assert kwargs["actor_type"] == "User"
        return SimpleNamespace(correlation_id=None)

    def submit_interaction(self, evaluation, **kwargs):
        self.interaction_calls += 1
        if self.interaction_error is not None:
            raise self.interaction_error
        self.submitted_prompt = kwargs["prompt"]
        return SimpleNamespace(
            blocked=self.response_blocked,
            status="Failed" if self.response_blocked and self.response_purview_processing != "Blocked" else "Accepted",
            purview_processing=self.response_purview_processing,
            correlation_id="22222222-2222-4222-8222-222222222222",
        )


class FakeFoundry:
    def __init__(self, *, with_tool_event: bool = False) -> None:
        self.inputs: list[FoundryModelInput] = []
        self.with_tool_event = with_tool_event

    async def generate(self, model_input: FoundryModelInput) -> FoundryChatResult:
        self.inputs.append(model_input)
        return FoundryChatResult(
            candidate_text="It is mild in Seoul.",
            model="gpt-5.6-sol",
            tool_events=(
                (
                    ToolEvent(
                        name="get_current_weather",
                        arguments={"latitude": 37.57, "longitude": 126.98},
                        result={"temperature": 22},
                        duration_ms=12,
                    ),
                )
                if self.with_tool_event
                else ()
            ),
        )


class FakeMcp:
    async def list_tools(self):
        return [McpToolDefinition("get_current_weather", "weather", {"type": "object"})]


def workflow(gateway: FakeGateway, foundry: FakeFoundry) -> AgentWorkflow:
    def gateway_factory(
        *, external_agent_id: str, gateway_agent_key: str
    ) -> FakeGateway:
        gateway.external_agent_ids.append(external_agent_id)
        gateway.gateway_keys.append(gateway_agent_key)
        return gateway

    return AgentWorkflow(
        config(),
        gateway_factory=gateway_factory,
        foundry=foundry,
        mcp_client=FakeMcp(),  # type: ignore[arg-type]
    )


def gateway_requests(result) -> list[dict[str, str]]:
    return [
        stage.as_dict()["gatewayRequest"]
        for stage in result.stages
        if "gatewayRequest" in stage.as_dict()
    ]


def test_status_requires_a_request_key_without_attempting_gateway_admission() -> None:
    called = False

    def unexpected_factory(*, external_agent_id: str, gateway_agent_key: str):
        nonlocal called
        called = True
        raise AssertionError("Status must not construct an authenticated Gateway client.")

    status_workflow = AgentWorkflow(
        config(),
        gateway_factory=unexpected_factory,
        foundry=FakeFoundry(),
        mcp_client=FakeMcp(),  # type: ignore[arg-type]
    )

    status = asyncio.run(status_workflow.service_status())

    assert called is False
    assert "agentId" not in status
    assert status["services"]["gateway"]["status"] == "Credential required"


def test_invalid_external_agent_id_is_rejected_before_gateway_or_foundry() -> None:
    gateway = FakeGateway()
    foundry = FakeFoundry()

    with pytest.raises(ValueError, match="externalAgentId"):
        asyncio.run(
            workflow(gateway, foundry).run_chat(
                message="Weather in Seoul?",
                history=(),
                session_id="59b7d10b-0785-4b43-a532-6f0c7a253855",
                external_agent_id="-invalid",
                gateway_agent_key=KEY,
            )
        )

    assert gateway.external_agent_ids == []
    assert gateway.gateway_keys == []
    assert gateway.readiness_calls == 0
    assert foundry.inputs == []


@pytest.mark.parametrize(
    ("failure_point", "expected_request"),
    [
        ("readiness", GATEWAY_READINESS_ENDPOINT.as_dict()),
        ("prompt", GATEWAY_PROMPT_EVALUATION_ENDPOINT.as_dict()),
    ],
)
def test_gateway_errors_keep_the_attempted_request_descriptor(
    failure_point: str, expected_request: dict[str, str]
) -> None:
    failure = GatewayTransportError(
        "The Gateway did not return a response.", uncertain=True
    )
    gateway = FakeGateway(
        readiness_error=failure if failure_point == "readiness" else None,
        evaluation_error=failure if failure_point == "prompt" else None,
    )
    foundry = FakeFoundry()

    result = asyncio.run(
        workflow(gateway, foundry).run_chat(
            message="Weather in Seoul?",
            history=(),
            session_id="59b7d10b-0785-4b43-a532-6f0c7a253855",
            external_agent_id="demo-01",
            gateway_agent_key=KEY,
        )
    )

    assert result.outcome == "unconfirmed"
    assert result.stages[-1].as_dict()["gatewayRequest"] == expected_request
    assert set(result.stages[-1].as_dict()["gatewayRequest"]) == {
        "method",
        "route",
    }
    assert foundry.inputs == []


def test_blocked_prompt_never_reaches_foundry_or_activity_submission() -> None:
    gateway = FakeGateway(allowed=False)
    foundry = FakeFoundry()

    result = asyncio.run(
        workflow(gateway, foundry).run_chat(
            message="blocked input",
            history=(),
            session_id="59b7d10b-0785-4b43-a532-6f0c7a253855",
            external_agent_id="demo-01",
            gateway_agent_key=KEY,
        )
    )

    assert result.outcome == "blocked"
    assert result.answer is None
    assert foundry.inputs == []
    assert gateway.activities == []
    assert gateway_requests(result) == [
        GATEWAY_READINESS_ENDPOINT.as_dict(),
        GATEWAY_PROMPT_EVALUATION_ENDPOINT.as_dict(),
    ]


def test_allowed_prompt_uses_exact_canonical_input_and_returns_after_intake() -> None:
    gateway = FakeGateway()
    foundry = FakeFoundry()

    result = asyncio.run(
        workflow(gateway, foundry).run_chat(
            message="Weather in Seoul?",
            history=(ChatMessage("user", "Hello"), ChatMessage("assistant", "Hi")),
            session_id="59b7d10b-0785-4b43-a532-6f0c7a253855",
            external_agent_id="demo-01",
            gateway_agent_key=KEY,
        )
    )

    assert result.outcome == "allowed"
    assert result.answer == "It is mild in Seoul."
    assert gateway.evaluated_prompt == foundry.inputs[0].protection_text
    assert gateway.submitted_prompt == foundry.inputs[0].protection_text
    assert foundry.inputs[0].messages[0].role == "system"
    assert gateway.activities == ["InvokeAgent"]
    assert gateway.external_agent_ids == ["demo-01"]
    assert gateway.gateway_keys == [KEY]
    assert result.stages[-1].status == "accepted"
    assert gateway_requests(result) == [
        GATEWAY_READINESS_ENDPOINT.as_dict(),
        GATEWAY_PROMPT_EVALUATION_ENDPOINT.as_dict(),
        GATEWAY_ACTIVITY_ENDPOINT.as_dict(),
        GATEWAY_INTERACTION_ENDPOINT.as_dict(),
    ]
    for stage_id in ("foundry", "mcp-tool"):
        stage = next(stage for stage in result.stages if stage.id == stage_id)
        assert "gatewayRequest" not in stage.as_dict()


def test_gateway_request_trace_uses_only_allowlisted_method_and_route_metadata() -> None:
    private_prompt = "private-prompt-marker-7819"
    gateway = FakeGateway()
    foundry = FakeFoundry(with_tool_event=True)

    result = asyncio.run(
        workflow(gateway, foundry).run_chat(
            message=private_prompt,
            history=(),
            session_id="59b7d10b-0785-4b43-a532-6f0c7a253855",
            external_agent_id="demo-01",
            gateway_agent_key=KEY,
        )
    )

    requests = gateway_requests(result)
    assert requests == [
        GATEWAY_READINESS_ENDPOINT.as_dict(),
        GATEWAY_PROMPT_EVALUATION_ENDPOINT.as_dict(),
        GATEWAY_ACTIVITY_ENDPOINT.as_dict(),
        GATEWAY_ACTIVITY_ENDPOINT.as_dict(),
        GATEWAY_INTERACTION_ENDPOINT.as_dict(),
    ]
    assert {(item["method"], item["route"]) for item in requests} == {
        ("GET", "/api/v1/agent-runtime/readiness"),
        ("POST", "/api/v1/prompts:evaluate"),
        ("POST", "/api/v1/agent-activities"),
        ("POST", "/api/v1/ai-interactions"),
    }
    assert all(set(item) == {"method", "route"} for item in requests)
    rendered = json.dumps(result.as_dict())
    assert KEY not in rendered
    assert private_prompt not in rendered


def test_sequential_requests_keep_selected_agent_ids_request_scoped() -> None:
    gateway = FakeGateway()
    foundry = FakeFoundry()
    selected_workflow = workflow(gateway, foundry)

    for external_agent_id in ("Demo.Agent-01", "demo-agent-02"):
        result = asyncio.run(
            selected_workflow.run_chat(
                message="Weather in Seoul?",
                history=(),
                session_id="59b7d10b-0785-4b43-a532-6f0c7a253855",
                external_agent_id=external_agent_id,
                gateway_agent_key=KEY,
            )
        )
        assert result.outcome == "allowed"

    assert gateway.external_agent_ids == ["Demo.Agent-01", "demo-agent-02"]
    assert gateway.gateway_keys == [KEY, KEY]


def test_prompt_only_evaluates_input_but_never_submits_completed_interaction() -> None:
    gateway = FakeGateway(receipt_lifetime_seconds=1)
    foundry = FakeFoundry()

    result = asyncio.run(
        workflow(gateway, foundry).run_chat(
            message="Weather in Seoul?",
            history=(),
            session_id="59b7d10b-0785-4b43-a532-6f0c7a253855",
            external_agent_id="demo-01",
            gateway_agent_key=KEY,
            prompt_evaluation_enabled=True,
            response_evaluation_enabled=False,
        )
    )

    assert result.outcome == "unevaluated"
    assert result.answer == "It is mild in Seoul."
    assert gateway.readiness_calls == 1
    assert gateway.evaluation_calls == 1
    assert gateway.interaction_calls == 0
    assert gateway.evaluated_prompt == foundry.inputs[0].protection_text
    assert gateway.submitted_prompt is None
    assert gateway.activities == ["InvokeAgent"]
    assert result.stages[-1].id == "interaction"
    assert result.stages[-1].status == "skipped"
    assert "skipped" in result.stages[-1].detail.lower()
    assert "not submitted" in result.stages[-1].detail.lower()
    assert gateway_requests(result) == [
        GATEWAY_READINESS_ENDPOINT.as_dict(),
        GATEWAY_PROMPT_EVALUATION_ENDPOINT.as_dict(),
        GATEWAY_ACTIVITY_ENDPOINT.as_dict(),
    ]
    assert "gatewayRequest" not in result.stages[-1].as_dict()


def test_evaluation_bypass_still_requires_admission_and_emits_agent_activities() -> None:
    gateway = FakeGateway(receipt_lifetime_seconds=0)
    foundry = FakeFoundry(with_tool_event=True)

    result = asyncio.run(
        workflow(gateway, foundry).run_chat(
            message="Weather in Seoul?",
            history=(),
            session_id="59b7d10b-0785-4b43-a532-6f0c7a253855",
            external_agent_id="demo-01",
            gateway_agent_key=KEY,
            prompt_evaluation_enabled=False,
            response_evaluation_enabled=False,
        )
    )

    assert result.outcome == "unevaluated"
    assert result.answer == "It is mild in Seoul."
    assert gateway.readiness_calls == 1
    assert gateway.evaluation_calls == 0
    assert gateway.interaction_calls == 0
    assert gateway.activities == ["InvokeAgent", "ToolInvocation"]
    assert len(foundry.inputs) == 1

    prompt_stage = next(stage for stage in result.stages if stage.id == "prompt-evaluation")
    interaction_stage = next(stage for stage in result.stages if stage.id == "interaction")
    for stage in (prompt_stage, interaction_stage):
        assert stage.status == "skipped"
        assert "skipped" in stage.detail.lower()
        assert "protected" not in stage.detail.lower()
        assert "allowed" not in stage.detail.lower()
        assert "accepted" not in stage.detail.lower()
        assert "downstream" not in stage.detail.lower()
    assert "do not evaluate" in prompt_stage.detail.lower()
    assert "not submitted" in interaction_stage.detail.lower()
    assert gateway_requests(result) == [
        GATEWAY_READINESS_ENDPOINT.as_dict(),
        GATEWAY_ACTIVITY_ENDPOINT.as_dict(),
        GATEWAY_ACTIVITY_ENDPOINT.as_dict(),
    ]
    assert "gatewayRequest" not in prompt_stage.as_dict()
    assert "gatewayRequest" not in interaction_stage.as_dict()


def test_response_evaluation_cannot_run_when_prompt_evaluation_is_off() -> None:
    gateway = FakeGateway()
    foundry = FakeFoundry()

    try:
        asyncio.run(
            workflow(gateway, foundry).run_chat(
                message="Weather in Seoul?",
                history=(),
                session_id="59b7d10b-0785-4b43-a532-6f0c7a253855",
                external_agent_id="demo-01",
                gateway_agent_key=KEY,
                prompt_evaluation_enabled=False,
                response_evaluation_enabled=True,
            )
        )
    except ValueError as error:
        assert "response" in str(error).lower()
        assert "prompt" in str(error).lower()
    else:
        raise AssertionError("The invalid evaluation combination was accepted.")

    assert gateway.gateway_keys == []
    assert gateway.readiness_calls == 0
    assert gateway.evaluation_calls == 0
    assert gateway.activities == []
    assert gateway.interaction_calls == 0
    assert foundry.inputs == []


def test_purview_response_block_withholds_candidate_answer() -> None:
    gateway = FakeGateway(
        response_blocked=True,
        response_purview_processing="Blocked",
    )
    foundry = FakeFoundry()

    result = asyncio.run(
        workflow(gateway, foundry).run_chat(
            message="Weather in Seoul?",
            history=(),
            session_id="59b7d10b-0785-4b43-a532-6f0c7a253855",
            external_agent_id="demo-01",
            gateway_agent_key=KEY,
        )
    )

    assert result.outcome == "blocked"
    assert result.answer is None
    assert result.stages[-1].id == "interaction"
    assert result.stages[-1].status == "blocked"
    assert (
        result.stages[-1].as_dict()["gatewayRequest"]
        == GATEWAY_INTERACTION_ENDPOINT.as_dict()
    )


def test_failed_interaction_intake_is_not_mislabeled_as_a_purview_block() -> None:
    gateway = FakeGateway(response_blocked=True)
    foundry = FakeFoundry()

    result = asyncio.run(
        workflow(gateway, foundry).run_chat(
            message="Weather in Seoul?",
            history=(),
            session_id="59b7d10b-0785-4b43-a532-6f0c7a253855",
            external_agent_id="demo-01",
            gateway_agent_key=KEY,
        )
    )

    assert result.outcome == "failed"
    assert result.answer is None
    assert result.stages[-1].status == "failed"
    assert "Purview" not in result.stages[-1].detail


def test_pre_model_activity_failure_stops_before_foundry() -> None:
    gateway = FakeGateway(
        activity_error=GatewayRequestError(
            "The Gateway agent is disabled.", status_code=403
        )
    )
    foundry = FakeFoundry()

    result = asyncio.run(
        workflow(gateway, foundry).run_chat(
            message="Weather in Seoul?",
            history=(),
            session_id="59b7d10b-0785-4b43-a532-6f0c7a253855",
            external_agent_id="demo-01",
            gateway_agent_key=KEY,
        )
    )

    assert result.outcome == "blocked"
    assert result.answer is None
    assert foundry.inputs == []
    assert result.stages[-1].id == "invoke-activity"
    assert result.stages[-1].status == "blocked"
    assert (
        result.stages[-1].as_dict()["gatewayRequest"]
        == GATEWAY_ACTIVITY_ENDPOINT.as_dict()
    )


def test_changed_protection_context_is_failed_not_blocked_and_prompts_retry() -> None:
    message = (
        "The agent or protection settings changed while this request was running. "
        "Start a new request."
    )
    gateway = FakeGateway(
        interaction_error=GatewayRequestError(
            message,
            status_code=403,
            error_code=PROMPT_EVALUATION_INVALID_ERROR_CODE,
        )
    )
    foundry = FakeFoundry()

    result = asyncio.run(
        workflow(gateway, foundry).run_chat(
            message="Weather in Seoul?",
            history=(),
            session_id="59b7d10b-0785-4b43-a532-6f0c7a253855",
            external_agent_id="demo-01",
            gateway_agent_key=KEY,
        )
    )

    assert result.outcome == "failed"
    assert result.answer is None
    assert result.message == message
    assert result.stages[-1].id == "interaction"
    assert result.stages[-1].status == "failed"
    assert result.stages[-1].detail == message
    assert (
        result.stages[-1].as_dict()["gatewayRequest"]
        == GATEWAY_INTERACTION_ENDPOINT.as_dict()
    )


def test_uncertain_pre_model_activity_stops_before_foundry() -> None:
    reconciliation_reference = "77777777-7777-4777-8777-777777777777"
    gateway = FakeGateway(
        activity_error=GatewayTransportError(
            "The activity outcome is unconfirmed.",
            uncertain=True,
            idempotency_key=reconciliation_reference,
        )
    )
    foundry = FakeFoundry()

    result = asyncio.run(
        workflow(gateway, foundry).run_chat(
            message="Weather in Seoul?",
            history=(),
            session_id="59b7d10b-0785-4b43-a532-6f0c7a253855",
            external_agent_id="demo-01",
            gateway_agent_key=KEY,
        )
    )

    assert result.outcome == "unconfirmed"
    assert foundry.inputs == []
    assert result.stages[-1].reconciliation_reference == reconciliation_reference
    assert (
        result.stages[-1].as_dict()["reconciliationReference"]
        == reconciliation_reference
    )
    assert (
        result.stages[-1].as_dict()["gatewayRequest"]
        == GATEWAY_ACTIVITY_ENDPOINT.as_dict()
    )


def test_expired_interaction_binding_is_reported_and_candidate_is_withheld() -> None:
    gateway = FakeGateway(
        interaction_error=ValueError("The prompt evaluation receipt has expired.")
    )
    foundry = FakeFoundry()

    result = asyncio.run(
        workflow(gateway, foundry).run_chat(
            message="Weather in Seoul?",
            history=(),
            session_id="59b7d10b-0785-4b43-a532-6f0c7a253855",
            external_agent_id="demo-01",
            gateway_agent_key=KEY,
        )
    )

    assert result.outcome == "failed"
    assert result.answer is None
    assert result.stages[-1].id == "interaction"
    assert "gatewayRequest" not in result.stages[-1].as_dict()
