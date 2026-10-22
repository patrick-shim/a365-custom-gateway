from dataclasses import FrozenInstanceError

import pytest

from weather_agent.config import (
    AppConfig,
    ConfigurationError,
    validate_external_agent_id,
    validate_gateway_agent_key,
)


SYNTHETIC_GATEWAY_KEY = "a365gw_v1_" + ("1" * 32) + "." + ("A" * 43)


def valid_environment(**overrides: str) -> dict[str, str]:
    values = {
        "GATEWAY_TENANT_USER_ID": "11111111-2222-4333-8444-555555555555",
        "FOUNDRY_ENDPOINT": "https://sample.cognitiveservices.azure.com/",
        "FOUNDRY_MODEL": "sample-chat",
    }
    values.update(overrides)
    return values


def test_app_config_uses_safe_local_defaults_and_is_immutable() -> None:
    config = AppConfig.from_env(valid_environment())

    assert config.gateway_base_url == "http://127.0.0.1:5080"
    assert config.foundry_endpoint == "https://sample.cognitiveservices.azure.com"
    assert config.foundry_api_version == "2024-12-01-preview"
    assert config.mcp_server_url == "http://127.0.0.1:5091/mcp"
    assert config.gateway_timeout_seconds == 10
    assert config.foundry_timeout_seconds == 60
    assert config.mcp_timeout_seconds == 15
    assert config.chat_turn_timeout_seconds == 90
    assert not hasattr(config, "gateway_agent_key")
    with pytest.raises(FrozenInstanceError):
        config.flask_port = 8000  # type: ignore[misc]


def test_app_config_does_not_read_a_long_lived_gateway_key() -> None:
    config = AppConfig.from_env(
        valid_environment(GATEWAY_AGENT_KEY="an-old-env-value-must-be-ignored")
    )

    assert "an-old-env-value-must-be-ignored" not in repr(config)


def test_gateway_agent_key_validator_accepts_only_the_exact_registration_format() -> None:
    assert validate_gateway_agent_key(SYNTHETIC_GATEWAY_KEY) == SYNTHETIC_GATEWAY_KEY

    for value in (None, "", "not-a-gateway-key", f" {SYNTHETIC_GATEWAY_KEY}"):
        with pytest.raises(ValueError) as error:
            validate_gateway_agent_key(value)
        assert SYNTHETIC_GATEWAY_KEY not in str(error.value)


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ("abc", "abc"),
        ("  Demo.Agent_01-Blue  ", "Demo.Agent_01-Blue"),
        ("A" + ("z" * 127), "A" + ("z" * 127)),
    ],
)
def test_external_agent_id_validator_normalizes_edges_and_preserves_case(
    value: str, expected: str
) -> None:
    assert validate_external_agent_id(value) == expected


@pytest.mark.parametrize(
    "value",
    [
        None,
        "",
        "   ",
        "ab",
        "-agent",
        "agent name",
        "agent/01",
        "a" * 129,
    ],
)
def test_external_agent_id_validator_rejects_invalid_values(value: object) -> None:
    with pytest.raises(ValueError, match="externalAgentId"):
        validate_external_agent_id(value)


@pytest.mark.parametrize(
    "url",
    [
        "http://gateway.example.test:5080",
        "ftp://127.0.0.1:5080",
        "http://127.0.0.1:5080/api",
        "http://user:password@127.0.0.1:5080",
    ],
)
def test_app_config_rejects_unsafe_gateway_urls(url: str) -> None:
    with pytest.raises(ConfigurationError, match="GATEWAY_BASE_URL"):
        AppConfig.from_env(valid_environment(GATEWAY_BASE_URL=url))


def test_app_config_allows_remote_https_gateway() -> None:
    config = AppConfig.from_env(
        valid_environment(GATEWAY_BASE_URL="https://gateway.example.test/")
    )
    assert config.gateway_base_url == "https://gateway.example.test"


@pytest.mark.parametrize(
    "endpoint",
    [
        "http://sample.cognitiveservices.azure.com/",
        "https://sample.cognitiveservices.azure.com/openai/v1",
        "https://sample.cognitiveservices.azure.com/?api-version=latest",
        "https://foundry.example/",
        "https://sample.openai.azure.com:444/",
    ],
)
def test_app_config_requires_https_foundry_resource_root(endpoint: str) -> None:
    with pytest.raises(ConfigurationError, match="FOUNDRY_ENDPOINT"):
        AppConfig.from_env(valid_environment(FOUNDRY_ENDPOINT=endpoint))


def test_app_config_accepts_supported_public_azure_foundry_hosts() -> None:
    cognitive = AppConfig.from_env(
        valid_environment(FOUNDRY_ENDPOINT="https://sample.cognitiveservices.azure.com/")
    )
    openai = AppConfig.from_env(
        valid_environment(FOUNDRY_ENDPOINT="https://sample.openai.azure.com/")
    )

    assert cognitive.foundry_endpoint.endswith(".cognitiveservices.azure.com")
    assert openai.foundry_endpoint.endswith(".openai.azure.com")


@pytest.mark.parametrize("host", ["0.0.0.0", "gateway.example", "192.0.2.10"])
def test_app_config_rejects_non_loopback_flask_hosts(host: str) -> None:
    with pytest.raises(ConfigurationError, match="FLASK_HOST"):
        AppConfig.from_env(valid_environment(FLASK_HOST=host))


@pytest.mark.parametrize(
    ("name", "value"),
    [
        ("GATEWAY_TIMEOUT_SECONDS", "20.1"),
        ("CHAT_TURN_TIMEOUT_SECONDS", "29.9"),
        ("CHAT_TURN_TIMEOUT_SECONDS", "90.1"),
    ],
)
def test_app_config_enforces_operation_timeout_bounds(name: str, value: str) -> None:
    with pytest.raises(ConfigurationError, match=name):
        AppConfig.from_env(valid_environment(**{name: value}))


def test_app_config_validates_mcp_transport_url() -> None:
    with pytest.raises(ConfigurationError, match="MCP_SERVER_URL"):
        AppConfig.from_env(valid_environment(MCP_SERVER_URL="http://weather.example/mcp"))
    with pytest.raises(ConfigurationError, match="MCP_SERVER_URL"):
        AppConfig.from_env(valid_environment(MCP_SERVER_URL="http://127.0.0.1:5091/other"))
    remote = AppConfig.from_env(
        valid_environment(MCP_SERVER_URL="https://weather.example/mcp")
    )
    assert remote.mcp_server_url == "https://weather.example/mcp"


@pytest.mark.parametrize(
    ("name", "value"),
    [
        ("GATEWAY_TENANT_USER_ID", "00000000-0000-0000-0000-000000000000"),
        ("GATEWAY_TIMEOUT_SECONDS", "0"),
        ("FOUNDRY_TIMEOUT_SECONDS", "nan"),
        ("FOUNDRY_API_VERSION", "latest"),
        ("MCP_TIMEOUT_SECONDS", "invalid"),
    ],
)
def test_app_config_rejects_invalid_required_values(name: str, value: str) -> None:
    with pytest.raises(ConfigurationError):
        AppConfig.from_env(valid_environment(**{name: value}))
