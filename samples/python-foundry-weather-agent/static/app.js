(() => {
  "use strict";

  const elements = {
    agentIdentity: document.querySelector("#agent-identity"),
    chatForm: document.querySelector("#chat-form"),
    chatTranscript: document.querySelector("#chat-transcript"),
    clearSavedCredentials: document.querySelector("#clear-saved-credentials"),
    clearChat: document.querySelector("#clear-chat"),
    credentialStorageMessage: document.querySelector("#credential-storage-message"),
    externalAgentIdError: document.querySelector("#external-agent-id-error"),
    externalAgentIdField: document.querySelector("#external-agent-id-field"),
    externalAgentIdInput: document.querySelector("#external-agent-id-input"),
    gatewayKeyAgent: document.querySelector("#gateway-key-agent"),
    gatewayKeyInput: document.querySelector("#gateway-key-input"),
    evaluationModeMessage: document.querySelector("#evaluation-mode-message"),
    evaluationSummary: document.querySelector("#evaluation-summary"),
    messageInput: document.querySelector("#message-input"),
    promptEvaluationToggle: document.querySelector("#prompt-evaluation-toggle"),
    refreshStatus: document.querySelector("#refresh-status"),
    responseEvaluationToggle: document.querySelector("#response-evaluation-toggle"),
    sendButton: document.querySelector("#send-button"),
    sendLabel: document.querySelector("#send-button .send-label"),
    systemNotice: document.querySelector("#system-notice"),
    welcomeCard: document.querySelector("#welcome-card"),
  };

  const state = {
    busy: false,
    statusAvailable: false,
    statusLoading: false,
    storageAvailable: true,
    agentIdValidationVisible: false,
    conversationAgentId: "",
    history: [],
    sessionId: createId(),
  };

  const EXTERNAL_AGENT_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$/;
  const STORAGE_KEYS = Object.freeze({
    externalAgentId: "a365-weather-agent.externalAgentId",
    gatewayAgentKey: "a365-weather-agent.gatewayAgentKey",
  });
  const ALLOWED_GATEWAY_REQUESTS = new Set([
    "GET /api/v1/agent-runtime/readiness",
    "POST /api/v1/prompts:evaluate",
    "POST /api/v1/agent-activities",
    "POST /api/v1/ai-interactions",
  ]);

  function createId() {
    if (globalThis.crypto?.randomUUID) return globalThis.crypto.randomUUID();
    const bytes = new Uint8Array(16);
    if (globalThis.crypto?.getRandomValues) {
      globalThis.crypto.getRandomValues(bytes);
    } else {
      for (let index = 0; index < bytes.length; index += 1) bytes[index] = Math.floor(Math.random() * 256);
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hex = Array.from(bytes, (value) => value.toString(16).padStart(2, "0")).join("");
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  }

  async function fetchWithTimeout(url, options, timeoutMs) {
    const controller = new AbortController();
    const timeout = window.setTimeout(() => controller.abort(), timeoutMs);
    try {
      return await fetch(url, { ...options, signal: controller.signal });
    } finally {
      window.clearTimeout(timeout);
    }
  }

  function normalizeStatus(value) {
    return String(value ?? "unknown").trim().toLowerCase().replace(/[\s_-]+/g, "");
  }

  function statusTone(value) {
    const status = normalizeStatus(value);
    if (["available", "connected", "healthy", "ready", "success", "succeeded"].includes(status)) return "ready";
    if (["blocked", "error", "failed", "offline", "unavailable", "unhealthy"].includes(status)) return "failed";
    if (["credentialrequired", "degraded", "required", "unconfirmed", "warning"].includes(status)) return "warning";
    if (["checking", "connecting", "loading", "pending", "running"].includes(status)) return "checking";
    return "neutral";
  }

  function displayStatus(value) {
    const raw = String(value ?? "Unknown").trim();
    if (!raw) return "Unknown";
    return raw.replace(/([a-z])([A-Z])/g, "$1 $2").replace(/[_-]+/g, " ").replace(/^./, (letter) => letter.toUpperCase());
  }

  function setStorageMessage(message, tone = "neutral") {
    elements.credentialStorageMessage.className = `credential-storage-message is-${tone}`;
    elements.credentialStorageMessage.textContent = message;
  }

  function markStorageUnavailable() {
    state.storageAvailable = false;
    setStorageMessage("Browser storage is unavailable. The agent ID and key will remain only until this page closes.", "warning");
  }

  function readStoredValue(key) {
    try {
      return window.localStorage.getItem(key) ?? "";
    } catch (_error) {
      markStorageUnavailable();
      return "";
    }
  }

  function writeStoredValue(key, value) {
    try {
      if (value) {
        window.localStorage.setItem(key, value);
      } else {
        window.localStorage.removeItem(key);
      }
    } catch (_error) {
      markStorageUnavailable();
    }
  }

  function clearStoredCredentials() {
    try {
      window.localStorage.removeItem(STORAGE_KEYS.externalAgentId);
      window.localStorage.removeItem(STORAGE_KEYS.gatewayAgentKey);
      if (state.storageAvailable) {
        setStorageMessage("Saved agent credentials were removed from this browser.", "success");
      }
    } catch (_error) {
      markStorageUnavailable();
    }
  }

  function selectedExternalAgentId() {
    return elements.externalAgentIdInput.value.trim();
  }

  function isValidExternalAgentId(value) {
    return EXTERNAL_AGENT_ID_PATTERN.test(value);
  }

  function renderSelectedAgent() {
    const externalAgentId = selectedExternalAgentId();
    const label = externalAgentId || "Not selected";
    elements.agentIdentity.textContent = label;
    elements.gatewayKeyAgent.textContent = externalAgentId || "selected agent";
  }

  function updateAgentIdValidation(showError = state.agentIdValidationVisible) {
    const externalAgentId = selectedExternalAgentId();
    const valid = isValidExternalAgentId(externalAgentId);
    state.agentIdValidationVisible = Boolean(showError && !valid);
    elements.externalAgentIdInput.setAttribute("aria-invalid", String(state.agentIdValidationVisible));
    elements.externalAgentIdField.classList.toggle("is-invalid", state.agentIdValidationVisible);
    elements.externalAgentIdError.hidden = !state.agentIdValidationVisible;
    renderSelectedAgent();
    return valid;
  }

  function restoreSavedCredentials() {
    elements.externalAgentIdInput.value = readStoredValue(STORAGE_KEYS.externalAgentId);
    elements.gatewayKeyInput.value = readStoredValue(STORAGE_KEYS.gatewayAgentKey);
    updateAgentIdValidation(false);
    if (state.storageAvailable && (elements.externalAgentIdInput.value || elements.gatewayKeyInput.value)) {
      setStorageMessage("Saved agent credentials were restored from this browser. Do not use a shared browser.", "success");
    }
  }

  function pickServices(payload) {
    const source = payload?.services ?? payload?.dependencies ?? payload ?? {};
    return {
      gateway: source.gateway ?? payload?.gateway,
      foundry: source.foundry ?? payload?.foundry,
      mcp: source.mcp ?? source.weather ?? payload?.mcp,
    };
  }

  function serviceValue(value) {
    if (typeof value === "string") return { status: value, detail: "" };
    if (typeof value === "boolean") return { status: value ? "Ready" : "Unavailable", detail: "" };
    return {
      status: value?.status ?? value?.state ?? (value?.ready === true ? "Ready" : value?.ready === false ? "Unavailable" : "Unknown"),
      detail: value?.detail ?? value?.message ?? "",
    };
  }

  function setService(service, value) {
    const row = document.querySelector(`[data-service="${service}"]`);
    if (!row) return;
    const current = serviceValue(value);
    const chip = row.querySelector(".status-chip");
    const chipText = chip.querySelector("span:last-child");
    const detail = row.querySelector("small");
    const tone = statusTone(current.status);

    chip.className = `status-chip is-${tone}`;
    chipText.textContent = displayStatus(current.status);
    if (current.detail) detail.textContent = current.detail;
  }

  function setNotice(message, tone = "neutral") {
    elements.systemNotice.hidden = !message;
    elements.systemNotice.className = `system-notice is-${tone}`;
    elements.systemNotice.textContent = message || "";
  }

  function updateControls() {
    const hasExternalAgentId = isValidExternalAgentId(selectedExternalAgentId());
    const hasGatewayKey = elements.gatewayKeyInput.value.trim().length > 0;
    const hasMessage = elements.messageInput.value.trim().length > 0;
    elements.sendButton.disabled = state.busy || state.statusLoading || !state.statusAvailable || !hasExternalAgentId || !hasGatewayKey || !hasMessage;
    elements.externalAgentIdInput.disabled = state.busy;
    elements.gatewayKeyInput.disabled = state.busy;
    elements.messageInput.disabled = state.busy;
    elements.promptEvaluationToggle.disabled = state.busy;
    elements.responseEvaluationToggle.disabled = state.busy || !elements.promptEvaluationToggle.checked;
    elements.clearChat.disabled = state.busy;
    elements.clearSavedCredentials.disabled = state.busy;
    elements.refreshStatus.disabled = state.busy || state.statusLoading;
    elements.chatForm.setAttribute("aria-busy", String(state.busy));
    elements.sendLabel.textContent = state.busy ? "Working…" : "Send";
  }

  function selectedEvaluationMode() {
    return {
      promptEvaluationEnabled: elements.promptEvaluationToggle.checked,
      responseEvaluationEnabled: elements.responseEvaluationToggle.checked,
    };
  }

  function updateEvaluationMode() {
    if (!elements.promptEvaluationToggle.checked) {
      elements.responseEvaluationToggle.checked = false;
    }

    const { promptEvaluationEnabled, responseEvaluationEnabled } = selectedEvaluationMode();
    const responseOption = elements.responseEvaluationToggle.closest(".evaluation-option");
    responseOption?.classList.toggle("is-dependent-disabled", !promptEvaluationEnabled);

    if (promptEvaluationEnabled && responseEvaluationEnabled) {
      elements.evaluationModeMessage.className = "evaluation-mode-message is-protected";
      elements.evaluationModeMessage.textContent = "Full evaluation is on. The response appears only after Gateway acceptance.";
      elements.evaluationSummary.textContent = "Prompt and response evaluation are on.";
    } else if (promptEvaluationEnabled) {
      elements.evaluationModeMessage.className = "evaluation-mode-message is-unevaluated";
      elements.evaluationModeMessage.textContent = "Prompt evaluation is on. The response will be shown without response evaluation or completed-interaction intake.";
      elements.evaluationSummary.textContent = "Response evaluation is off · output will be marked unevaluated.";
    } else {
      elements.evaluationModeMessage.className = "evaluation-mode-message is-unevaluated";
      elements.evaluationModeMessage.textContent = "Prompt and response evaluation are off. This is an unevaluated comparison preview; do not enter sensitive data.";
      elements.evaluationSummary.textContent = "Evaluation is off · input and output will be marked unevaluated.";
    }

    updateControls();
  }

  async function refreshStatus() {
    if (state.busy || state.statusLoading) return;
    state.statusLoading = true;
    state.statusAvailable = false;
    elements.refreshStatus.classList.add("is-loading");
    elements.refreshStatus.setAttribute("aria-busy", "true");
    ["gateway", "foundry", "mcp"].forEach((service) => setService(service, { status: "Checking" }));
    updateControls();

    try {
      const response = await fetchWithTimeout("/api/status", {
        headers: { "Accept": "application/json" },
        cache: "no-store",
      }, 10000);
      const payload = await parseJsonResponse(response);
      if (!response.ok) throw new Error(payload?.message || "Status is unavailable.");

      const services = pickServices(payload);
      setService("gateway", services.gateway);
      setService("foundry", services.foundry);
      setService("mcp", services.mcp);
      state.statusAvailable = true;
      setNotice("");
    } catch (_error) {
      state.statusAvailable = false;
      ["gateway", "foundry", "mcp"].forEach((service) => setService(service, { status: "Unavailable" }));
      setNotice("Could not read the sample server status. Check that the Flask app is running, then refresh.", "failed");
    } finally {
      state.statusLoading = false;
      elements.refreshStatus.classList.remove("is-loading");
      elements.refreshStatus.setAttribute("aria-busy", "false");
      updateControls();
    }
  }

  async function parseJsonResponse(response) {
    const contentType = response.headers.get("content-type") || "";
    if (!contentType.toLowerCase().includes("application/json")) return null;
    try {
      return await response.json();
    } catch (_error) {
      return null;
    }
  }

  function createTextElement(tag, className, text) {
    const element = document.createElement(tag);
    if (className) element.className = className;
    element.textContent = text;
    return element;
  }

  function appendUserMessage(message) {
    elements.chatTranscript.querySelectorAll(".welcome-card").forEach((card) => card.remove());
    const article = document.createElement("article");
    article.className = "message message-user";
    article.setAttribute("aria-label", "You");
    article.append(createTextElement("p", "message-role", "You"));
    article.append(createTextElement("p", "message-content", message));
    elements.chatTranscript.append(article);
    scrollToLatest();
  }

  function createTurnCard(externalAgentId, promptEvaluationEnabled, responseEvaluationEnabled) {
    const article = document.createElement("article");
    article.className = "turn-card is-running";
    article.setAttribute("aria-busy", "true");
    article.setAttribute("aria-label", "Agent request in progress");

    const header = document.createElement("div");
    header.className = "turn-header";
    header.append(createTextElement("p", "message-role", `Foundry Weather Agent · ${externalAgentId}`));
    const outcome = createTextElement("span", "outcome-chip is-running", "In progress");
    header.append(outcome);
    article.append(header);

    const timeline = document.createElement("ol");
    timeline.className = "stage-timeline";
    timeline.setAttribute("aria-label", "Request stages");
    let label = "Sending fully evaluated request";
    let detail = "Prompt and response evaluation are enabled.";
    if (promptEvaluationEnabled && !responseEvaluationEnabled) {
      label = "Sending input-evaluated preview";
      detail = "Prompt evaluation is enabled; response evaluation is skipped.";
    } else if (!promptEvaluationEnabled) {
      label = "Sending unevaluated preview";
      detail = "Prompt and response evaluation are skipped for this request.";
    }
    const initial = createStage({ id: "request", label, status: "running", detail });
    timeline.append(initial);
    article.append(timeline);

    elements.chatTranscript.append(article);
    scrollToLatest();
    return article;
  }

  function stageTone(status) {
    const value = normalizeStatus(status);
    if (["accepted", "allowed", "complete", "completed", "success", "succeeded"].includes(value)) return "success";
    if (value === "blocked") return "blocked";
    if (["failed", "error", "unavailable"].includes(value)) return "failed";
    if (["unconfirmed", "warning"].includes(value)) return "warning";
    if (["skipped", "unevaluated"].includes(value)) return "skipped";
    if (["pending", "running", "inprogress", "processing"].includes(value)) return "running";
    return "neutral";
  }

  function normalizeGatewayRequest(stage) {
    const request = stage?.gatewayRequest;
    if (!request || typeof request !== "object" || Array.isArray(request)) return null;
    if (typeof request.method !== "string" || typeof request.route !== "string") return null;
    const key = `${request.method} ${request.route}`;
    if (!ALLOWED_GATEWAY_REQUESTS.has(key)) return null;
    return { method: request.method, route: request.route };
  }

  function createGatewayRequestTrace(gatewayRequest) {
    const trace = document.createElement("div");
    trace.className = "stage-endpoint";
    trace.setAttribute("role", "group");
    trace.setAttribute(
      "aria-label",
      `Gateway API call: ${gatewayRequest.method} ${gatewayRequest.route}`,
    );

    const label = createTextElement("span", "stage-endpoint-label", "Gateway API");
    const method = createTextElement("span", "stage-method", gatewayRequest.method);
    const route = createTextElement("code", "stage-route", gatewayRequest.route);
    label.setAttribute("aria-hidden", "true");
    method.setAttribute("aria-hidden", "true");
    route.setAttribute("aria-hidden", "true");
    trace.append(label, method, route);
    return trace;
  }

  function createStage(stage) {
    const item = document.createElement("li");
    const tone = stageTone(stage?.status);
    item.className = `stage-item is-${tone}`;
    item.dataset.stageId = String(stage?.id ?? "stage");

    const marker = document.createElement("span");
    marker.className = "stage-marker";
    marker.setAttribute("aria-hidden", "true");
    item.append(marker);

    const body = document.createElement("div");
    body.className = "stage-body";
    const labelRow = document.createElement("div");
    labelRow.className = "stage-label-row";
    labelRow.append(createTextElement("strong", "stage-label", String(stage?.label ?? "Stage")));
    labelRow.append(createTextElement("span", `stage-status is-${tone}`, displayStatus(stage?.status ?? "Unknown")));
    body.append(labelRow);
    const gatewayRequest = normalizeGatewayRequest(stage);
    if (gatewayRequest) body.append(createGatewayRequestTrace(gatewayRequest));
    if (stage?.detail) body.append(createTextElement("p", "stage-detail", String(stage.detail)));
    if (stage?.correlationId) body.append(createTextElement("p", "stage-correlation", `Reference: ${String(stage.correlationId)}`));
    if (stage?.reconciliationReference) {
      body.append(createTextElement("p", "stage-correlation", `Reconciliation reference: ${String(stage.reconciliationReference)}`));
    }
    item.append(body);
    return item;
  }

  function finalizeTurn(card, payload) {
    const outcome = ["allowed", "blocked", "failed", "unconfirmed", "unevaluated"].includes(payload?.outcome) ? payload.outcome : "failed";
    const message = typeof payload?.message === "string" && payload.message.trim()
      ? payload.message.trim()
      : outcome === "allowed"
        ? "The Gateway accepted this interaction."
        : outcome === "unevaluated"
          ? "The model response is available, but at least one evaluation phase was skipped."
          : "The request did not complete.";

    card.className = `turn-card is-${outcome}`;
    card.setAttribute("aria-busy", "false");
    card.setAttribute("aria-label", `Agent request ${outcome}`);
    const chip = card.querySelector(".outcome-chip");
    chip.className = `outcome-chip is-${outcome}`;
    chip.textContent = displayStatus(outcome);

    const timeline = card.querySelector(".stage-timeline");
    timeline.replaceChildren();
    const stages = Array.isArray(payload?.stages) ? payload.stages : [];
    if (stages.length) {
      stages.forEach((stage) => timeline.append(createStage(stage)));
    } else {
      timeline.append(createStage({ id: "result", label: "Request result", status: outcome, detail: message }));
    }

    const response = document.createElement("div");
    response.className = "turn-response";
    response.append(createTextElement("p", "turn-summary", message));
    if (["allowed", "unevaluated"].includes(outcome) && typeof payload?.answer === "string" && payload.answer.trim()) {
      response.append(createTextElement("p", "message-content agent-answer", payload.answer.trim()));
    }
    card.append(response);
    scrollToLatest();
  }

  function finalizeClientFailure(card) {
    finalizeTurn(card, {
      outcome: "failed",
      message: "The sample server could not complete this request. Check its status and try a new message.",
      stages: [{ id: "request", label: "Agent request", status: "failed", detail: "No confirmed result was returned." }],
    });
  }

  function isValidChatResponse(payload) {
    return payload && ["allowed", "blocked", "failed", "unconfirmed", "unevaluated"].includes(payload.outcome)
      && typeof payload.message === "string" && Array.isArray(payload.stages);
  }

  function bindConversationToAgent(externalAgentId) {
    const previousAgentId = state.conversationAgentId;
    if (previousAgentId && previousAgentId !== externalAgentId) {
      state.history = [];
      state.sessionId = createId();
      elements.chatTranscript.replaceChildren();
      const notice = document.createElement("article");
      notice.className = "conversation-boundary";
      notice.setAttribute("role", "status");
      notice.append(createTextElement("strong", "", `New conversation for ${externalAgentId}`));
      notice.append(createTextElement("p", "", `The selected agent changed from ${previousAgentId}. Previous messages were removed before this request.`));
      elements.chatTranscript.append(notice);
    }
    state.conversationAgentId = externalAgentId;
  }

  async function sendMessage(message, externalAgentId, gatewayAgentKey, promptEvaluationEnabled, responseEvaluationEnabled) {
    if (state.busy || !state.statusAvailable || !message || !gatewayAgentKey || !isValidExternalAgentId(externalAgentId)) return;
    state.busy = true;
    setNotice("");
    writeStoredValue(STORAGE_KEYS.externalAgentId, externalAgentId);
    writeStoredValue(STORAGE_KEYS.gatewayAgentKey, gatewayAgentKey);
    bindConversationToAgent(externalAgentId);
    const priorHistory = state.history.slice(-20).map(({ role, content }) => ({ role, content }));
    appendUserMessage(message);
    const turnCard = createTurnCard(externalAgentId, promptEvaluationEnabled, responseEvaluationEnabled);
    elements.messageInput.value = "";
    autoSizeInput();
    updateControls();

    try {
      const response = await fetchWithTimeout("/api/chat", {
        method: "POST",
        headers: { "Accept": "application/json", "Content-Type": "application/json" },
        body: JSON.stringify({
          externalAgentId,
          gatewayAgentKey,
          message,
          history: priorHistory,
          sessionId: state.sessionId,
          promptEvaluationEnabled,
          responseEvaluationEnabled,
        }),
      }, 120000);
      const payload = await parseJsonResponse(response);
      if (!isValidChatResponse(payload)) throw new Error("Invalid response contract");

      let effectivePayload = payload;
      if (!response.ok && ["allowed", "unevaluated"].includes(payload.outcome)) {
        const { answer: _withheldAnswer, ...safePayload } = payload;
        effectivePayload = {
          ...safePayload,
          outcome: "unconfirmed",
          message: "The server returned a contradictory result. No model response was released.",
          stages: [
            ...payload.stages,
            {
              id: "transport-status",
              label: "HTTP response status",
              status: "unconfirmed",
              detail: "The HTTP status did not confirm the successful result.",
            },
          ],
        };
        setNotice("The server returned an inconsistent status. Treat this turn as unconfirmed.", "warning");
      }

      if (typeof effectivePayload.sessionId === "string" && effectivePayload.sessionId) {
        state.sessionId = effectivePayload.sessionId;
      }
      if (["allowed", "unevaluated"].includes(effectivePayload.outcome) && typeof effectivePayload.answer === "string" && effectivePayload.answer.trim()) {
        state.history.push({ role: "user", content: message });
        state.history.push({ role: "assistant", content: effectivePayload.answer.trim() });
      }
      state.history = state.history.slice(-20);
      finalizeTurn(turnCard, effectivePayload);
    } catch (_error) {
      finalizeClientFailure(turnCard);
    } finally {
      state.busy = false;
      updateControls();
      elements.messageInput.focus();
    }
  }

  function scrollToLatest() {
    requestAnimationFrame(() => {
      const reducedMotion = window.matchMedia?.("(prefers-reduced-motion: reduce)")?.matches;
      elements.chatTranscript.scrollTo({ top: elements.chatTranscript.scrollHeight, behavior: reducedMotion ? "auto" : "smooth" });
    });
  }

  function autoSizeInput() {
    elements.messageInput.style.height = "auto";
    elements.messageInput.style.height = `${Math.min(elements.messageInput.scrollHeight, 168)}px`;
    updateControls();
  }

  function resetConversation(focusAgentId = false) {
    if (state.busy) return;
    elements.promptEvaluationToggle.checked = true;
    elements.responseEvaluationToggle.checked = true;
    state.history = [];
    state.sessionId = createId();
    state.conversationAgentId = "";
    elements.chatTranscript.replaceChildren();
    const card = document.createElement("article");
    card.className = "welcome-card compact-welcome";
    card.append(createTextElement("p", "eyebrow", "New conversation"));
    card.append(createTextElement("h2", "", "What weather can I help with?"));
    card.append(createTextElement("p", "", "Your previous messages were cleared from this browser's memory."));
    elements.chatTranscript.append(card);
    setNotice("");
    updateEvaluationMode();
    (focusAgentId ? elements.externalAgentIdInput : elements.messageInput).focus();
  }

  function clearSavedAgent() {
    if (state.busy) return;
    clearStoredCredentials();
    elements.externalAgentIdInput.value = "";
    elements.gatewayKeyInput.value = "";
    state.agentIdValidationVisible = false;
    updateAgentIdValidation(false);
    resetConversation(true);
    updateControls();
  }

  elements.chatForm.addEventListener("submit", (event) => {
    event.preventDefault();
    const externalAgentId = selectedExternalAgentId();
    const gatewayAgentKey = elements.gatewayKeyInput.value.trim();
    const message = elements.messageInput.value.trim();
    const { promptEvaluationEnabled, responseEvaluationEnabled } = selectedEvaluationMode();
    if (!isValidExternalAgentId(externalAgentId)) {
      updateAgentIdValidation(true);
      updateControls();
      elements.externalAgentIdInput.focus();
      return;
    }
    if (!gatewayAgentKey || !message) {
      updateControls();
      return;
    }
    void sendMessage(message, externalAgentId, gatewayAgentKey, promptEvaluationEnabled, responseEvaluationEnabled);
  });

  elements.externalAgentIdInput.addEventListener("input", () => {
    const externalAgentId = selectedExternalAgentId();
    writeStoredValue(STORAGE_KEYS.externalAgentId, externalAgentId);
    updateAgentIdValidation(state.agentIdValidationVisible);
    updateControls();
  });
  elements.externalAgentIdInput.addEventListener("blur", () => {
    if (selectedExternalAgentId()) updateAgentIdValidation(true);
  });
  elements.gatewayKeyInput.addEventListener("input", () => {
    writeStoredValue(STORAGE_KEYS.gatewayAgentKey, elements.gatewayKeyInput.value.trim());
    updateControls();
  });
  elements.promptEvaluationToggle.addEventListener("change", updateEvaluationMode);
  elements.responseEvaluationToggle.addEventListener("change", updateEvaluationMode);
  elements.messageInput.addEventListener("input", autoSizeInput);
  elements.messageInput.addEventListener("keydown", (event) => {
    if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
      event.preventDefault();
      if (!elements.sendButton.disabled) elements.chatForm.requestSubmit();
    }
  });

  elements.refreshStatus.addEventListener("click", () => void refreshStatus());
  elements.clearChat.addEventListener("click", () => resetConversation(false));
  elements.clearSavedCredentials.addEventListener("click", clearSavedAgent);
  document.querySelectorAll(".suggestion").forEach((button) => {
    button.addEventListener("click", () => {
      elements.messageInput.value = button.textContent.trim();
      autoSizeInput();
      elements.messageInput.focus();
    });
  });

  restoreSavedCredentials();
  updateEvaluationMode();
  void refreshStatus();
})();
