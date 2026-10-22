from __future__ import annotations

import json
from dataclasses import FrozenInstanceError
from datetime import datetime, timedelta, timezone
from uuid import UUID, uuid4

import httpx
import pytest

from weather_agent.config import AppConfig
from weather_agent.gateway_client import (
    ActivityTool,
    GATEWAY_ACTIVITY_ENDPOINT,
    GATEWAY_ENDPOINTS,
    GATEWAY_INTERACTION_ENDPOINT,
    GATEWAY_PROMPT_EVALUATION_ENDPOINT,
    GATEWAY_READINESS_ENDPOINT,
    GatewayClient,
    GatewayProtocolError,
    GatewayRequestError,
    GatewayTransportError,
)


SYNTHETIC_GATEWAY_KEY = "a365gw_v1_" + ("2" * 32) + "." + ("B" * 43)
USER_ID = UUID("11111111-2222-4333-8444-555555555555")


def config() -> AppConfig:
    return AppConfig(
        gateway_base_url="http://127.0.0.1:5080",
        gateway_tenant_user_id=USER_ID,
        foundry_endpoint="https://sample.cognitiveservices.azure.com",
        foundry_model="sample-chat",
        foundry_api_version="2024-12-01-preview",
        mcp_server_url="http://127.0.0.1:5091/mcp",
    )


def json_response(request: httpx.Request, status: int, body: dict) -> httpx.Response:
    return httpx.Response(status, json=body, request=request)


def assert_gateway_headers(request: httpx.Request) -> None:
    assert request.headers["Authorization"] == f"Bearer {SYNTHETIC_GATEWAY_KEY}"
    key = UUID(request.headers["Idempotency-Key"])
    assert key.version == 4
    assert str(key) == request.headers["Idempotency-Key"]


def test_gateway_endpoint_descriptors_are_the_exact_immutable_allowlist() -> None:
    assert tuple(endpoint.as_dict() for endpoint in GATEWAY_ENDPOINTS) == (
        {"method": "GET", "route": "/api/v1/agent-runtime/readiness"},
        {"method": "POST", "route": "/api/v1/prompts:evaluate"},
        {"method": "POST", "route": "/api/v1/agent-activities"},
        {"method": "POST", "route": "/api/v1/ai-interactions"},
    )
    assert GATEWAY_ENDPOINTS == (
        GATEWAY_READINESS_ENDPOINT,
        GATEWAY_PROMPT_EVALUATION_ENDPOINT,
        GATEWAY_ACTIVITY_ENDPOINT,
        GATEWAY_INTERACTION_ENDPOINT,
    )
    with pytest.raises(FrozenInstanceError):
        GATEWAY_READINESS_ENDPOINT.method = "POST"  # type: ignore[misc]


def test_gateway_client_keeps_its_request_scoped_key_out_of_repr_and_errors() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return json_response(
            request,
            401,
            {"detail": SYNTHETIC_GATEWAY_KEY},
        )

    with GatewayClient(
        config(),
        external_agent_id="demo-01",
        gateway_agent_key=SYNTHETIC_GATEWAY_KEY,
        transport=httpx.MockTransport(handler),
    ) as client:
        assert SYNTHETIC_GATEWAY_KEY not in repr(client)
        with pytest.raises(GatewayRequestError) as error:
            client.readiness()

    assert SYNTHETIC_GATEWAY_KEY not in str(error.value)
    assert SYNTHETIC_GATEWAY_KEY not in repr(error.value)


def allowed_evaluation(request: httpx.Request, interaction_id: str) -> httpx.Response:
    evaluation_id = str(uuid4())
    return json_response(
        request,
        200,
        {
            "evaluationId": evaluation_id,
            "evaluationReceiptId": evaluation_id,
            "interactionId": interaction_id,
            "allowed": True,
            "decision": "PROMPT_ALLOWED",
            "promptShieldProcessing": "Allowed",
            "purviewProcessing": "Allowed",
            "expiresAtUtc": (
                datetime.now(timezone.utc) + timedelta(minutes=5)
            ).isoformat(),
            "userMessage": "Allowed.",
            "correlationId": str(uuid4()),
        },
    )


def test_gateway_client_readiness_uses_server_side_bearer_without_redirects() -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return httpx.Response(204, request=request)

    with GatewayClient(
        config(),
        external_agent_id="demo-01",
        gateway_agent_key=SYNTHETIC_GATEWAY_KEY,
        transport=httpx.MockTransport(handler)) as client:
        client.readiness()

    assert len(requests) == 1
    assert requests[0].url.path == "/api/v1/agent-runtime/readiness"
    assert requests[0].headers["Authorization"] == f"Bearer {SYNTHETIC_GATEWAY_KEY}"
    assert "Idempotency-Key" not in requests[0].headers


def test_gateway_client_evaluates_exact_prompt_and_validates_allow_receipt() -> None:
    interaction_id = "turn-123"

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/api/v1/prompts:evaluate"
        assert_gateway_headers(request)
        body = json.loads(request.content)
        assert body["externalAgentId"] == "Demo.Agent-01"
        assert body["interactionId"] == interaction_id
        assert body["prompt"] == {
            "contentType": "text/plain",
            "content": "Weather in Seoul?",
        }
        assert body["userContext"]["tenantUserObjectId"] == str(USER_ID)
        return allowed_evaluation(request, interaction_id)

    with GatewayClient(
        config(),
        external_agent_id="Demo.Agent-01",
        gateway_agent_key=SYNTHETIC_GATEWAY_KEY,
        transport=httpx.MockTransport(handler)) as client:
        result = client.evaluate_prompt(
            interaction_id=interaction_id, prompt="Weather in Seoul?"
        )

    assert result.allowed is True
    assert result.evaluation_receipt_id is not None
    assert result.evaluation_id == result.evaluation_receipt_id
    assert result.expires_at_utc is not None


def test_gateway_clients_keep_external_agent_ids_isolated_per_request() -> None:
    selected_ids: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content)
        selected_ids.append(body["externalAgentId"])
        return allowed_evaluation(request, body["interactionId"])

    for index, external_agent_id in enumerate(
        ("Demo.Agent-01", "demo-agent-02"), start=1
    ):
        with GatewayClient(
            config(),
            external_agent_id=external_agent_id,
            gateway_agent_key=SYNTHETIC_GATEWAY_KEY,
            transport=httpx.MockTransport(handler),
        ) as client:
            client.evaluate_prompt(
                interaction_id=f"turn-{index}", prompt="Weather in Seoul?"
            )

    assert selected_ids == ["Demo.Agent-01", "demo-agent-02"]


def test_gateway_client_returns_typed_prompt_block_without_receipt() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return json_response(
            request,
            403,
            {
                "evaluationId": str(uuid4()),
                "errorCode": "PROMPT_BLOCKED_BY_DLP",
                "promptShieldProcessing": "Allowed",
                "purviewProcessing": "Blocked",
                "correlationId": str(uuid4()),
                "detail": "raw-provider-text-must-not-be-used",
            },
        )

    with GatewayClient(
        config(),
        external_agent_id="demo-01",
        gateway_agent_key=SYNTHETIC_GATEWAY_KEY,
        transport=httpx.MockTransport(handler)) as client:
        result = client.evaluate_prompt(interaction_id="blocked", prompt="synthetic")

    assert result.allowed is False
    assert result.evaluation_receipt_id is None
    assert result.decision == "PROMPT_BLOCKED_BY_DLP"
    assert "raw-provider" not in result.user_message


@pytest.mark.parametrize(
    ("error_code", "expected_message"),
    [
        (
            "AGENT_IDENTITY_MISMATCH",
            "The external agent ID does not match this Gateway key.",
        ),
        (
            "AGENT_DISABLED",
            "The selected agent is disabled in this Gateway.",
        ),
    ],
)
def test_gateway_client_explains_agent_identity_and_state_failures_safely(
    error_code: str, expected_message: str
) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return json_response(
            request,
            403,
            {
                "errorCode": error_code,
                "correlationId": str(uuid4()),
                "detail": f"provider detail {SYNTHETIC_GATEWAY_KEY}",
            },
        )

    with GatewayClient(
        config(),
        external_agent_id="demo-01",
        gateway_agent_key=SYNTHETIC_GATEWAY_KEY,
        transport=httpx.MockTransport(handler),
    ) as client:
        with pytest.raises(GatewayRequestError) as caught:
            client.evaluate_prompt(interaction_id="turn", prompt="hello")

    assert str(caught.value) == expected_message
    assert caught.value.error_code == error_code
    assert SYNTHETIC_GATEWAY_KEY not in str(caught.value)


@pytest.mark.parametrize(
    "mutation",
    [
        {"evaluationReceiptId": None},
        {
            "expiresAtUtc": (
                datetime.now(timezone.utc) - timedelta(seconds=1)
            ).isoformat()
        },
        {"interactionId": "some-other-turn"},
    ],
)
def test_gateway_client_rejects_inconsistent_allow_receipts(mutation: dict) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        response = allowed_evaluation(request, "turn")
        body = json.loads(response.content)
        body.update(mutation)
        return json_response(request, 200, body)

    with GatewayClient(
        config(),
        external_agent_id="demo-01",
        gateway_agent_key=SYNTHETIC_GATEWAY_KEY,
        transport=httpx.MockTransport(handler)) as client:
        with pytest.raises(GatewayProtocolError):
            client.evaluate_prompt(interaction_id="turn", prompt="hello")


def test_gateway_client_rejects_mismatched_evaluation_and_receipt_ids() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        response = allowed_evaluation(request, "turn")
        body = json.loads(response.content)
        body["evaluationReceiptId"] = str(uuid4())
        return json_response(request, 200, body)

    with GatewayClient(
        config(),
        external_agent_id="demo-01",
        gateway_agent_key=SYNTHETIC_GATEWAY_KEY,
        transport=httpx.MockTransport(handler)) as client:
        with pytest.raises(GatewayProtocolError, match="identifiers did not match") as caught:
            client.evaluate_prompt(interaction_id="turn", prompt="hello")

    assert caught.value.uncertain is True
    assert caught.value.idempotency_key is not None


@pytest.mark.parametrize(
    "purview_processing",
    [
        "Blocked",
        "PurviewSkipped_NoUserContext",
        "PurviewSkipped_InvalidUser",
        "FutureUnknownState",
    ],
)
def test_gateway_client_never_authorizes_nonpermitted_purview_allow_state(
    purview_processing: str,
) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        response = allowed_evaluation(request, "turn")
        body = json.loads(response.content)
        body["purviewProcessing"] = purview_processing
        return json_response(request, 200, body)

    with GatewayClient(
        config(),
        external_agent_id="demo-01",
        gateway_agent_key=SYNTHETIC_GATEWAY_KEY,
        transport=httpx.MockTransport(handler)) as client:
        with pytest.raises(GatewayProtocolError, match="allow decision") as caught:
            client.evaluate_prompt(interaction_id="turn", prompt="hello")

    assert caught.value.uncertain is True
    assert caught.value.idempotency_key is not None


@pytest.mark.parametrize(
    "purview_processing",
    [
        "Allowed",
        "AuditOnly",
        "AuditLogged",
        "PurviewDisabled",
        "SimulationUnavailable",
        "SimulatedBlock",
    ],
)
def test_gateway_client_accepts_documented_purview_allow_states(
    purview_processing: str,
) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        response = allowed_evaluation(request, "turn")
        body = json.loads(response.content)
        body["purviewProcessing"] = purview_processing
        return json_response(request, 200, body)

    with GatewayClient(
        config(),
        external_agent_id="demo-01",
        gateway_agent_key=SYNTHETIC_GATEWAY_KEY,
        transport=httpx.MockTransport(handler)) as client:
        result = client.evaluate_prompt(interaction_id="turn", prompt="hello")

    assert result.allowed is True
    assert result.purview_processing == purview_processing


def test_gateway_client_submits_tool_activity_and_matches_202_receipt() -> None:
    activity_id = "tool-123"

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/api/v1/agent-activities"
        assert_gateway_headers(request)
        body = json.loads(request.content)
        assert body["externalAgentId"] == "demo-activity-02"
        assert body["activityType"] == "ToolInvocation"
        assert body["actor"]["type"] == "User"
        assert body["tool"]["name"] == "get_weather"
        return json_response(
            request,
            202,
            {
                "receiptId": str(uuid4()),
                "activityId": activity_id,
                "status": "Accepted",
                "receivedAtUtc": datetime.now(timezone.utc).isoformat(),
                "correlationId": str(uuid4()),
            },
        )

    with GatewayClient(
        config(),
        external_agent_id="demo-activity-02",
        gateway_agent_key=SYNTHETIC_GATEWAY_KEY,
        transport=httpx.MockTransport(handler)) as client:
        receipt = client.submit_activity(
            activity_id=activity_id,
            session_id="session-1",
            activity_type="ToolInvocation",
            tool=ActivityTool(
                name="get_weather",
                operation="Open-Meteo current weather",
                outcome="Succeeded",
                duration_ms=42,
            ),
        )

    assert receipt.activity_id == activity_id
    assert receipt.status == "Accepted"


def test_unexpected_success_status_for_prompt_evaluation_is_unconfirmed() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        expected = allowed_evaluation(request, "turn-unexpected")
        return json_response(request, 202, json.loads(expected.content))

    with GatewayClient(
        config(),
        external_agent_id="demo-01",
        gateway_agent_key=SYNTHETIC_GATEWAY_KEY,
        transport=httpx.MockTransport(handler)) as client:
        with pytest.raises(GatewayRequestError) as caught:
            client.evaluate_prompt(
                interaction_id="turn-unexpected", prompt="Weather in Seoul?"
            )

    assert caught.value.uncertain is True
    assert caught.value.status_code == 202
    assert caught.value.idempotency_key is not None


def test_unexpected_success_status_for_activity_is_unconfirmed() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return json_response(
            request,
            200,
            {
                "receiptId": str(uuid4()),
                "activityId": "invoke-unexpected",
                "status": "Accepted",
                "receivedAtUtc": datetime.now(timezone.utc).isoformat(),
                "correlationId": str(uuid4()),
            },
        )

    with GatewayClient(
        config(),
        external_agent_id="demo-01",
        gateway_agent_key=SYNTHETIC_GATEWAY_KEY,
        transport=httpx.MockTransport(handler)) as client:
        with pytest.raises(GatewayRequestError) as caught:
            client.submit_activity(
                activity_id="invoke-unexpected",
                session_id="session-1",
                activity_type="InvokeAgent",
            )

    assert caught.value.uncertain is True
    assert caught.value.status_code == 200
    assert caught.value.idempotency_key is not None


def test_unexpected_success_status_for_interaction_is_unconfirmed() -> None:
    interaction_id = "turn-interaction-unexpected"
    calls = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        if calls == 1:
            return allowed_evaluation(request, interaction_id)
        return json_response(
            request,
            200,
            {
                "receiptId": str(uuid4()),
                "interactionId": interaction_id,
                "status": "Accepted",
                "purviewProcessing": "Allowed",
                "observabilityProcessing": "Queued",
                "correlationId": str(uuid4()),
            },
        )

    with GatewayClient(
        config(),
        external_agent_id="demo-01",
        gateway_agent_key=SYNTHETIC_GATEWAY_KEY,
        transport=httpx.MockTransport(handler)) as client:
        evaluation = client.evaluate_prompt(
            interaction_id=interaction_id, prompt="hello"
        )
        with pytest.raises(GatewayRequestError) as caught:
            client.submit_interaction(
                evaluation,
                session_id="session-1",
                prompt="hello",
                response_content="candidate answer",
            )

    assert caught.value.uncertain is True
    assert caught.value.status_code == 200
    assert caught.value.idempotency_key is not None


def test_changed_protection_context_has_sanitized_retryable_error() -> None:
    interaction_id = "turn-protection-context-changed"
    correlation_id = str(uuid4())
    calls = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        if calls == 1:
            return allowed_evaluation(request, interaction_id)
        return json_response(
            request,
            403,
            {
                "errorCode": "PROMPT_EVALUATION_INVALID",
                "correlationId": correlation_id,
                "detail": "raw-provider-detail-must-not-be-used",
            },
        )

    with GatewayClient(
        config(),
        external_agent_id="demo-01",
        gateway_agent_key=SYNTHETIC_GATEWAY_KEY,
        transport=httpx.MockTransport(handler)) as client:
        evaluation = client.evaluate_prompt(
            interaction_id=interaction_id, prompt="hello"
        )
        with pytest.raises(GatewayRequestError) as caught:
            client.submit_interaction(
                evaluation,
                session_id="session-1",
                prompt="hello",
                response_content="candidate answer",
            )

    assert caught.value.status_code == 403
    assert caught.value.error_code == "PROMPT_EVALUATION_INVALID"
    assert caught.value.correlation_id == correlation_id
    assert caught.value.uncertain is False
    assert str(caught.value) == (
        "The agent or protection settings changed while this request was running. "
        "Start a new request."
    )
    assert "raw-provider" not in str(caught.value)


def test_malformed_mutation_receipt_preserves_reconciliation_key() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return json_response(
            request,
            202,
            {
                "receiptId": "not-a-uuid",
                "activityId": "tool-123",
                "status": "Accepted",
                "receivedAtUtc": datetime.now(timezone.utc).isoformat(),
                "correlationId": str(uuid4()),
            },
        )

    with GatewayClient(
        config(),
        external_agent_id="demo-01",
        gateway_agent_key=SYNTHETIC_GATEWAY_KEY,
        transport=httpx.MockTransport(handler)) as client:
        with pytest.raises(GatewayProtocolError) as caught:
            client.submit_activity(
                activity_id="tool-123",
                session_id="session-1",
                activity_type="ToolInvocation",
            )

    assert caught.value.uncertain is True
    assert caught.value.idempotency_key is not None
    assert UUID(caught.value.idempotency_key).version == 4


@pytest.mark.parametrize(
    ("status", "purview", "blocked"),
    [
        ("Accepted", "Allowed", False),
        ("Failed", "Allowed", True),
        ("Accepted", "Blocked", True),
    ],
)
def test_gateway_client_withholds_failed_or_purview_blocked_interaction(
    status: str, purview: str, blocked: bool
) -> None:
    interaction_id = "turn-response"
    calls = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        if calls == 1:
            return allowed_evaluation(request, interaction_id)
        assert request.url.path == "/api/v1/ai-interactions"
        assert_gateway_headers(request)
        body = json.loads(request.content)
        assert body["externalAgentId"] == "demo-response-03"
        assert body["interactionId"] == interaction_id
        assert body["prompt"]["content"] == "hello"
        assert body["response"]["content"] == "candidate answer"
        return json_response(
            request,
            202,
            {
                "receiptId": str(uuid4()),
                "interactionId": interaction_id,
                "status": status,
                "purviewProcessing": purview,
                "observabilityProcessing": "Queued",
                "correlationId": str(uuid4()),
            },
        )

    with GatewayClient(
        config(),
        external_agent_id="demo-response-03",
        gateway_agent_key=SYNTHETIC_GATEWAY_KEY,
        transport=httpx.MockTransport(handler)) as client:
        evaluation = client.evaluate_prompt(
            interaction_id=interaction_id, prompt="hello"
        )
        receipt = client.submit_interaction(
            evaluation,
            session_id="session-1",
            prompt="hello",
            response_content="candidate answer",
        )

    assert receipt.blocked is blocked


@pytest.mark.parametrize(
    "purview_processing",
    ["PurviewSkipped_NoUserContext", "PurviewSkipped_InvalidUser"],
)
def test_gateway_client_withholds_interaction_with_skipped_purview_state(
    purview_processing: str,
) -> None:
    interaction_id = "turn-skipped-purview"
    calls = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        if calls == 1:
            return allowed_evaluation(request, interaction_id)
        return json_response(
            request,
            202,
            {
                "receiptId": str(uuid4()),
                "interactionId": interaction_id,
                "status": "Accepted",
                "purviewProcessing": purview_processing,
                "observabilityProcessing": "Queued",
                "correlationId": str(uuid4()),
            },
        )

    with GatewayClient(
        config(),
        external_agent_id="demo-01",
        gateway_agent_key=SYNTHETIC_GATEWAY_KEY,
        transport=httpx.MockTransport(handler)) as client:
        evaluation = client.evaluate_prompt(
            interaction_id=interaction_id, prompt="hello"
        )
        with pytest.raises(GatewayProtocolError, match="permitted Purview state") as caught:
            client.submit_interaction(
                evaluation,
                session_id="session-1",
                prompt="hello",
                response_content="candidate answer",
            )

    assert caught.value.uncertain is True
    assert caught.value.idempotency_key is not None


def test_gateway_client_fails_closed_on_unknown_interaction_status() -> None:
    interaction_id = "turn-unknown-status"
    calls = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        if calls == 1:
            return allowed_evaluation(request, interaction_id)
        return json_response(
            request,
            202,
            {
                "receiptId": str(uuid4()),
                "interactionId": interaction_id,
                "status": "QueuedForSomethingNew",
                "purviewProcessing": "Allowed",
                "observabilityProcessing": "Queued",
                "correlationId": str(uuid4()),
            },
        )

    with GatewayClient(
        config(),
        external_agent_id="demo-01",
        gateway_agent_key=SYNTHETIC_GATEWAY_KEY,
        transport=httpx.MockTransport(handler)) as client:
        evaluation = client.evaluate_prompt(
            interaction_id=interaction_id, prompt="hello"
        )
        with pytest.raises(GatewayProtocolError, match="unknown interaction") as caught:
            client.submit_interaction(
                evaluation,
                session_id="session-1",
                prompt="hello",
                response_content="candidate answer",
            )

    assert caught.value.uncertain is True
    assert caught.value.idempotency_key is not None


def test_gateway_client_refuses_prompt_changed_after_evaluation() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return allowed_evaluation(request, "turn")

    with GatewayClient(
        config(),
        external_agent_id="demo-01",
        gateway_agent_key=SYNTHETIC_GATEWAY_KEY,
        transport=httpx.MockTransport(handler)) as client:
        evaluation = client.evaluate_prompt(interaction_id="turn", prompt="original")
        with pytest.raises(ValueError, match="does not match"):
            client.submit_interaction(
                evaluation,
                session_id="session-1",
                prompt="changed",
                response_content="candidate",
            )


def test_gateway_transport_error_never_echoes_key_prompt_or_provider_body() -> None:
    prompt = "private prompt text"

    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError(
            f"upstream included {SYNTHETIC_GATEWAY_KEY} and {prompt}", request=request
        )

    with GatewayClient(
        config(),
        external_agent_id="demo-01",
        gateway_agent_key=SYNTHETIC_GATEWAY_KEY,
        transport=httpx.MockTransport(handler)) as client:
        with pytest.raises(GatewayTransportError) as caught:
            client.evaluate_prompt(interaction_id="turn", prompt=prompt)

    rendered = str(caught.value)
    assert caught.value.uncertain is True
    assert SYNTHETIC_GATEWAY_KEY not in rendered
    assert prompt not in rendered


def test_gateway_client_does_not_follow_redirects() -> None:
    calls = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        return httpx.Response(
            307,
            headers={"Location": "https://untrusted.example.test/collect"},
            request=request,
        )

    with GatewayClient(
        config(),
        external_agent_id="demo-01",
        gateway_agent_key=SYNTHETIC_GATEWAY_KEY,
        transport=httpx.MockTransport(handler)) as client:
        with pytest.raises(GatewayProtocolError, match="redirect"):
            client.evaluate_prompt(interaction_id="turn", prompt="hello")

    assert calls == 1
