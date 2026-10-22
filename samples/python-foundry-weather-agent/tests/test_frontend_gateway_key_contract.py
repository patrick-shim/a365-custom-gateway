from __future__ import annotations

import re
from html.parser import HTMLParser
from pathlib import Path


SAMPLE_ROOT = Path(__file__).resolve().parents[1]


class _SampleControlsParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.inputs: dict[str, dict[str, str | None]] = {}
        self.button_ids: set[str] = set()
        self.labels_for: set[str] = set()
        self.theme_color: str | None = None

    def handle_starttag(
        self,
        tag: str,
        attrs: list[tuple[str, str | None]],
    ) -> None:
        attributes = dict(attrs)
        element_id = attributes.get("id")
        if tag == "input" and element_id:
            self.inputs[element_id] = attributes
        if tag == "button" and element_id:
            self.button_ids.add(element_id)
        if tag == "label" and attributes.get("for"):
            self.labels_for.add(str(attributes["for"]))
        if tag == "meta" and attributes.get("name") == "theme-color":
            self.theme_color = attributes.get("content")


def _parse_controls() -> _SampleControlsParser:
    parser = _SampleControlsParser()
    parser.feed((SAMPLE_ROOT / "templates" / "index.html").read_text(encoding="utf-8"))
    return parser


def _relative_luminance(hex_color: str) -> float:
    channels = [int(hex_color[index : index + 2], 16) / 255 for index in (1, 3, 5)]
    linear = [
        channel / 12.92
        if channel <= 0.04045
        else ((channel + 0.055) / 1.055) ** 2.4
        for channel in channels
    ]
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]


def _contrast_ratio(first: str, second: str) -> float:
    light, dark = sorted(
        (_relative_luminance(first), _relative_luminance(second)), reverse=True
    )
    return (light + 0.05) / (dark + 0.05)


def test_agent_and_key_fields_are_explicit_accessible_and_never_html_prefilled() -> None:
    parser = _parse_controls()
    agent = parser.inputs["external-agent-id-input"]
    key = parser.inputs["gateway-key-input"]

    assert agent["type"] == "text"
    assert agent["minlength"] == "3"
    assert agent["maxlength"] == "128"
    assert agent["pattern"] == "[A-Za-z0-9][A-Za-z0-9._-]{2,127}"
    assert agent["autocomplete"] == "off"
    assert agent["autocapitalize"] == "none"
    assert agent["spellcheck"] == "false"
    assert agent["aria-invalid"] == "false"
    assert "external-agent-id-help" in str(agent["aria-describedby"])
    assert "external-agent-id-error" in str(agent["aria-describedby"])
    assert "required" in agent
    assert "value" not in agent
    assert "name" not in agent

    assert key["type"] == "password"
    assert key["autocomplete"] in {"new-password", "off"}
    assert key["autocapitalize"] == "none"
    assert key["spellcheck"] == "false"
    assert "required" in key
    assert "value" not in key
    assert "name" not in key

    assert {"external-agent-id-input", "gateway-key-input"} <= parser.labels_for
    assert "clear-saved-credentials" in parser.button_ids


def test_agent_and_key_are_restored_locally_and_only_explicit_clear_removes_them() -> None:
    script = (SAMPLE_ROOT / "static" / "app.js").read_text(encoding="utf-8")
    send_message = script[
        script.index("async function sendMessage") : script.index("function scrollToLatest")
    ]
    reset_conversation = script[
        script.index("function resetConversation") : script.index("function clearSavedAgent")
    ]
    clear_saved_agent = script[
        script.index("function clearSavedAgent") : script.index(
            'elements.chatForm.addEventListener("submit"'
        )
    ]

    assert 'externalAgentId: "a365-weather-agent.externalAgentId"' in script
    assert 'gatewayAgentKey: "a365-weather-agent.gatewayAgentKey"' in script
    assert "window.localStorage.getItem(key)" in script
    assert "window.localStorage.setItem(key, value)" in script
    assert "window.localStorage.removeItem(key)" in script
    assert "function restoreSavedCredentials()" in script
    assert script.index("restoreSavedCredentials();") < script.index("void refreshStatus();")
    assert "catch (_error)" in script
    assert "Browser storage is unavailable" in script

    assert "body: JSON.stringify({" in send_message
    assert "externalAgentId," in send_message
    assert "gatewayAgentKey," in send_message
    assert "promptEvaluationEnabled," in send_message
    assert "responseEvaluationEnabled," in send_message
    assert 'elements.gatewayKeyInput.value = ""' not in send_message
    assert 'elements.gatewayKeyInput.value = ""' not in reset_conversation
    assert 'elements.externalAgentIdInput.value = ""' not in reset_conversation
    assert 'elements.gatewayKeyInput.value = ""' in clear_saved_agent
    assert 'elements.externalAgentIdInput.value = ""' in clear_saved_agent
    assert "clearStoredCredentials();" in clear_saved_agent
    assert "pagehide" not in script

    for forbidden_sink in (
        "sessionStorage",
        "document.cookie",
        "URLSearchParams",
        "history.pushState",
        "history.replaceState",
    ):
        assert forbidden_sink not in script


def test_agent_selection_is_validated_and_switching_agents_isolates_conversations() -> None:
    script = (SAMPLE_ROOT / "static" / "app.js").read_text(encoding="utf-8")
    bind_conversation = script[
        script.index("function bindConversationToAgent") : script.index(
            "async function sendMessage"
        )
    ]
    refresh_status = script[
        script.index("async function refreshStatus") : script.index(
            "async function parseJsonResponse"
        )
    ]

    assert "EXTERNAL_AGENT_ID_PATTERN" in script
    assert "/^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$/" in script
    assert 'setAttribute("aria-invalid"' in script
    assert "externalAgentIdError.hidden" in script
    assert "elements.externalAgentIdInput.focus();" in script
    assert "state.conversationAgentId" in bind_conversation
    assert "previousAgentId !== externalAgentId" in bind_conversation
    assert "state.history = []" in bind_conversation
    assert "state.sessionId = createId()" in bind_conversation
    assert "Previous messages were removed before this request." in bind_conversation
    assert "pickAgentId" not in script
    assert "externalAgentIdInput.value" not in refresh_status
    assert "state.statusAvailable = true" in refresh_status
    assert "!state.statusAvailable" in script


def test_evaluation_controls_are_accessible_default_on_and_volatile() -> None:
    parser = _parse_controls()
    evaluation_inputs = {
        key: value
        for key, value in parser.inputs.items()
        if key in {"prompt-evaluation-toggle", "response-evaluation-toggle"}
    }

    assert set(evaluation_inputs) == {
        "prompt-evaluation-toggle",
        "response-evaluation-toggle",
    }
    for attributes in evaluation_inputs.values():
        assert attributes["type"] == "checkbox"
        assert attributes["role"] == "switch"
        assert "checked" in attributes
        assert "name" not in attributes


def test_evaluation_dependency_and_unevaluated_result_are_explicit() -> None:
    script = (SAMPLE_ROOT / "static" / "app.js").read_text(encoding="utf-8")
    reset_conversation = script[
        script.index("function resetConversation") : script.index("function clearSavedAgent")
    ]

    assert "if (!elements.promptEvaluationToggle.checked)" in script
    assert "elements.responseEvaluationToggle.checked = false" in script
    assert "state.busy || !elements.promptEvaluationToggle.checked" in script
    assert "promptEvaluationEnabled" in script
    assert "responseEvaluationEnabled" in script
    assert '"unevaluated"' in script
    assert '["skipped", "unevaluated"]' in script
    assert "elements.promptEvaluationToggle.checked = true" in reset_conversation
    assert "elements.responseEvaluationToggle.checked = true" in reset_conversation


def test_gateway_route_trace_is_exact_accessible_and_responsive() -> None:
    script = (SAMPLE_ROOT / "static" / "app.js").read_text(encoding="utf-8")
    stylesheet = (SAMPLE_ROOT / "static" / "app.css").read_text(encoding="utf-8")
    normalize_request = script[
        script.index("function normalizeGatewayRequest") : script.index(
            "function createGatewayRequestTrace"
        )
    ]
    create_trace = script[
        script.index("function createGatewayRequestTrace") : script.index(
            "function createStage"
        )
    ]

    for method_and_route in (
        "GET /api/v1/agent-runtime/readiness",
        "POST /api/v1/prompts:evaluate",
        "POST /api/v1/agent-activities",
        "POST /api/v1/ai-interactions",
    ):
        assert f'"{method_and_route}"' in script

    assert "const request = stage?.gatewayRequest" in normalize_request
    assert "ALLOWED_GATEWAY_REQUESTS.has(key)" in normalize_request
    assert ".startsWith(" not in normalize_request
    assert ".toUpperCase(" not in normalize_request
    assert ".trim(" not in normalize_request
    assert 'trace.setAttribute("role", "group")' in create_trace
    assert "Gateway API call:" in create_trace
    assert 'createTextElement("span", "stage-endpoint-label", "Gateway API")' in create_trace
    assert 'createTextElement("span", "stage-method", gatewayRequest.method)' in create_trace
    assert 'createTextElement("code", "stage-route", gatewayRequest.route)' in create_trace
    assert "trace.append(label, method, route)" in create_trace
    assert "innerHTML" not in create_trace
    assert "if (gatewayRequest) body.append(createGatewayRequestTrace(gatewayRequest));" in script

    assert ".stage-endpoint {" in stylesheet
    assert "flex-wrap: wrap;" in stylesheet
    assert "overflow-wrap: anywhere;" in stylesheet
    assert "word-break: break-word;" in stylesheet
    assert ".stage-route { flex-basis: 100%; }" in stylesheet


def test_demo_uses_accessible_burgundy_chrome_and_preserves_semantic_colors() -> None:
    parser = _parse_controls()
    stylesheet = (SAMPLE_ROOT / "static" / "app.css").read_text(encoding="utf-8")
    variables = dict(
        re.findall(r"--([a-z-]+):\s*(#[0-9a-fA-F]{6})\s*;", stylesheet)
    )

    assert parser.theme_color == "#13080e"
    assert variables["bg"] == "#13080e"
    assert variables["accent-strong"] == "#9e3154"
    assert variables["success"] == "#54d59a"
    assert variables["warning"] == "#f5c769"
    assert variables["danger"] == "#ff7f8d"
    assert _contrast_ratio(variables["text"], variables["bg"]) >= 7
    assert _contrast_ratio(variables["muted"], variables["bg"]) >= 4.5
    assert _contrast_ratio(variables["text"], variables["accent-strong"]) >= 4.5
    assert "#5790ff" not in stylesheet
    assert "#568bef" not in stylesheet
    assert "rgba(117, 167, 255" not in stylesheet
    assert "@media (max-width: 620px)" in stylesheet
    assert ".credential-grid { grid-template-columns: 1fr; }" in stylesheet
    assert "@media (prefers-reduced-motion: reduce)" in stylesheet
