import { beforeEach, describe, expect, it, vi } from "vitest";
import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { FluentProvider, webLightTheme } from "@fluentui/react-components";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { MemoryRouter, Route, Routes, useLocation } from "react-router-dom";
import { App } from "./App";
import { AppShell } from "./components/AppShell";
import { RouteErrorBoundary } from "./components/RouteErrorBoundary";
import { satisfyApiClaimsChallenge } from "./auth/msal";
import {
  agent, agentId, blueprintObjectId, credentials, features, mockServer,
  operationId, registration, response, rowVersion, testKey, systemConfig,
  approvalAgent, registrationOperation, provisioningHistory, tenantId,
} from "./test/fixtures";

vi.mock("./auth/msal", () => ({
  getApiToken: vi.fn(async () => "test-token"),
  getAccount: () => ({ idTokenClaims: { oid: "88888888-8888-4888-8888-888888888888" } }),
  apiScopes: ["api://test/access_as_user"],
  msalInstance: { loginRedirect: vi.fn(async () => undefined) },
  satisfyApiClaimsChallenge: vi.fn(async () => undefined),
}));
vi.mock("./runtime-config", () => ({ config: { tenantId: "11111111-1111-4111-8111-111111111111" } }));

let server: ReturnType<typeof mockServer>;
beforeEach(() => { server = mockServer(); });

function renderApp(path = "/") {
  const client = new QueryClient({ defaultOptions: {
    queries: { retry: false, gcTime: 0, refetchOnWindowFocus: false }, mutations: { retry: false, gcTime: 0 },
  } });
  render(
    <FluentProvider theme={webLightTheme}>
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={[path]} future={{ v7_startTransition: true, v7_relativeSplatPath: true }}><App /></MemoryRouter>
      </QueryClientProvider>
    </FluentProvider>,
  );
  return client;
}

async function selectBlueprint() {
  const user = userEvent.setup();
  await user.click(screen.getByRole("textbox", { name: "Agent name" }));
  await user.paste("Navigation test");
  await user.clear(screen.getByRole("textbox", { name: "External ID" }));
  await user.paste(agent.externalAgentId);
  await waitFor(() => expect(screen.getByRole("button", { name: "Next" })).toBeEnabled());
  await user.click(screen.getByRole("button", { name: "Next" }));
  await user.click(await screen.findByRole("combobox", { name: "Blueprint" }));
  expect(screen.queryByRole("option", { name: "Incompatible blueprint" })).not.toBeInTheDocument();
  await user.click(screen.getByRole("option", { name: "Support blueprint" }));
  return user;
}

describe("Console routes with actual API envelopes", () => {
  it("navigates through every menu page without losing the shell", async () => {
    renderApp();
    const user = userEvent.setup();
    const nav = screen.getByRole("navigation", { name: "Primary" });
    for (const label of ["Agents", "Register agent", "Purview connection", "Policies", "Gateway settings", "Home"]) {
      await user.click(within(nav).getByRole("link", { name: label }));
      expect(await screen.findByRole("heading", { name: label })).toBeVisible();
      expect(screen.getByRole("navigation", { name: "Primary" })).toBeVisible();
    }
    expect(screen.queryByText(/All clear/)).not.toBeInTheDocument();
  });

  it("advances Name to Blueprint using the real items envelope", async () => {
    renderApp("/register");
    await selectBlueprint();
    expect(screen.getByRole("button", { name: "Create agent" })).toBeEnabled();
    expect(server.requests.some(r => r.method === "POST")).toBe(false);
  });

  it("shows the server's preview reason without an environment selector", async () => {
    renderApp("/register");
    expect(await screen.findByText("Registration environment: Development")).toBeVisible();
    expect(screen.getByText(systemConfig.registrationDefaults.reason)).toBeVisible();
    expect(screen.queryByRole("combobox", { name: "Environment" })).not.toBeInTheDocument();
  });

  it("uses Production when the server advertises the standard default", async () => {
    server.handlers.set("GET /api/v1/system/config", () => ({
      ...systemConfig, registrationDefaults: { environment: "Production", reason: null },
    }));
    renderApp("/register");
    const user = await selectBlueprint();
    await user.click(screen.getByRole("button", { name: "Create agent" }));
    await screen.findByText("Registration accepted");
    expect(server.requests.find(r => r.path === "/api/v1/agents" && r.method === "POST")?.body)
      .toHaveProperty("environment", "Production");
  });

  it("fails visibly and prevents registration when defaults are missing", async () => {
    server.handlers.set("GET /api/v1/system/config", () => ({ ...systemConfig, registrationDefaults: undefined }));
    renderApp("/register");
    expect(await screen.findByRole("alert")).toHaveTextContent("Registration defaults are unavailable");
    expect(screen.getByRole("button", { name: "Next" })).toBeDisabled();
    expect(server.requests.some(r => r.method === "POST")).toBe(false);
  });

  it("prevents a doomed job when the provisioning gate is closed", async () => {
    server.handlers.set("GET /api/v1/system/config", () => ({ ...systemConfig, provisioningExecutionEnabled: false }));
    renderApp("/register");
    expect(await screen.findByText(/Registration is closed on this Gateway/)).toBeVisible();
    expect(screen.getByRole("button", { name: "Next" })).toBeDisabled();
  });

  it("performs real registration and shows the returned key once outside query caches", async () => {
    const client = renderApp("/register");
    const user = await selectBlueprint();
    await user.click(screen.getByRole("button", { name: "Create agent" }));
    expect(await screen.findByText("Registration accepted")).toBeVisible();
    expect(screen.getByRole("textbox", { name: "One-time Gateway key" })).toHaveValue(testKey);
    const posted = server.requests.find(r => r.path === "/api/v1/agents" && r.method === "POST");
    expect(posted?.body).toMatchObject({
      externalAgentId: agent.externalAgentId, environment: "Development", ownerObjectId: agent.ownerObjectId,
      blueprint: { mode: "UseExisting", blueprintObjectId }, features: { purviewEnabled: false },
    });
    expect(JSON.stringify(client.getQueryCache().getAll().map(q => q.state.data))).not.toContain(testKey);
    expect(client.getMutationCache().getAll()).toHaveLength(0);
    expect(screen.getByRole("button", { name: "Open agent" })).toBeDisabled();
    await user.click(screen.getByRole("checkbox", { name: "I saved the key" }));
    await user.click(screen.getByRole("button", { name: "Open agent" }));
    expect(await screen.findByRole("heading", { name: agent.name })).toBeVisible();
    expect(screen.queryByRole("textbox", { name: "One-time Gateway key" })).not.toBeInTheDocument();
  }, 10000);

  it("uses registration-required language and a review destination in the agent list", async () => {
    server.handlers.set("GET /api/v1/agents", () => ({ items: [approvalAgent], nextCursor: null, totalCount: 1 }));
    server.handlers.set(`GET /api/v1/agents/${agentId}`, () => approvalAgent);
    renderApp("/agents");
    expect(await screen.findByText("Registration required")).toBeVisible();
    expect(screen.queryByText("Awaiting Admin Approval")).not.toBeInTheDocument();
    await userEvent.setup().click(screen.getByRole("link", { name: `Review registration for ${approvalAgent.name}` }));
    expect(await screen.findByRole("button", { name: "Finish Agent 365 registration" })).toBeVisible();
    expect(screen.getAllByRole("region", { name: "Agent setup" })).toHaveLength(1);
    expect(screen.getByRole("navigation", { name: "Primary" })).toBeVisible();
  });

  it("explains registration confirmation after acceptance without bypassing the one-time-key handoff", async () => {
    server.handlers.set("POST /api/v1/agents", () => ({ ...registration, status: "AwaitingAdminApproval" }));
    renderApp("/register");
    const user = await selectBlueprint();
    await user.click(screen.getByRole("button", { name: "Create agent" }));
    expect(await screen.findByText("Registration required")).toBeVisible();
    expect(screen.getByText(/Save the key, then open the agent to finish/)).toBeVisible();
    expect(screen.queryByText("Awaiting Admin Approval")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Open agent" })).toBeDisabled();
    expect(server.requests.filter(request => request.method === "POST")).toHaveLength(1);
  }, 10000);

  it("never fabricates a key if registration returns none", async () => {
    server.handlers.set("POST /api/v1/agents", () => ({ ...registration, gatewayCredential: null }));
    renderApp("/register");
    const user = await selectBlueprint();
    await user.click(screen.getByRole("button", { name: "Create agent" }));
    expect(await screen.findByText(/No key was returned/)).toBeVisible();
    expect(screen.queryByRole("textbox", { name: "One-time Gateway key" })).not.toBeInTheDocument();
  }, 10000);

  it("does not report a failed registration as created", async () => {
    server.handlers.set("POST /api/v1/agents", () => response({ errors: { name: ["Name is not allowed."] } }, 400));
    renderApp("/register");
    const user = await selectBlueprint();
    await user.click(screen.getByRole("button", { name: "Create agent" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Name is not allowed.");
    expect(screen.queryByText("Registration accepted")).not.toBeInTheDocument();
  }, 10000);

  it("reconciles an uncertain registration by exact external ID without reposting", async () => {
    server.handlers.set("POST /api/v1/agents", () => { throw new TypeError("Lost response"); });
    renderApp("/register");
    const user = await selectBlueprint();
    await user.click(screen.getByRole("button", { name: "Create agent" }));
    await user.click(await screen.findByRole("button", { name: "Check registration" }));
    expect(await screen.findByRole("link", { name: "Open agent to create a replacement key" })).toHaveAttribute("href", `/agents/${agentId}`);
    expect(server.requests.filter(r => r.path === "/api/v1/agents" && r.method === "POST")).toHaveLength(1);
    expect(screen.getByRole("button", { name: "Create agent" })).toBeDisabled();
  }, 10000);

  it("loads the next agent page instead of dropping pagination", async () => {
    server.handlers.set("GET /api/v1/agents", request => request.query.has("cursor")
      ? { items: [{ ...agent, agentId: operationId, name: "Second agent" }], nextCursor: null, totalCount: 2 }
      : { items: [agent], nextCursor: "next", totalCount: 2 });
    renderApp("/agents");
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Load more agents" }));
    expect(await screen.findByRole("link", { name: "Second agent" })).toBeVisible();
    expect(screen.queryByRole("button", { name: "Load more agents" })).not.toBeInTheDocument();
  });

  it.each(["Active", "Disabled"])("changes Prompt Shields without changing the %s lifecycle", async status => {
    server.handlers.set(`GET /api/v1/agents/${agentId}`, () => ({ ...agent, status }));
    const updated = { ...agent, status, features: { ...features, promptShieldEnabled: true, promptShieldEffectivelyEnabled: true } };
    server.handlers.set(`PATCH /api/v1/agents/${agentId}/features`, () => {
      server.handlers.set(`GET /api/v1/agents/${agentId}`, () => updated);
      return { agentId, features: updated.features, updatedAtUtc: agent.updatedAtUtc };
    });
    renderApp(`/agents/${agentId}`);
    const user = userEvent.setup();
    await user.click(await screen.findByRole("switch", { name: "Prompt Shields" }));
    expect(await screen.findByText("On", { exact: true })).toBeVisible();
    expect(screen.getByText(status, { exact: true })).toBeVisible();
    const change = server.requests.find(r => r.method === "PATCH");
    expect(change?.path).toBe(`/api/v1/agents/${agentId}/features`);
    expect(change?.headers.get("If-Match")).toBe(rowVersion);
    expect(server.requests.some(r => /:(enable|disable)$/.test(r.path))).toBe(false);
  });

  it("shows a failed Prompt Shields update without silently changing the switch", async () => {
    server.handlers.set(`PATCH /api/v1/agents/${agentId}/features`, () => response({ detail: "The agent changed. Reload first." }, 412));
    renderApp(`/agents/${agentId}`);
    const user = userEvent.setup();
    await user.click(await screen.findByRole("switch", { name: "Prompt Shields" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("The agent changed. Reload first.");
    expect(screen.getByRole("switch", { name: "Prompt Shields" })).not.toBeChecked();
  });

  it("explains provisioning failure and does not offer protection changes on a failed agent", async () => {
    server.handlers.set(`GET /api/v1/agents/${agentId}`, () => ({
      ...agent, status: "Failed", provisioning: {
        currentStep: "ResolveBlueprint", percentComplete: 0,
        lastError: "DirectRegistryPreview is restricted to Development.",
      },
    }));
    renderApp(`/agents/${agentId}`);
    expect(await screen.findByRole("alert")).toHaveTextContent("DirectRegistryPreview is restricted to Development.");
    expect(screen.getByRole("alert")).toHaveTextContent("Prepare the blueprint");
    expect(screen.getByRole("switch", { name: "Prompt Shields" })).toBeDisabled();
  });

  it("automatically refreshes a Draft agent until provisioning finishes", async () => {
    let reads = 0;
    server.handlers.set(`GET /api/v1/agents/${agentId}`, () => ({
      ...agent, status: ++reads === 1 ? "Draft" : "Active",
    }));
    renderApp(`/agents/${agentId}`);
    expect(await screen.findByText("Queued for setup")).toBeVisible();
    expect(screen.getByRole("switch", { name: "Prompt Shields" })).toBeDisabled();
    await waitFor(() => expect(screen.getByRole("switch", { name: "Prompt Shields" })).toBeEnabled(), { timeout: 6500 });
    expect(reads).toBe(2);
  }, 10000);

  it("explains a missing Registry action on the default agent tab without inventing an approval inbox", async () => {
    server.handlers.set(`GET /api/v1/agents/${agentId}`, () => ({ ...agent, status: "AwaitingAdminApproval" }));
    renderApp(`/agents/${agentId}`);
    expect(await screen.findByText(/No provisioning job was reported/)).toBeVisible();
    expect(screen.getAllByText("Registration required").length).toBeGreaterThan(0);
    expect(screen.getByRole("link", { name: "Review registration access and compatibility" })).toHaveAttribute("href", "/platform#registration-access");
    expect(screen.getByRole("switch", { name: "Prompt Shields" })).toBeDisabled();
  });

  it("finds the existing Registry action after a direct reload with no detail operation ID", async () => {
    server.handlers.set(`GET /api/v1/agents/${agentId}`, () => ({
      ...approvalAgent, provisioning: { ...approvalAgent.provisioning, operationId: undefined },
    }));
    server.handlers.set(`GET /api/v1/agents/${agentId}/provisioning-history`, () => provisioningHistory);
    renderApp(`/agents/${agentId}`);
    expect(await screen.findByRole("button", { name: "Finish Agent 365 registration" })).toBeVisible();
    expect(screen.getByText("Operation found in this agent's provisioning history.")).toBeVisible();
    expect(server.requests.every(request => request.method === "GET")).toBe(true);
    expect(screen.getAllByRole("region", { name: "Agent setup" })).toHaveLength(1);
  });

  it("does not follow an operation when the detail response is for a different route agent", async () => {
    server.handlers.set(`GET /api/v1/agents/${agentId}`, () => ({ ...approvalAgent, agentId: tenantId }));
    renderApp(`/agents/${agentId}`);
    expect(await screen.findByRole("alert")).toHaveTextContent("does not match the requested agent");
    expect(screen.queryByRole("region", { name: "Agent setup" })).not.toBeInTheDocument();
    expect(server.requests.some(request => request.path.includes("/operations/") || request.path.endsWith("/provisioning-history"))).toBe(false);
    expect(server.requests.every(request => request.method === "GET")).toBe(true);
  });

  it("confirms Registry completion once and polls through worker verification to Active readback", async () => {
    server.handlers.set(`GET /api/v1/agents/${agentId}`, () => approvalAgent);
    let completed = false;
    let verificationReads = 0;
    server.handlers.set(`GET /api/v1/operations/${operationId}`, () => {
      if (!completed) return registrationOperation;
      verificationReads++;
      if (verificationReads < 2) return { ...registrationOperation, status: "Pending",
        currentStep: "VerifyAgent365Connection", percentComplete: 85,
        steps: registrationOperation.steps.map((step, index) => ({ ...step, status: index < 6 ? "Completed" : "Pending" })),
        pollingRecommended: true, requiredAction: null, agent365RegistrationCompletionAvailable: false };
      server.handlers.set(`GET /api/v1/agents/${agentId}`, () => ({ ...approvalAgent, status: "Active" }));
      return { ...registrationOperation, status: "Completed", currentStep: null, percentComplete: 100,
        steps: registrationOperation.steps.map(step => ({ ...step, status: "Completed" })),
        pollingRecommended: false, requiredAction: null, agent365RegistrationCompletionAvailable: false };
    });
    server.handlers.set(`POST /api/v1/operations/${operationId}:complete-agent365-registration`, () => {
      completed = true;
      return { operationId, agentId, agent365RegistrationId: agentId, status: "VerificationQueued" };
    });
    renderApp(`/agents/${agentId}`);
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Finish Agent 365 registration" }));
    expect(server.requests.some(r => r.method === "POST")).toBe(false);
    await user.click(screen.getByRole("button", { name: "Confirm registration" }));
    expect(await screen.findByText(/Waiting for worker verification and an Active agent readback/)).toBeVisible();
    expect(screen.getByRole("region", { name: "Agent setup" })).toHaveAttribute("data-state", "busy");
    expect(screen.getByRole("switch", { name: "Prompt Shields" })).toBeDisabled();
    await waitFor(() => expect(screen.getByRole("switch", { name: "Prompt Shields" })).toBeEnabled(), { timeout: 5000 });
    const posts = server.requests.filter(r => r.method === "POST");
    expect(posts).toHaveLength(1);
    expect(posts[0].body).toBeUndefined();
  }, 10000);

  it("does not offer completion when the authoritative Registry gate is closed", async () => {
    server.handlers.set(`GET /api/v1/agents/${agentId}`, () => approvalAgent);
    server.handlers.set(`GET /api/v1/operations/${operationId}`, () => ({
      ...registrationOperation, agent365RegistrationCompletionAvailable: false,
    }));
    renderApp(`/agents/${agentId}`);
    expect(await screen.findByText(/Registry completion gate is closed/)).toBeVisible();
    expect(screen.queryByRole("button", { name: "Finish Agent 365 registration" })).not.toBeInTheDocument();
  });

  it.each([403, 503])("surfaces Registry HTTP %s without a success or automatic replay", async status => {
    server.handlers.set(`GET /api/v1/agents/${agentId}`, () => approvalAgent);
    server.handlers.set(`POST /api/v1/operations/${operationId}:complete-agent365-registration`, () =>
      response({ detail: "Registry action is not permitted.", errorCode: "TEST_GATE", correlationId: operationId }, status));
    renderApp(`/agents/${agentId}`);
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Finish Agent 365 registration" }));
    await user.click(screen.getByRole("button", { name: "Confirm registration" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Registry action is not permitted.");
    expect(screen.queryByText(/Registry completion was accepted/)).not.toBeInTheDocument();
    expect(server.requests.filter(r => r.method === "POST")).toHaveLength(1);
  });

  it("keeps an uncertain Registry completion blocked until an explicit operation check", async () => {
    server.handlers.set(`GET /api/v1/agents/${agentId}`, () => approvalAgent);
    server.handlers.set(`POST /api/v1/operations/${operationId}:complete-agent365-registration`, () => { throw new TypeError("Lost"); });
    renderApp(`/agents/${agentId}`);
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Finish Agent 365 registration" }));
    await user.click(screen.getByRole("button", { name: "Confirm registration" }));
    expect(await screen.findByText(/no request will be repeated automatically/)).toBeVisible();
    expect(screen.getByRole("button", { name: "Finish Agent 365 registration" })).toBeDisabled();
    await waitFor(() => expect(screen.getByRole("button", { name: "Refresh setup status" })).toBeEnabled());
    await user.click(screen.getByRole("button", { name: "Refresh setup status" }));
    await waitFor(() => expect(screen.getByRole("button", { name: "Finish Agent 365 registration" })).toBeEnabled());
    expect(server.requests.filter(r => r.method === "POST")).toHaveLength(1);
  });

  it("handles a claims challenge interactively without replaying Registry completion", async () => {
    const claims = JSON.stringify({ access_token: { acrs: { essential: true, value: "test" } } });
    server.handlers.set(`GET /api/v1/agents/${agentId}`, () => approvalAgent);
    server.handlers.set(`POST /api/v1/operations/${operationId}:complete-agent365-registration`, () => new Response(
      JSON.stringify({ detail: "Additional authorization is required.", errorCode: "AGENT365_REGISTRY_DELEGATED_ACCESS_REQUIRED" }),
      { status: 401, headers: { "WWW-Authenticate": `Bearer error="insufficient_claims", claims="${btoa(claims)}"` } },
    ));
    renderApp(`/agents/${agentId}`);
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Finish Agent 365 registration" }));
    await user.click(screen.getByRole("button", { name: "Confirm registration" }));
    await user.click(await screen.findByRole("button", { name: "Continue sign-in" }));
    expect(await screen.findByText(/Authorization updated/)).toBeVisible();
    expect(satisfyApiClaimsChallenge).toHaveBeenCalledWith(claims);
    expect(server.requests.filter(r => r.method === "POST")).toHaveLength(1);
    expect(screen.queryByText(claims)).not.toBeInTheDocument();
  });

  it("keeps the consent requirement specific to the Gateway API rather than asking the SPA for Graph permissions", async () => {
    server.handlers.set(`GET /api/v1/agents/${agentId}`, () => approvalAgent);
    server.handlers.set(`POST /api/v1/operations/${operationId}:complete-agent365-registration`, () => new Response(
      JSON.stringify({ detail: "Administrator consent is required.", errorCode: "AGENT365_REGISTRY_DELEGATED_ACCESS_REQUIRED" }),
      { status: 401, headers: { "WWW-Authenticate": 'Bearer error="insufficient_scope", scope="https://graph.microsoft.com/AgentRegistration.ReadWrite.All"' } },
    ));
    renderApp(`/agents/${agentId}`);
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Finish Agent 365 registration" }));
    await user.click(screen.getByRole("button", { name: "Confirm registration" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Gateway API's delegated Graph permissions");
    expect(screen.getByRole("alert")).toHaveTextContent("Run gateway up");
    expect(screen.queryByRole("button", { name: "Sign in again" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Continue sign-in" })).not.toBeInTheDocument();
    expect(server.requests.filter(r => r.method === "POST")).toHaveLength(1);
  });

  it("stops the waiting message on a precise Registry verification failure", async () => {
    server.handlers.set(`GET /api/v1/agents/${agentId}`, () => approvalAgent);
    server.handlers.set(`POST /api/v1/operations/${operationId}:complete-agent365-registration`, () => {
      server.handlers.set(`GET /api/v1/operations/${operationId}`, () => ({
        ...registrationOperation, status: "RequiresManualIntervention", requiredAction: null,
        agent365RegistrationCompletionAvailable: false,
        error: { code: "AGENT365_EXACT_READBACK_FAILED", message: "Exact Registry readback was not verified." },
      }));
      return { operationId, agentId, agent365RegistrationId: agentId, status: "VerificationQueued" };
    });
    renderApp(`/agents/${agentId}`);
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Finish Agent 365 registration" }));
    await user.click(screen.getByRole("button", { name: "Confirm registration" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Exact Registry readback was not verified.");
    expect(screen.queryByText(/Waiting for worker verification/)).not.toBeInTheDocument();
    await user.click(screen.getByText("Operation details"));
    expect(screen.getByText("Code: AGENT365_EXACT_READBACK_FAILED")).toBeVisible();
  });

  it("reads all agent tabs and issues a replacement only after confirmation", async () => {
    const client = renderApp(`/agents/${agentId}`);
    const user = userEvent.setup();
    await user.click(await screen.findByRole("tab", { name: "Identity" }));
    expect(await screen.findByText(agent.agent365.blueprintId)).toBeVisible();
    expect(screen.getByText(agent.agent365.blueprintObjectId)).toBeVisible();
    await user.click(screen.getByRole("tab", { name: "Activity" }));
    expect(screen.getByText("Activity acceptance is not proof of downstream delivery.")).toBeVisible();
    await user.click(screen.getByRole("tab", { name: "API key" }));
    await user.click(await screen.findByRole("button", { name: "Create replacement key" }));
    expect(server.requests.some(r => r.method === "POST")).toBe(false);
    await user.click(screen.getByRole("button", { name: "Confirm" }));
    expect(await screen.findByRole("textbox", { name: "One-time Gateway key" })).toHaveValue(testKey);
    expect(server.requests.some(r => r.method === "DELETE")).toBe(false);
    expect(JSON.stringify(client.getQueryCache().getAll().map(q => q.state.data))).not.toContain(testKey);
  });

  it("uses only the signed catalog for connection diagnostics without starting old operations", async () => {
    renderApp("/settings/purview");
    expect(await screen.findByText("A current, signed policy catalog is available.")).toBeVisible();
    expect(screen.getByText(/does not prove that assignments can be written/)).toBeVisible();
    expect(server.requests.every(r => r.method === "GET")).toBe(true);
    expect(server.requests.some(r => r.path.includes("connection-operations"))).toBe(false);
  });

  it("does not retain a successful connection claim after catalog refresh fails", async () => {
    renderApp("/settings/purview");
    await screen.findByText("A current, signed policy catalog is available.");
    server.handlers.set("GET /api/v1/protection/purview/policies", () => response({ detail: "Catalog unavailable" }, 503));
    await userEvent.setup().click(screen.getByRole("button", { name: "Refresh status" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Catalog unavailable");
    expect(screen.queryByText("A current, signed policy catalog is available.")).not.toBeInTheDocument();
  });

  it("rejects stale catalog evidence in connection diagnostics", async () => {
    server.handlers.set("GET /api/v1/protection/purview/policies", () => ({ tenantId, source: "Purview", retrievedAtUtc: "2000-01-01T00:00:00Z", items: [] }));
    renderApp("/settings/purview");
    expect(await screen.findByRole("alert")).toHaveTextContent("current policy catalog");
    expect(screen.queryByText("A current, signed policy catalog is available.")).not.toBeInTheDocument();
  });

  it("redirects the retired classifier page to policies without requesting the classifier inventory", async () => {
    renderApp("/data-protection/classifiers");
    expect(await screen.findByRole("heading", { name: "Policies" })).toBeVisible();
    expect(screen.queryByRole("link", { name: "Classifiers" })).not.toBeInTheDocument();
    expect(server.requests.some(r => r.path.includes("sensitive-information-types"))).toBe(false);
  });

  it("opens an individual agent's protection tab without treating missing catalog data as no Purview policies", async () => {
    renderApp("/data-protection");
    expect(await screen.findByText("Purview returned no policies for this tenant.")).toBeVisible();
    await userEvent.setup().click(await screen.findByRole("link", { name: agent.name }));
    expect(await screen.findByRole("tab", { name: "Data protection" })).toHaveAttribute("aria-selected", "true");
    expect(screen.getByText(agent.agent365.agentId)).toBeVisible();
    expect(screen.queryByText(agent.agent365.blueprintId)).not.toBeInTheDocument();
    expect(screen.queryByText("Gateway allow and block verified")).not.toBeInTheDocument();
    expect(server.requests.every(r => r.method === "GET")).toBe(true);
  });

  it.each([true, false, null])("does not infer verified enforcement from purviewEnabled=%s", async enabled => {
    server.handlers.set(`GET /api/v1/agents/${agentId}`, () => ({ ...agent, features: { ...features, purviewEnabled: enabled } }));
    renderApp(`/agents/${agentId}?tab=data-protection`);
    expect(await screen.findByText("No policies selected in this Console. Policies scoped elsewhere in Purview may still apply.")).toBeVisible();
    expect(screen.queryByText("Gateway allow and block verified")).not.toBeInTheDocument();
    expect(screen.getByText(`Gateway content evaluation: ${enabled === true ? "Enabled · verification needed" : enabled === false ? "Not enabled" : "Not reported"}`)).toBeVisible();
    expect(screen.queryByRole("button", { name: /apply/i })).not.toBeInTheDocument();
  });

  it("reviews the exact agent and policy before confirming, and does not label a pending assignment protected", async () => {
    const policyId = "99999999-9999-4999-8999-999999999999";
    const revision = "a".repeat(64);
    server.handlers.set("GET /api/v1/protection/purview/policies", () => ({ tenantId, source: "Purview", retrievedAtUtc: new Date().toISOString(), items: [
      { id: policyId, displayName: "Existing DLP", mode: "Enable", enforcementPlanes: ["Application"], individualApplicationIds: [], revision, compatibility: { canAssign: true, reason: null } },
    ] }));
    server.handlers.set(`POST /api/v1/agents/${agentId}/purview-policies/review`, () => ({ operationId, agentId, agentIdentityId: agent.agent365.agentId, policyId, policyName: "Existing DLP", expiresAtUtc: new Date(Date.now()+60000).toISOString(), effect: "Only this individual agent is added." }));
    server.handlers.set(`POST /api/v1/agents/${agentId}/purview-policies/${operationId}/confirm`, () => {
      server.handlers.set(`GET /api/v1/agents/${agentId}/purview-policies`, () => ({ agentId, agentIdentityId: agent.agent365.agentId, bindingCurrent: false, allowObservedAtUtc: null, blockObservedAtUtc: null,
        items: [{ operationId, policyId, policyName: "Existing DLP", status: "Pending", failureCode: null, confirmedAtUtc: new Date(Date.now() - 120000).toISOString(), expiresAtUtc: new Date(Date.now() + 780000).toISOString(), assignedAtUtc: null }] }));
      return response({ operationId, status: "Pending" }, 202);
    });
    renderApp(`/agents/${agentId}?tab=data-protection`);
    const user = userEvent.setup();
    await screen.findByRole("option", { name: "Existing DLP" });
    await user.selectOptions(screen.getByLabelText("Choose an existing policy"), policyId);
    expect(server.requests.filter(x => x.method === "POST")).toHaveLength(0);
    await user.click(screen.getByRole("button", { name: "Review assignment" }));
    expect(await screen.findByText(`Agent identity: ${agent.agent365.agentId}`)).toBeVisible();
    expect(server.requests.filter(x => x.method === "POST")).toHaveLength(1);
    await user.click(screen.getByRole("button", { name: "Apply to this agent" }));
    expect(await screen.findByText("Applying assignment")).toBeVisible();
    expect(screen.getByRole("progressbar", { name: "Applying assignment" })).toBeVisible();
    expect(screen.getByText(/Elapsed: 2m/)).toBeVisible();
    expect(screen.getByText(/Last checked/)).toBeVisible();
    expect(screen.queryByText("Gateway allow and block verified")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Review assignment" })).toBeDisabled();
    expect(server.requests.find(x => x.path.endsWith("/purview-policies/review"))?.body).toEqual({ policyId, revision });
    expect(server.requests.filter(x => x.method === "POST")).toHaveLength(2);
    server.handlers.set(`GET /api/v1/agents/${agentId}/purview-policies`, () => ({ agentId, agentIdentityId: agent.agent365.agentId, bindingCurrent: true, allowObservedAtUtc: null, blockObservedAtUtc: null,
      items: [{ operationId, policyId, policyName: "Existing DLP", status: "Assigned", failureCode: null, assignedAtUtc: new Date().toISOString() }] }));
    await user.click(screen.getByRole("button", { name: "Check assignment status" }));
    expect(await screen.findByText("Assigned", { exact: true })).toBeVisible();
    expect(screen.queryByRole("progressbar", { name: "Applying assignment" })).not.toBeInTheDocument();
    expect(screen.getByText("Assigned · awaiting sync and gateway verification")).toBeVisible();
    expect(server.requests.filter(x => x.method === "POST")).toHaveLength(2);
  });

  it("stops animating an overdue assignment without inventing success or submitting again", async () => {
    server.handlers.set(`GET /api/v1/agents/${agentId}/purview-policies`, () => ({ agentId, agentIdentityId: agent.agent365.agentId, bindingCurrent: false, allowObservedAtUtc: null, blockObservedAtUtc: null,
      items: [{ operationId, policyId: operationId, policyName: "Existing DLP", status: "Pending", failureCode: null, confirmedAtUtc: "2000-01-01T00:00:00Z", expiresAtUtc: "2000-01-01T00:15:00Z", assignedAtUtc: null }] }));
    renderApp(`/agents/${agentId}?tab=data-protection`);
    expect(await screen.findByText("Assignment taking longer than expected")).toBeVisible();
    expect(screen.queryByRole("progressbar", { name: "Applying assignment" })).not.toBeInTheDocument();
    expect(screen.getByText(/The confirmation window has elapsed/)).toBeVisible();
    expect(server.requests.every(x => x.method === "GET")).toBe(true);
  });

  it("stops showing assignment activity when its status cannot be read", async () => {
    server.handlers.set(`GET /api/v1/agents/${agentId}/purview-policies`, () => ({ agentId, agentIdentityId: agent.agent365.agentId, bindingCurrent: false, allowObservedAtUtc: null, blockObservedAtUtc: null,
      items: [{ operationId, policyId: operationId, policyName: "Existing DLP", status: "Pending", failureCode: null, assignedAtUtc: null }] }));
    renderApp(`/agents/${agentId}?tab=data-protection`);
    expect(await screen.findByRole("progressbar", { name: "Applying assignment" })).toBeVisible();
    server.handlers.set(`GET /api/v1/agents/${agentId}/purview-policies`, () => { throw new TypeError("Offline"); });
    await userEvent.setup().click(screen.getByRole("button", { name: "Check assignment status" }));
    expect(await screen.findByText("Assignment status is unavailable. No protection state has been assumed.")).toBeVisible();
    expect(screen.queryByRole("progressbar", { name: "Applying assignment" })).not.toBeInTheDocument();
  });

  it("does not report assigned policy state as verified blocking without both gateway observations", async () => {
    server.handlers.set(`GET /api/v1/agents/${agentId}/purview-policies`, () => ({ agentId, agentIdentityId: agent.agent365.agentId, bindingCurrent: true,
      allowObservedAtUtc: new Date().toISOString(), blockObservedAtUtc: null,
      items: [{ operationId, policyId: operationId, policyName: "Existing DLP", status: "Assigned", failureCode: null, assignedAtUtc: new Date().toISOString() }] }));
    renderApp(`/agents/${agentId}?tab=data-protection`);
    expect(await screen.findByText("Assigned · awaiting sync and gateway verification")).toBeVisible();
    expect(screen.queryByText("Gateway allow and block verified")).not.toBeInTheDocument();
  });

  it("searches and paginates agents while preserving the server-side search", async () => {
    server.handlers.set("GET /api/v1/agents", request => ({
      items: request.query.get("cursor") ? [{ ...agent, agentId: operationId, name: "Second match" }] : [agent],
      nextCursor: request.query.get("search") && !request.query.get("cursor") ? "page-two" : null,
      totalCount: null,
    }));
    renderApp("/data-protection/policies");
    const user = userEvent.setup();
    await user.type(screen.getByRole("textbox", { name: "Search agents" }), "Test");
    await user.click(screen.getByRole("button", { name: "Search" }));
    await user.click(await screen.findByRole("button", { name: "Load more agents" }));
    expect(await screen.findByRole("link", { name: "Second match" })).toBeVisible();
    expect(server.requests.find(r => r.query.get("cursor") === "page-two")?.query.get("search")).toBe("Test");
    expect(screen.queryByRole("button", { name: "Load more agents" })).not.toBeInTheDocument();
  });

  it("shows the Purview catalog without calling the removed blueprint-profile workflow", async () => {
    server.handlers.set("GET /api/v1/protection/purview/policies", () => ({
      tenantId, source: "Purview", retrievedAtUtc: new Date().toISOString(), items: [{
        id: operationId, displayName: "Existing tenant DLP", mode: "Enable", enforcementPlanes: ["Application"],
        individualApplicationIds: [], revision: "a".repeat(64), compatibility: { canAssign: true, reason: null },
      }],
    }));
    renderApp("/data-protection/policies");
    expect(await screen.findByText("Existing tenant DLP")).toBeVisible();
    expect(server.requests.some(r => r.path.includes("dlp-profiles"))).toBe(false);
    expect(screen.getByText("Compatible", { exact: true })).toBeVisible();
    expect(screen.queryByRole("button", { name: /apply/i })).not.toBeInTheDocument();
  });

  it.each(["/", "/agents", `/agents/${agentId}`, "/data-protection/connection", "/data-protection/classifiers", "/data-protection/policies", "/platform"])(
    "keeps navigation and a visible error at %s when the API fails", async path => {
      for (const key of server.handlers.keys()) {
        if (key.startsWith("GET ")) server.handlers.set(key, () => response({ detail: "Gateway temporarily unavailable." }, 503));
      }
      renderApp(path);
      expect((await screen.findAllByRole("alert"))[0]).toHaveTextContent("Gateway temporarily unavailable.");
      expect(screen.getByRole("navigation", { name: "Primary" })).toBeVisible();
      expect(screen.queryByText(/All clear/)).not.toBeInTheDocument();
    },
  );

  it.each([401, 403])("renders a recoverable HTTP %s on the agents page", async status => {
    server.handlers.set("GET /api/v1/agents", () => response({}, status));
    renderApp("/agents");
    expect(await screen.findByRole("alert")).toBeVisible();
    if (status === 401) expect(screen.getByRole("button", { name: "Sign in again" })).toBeVisible();
    else expect(screen.getByRole("alert")).toHaveTextContent("does not have permission");
  });

  it("contains a render exception while preserving navigation to another route", async () => {
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => undefined);
    function Broken(): never { throw new Error("Test render failure"); }
    function TestRoutes() {
      const location = useLocation();
      return <AppShell><RouteErrorBoundary key={location.pathname} onReset={() => undefined}><Routes>
        <Route path="/broken" element={<Broken />} /><Route path="/" element={<h1>Recovered home</h1>} />
      </Routes></RouteErrorBoundary></AppShell>;
    }
    render(<FluentProvider theme={webLightTheme}><MemoryRouter initialEntries={["/broken"]} future={{ v7_startTransition: true, v7_relativeSplatPath: true }}><TestRoutes /></MemoryRouter></FluentProvider>);
    expect(screen.getByRole("alert")).toHaveTextContent("This page could not be displayed");
    await userEvent.setup().click(screen.getByRole("link", { name: "Home" }));
    expect(await screen.findByRole("heading", { name: "Recovered home" })).toBeVisible();
    expect(consoleError).toHaveBeenCalled();
  });

  it("reads actual platform defaults instead of assuming they are on", async () => {
    renderApp("/platform");
    expect(await screen.findByRole("switch", { name: "Prompt Shields default" })).not.toBeChecked();
    expect(screen.queryByText("Worker")).not.toBeInTheDocument();
  });

  it("revokes only the selected credential after confirmation", async () => {
    renderApp(`/agents/${agentId}`);
    const user = userEvent.setup();
    await user.click(await screen.findByRole("tab", { name: "API key" }));
    await user.click(await screen.findByRole("button", { name: "Revoke key" }));
    expect(server.requests.some(r => r.method === "DELETE")).toBe(false);
    await user.click(screen.getByRole("button", { name: "Confirm" }));
    await waitFor(() => expect(server.requests.filter(r => r.method === "DELETE")).toHaveLength(1));
    expect(server.requests.find(r => r.method === "DELETE")?.path).toBe(`/api/v1/agents/${agentId}/credentials/${credentials.items[0].keyId}`);
  });
});
