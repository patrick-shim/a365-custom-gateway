import { beforeEach, describe, expect, it, vi } from "vitest";
import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { FluentProvider, webLightTheme } from "@fluentui/react-components";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { MemoryRouter, Route, Routes, useLocation } from "react-router-dom";
import { App } from "./App";
import { AppShell } from "./components/AppShell";
import { RouteErrorBoundary } from "./components/RouteErrorBoundary";
import {
  agent, agentId, blueprintObjectId, connected, credentials, features, mockServer,
  operation, operationId, registration, response, rowVersion, testKey,
} from "./test/fixtures";

vi.mock("./auth/msal", () => ({
  getApiToken: vi.fn(async () => "test-token"),
  getAccount: () => ({ idTokenClaims: { oid: "88888888-8888-4888-8888-888888888888" } }),
  apiScopes: ["api://test/access_as_user"],
  msalInstance: { loginRedirect: vi.fn(async () => undefined) },
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
  await user.type(screen.getByRole("textbox", { name: "Agent name" }), "Navigation test");
  await user.clear(screen.getByRole("textbox", { name: "External ID" }));
  await user.type(screen.getByRole("textbox", { name: "External ID" }), agent.externalAgentId);
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
    for (const label of ["Agents", "Register agent", "Connection", "Classifiers", "Policies", "Platform", "Home"]) {
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
  });

  it("never fabricates a key if registration returns none", async () => {
    server.handlers.set("POST /api/v1/agents", () => ({ ...registration, gatewayCredential: null }));
    renderApp("/register");
    const user = await selectBlueprint();
    await user.click(screen.getByRole("button", { name: "Create agent" }));
    expect(await screen.findByText(/No key was returned/)).toBeVisible();
    expect(screen.queryByRole("textbox", { name: "One-time Gateway key" })).not.toBeInTheDocument();
  });

  it("does not report a failed registration as created", async () => {
    server.handlers.set("POST /api/v1/agents", () => response({ errors: { name: ["Name is not allowed."] } }, 400));
    renderApp("/register");
    const user = await selectBlueprint();
    await user.click(screen.getByRole("button", { name: "Create agent" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Name is not allowed.");
    expect(screen.queryByText("Registration accepted")).not.toBeInTheDocument();
  });

  it("reconciles an uncertain registration by exact external ID without reposting", async () => {
    server.handlers.set("POST /api/v1/agents", () => { throw new TypeError("Lost response"); });
    renderApp("/register");
    const user = await selectBlueprint();
    await user.click(screen.getByRole("button", { name: "Create agent" }));
    await user.click(await screen.findByRole("button", { name: "Check registration" }));
    expect(await screen.findByRole("link", { name: "Open agent to create a replacement key" })).toHaveAttribute("href", `/agents/${agentId}`);
    expect(server.requests.filter(r => r.path === "/api/v1/agents" && r.method === "POST")).toHaveLength(1);
    expect(screen.getByRole("button", { name: "Create agent" })).toBeDisabled();
  });

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

  it("changes Prompt Shields without changing agent lifecycle", async () => {
    const updated = { ...agent, features: { ...features, promptShieldEnabled: true, promptShieldEffectivelyEnabled: true } };
    server.handlers.set(`PATCH /api/v1/agents/${agentId}/features`, () => {
      server.handlers.set(`GET /api/v1/agents/${agentId}`, () => updated);
      return { agentId, features: updated.features, updatedAtUtc: agent.updatedAtUtc };
    });
    renderApp(`/agents/${agentId}`);
    const user = userEvent.setup();
    await user.click(await screen.findByRole("switch", { name: "Prompt Shields" }));
    expect(await screen.findByText("On", { exact: true })).toBeVisible();
    expect(screen.getByText("Active", { exact: true })).toBeVisible();
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

  it("shows failed and null connection states without a render exception or guessed repair command", async () => {
    renderApp("/data-protection/connection");
    expect(await screen.findByText("Verification Failed")).toBeVisible();
    expect(screen.queryByText(/New-ServicePrincipal/)).not.toBeInTheDocument();
    server.handlers.set("GET /api/v1/protection/purview/connection", () => ({ connection: null }));
    await userEvent.setup().click(screen.getByRole("button", { name: "Reload status" }));
    expect(await screen.findByText("Not Connected")).toBeVisible();
  });

  it("requires explicit confirmation and never calls the invented recheck endpoint", async () => {
    server.handlers.set("POST /api/v1/protection/purview/connection-operations", () => {
      server.handlers.set("GET /api/v1/protection/purview/connection", () => ({ connection: connected }));
      return response({ operationId, status: "Submitted", correlationId: operationId }, 202);
    });
    renderApp("/data-protection/connection");
    const user = userEvent.setup();
    await waitFor(() => expect(screen.getByRole("button", { name: "Check connection" })).toBeEnabled());
    await user.click(screen.getByRole("button", { name: "Check connection" }));
    await screen.findByRole("button", { name: "Confirm check" });
    expect(server.requests.filter(r => r.method === "POST")).toHaveLength(1);
    await user.click(screen.getByRole("button", { name: "Confirm check" }));
    expect(await screen.findByText("Completed")).toBeVisible();
    expect(await screen.findByText(/Gateway access is verified/)).toBeVisible();
    expect(server.requests.some(r => r.path.endsWith("connection:recheck"))).toBe(false);
  });

  it("does not treat HTTP 202 as verified Purview access", async () => {
    server.handlers.set(`GET /api/v1/protection/operations/${operationId}`, () => ({
      ...operation, operation: { ...operation.operation, status: "Running" },
    }));
    renderApp(`/data-protection/connection?operation=${operationId}`);
    expect(await screen.findByText("Running", { exact: true })).toBeVisible();
    expect(screen.queryByText(/Gateway access is verified/)).not.toBeInTheDocument();
  });

  it("unwraps a classifier inventory and renders exactName", async () => {
    server.handlers.set("GET /api/v1/protection/purview/connection", () => ({ connection: connected }));
    renderApp("/data-protection/classifiers");
    expect(await screen.findByText("Credit Card Number")).toBeVisible();
    expect(screen.getByRole("table", { name: "Classifiers" })).toBeVisible();
  });

  it("shows stale inventory errors instead of an empty successful list", async () => {
    server.handlers.set("GET /api/v1/protection/purview/connection", () => ({ connection: connected }));
    server.handlers.set("GET /api/v1/protection/purview/sensitive-information-types", () => response({
      detail: "The tenant has no current inventory.", errorCode: "PURVIEW_INVENTORY_STALE", correlationId: operationId,
    }, 409));
    renderApp("/data-protection/classifiers");
    expect(await screen.findByRole("alert")).toHaveTextContent("The tenant has no current inventory.");
    expect(screen.queryByText("No classifiers were returned by Purview.")).not.toBeInTheDocument();
  });

  it("unwraps policies and does not confuse a readiness object with a status string", async () => {
    server.handlers.set("GET /api/v1/protection/purview/dlp-profiles", () => ({ items: [{
      id: operationId, blueprintApplicationId: agent.agent365.blueprintId, displayName: "Card policy",
      mode: "AuditOnly", policyMode: "SimulationWithoutTips", status: "SimulationReady",
      sensitiveInformationTypeName: "Credit Card Number", sensitiveInformationTypes: null,
      readiness: { isReady: false, blockers: ["RuntimeVerificationPending"] }, lastReadbackAtUtc: null, rowVersion,
    }] }));
    renderApp("/data-protection/policies");
    expect(await screen.findByText("Card policy")).toBeVisible();
    expect(screen.getByText("Simulating", { exact: true })).toBeVisible();
    expect(screen.getByText("Simulation Ready")).toBeVisible();
    expect(screen.queryByRole("button", { name: "New policy" })).not.toBeInTheDocument();
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
