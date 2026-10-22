from __future__ import annotations

import ipaddress
import math
import os
import re
from dataclasses import dataclass
from types import MappingProxyType
from typing import Mapping
from urllib.parse import urlsplit, urlunsplit
from uuid import UUID


_AGENT_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$")
_GATEWAY_KEY_PATTERN = re.compile(
    r"^a365gw_v1_[0-9A-Fa-f]{32}\.[A-Za-z0-9_-]{43}$"
)
_FOUNDRY_HOST_SUFFIXES = (
    ".cognitiveservices.azure.com",
    ".openai.azure.com",
)


class ConfigurationError(ValueError):
    """A safe startup error that never contains a configured secret."""


def validate_gateway_agent_key(
    value: object, *, field_name: str = "gatewayAgentKey"
) -> str:
    """Return an exact registration-bound key or raise a secret-safe error."""

    if not isinstance(value, str) or not value:
        raise ValueError(f"{field_name} is required.")
    if not _GATEWAY_KEY_PATTERN.fullmatch(value):
        raise ValueError(
            f"{field_name} is not a valid registration-bound Gateway key."
        )
    return value


def validate_external_agent_id(
    value: object, *, field_name: str = "externalAgentId"
) -> str:
    """Return a normalized external agent ID or raise a safe validation error."""

    if not isinstance(value, str):
        raise ValueError(f"{field_name} is required.")
    normalized = value.strip()
    if not normalized:
        raise ValueError(f"{field_name} is required.")
    if not _AGENT_ID_PATTERN.fullmatch(normalized):
        raise ValueError(
            f"{field_name} must be 3-128 URL-safe characters."
        )
    return normalized


def _required(environment: Mapping[str, str], name: str) -> str:
    value = environment.get(name, "").strip()
    if not value:
        raise ConfigurationError(f"{name} is required.")
    return value


def _is_loopback(hostname: str | None) -> bool:
    if not hostname:
        return False
    if hostname.lower() == "localhost":
        return True
    try:
        return ipaddress.ip_address(hostname).is_loopback
    except ValueError:
        return False


def _normalize_url(
    value: str,
    name: str,
    *,
    allow_loopback_http: bool = False,
    root_only: bool = False,
) -> str:
    try:
        parsed = urlsplit(value)
        port = parsed.port
    except ValueError as exc:
        raise ConfigurationError(f"{name} is not a valid URL.") from exc

    if (
        parsed.scheme not in {"http", "https"}
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise ConfigurationError(
            f"{name} must be an HTTP(S) URL without credentials, query, or fragment."
        )
    if port is not None and not 1 <= port <= 65_535:
        raise ConfigurationError(f"{name} contains an invalid port.")
    if parsed.scheme == "http" and not (
        allow_loopback_http and _is_loopback(parsed.hostname)
    ):
        raise ConfigurationError(
            f"{name} must use HTTPS unless it targets loopback."
        )
    if root_only and parsed.path not in {"", "/"}:
        raise ConfigurationError(f"{name} must be a resource root URL.")
    if name == "FOUNDRY_ENDPOINT" and (
        parsed.scheme != "https"
        or parsed.hostname is None
        or not parsed.hostname.lower().endswith(_FOUNDRY_HOST_SUFFIXES)
        or port not in {None, 443}
    ):
        raise ConfigurationError(
            "FOUNDRY_ENDPOINT must be a public Azure resource root URL."
        )
    if name == "GATEWAY_BASE_URL" and parsed.path not in {"", "/"}:
        raise ConfigurationError("GATEWAY_BASE_URL must not contain a path.")
    if name == "MCP_SERVER_URL" and parsed.path.rstrip("/") != "/mcp":
        raise ConfigurationError("MCP_SERVER_URL must end in /mcp.")

    normalized_path = parsed.path.rstrip("/")
    return urlunsplit(
        (parsed.scheme.lower(), parsed.netloc, normalized_path, "", "")
    )


def _bounded_seconds(
    environment: Mapping[str, str],
    name: str,
    default: float,
    *,
    minimum: float = 0.0,
    maximum: float = 300.0,
    include_minimum: bool = False,
) -> float:
    raw = environment.get(name, str(default)).strip()
    try:
        value = float(raw)
    except ValueError as exc:
        raise ConfigurationError(f"{name} must be a number of seconds.") from exc
    below_minimum = value < minimum if include_minimum else value <= minimum
    if not math.isfinite(value) or below_minimum or value > maximum:
        minimum_text = "at least" if include_minimum else "greater than"
        raise ConfigurationError(
            f"{name} must be {minimum_text} {minimum:g} and at most {maximum:g}."
        )
    return value


def _port(environment: Mapping[str, str]) -> int:
    raw = environment.get("FLASK_PORT", "5090").strip()
    try:
        value = int(raw)
    except ValueError as exc:
        raise ConfigurationError("FLASK_PORT must be an integer.") from exc
    if not 1 <= value <= 65_535:
        raise ConfigurationError("FLASK_PORT must be between 1 and 65535.")
    return value


@dataclass(frozen=True, slots=True)
class AppConfig:
    gateway_base_url: str
    gateway_tenant_user_id: UUID
    foundry_endpoint: str
    foundry_model: str
    foundry_api_version: str
    mcp_server_url: str
    gateway_timeout_seconds: float = 10.0
    foundry_timeout_seconds: float = 60.0
    mcp_timeout_seconds: float = 15.0
    chat_turn_timeout_seconds: float = 90.0
    flask_host: str = "127.0.0.1"
    flask_port: int = 5090

    @classmethod
    def from_env(cls, environ: Mapping[str, str] | None = None) -> "AppConfig":
        environment = MappingProxyType(dict(os.environ if environ is None else environ))

        gateway_base_url = _normalize_url(
            environment.get("GATEWAY_BASE_URL", "http://127.0.0.1:5080").strip(),
            "GATEWAY_BASE_URL",
            allow_loopback_http=True,
        )

        user_id_text = _required(environment, "GATEWAY_TENANT_USER_ID")
        try:
            user_id = UUID(user_id_text)
        except ValueError as exc:
            raise ConfigurationError(
                "GATEWAY_TENANT_USER_ID must be a non-empty UUID."
            ) from exc
        if user_id.int == 0:
            raise ConfigurationError(
                "GATEWAY_TENANT_USER_ID must be a non-empty UUID."
            )

        foundry_endpoint = _normalize_url(
            _required(environment, "FOUNDRY_ENDPOINT"),
            "FOUNDRY_ENDPOINT",
            root_only=True,
        )
        foundry_model = _required(environment, "FOUNDRY_MODEL")
        foundry_api_version = environment.get(
            "FOUNDRY_API_VERSION", "2024-12-01-preview"
        ).strip()
        if not re.fullmatch(r"20\d{2}-\d{2}-\d{2}(?:-preview)?", foundry_api_version):
            raise ConfigurationError("FOUNDRY_API_VERSION is invalid.")
        mcp_server_url = _normalize_url(
            environment.get("MCP_SERVER_URL", "http://127.0.0.1:5091/mcp").strip(),
            "MCP_SERVER_URL",
            allow_loopback_http=True,
        )

        flask_host = environment.get("FLASK_HOST", "127.0.0.1").strip()
        if not _is_loopback(flask_host):
            raise ConfigurationError("FLASK_HOST must be a loopback host or address.")

        return cls(
            gateway_base_url=gateway_base_url,
            gateway_tenant_user_id=user_id,
            foundry_endpoint=foundry_endpoint,
            foundry_model=foundry_model,
            foundry_api_version=foundry_api_version,
            mcp_server_url=mcp_server_url,
            gateway_timeout_seconds=_bounded_seconds(
                environment,
                "GATEWAY_TIMEOUT_SECONDS",
                10.0,
                maximum=20.0,
            ),
            foundry_timeout_seconds=_bounded_seconds(
                environment, "FOUNDRY_TIMEOUT_SECONDS", 60.0
            ),
            mcp_timeout_seconds=_bounded_seconds(
                environment, "MCP_TIMEOUT_SECONDS", 15.0
            ),
            chat_turn_timeout_seconds=_bounded_seconds(
                environment,
                "CHAT_TURN_TIMEOUT_SECONDS",
                90.0,
                minimum=30.0,
                maximum=90.0,
                include_minimum=True,
            ),
            flask_host=flask_host,
            flask_port=_port(environment),
        )
