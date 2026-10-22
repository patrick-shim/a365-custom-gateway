"""Flask application factory for the protected weather-agent sample."""

from __future__ import annotations

import asyncio
import ipaddress
from typing import Any
from urllib.parse import urlsplit

from flask import Flask, Response, jsonify, render_template, request
from werkzeug.exceptions import RequestEntityTooLarge

from .config import (
    AppConfig,
    validate_external_agent_id,
    validate_gateway_agent_key,
)
from .foundry_chat import FoundryChat
from .gateway_client import GatewayClient
from .mcp_client import McpWeatherClient
from .workflow import AgentWorkflow, ChatResult, Stage, parse_history, validate_session_id


def _run(coroutine: Any) -> Any:
    return asyncio.run(coroutine)


def _is_loopback_request_host(value: str) -> bool:
    """Validate the Host header lexically; never resolve attacker-controlled DNS."""

    try:
        parsed = urlsplit(f"//{value}")
        _ = parsed.port
    except ValueError:
        return False
    if (
        not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.path
        or parsed.query
        or parsed.fragment
    ):
        return False
    if parsed.hostname.lower() == "localhost":
        return True
    try:
        return ipaddress.ip_address(parsed.hostname).is_loopback
    except ValueError:
        return False


def _validation_failure(message: str, session_id: str | None = None) -> ChatResult:
    return ChatResult(
        outcome="failed",
        message="The chat request was not valid.",
        stages=(
            Stage(
                id="request-validation",
                label="Request validation",
                status="failed",
                detail=message,
            ),
        ),
        session_id=session_id or "",
    )


def _request_boolean(payload: dict[str, Any], name: str) -> bool:
    value = payload.get(name, True)
    if type(value) is not bool:
        raise ValueError(f"{name} must be true or false.")
    return value


def build_workflow(config: AppConfig) -> AgentWorkflow:
    mcp_client = McpWeatherClient(
        server_url=config.mcp_server_url,
        mcp_timeout_seconds=config.mcp_timeout_seconds,
    )
    foundry = FoundryChat(
        azure_endpoint=config.foundry_endpoint,
        model_deployment=config.foundry_model,
        api_version=config.foundry_api_version,
        mcp_client=mcp_client,
        request_timeout_seconds=config.foundry_timeout_seconds,
    )

    def gateway_factory(
        *, external_agent_id: str, gateway_agent_key: str
    ) -> GatewayClient:
        return GatewayClient(
            config,
            external_agent_id=external_agent_id,
            gateway_agent_key=gateway_agent_key,
        )

    return AgentWorkflow(
        config,
        gateway_factory=gateway_factory,
        foundry=foundry,
        mcp_client=mcp_client,
    )


def create_app(
    config: AppConfig,
    *,
    workflow: AgentWorkflow | None = None,
) -> Flask:
    app = Flask(
        __name__,
        template_folder="../templates",
        static_folder="../static",
    )
    app.config.update(
        MAX_CONTENT_LENGTH=64 * 1024,
        JSON_SORT_KEYS=False,
    )
    agent_workflow = workflow or build_workflow(config)

    @app.before_request
    def reject_untrusted_request_boundary() -> Response | None:
        if not _is_loopback_request_host(request.host):
            return jsonify(
                {
                    "outcome": "failed",
                    "message": "The request host is not allowed.",
                    "stages": [
                        {
                            "id": "request-host",
                            "label": "Request host",
                            "status": "failed",
                            "detail": "Open the chat through its local loopback address.",
                        }
                    ],
                    "sessionId": "",
                }
            ), 403
        if request.method != "POST" or not request.path.startswith("/api/"):
            return None
        origin = request.headers.get("Origin")
        if not origin:
            return None
        parsed = urlsplit(origin)
        if (
            parsed.scheme not in {"http", "https"}
            or parsed.username is not None
            or parsed.password is not None
            or parsed.path not in {"", "/"}
            or parsed.query
            or parsed.fragment
            or parsed.netloc.lower() != request.host.lower()
        ):
            return jsonify(
                {
                    "outcome": "failed",
                    "message": "The browser origin is not allowed.",
                    "stages": [
                        {
                            "id": "request-origin",
                            "label": "Request origin",
                            "status": "failed",
                            "detail": "Open the chat from this Flask server and try again.",
                        }
                    ],
                    "sessionId": "",
                }
            ), 403
        return None

    @app.after_request
    def secure_response(response: Response) -> Response:
        response.headers["Cache-Control"] = "no-store"
        response.headers["Pragma"] = "no-cache"
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["Permissions-Policy"] = (
            "camera=(), microphone=(), geolocation=(), payment=()"
        )
        response.headers["Content-Security-Policy"] = (
            "default-src 'self'; base-uri 'none'; frame-ancestors 'none'; "
            "form-action 'self'; img-src 'self' data:; style-src 'self'; "
            "script-src 'self'; connect-src 'self'"
        )
        return response

    @app.get("/")
    def index() -> str:
        return render_template("index.html")

    @app.get("/api/status")
    def status() -> Response:
        try:
            return jsonify(_run(agent_workflow.service_status()))
        except Exception:
            return jsonify(
                {
                    "services": {
                        "gateway": {
                            "status": "Unavailable",
                            "detail": "The status check failed safely.",
                        },
                        "foundry": {
                            "status": "Configured",
                            "detail": f"{config.foundry_model} is configured server-side.",
                        },
                        "mcp": {
                            "status": "Unavailable",
                            "detail": "The weather tool status could not be read.",
                        },
                    },
                }
            ), 503

    @app.post("/api/chat")
    def chat() -> Response:
        if not request.is_json:
            result = _validation_failure("Content-Type must be application/json.")
            return jsonify(result.as_dict()), 415
        payload = request.get_json(silent=True)
        if not isinstance(payload, dict):
            result = _validation_failure("The request body must be a JSON object.")
            return jsonify(result.as_dict()), 400
        try:
            external_agent_id = validate_external_agent_id(
                payload.get("externalAgentId")
            )
            gateway_agent_key = validate_gateway_agent_key(
                payload.pop("gatewayAgentKey", None)
            )
            prompt_evaluation_enabled = _request_boolean(
                payload, "promptEvaluationEnabled"
            )
            response_evaluation_enabled = _request_boolean(
                payload, "responseEvaluationEnabled"
            )
            if response_evaluation_enabled and not prompt_evaluation_enabled:
                raise ValueError(
                    "responseEvaluationEnabled requires promptEvaluationEnabled."
                )
            session_id = validate_session_id(payload.get("sessionId"))
            history = parse_history(payload.get("history"))
            message = payload.get("message")
            if not isinstance(message, str):
                raise ValueError("message is required.")
            result = _run(
                asyncio.wait_for(
                    agent_workflow.run_chat(
                        message=message,
                        history=history,
                        session_id=session_id,
                        external_agent_id=external_agent_id,
                        gateway_agent_key=gateway_agent_key,
                        prompt_evaluation_enabled=prompt_evaluation_enabled,
                        response_evaluation_enabled=response_evaluation_enabled,
                    ),
                    timeout=config.chat_turn_timeout_seconds,
                )
            )
        except TimeoutError:
            result = ChatResult(
                outcome="unconfirmed",
                message="The chat request did not finish before the server deadline.",
                stages=(
                    Stage(
                        id="turn-timeout",
                        label="Chat request deadline",
                        status="unconfirmed",
                        detail=(
                            "Any current Gateway mutation is unconfirmed. "
                            "No later workflow step was started after the deadline."
                        ),
                    ),
                ),
                session_id=str(payload.get("sessionId") or ""),
            )
            return jsonify(result.as_dict()), 503
        except ValueError as error:
            result = _validation_failure(str(error), payload.get("sessionId"))
            return jsonify(result.as_dict()), 400
        except Exception:
            result = ChatResult(
                outcome="failed",
                message="The sample server could not complete the chat request.",
                stages=(
                    Stage(
                        id="server",
                        label="Sample server",
                        status="failed",
                        detail="Review the server health and start a new request.",
                    ),
                ),
                session_id=str(payload.get("sessionId") or ""),
            )
            return jsonify(result.as_dict()), 500

        status_code = {
            "allowed": 200,
            "unevaluated": 200,
            "blocked": 403,
            "failed": 502,
            "unconfirmed": 503,
        }[result.outcome]
        return jsonify(result.as_dict()), status_code

    @app.errorhandler(RequestEntityTooLarge)
    def request_too_large(_: RequestEntityTooLarge) -> tuple[Response, int]:
        result = _validation_failure("The request exceeded the 64 KiB limit.")
        return jsonify(result.as_dict()), 413

    return app

