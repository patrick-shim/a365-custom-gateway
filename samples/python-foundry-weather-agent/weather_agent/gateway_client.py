from __future__ import annotations

import hashlib
import re
from collections.abc import Callable, Mapping
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any
from uuid import UUID, uuid4

import httpx

from .config import (
    AppConfig,
    validate_external_agent_id,
    validate_gateway_agent_key,
)


_SAFE_REFERENCE = re.compile(r"^[A-Fa-f0-9-]{16,64}$")
_PROMPT_BLOCK_CODES = frozenset(
    {
        "PROMPT_BLOCKED_BY_PROMPT_SHIELD",
        "PROMPT_BLOCKED_BY_DLP",
        "PROMPT_BLOCKED_BY_MULTIPLE_CONTROLS",
    }
)
PROMPT_EVALUATION_INVALID_ERROR_CODE = "PROMPT_EVALUATION_INVALID"
AGENT_IDENTITY_MISMATCH_ERROR_CODE = "AGENT_IDENTITY_MISMATCH"
AGENT_DISABLED_ERROR_CODE = "AGENT_DISABLED"
_PROTECTION_CONTEXT_CHANGED_MESSAGE = (
    "The agent or protection settings changed while this request was running. "
    "Start a new request."
)
_MAX_GATEWAY_RESPONSE_BYTES = 128 * 1024
_INTERACTION_RECEIPT_STATUSES = frozenset({"Accepted", "Failed"})
_PROMPT_SHIELD_PROCESSING_STATUSES = frozenset({"Allowed", "Blocked", "Disabled"})
_PURVIEW_PROCESSING_STATUSES = frozenset(
    {
        "Allowed",
        "Blocked",
        "AuditOnly",
        "AuditLogged",
        "PurviewSkipped_NoUserContext",
        "PurviewSkipped_InvalidUser",
        "PurviewDisabled",
        "SimulationUnavailable",
        "SimulatedBlock",
    }
)
_PURVIEW_ALLOWED_PROCESSING_STATUSES = frozenset(
    {
        "Allowed",
        "AuditOnly",
        "AuditLogged",
        "PurviewDisabled",
        "SimulationUnavailable",
        "SimulatedBlock",
    }
)


@dataclass(frozen=True, slots=True)
class GatewayEndpoint:
    """Allowlisted method and route used for transport and safe UI tracing."""

    method: str
    route: str

    def as_dict(self) -> dict[str, str]:
        return {"method": self.method, "route": self.route}


GATEWAY_READINESS_ENDPOINT = GatewayEndpoint(
    "GET", "/api/v1/agent-runtime/readiness"
)
GATEWAY_PROMPT_EVALUATION_ENDPOINT = GatewayEndpoint(
    "POST", "/api/v1/prompts:evaluate"
)
GATEWAY_ACTIVITY_ENDPOINT = GatewayEndpoint(
    "POST", "/api/v1/agent-activities"
)
GATEWAY_INTERACTION_ENDPOINT = GatewayEndpoint(
    "POST", "/api/v1/ai-interactions"
)
GATEWAY_ENDPOINTS = (
    GATEWAY_READINESS_ENDPOINT,
    GATEWAY_PROMPT_EVALUATION_ENDPOINT,
    GATEWAY_ACTIVITY_ENDPOINT,
    GATEWAY_INTERACTION_ENDPOINT,
)


class GatewayError(RuntimeError):
    """A sanitized Gateway failure safe to surface in the sample UI."""

    def __init__(
        self,
        message: str,
        *,
        status_code: int | None = None,
        error_code: str | None = None,
        correlation_id: str | None = None,
        uncertain: bool = False,
        idempotency_key: str | None = None,
    ) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.error_code = error_code
        self.correlation_id = correlation_id
        self.uncertain = uncertain
        self.idempotency_key = idempotency_key


class GatewayTransportError(GatewayError):
    """The Gateway did not return a usable HTTP response."""


class GatewayProtocolError(GatewayError):
    """The Gateway response did not match the documented contract."""


class GatewayRequestError(GatewayError):
    """The Gateway rejected or could not complete a request."""


@dataclass(frozen=True, slots=True)
class PromptEvaluationResult:
    evaluation_id: UUID
    evaluation_receipt_id: UUID | None
    interaction_id: str
    allowed: bool
    decision: str
    prompt_shield_processing: str
    purview_processing: str
    expires_at_utc: datetime | None
    occurred_at_utc: datetime
    correlation_id: str | None
    user_message: str
    _prompt_digest: bytes = field(repr=False)


@dataclass(frozen=True, slots=True)
class ActivityTool:
    name: str
    operation: str | None
    outcome: str
    duration_ms: int | None = None


@dataclass(frozen=True, slots=True)
class ActivityReceipt:
    receipt_id: UUID
    activity_id: str
    status: str
    received_at_utc: datetime
    correlation_id: str | None


@dataclass(frozen=True, slots=True)
class InteractionReceipt:
    receipt_id: UUID
    interaction_id: str
    status: str
    purview_processing: str | None
    observability_processing: str | None
    correlation_id: str | None
    blocked: bool


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _as_utc(value: datetime | None) -> datetime:
    if value is None:
        return _utc_now()
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("A timezone-aware UTC timestamp is required.")
    return value.astimezone(timezone.utc)


def _utc_text(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _parse_datetime(value: Any, field_name: str) -> datetime:
    if not isinstance(value, str):
        raise GatewayProtocolError(f"Gateway response omitted {field_name}.")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise GatewayProtocolError(
            f"Gateway response contained an invalid {field_name}."
        ) from exc
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise GatewayProtocolError(
            f"Gateway response contained a non-UTC {field_name}."
        )
    return parsed.astimezone(timezone.utc)


def _parse_uuid(value: Any, field_name: str) -> UUID:
    try:
        parsed = UUID(str(value))
    except (ValueError, TypeError, AttributeError) as exc:
        raise GatewayProtocolError(
            f"Gateway response contained an invalid {field_name}."
        ) from exc
    if parsed.int == 0:
        raise GatewayProtocolError(
            f"Gateway response contained an invalid {field_name}."
        )
    return parsed


def _required_text(payload: Mapping[str, Any], name: str) -> str:
    value = payload.get(name)
    if not isinstance(value, str) or not value:
        raise GatewayProtocolError(f"Gateway response omitted {name}.")
    return value


def _safe_reference(value: Any) -> str | None:
    return value if isinstance(value, str) and _SAFE_REFERENCE.fullmatch(value) else None


def _prompt_digest(content_type: str, prompt: str) -> bytes:
    return hashlib.sha256(
        content_type.encode("utf-8") + b"\x00" + prompt.encode("utf-8")
    ).digest()


def _validate_content(value: str, name: str, maximum: int) -> None:
    if not value or len(value) > maximum:
        raise ValueError(f"{name} must contain between 1 and {maximum} characters.")


class GatewayClient:
    """Synchronous, no-retry client for registration-bound Gateway ingress."""

    def __init__(
        self,
        config: AppConfig,
        *,
        external_agent_id: str,
        gateway_agent_key: str,
        transport: httpx.BaseTransport | None = None,
    ) -> None:
        self._config = config
        self._external_agent_id = validate_external_agent_id(external_agent_id)
        self._gateway_agent_key = validate_gateway_agent_key(gateway_agent_key)
        self._client = httpx.Client(
            base_url=config.gateway_base_url,
            timeout=httpx.Timeout(config.gateway_timeout_seconds),
            follow_redirects=False,
            trust_env=False,
            transport=transport,
        )

    def close(self) -> None:
        self._client.close()

    def __enter__(self) -> "GatewayClient":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def readiness(self) -> None:
        response, payload, _ = self._send(GATEWAY_READINESS_ENDPOINT)
        if response.status_code != 204:
            self._raise_request_error(response, None, payload)

    @staticmethod
    def _parse_mutation_value(
        response: httpx.Response,
        payload: Mapping[str, Any],
        idempotency_key: str | None,
        parser: Callable[[], Any],
    ) -> Any:
        """Preserve reconciliation data when a committed response is malformed."""

        try:
            return parser()
        except GatewayProtocolError as error:
            raise GatewayProtocolError(
                str(error),
                status_code=error.status_code or response.status_code,
                correlation_id=(
                    error.correlation_id
                    or _safe_reference(payload.get("correlationId"))
                ),
                uncertain=True,
                idempotency_key=error.idempotency_key or idempotency_key,
            ) from error

    def evaluate_prompt(
        self,
        *,
        interaction_id: str,
        prompt: str,
        content_type: str = "text/plain",
        occurred_at_utc: datetime | None = None,
    ) -> PromptEvaluationResult:
        self._validate_interaction_id(interaction_id)
        _validate_content(prompt, "prompt", 10_000)
        self._validate_content_type(content_type)
        occurred_at = _as_utc(occurred_at_utc)
        body = {
            "externalAgentId": self._external_agent_id,
            "interactionId": interaction_id,
            "occurredAtUtc": _utc_text(occurred_at),
            "userContext": {
                "tenantUserObjectId": str(self._config.gateway_tenant_user_id)
            },
            "prompt": {"contentType": content_type, "content": prompt},
        }
        response, payload, idempotency_key = self._send(
            GATEWAY_PROMPT_EVALUATION_ENDPOINT, body
        )
        digest = _prompt_digest(content_type, prompt)

        if response.status_code == 403 and payload is not None:
            error_code = payload.get("errorCode")
            if isinstance(error_code, str) and error_code in _PROMPT_BLOCK_CODES:
                return PromptEvaluationResult(
                    evaluation_id=self._parse_mutation_value(
                        response,
                        payload,
                        idempotency_key,
                        lambda: _parse_uuid(
                            payload.get("evaluationId"), "evaluationId"
                        ),
                    ),
                    evaluation_receipt_id=None,
                    interaction_id=interaction_id,
                    allowed=False,
                    decision=error_code,
                    prompt_shield_processing=self._parse_mutation_value(
                        response,
                        payload,
                        idempotency_key,
                        lambda: _required_text(payload, "promptShieldProcessing"),
                    ),
                    purview_processing=self._parse_mutation_value(
                        response,
                        payload,
                        idempotency_key,
                        lambda: _required_text(payload, "purviewProcessing"),
                    ),
                    expires_at_utc=None,
                    occurred_at_utc=occurred_at,
                    correlation_id=_safe_reference(payload.get("correlationId")),
                    user_message="The prompt was blocked by the configured protection policy.",
                    _prompt_digest=digest,
                )

        if response.status_code != 200 or payload is None:
            self._raise_request_error(response, idempotency_key, payload)
        if payload.get("interactionId") != interaction_id:
            raise GatewayProtocolError(
                "Gateway prompt evaluation did not match this interaction.",
                idempotency_key=idempotency_key,
                uncertain=True,
            )
        if payload.get("allowed") is not True:
            raise GatewayProtocolError(
                "Gateway returned an inconsistent prompt evaluation.",
                idempotency_key=idempotency_key,
                uncertain=True,
            )
        evaluation_id = self._parse_mutation_value(
            response,
            payload,
            idempotency_key,
            lambda: _parse_uuid(payload.get("evaluationId"), "evaluationId"),
        )
        receipt_id = self._parse_mutation_value(
            response,
            payload,
            idempotency_key,
            lambda: _parse_uuid(
                payload.get("evaluationReceiptId"), "evaluationReceiptId"
            ),
        )
        if evaluation_id != receipt_id:
            raise GatewayProtocolError(
                "Gateway prompt evaluation and receipt identifiers did not match.",
                status_code=response.status_code,
                correlation_id=_safe_reference(payload.get("correlationId")),
                uncertain=True,
                idempotency_key=idempotency_key,
            )
        expires_at = self._parse_mutation_value(
            response,
            payload,
            idempotency_key,
            lambda: _parse_datetime(payload.get("expiresAtUtc"), "expiresAtUtc"),
        )
        if expires_at <= _utc_now():
            raise GatewayProtocolError(
                "Gateway returned an expired prompt evaluation receipt.",
                idempotency_key=idempotency_key,
                uncertain=True,
            )
        decision = self._parse_mutation_value(
            response,
            payload,
            idempotency_key,
            lambda: _required_text(payload, "decision"),
        )
        prompt_shield_processing = self._parse_mutation_value(
            response,
            payload,
            idempotency_key,
            lambda: _required_text(payload, "promptShieldProcessing"),
        )
        purview_processing = self._parse_mutation_value(
            response,
            payload,
            idempotency_key,
            lambda: _required_text(payload, "purviewProcessing"),
        )
        if (
            decision != "PROMPT_ALLOWED"
            or prompt_shield_processing not in _PROMPT_SHIELD_PROCESSING_STATUSES
            or prompt_shield_processing == "Blocked"
            or purview_processing not in _PURVIEW_ALLOWED_PROCESSING_STATUSES
        ):
            raise GatewayProtocolError(
                "Gateway returned an unknown or inconsistent allow decision.",
                status_code=response.status_code,
                correlation_id=_safe_reference(payload.get("correlationId")),
                uncertain=True,
                idempotency_key=idempotency_key,
            )
        return PromptEvaluationResult(
            evaluation_id=evaluation_id,
            evaluation_receipt_id=receipt_id,
            interaction_id=interaction_id,
            allowed=True,
            decision=decision,
            prompt_shield_processing=prompt_shield_processing,
            purview_processing=purview_processing,
            expires_at_utc=expires_at,
            occurred_at_utc=occurred_at,
            correlation_id=_safe_reference(payload.get("correlationId")),
            user_message=(
                payload.get("userMessage")
                if isinstance(payload.get("userMessage"), str)
                else "The prompt passed Gateway protection checks."
            ),
            _prompt_digest=digest,
        )

    def submit_activity(
        self,
        *,
        activity_id: str,
        session_id: str | None,
        activity_type: str,
        actor_type: str = "User",
        tool: ActivityTool | None = None,
        attributes: Mapping[str, str] | None = None,
        occurred_at_utc: datetime | None = None,
    ) -> ActivityReceipt:
        self._validate_interaction_id(activity_id, "activity_id")
        occurred_at = _as_utc(occurred_at_utc)
        body: dict[str, Any] = {
            "externalAgentId": self._external_agent_id,
            "activityId": activity_id,
            "sessionId": session_id,
            "activityType": activity_type,
            "occurredAtUtc": _utc_text(occurred_at),
            "actor": {
                "type": actor_type,
                "tenantUserObjectId": str(self._config.gateway_tenant_user_id),
            },
            "attributes": dict(attributes) if attributes is not None else None,
        }
        if tool is not None:
            body["tool"] = {
                "name": tool.name,
                "operation": tool.operation,
                "outcome": tool.outcome,
                "durationMs": tool.duration_ms,
            }
        response, payload, idempotency_key = self._send(
            GATEWAY_ACTIVITY_ENDPOINT, body
        )
        if response.status_code != 202 or payload is None:
            self._raise_request_error(response, idempotency_key, payload)
        if payload.get("activityId") != activity_id:
            raise GatewayProtocolError(
                "Gateway activity receipt did not match this activity.",
                status_code=response.status_code,
                correlation_id=_safe_reference(payload.get("correlationId")),
                idempotency_key=idempotency_key,
                uncertain=True,
            )
        status = self._parse_mutation_value(
            response,
            payload,
            idempotency_key,
            lambda: _required_text(payload, "status"),
        )
        if status != "Accepted":
            raise GatewayProtocolError(
                "Gateway returned an unknown activity receipt status.",
                status_code=response.status_code,
                correlation_id=_safe_reference(payload.get("correlationId")),
                uncertain=True,
                idempotency_key=idempotency_key,
            )
        return ActivityReceipt(
            receipt_id=self._parse_mutation_value(
                response,
                payload,
                idempotency_key,
                lambda: _parse_uuid(payload.get("receiptId"), "receiptId"),
            ),
            activity_id=activity_id,
            status=status,
            received_at_utc=self._parse_mutation_value(
                response,
                payload,
                idempotency_key,
                lambda: _parse_datetime(
                    payload.get("receivedAtUtc"), "receivedAtUtc"
                ),
            ),
            correlation_id=_safe_reference(payload.get("correlationId")),
        )

    def submit_interaction(
        self,
        evaluation: PromptEvaluationResult,
        *,
        session_id: str | None,
        prompt: str,
        response_content: str,
        prompt_content_type: str = "text/plain",
        response_content_type: str = "text/plain",
        model_provider: str = "Microsoft Foundry",
        model_name: str | None = None,
        metadata: Mapping[str, str] | None = None,
    ) -> InteractionReceipt:
        if (
            not evaluation.allowed
            or evaluation.evaluation_receipt_id is None
            or evaluation.expires_at_utc is None
        ):
            raise ValueError("An allowed prompt evaluation receipt is required.")
        if evaluation.expires_at_utc <= _utc_now():
            raise ValueError("The prompt evaluation receipt has expired.")
        _validate_content(prompt, "prompt", 32_768)
        _validate_content(response_content, "response", 32_768)
        self._validate_content_type(prompt_content_type)
        self._validate_content_type(response_content_type)
        if _prompt_digest(prompt_content_type, prompt) != evaluation._prompt_digest:
            raise ValueError("The interaction prompt does not match its evaluation.")

        body = {
            "externalAgentId": self._external_agent_id,
            "interactionId": evaluation.interaction_id,
            "sessionId": session_id,
            "occurredAtUtc": _utc_text(evaluation.occurred_at_utc),
            "userContext": {
                "tenantUserObjectId": str(self._config.gateway_tenant_user_id)
            },
            "prompt": {
                "contentType": prompt_content_type,
                "content": prompt,
            },
            "response": {
                "contentType": response_content_type,
                "content": response_content,
            },
            "model": {
                "provider": model_provider,
                "name": model_name or self._config.foundry_model,
            },
            "metadata": dict(metadata) if metadata is not None else None,
            "promptEvaluationReceiptId": str(evaluation.evaluation_receipt_id),
        }
        gateway_response, payload, idempotency_key = self._send(
            GATEWAY_INTERACTION_ENDPOINT, body
        )
        if gateway_response.status_code != 202 or payload is None:
            self._raise_request_error(
                gateway_response, idempotency_key, payload
            )
        if payload.get("interactionId") != evaluation.interaction_id:
            raise GatewayProtocolError(
                "Gateway interaction receipt did not match this interaction.",
                status_code=gateway_response.status_code,
                correlation_id=_safe_reference(payload.get("correlationId")),
                idempotency_key=idempotency_key,
                uncertain=True,
            )
        status = self._parse_mutation_value(
            gateway_response,
            payload,
            idempotency_key,
            lambda: _required_text(payload, "status"),
        )
        if status not in _INTERACTION_RECEIPT_STATUSES:
            raise GatewayProtocolError(
                "Gateway returned an unknown interaction receipt status.",
                status_code=gateway_response.status_code,
                correlation_id=_safe_reference(payload.get("correlationId")),
                uncertain=True,
                idempotency_key=idempotency_key,
            )
        purview = self._parse_mutation_value(
            gateway_response,
            payload,
            idempotency_key,
            lambda: _required_text(payload, "purviewProcessing"),
        )
        if purview not in _PURVIEW_PROCESSING_STATUSES:
            raise GatewayProtocolError(
                "Gateway returned an unknown purviewProcessing value.",
                status_code=gateway_response.status_code,
                correlation_id=_safe_reference(payload.get("correlationId")),
                uncertain=True,
                idempotency_key=idempotency_key,
            )
        if purview not in _PURVIEW_ALLOWED_PROCESSING_STATUSES and purview != "Blocked":
            raise GatewayProtocolError(
                "Gateway interaction did not return a permitted Purview state.",
                status_code=gateway_response.status_code,
                correlation_id=_safe_reference(payload.get("correlationId")),
                uncertain=True,
                idempotency_key=idempotency_key,
            )
        observability = payload.get("observabilityProcessing")
        if observability is not None and not isinstance(observability, str):
            raise GatewayProtocolError(
                "Gateway response contained an invalid observabilityProcessing value.",
                status_code=gateway_response.status_code,
                correlation_id=_safe_reference(payload.get("correlationId")),
                idempotency_key=idempotency_key,
                uncertain=True,
            )
        blocked = status == "Failed" or purview == "Blocked"
        return InteractionReceipt(
            receipt_id=self._parse_mutation_value(
                gateway_response,
                payload,
                idempotency_key,
                lambda: _parse_uuid(payload.get("receiptId"), "receiptId"),
            ),
            interaction_id=evaluation.interaction_id,
            status=status,
            purview_processing=purview,
            observability_processing=observability,
            correlation_id=_safe_reference(payload.get("correlationId")),
            blocked=blocked,
        )

    def _send(
        self,
        endpoint: GatewayEndpoint,
        body: Mapping[str, Any] | None = None,
    ) -> tuple[httpx.Response, Mapping[str, Any] | None, str | None]:
        method = endpoint.method
        idempotency_key = str(uuid4()) if method == "POST" else None
        headers = {"Authorization": f"Bearer {self._gateway_agent_key}"}
        if body is not None:
            headers["Content-Type"] = "application/json"
        if idempotency_key is not None:
            headers["Idempotency-Key"] = idempotency_key
        try:
            response = self._client.request(
                method,
                endpoint.route,
                headers=headers,
                json=body if body is not None else None,
            )
        except httpx.RequestError as exc:
            raise GatewayTransportError(
                "The Gateway did not return a response. The request outcome is unconfirmed.",
                uncertain=method != "GET",
                idempotency_key=idempotency_key,
            ) from exc

        if 300 <= response.status_code < 400:
            raise GatewayProtocolError(
                "The Gateway returned an unexpected redirect.",
                status_code=response.status_code,
                uncertain=method != "GET",
                idempotency_key=idempotency_key,
            )
        if len(response.content) > _MAX_GATEWAY_RESPONSE_BYTES:
            raise GatewayProtocolError(
                "The Gateway returned an oversized response.",
                status_code=response.status_code,
                uncertain=method != "GET",
                idempotency_key=idempotency_key,
            )
        if response.status_code == 204:
            return response, None, idempotency_key
        try:
            payload = response.json()
        except ValueError as exc:
            raise GatewayProtocolError(
                "The Gateway returned an unreadable response.",
                status_code=response.status_code,
                uncertain=method != "GET",
                idempotency_key=idempotency_key,
            ) from exc
        if not isinstance(payload, Mapping):
            raise GatewayProtocolError(
                "The Gateway returned an invalid response object.",
                status_code=response.status_code,
                uncertain=method != "GET",
                idempotency_key=idempotency_key,
            )
        return response, payload, idempotency_key

    def _raise_request_error(
        self,
        response: httpx.Response,
        idempotency_key: str | None,
        payload: Mapping[str, Any] | None = None,
    ) -> None:
        error_code = (
            payload.get("errorCode")
            if payload is not None and isinstance(payload.get("errorCode"), str)
            else None
        )
        correlation_id = (
            _safe_reference(payload.get("correlationId"))
            if payload is not None
            else None
        )
        unexpected_success = (
            idempotency_key is not None and 200 <= response.status_code < 300
        )
        messages = {
            400: "The Gateway rejected the request fields.",
            401: "The Gateway agent key was rejected.",
            403: "The Gateway denied this agent request.",
            409: "The agent protection state is not ready or changed.",
            413: "The Gateway request exceeded its size limit.",
            429: "The Gateway request limit was reached.",
            503: "A required Gateway protection service is unavailable.",
        }
        error_messages = {
            PROMPT_EVALUATION_INVALID_ERROR_CODE: _PROTECTION_CONTEXT_CHANGED_MESSAGE,
            AGENT_IDENTITY_MISMATCH_ERROR_CODE: (
                "The external agent ID does not match this Gateway key."
            ),
            AGENT_DISABLED_ERROR_CODE: (
                "The selected agent is disabled in this Gateway."
            ),
        }
        message = error_messages.get(
            error_code,
            messages.get(
                response.status_code, "The Gateway could not complete the request."
            ),
        )
        raise GatewayRequestError(
            (
                "The Gateway returned an unexpected success response. "
                "The request outcome is unconfirmed."
                if unexpected_success
                else message
            ),
            status_code=response.status_code,
            error_code=error_code,
            correlation_id=correlation_id,
            uncertain=unexpected_success or response.status_code >= 500,
            idempotency_key=idempotency_key,
        )

    @staticmethod
    def _validate_interaction_id(value: str, name: str = "interaction_id") -> None:
        if not value or len(value) > 256:
            raise ValueError(f"{name} must contain between 1 and 256 characters.")

    @staticmethod
    def _validate_content_type(value: str) -> None:
        if value not in {"text/plain", "text/markdown"}:
            raise ValueError("Content type must be text/plain or text/markdown.")
