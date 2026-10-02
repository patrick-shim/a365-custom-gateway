import { beforeEach, describe, expect, it, vi } from "vitest";
import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { FluentProvider, webLightTheme } from "@fluentui/react-components";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { MemoryRouter } from "react-router-dom";
import { AgentRegistrationProgress } from "./AgentRegistrationProgress";
import type { AgentDetail } from "../../api/types";
import {
  agentId, approvalAgent, mockServer, operationId, provisioningHistory, registrationOperation, response, tenantId,
} from "../../test/fixtures";

vi.mock("../../auth/msal", () => ({
  getApiToken: vi.fn(async () => "test-token"),
  apiScopes: ["api://test/access_as_user"],
  msalInstance: { loginRedirect: vi.fn(async () => undefined) },
  satisfyApiClaimsChallenge: vi.fn(async () => undefined),
}));
vi.mock("../../runtime-config", () => ({ config: { tenantId: "11111111-1111-4111-8111-111111111111" } }));

const labels = [
  "Prepare the blueprint", "Enable the blueprint identity", "Connect the Gateway", "Create the agent identity",
  "Assign Agent 365 access", "Add to Microsoft 365 Registry", "Verify the connection",
];
let server: ReturnType<typeof mockServer>;
beforeEach(() => { server = mockServer(); });

function running(stage: number, status = "Running") {
  return {
    ...registrationOperation, status, requiredAction: null, agent365RegistrationCompletionAvailable: false, pollingRecommended: true,
    currentStep: registrationOperation.steps[stage].step, percentComplete: Math.floor(stage * 100 / 7),
    steps: registrationOperation.steps.map((step, index) => ({
      ...step, status: index < stage ? "Completed" : index === stage && status === "Running" ? "Running" : "Pending",
    })),
  };
}

function renderSetup(agent: AgentDetail = approvalAgent) {
  const client = new QueryClient({ defaultOptions: {
    queries: { retry: false, gcTime: 0, refetchOnWindowFocus: false }, mutations: { retry: false },
  } });
  const content = (current: AgentDetail) => <FluentProvider theme={webLightTheme}>
    <QueryClientProvider client={client}>
      <MemoryRouter future={{ v7_startTransition: true, v7_relativeSplatPath: true }}>
        <AgentRegistrationProgress agent={current} />
      </MemoryRouter>
    </QueryClientProvider>
  </FluentProvider>;
  const view = render(content(agent));
  return { client, ...view, showAgent: (current: AgentDetail) => view.rerender(content(current)) };
}

function setupCard() { return screen.getByRole("region", { name: "Agent setup" }); }
async function refresh() {
  const button = screen.getByRole("button", { name: "Refresh setup status" });
  await waitFor(() => expect(button).toBeEnabled());
  await userEvent.setup().click(button);
}

describe("Authoritative, accessible agent setup", () => {
  it.each(labels.map((label, index) => ({ label, index })))("shows prominent running progress for $label", async ({ label, index }) => {
    const operation = running(index);
    server.handlers.set(`GET /api/v1/operations/${operationId}`, () => operation);
    renderSetup({ ...approvalAgent, status: "Provisioning" });
    const stages = await screen.findByRole("list", { name: "Setup stages" });
    const items = within(stages).getAllByRole("listitem");
    expect(items).toHaveLength(7);
    items.forEach((item, stage) => {
      expect(item).toHaveTextContent(labels[stage]);
      expect(item).toHaveAttribute("data-state", stage < index ? "done" : stage === index ? "current" : "future");
    });
    expect(items[index]).toHaveAttribute("aria-current", "step");
    expect(items[index]).toHaveTextContent(label);
    expect(setupCard()).toHaveAttribute("data-state", "busy");
    expect(setupCard()).toHaveAttribute("data-motion", "animated");
    expect(setupCard().querySelector(".fui-Spinner")).not.toBeNull();
    const progress = screen.getByRole("progressbar", { name: "Agent setup progress" });
    expect(progress).toHaveAttribute("aria-valuenow", String(operation.percentComplete));
    expect(progress).toHaveAttribute("aria-valuemax", "100");
    expect(progress).toHaveAttribute("aria-valuetext", expect.stringContaining(`${operation.percentComplete}% reported by the Gateway`));
    expect(screen.getByRole("status")).toHaveAttribute("aria-live", "polite");
    expect(screen.getByRole("status")).toHaveAttribute("aria-atomic", "true");
    expect(screen.queryByRole("button", { name: "Finish Agent 365 registration" })).not.toBeInTheDocument();
    expect(server.requests.filter(request => request.method !== "GET")).toHaveLength(0);
  });

  it("shows queued verification as work even while the agent's older status still requires registration", async () => {
    server.handlers.set(`GET /api/v1/operations/${operationId}`, () => running(6, "Pending"));
    renderSetup();
    expect(await screen.findByText("Queued for setup")).toBeVisible();
    expect(setupCard()).toHaveAttribute("data-state", "busy");
    expect(screen.getByRole("progressbar", { name: "Agent setup progress" })).toHaveAttribute("aria-valuenow", "85");
    expect(screen.queryByText(/Setup is paused/)).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Finish Agent 365 registration" })).not.toBeInTheDocument();
  });

  it("keeps a human wait static and explains exactly what registration confirms", async () => {
    renderSetup();
    expect(await screen.findByRole("button", { name: "Finish Agent 365 registration" })).toBeEnabled();
    expect(setupCard()).toHaveAttribute("data-state", "waiting");
    expect(setupCard()).toHaveAttribute("data-motion", "static");
    expect(setupCard().querySelector(".fui-Spinner")).toBeNull();
    expect(screen.getByText(/The agent identity is already created/)).toHaveTextContent(
      "A signed-in Gateway Administrator confirms adding this existing agent to Microsoft 365's Registry.",
    );
    expect(screen.getByText(/The agent identity is already created/)).toHaveTextContent("no new identity or Gateway key");
    expect(screen.getByText(/The agent identity is already created/)).toHaveTextContent("not Purview approval");
    expect(screen.getByText(/The agent identity is already created/)).toHaveTextContent("no outside approval inbox");
    const item = within(screen.getByRole("list", { name: "Setup stages" })).getAllByRole("listitem")[5];
    expect(item).toHaveTextContent("Confirmation needed");
    expect(screen.queryByText("Awaiting Admin Approval")).not.toBeInTheDocument();
    expect(server.requests.every(request => request.method === "GET")).toBe(true);
  });

  it("does not increment progress during repeated unchanged server reads", async () => {
    server.handlers.set(`GET /api/v1/operations/${operationId}`, () => running(2));
    renderSetup({ ...approvalAgent, status: "Provisioning" });
    await screen.findByRole("list", { name: "Setup stages" });
    await refresh();
    await refresh();
    expect(screen.getByRole("progressbar", { name: "Agent setup progress" })).toHaveAttribute("aria-valuenow", "28");
    expect(server.requests.filter(request => request.path === `/api/v1/operations/${operationId}`)).toHaveLength(3);
  });

  it("honors reduced motion, including preference changes, without hiding progress or its status", async () => {
    let reduced = true;
    const preference = window.matchMedia("(prefers-reduced-motion: reduce)");
    Object.defineProperty(preference, "matches", { get: () => reduced });
    const added = vi.spyOn(preference, "addEventListener");
    const removed = vi.spyOn(preference, "removeEventListener");
    vi.spyOn(window, "matchMedia").mockReturnValue(preference);
    server.handlers.set(`GET /api/v1/operations/${operationId}`, () => running(2));
    const view = renderSetup({ ...approvalAgent, status: "Provisioning" });
    await screen.findByRole("list", { name: "Setup stages" });
    expect(setupCard()).toHaveAttribute("data-state", "busy");
    expect(setupCard()).toHaveAttribute("data-motion", "static");
    expect(setupCard().querySelector(".fui-Spinner")).toBeNull();
    expect(setupCard().querySelector(".fui-ProgressBar__bar")).toHaveStyle({ transitionProperty: "none" });
    expect(screen.getByRole("progressbar", { name: "Agent setup progress" })).toHaveAttribute("aria-valuenow", "28");
    expect(screen.getByRole("status")).toHaveTextContent("Connect the Gateway");
    const listener = added.mock.calls[0][1];
    act(() => {
      reduced = false;
      if (typeof listener === "function") listener.call(preference, new Event("change"));
      else listener?.handleEvent(new Event("change"));
    });
    expect(setupCard()).toHaveAttribute("data-motion", "animated");
    expect(setupCard().querySelector(".fui-Spinner")).not.toBeNull();
    view.unmount();
    expect(removed).toHaveBeenCalledWith("change", listener);
  });

  it("requires confirmation and dispatches only one request on a double click", async () => {
    let finish: ((value: unknown) => void) | undefined;
    server.handlers.set(`POST /api/v1/operations/${operationId}:complete-agent365-registration`, () => new Promise(resolve => { finish = resolve; }));
    renderSetup();
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Finish Agent 365 registration" }));
    expect(server.requests.filter(request => request.method === "POST")).toHaveLength(0);
    expect(screen.getByRole("group", { name: "Confirm Microsoft 365 Registry registration" })).toBeVisible();
    expect(screen.getByRole("button", { name: "Confirm registration" })).toHaveFocus();
    await user.dblClick(screen.getByRole("button", { name: "Confirm registration" }));
    expect(server.requests.filter(request => request.method === "POST")).toHaveLength(1);
    expect(server.requests.find(request => request.method === "POST")?.body).toBeUndefined();
    act(() => finish?.({ operationId, agentId, agent365RegistrationId: agentId, status: "VerificationQueued" }));
    await screen.findByText(/Registry completion was accepted/);
    expect(screen.queryByText("Agent is Active")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Finish Agent 365 registration" })).toBeDisabled();
  });

  it("does not submit when confirmation is cancelled", async () => {
    renderSetup();
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Finish Agent 365 registration" }));
    await user.click(screen.getByRole("button", { name: "Cancel" }));
    expect(screen.queryByRole("group", { name: "Confirm Microsoft 365 Registry registration" })).not.toBeInTheDocument();
    await waitFor(() => expect(screen.getByRole("button", { name: "Finish Agent 365 registration" })).toHaveFocus());
    expect(server.requests.every(request => request.method === "GET")).toBe(true);
  });

  it("does not treat a completed operation as an Active agent", async () => {
    server.handlers.set(`GET /api/v1/operations/${operationId}`, () => ({
      ...registrationOperation, status: "Completed", currentStep: null, percentComplete: 100,
      steps: registrationOperation.steps.map(step => ({ ...step, status: "Completed" })),
      pollingRecommended: false, requiredAction: null, agent365RegistrationCompletionAvailable: false,
    }));
    const view = renderSetup();
    expect(await screen.findByText("Waiting for the agent's Active status")).toBeVisible();
    expect(setupCard()).toHaveAttribute("data-motion", "static");
    expect(screen.queryByText("Agent is Active")).not.toBeInTheDocument();
    view.showAgent({ ...approvalAgent, status: "Active" });
    expect(screen.getByText("Agent is Active")).toBeVisible();
    expect(screen.queryByRole("button", { name: "Finish Agent 365 registration" })).not.toBeInTheDocument();
  });

  it("does not offer a stale action when another administrator already activated the agent", async () => {
    renderSetup({ ...approvalAgent, status: "Active" });
    await screen.findByRole("list", { name: "Setup stages" });
    expect(screen.getByText("Agent is Active")).toBeVisible();
    expect(screen.queryByRole("button", { name: "Finish Agent 365 registration" })).not.toBeInTheDocument();
    expect(server.requests.every(request => request.method === "GET")).toBe(true);
  });

  it("does not treat a disabled agent's setup history as pending activation or offer a stale confirmation", async () => {
    renderSetup({ ...approvalAgent, status: "Disabled" });
    await screen.findByRole("list", { name: "Setup stages" });
    expect(screen.getByText("Agent status: Disabled")).toBeVisible();
    expect(screen.getByText(/setup history does not change this agent's current state/)).toBeVisible();
    expect(screen.queryByText("Waiting for the agent's Active status")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Finish Agent 365 registration" })).not.toBeInTheDocument();
    expect(setupCard()).toHaveAttribute("data-motion", "static");
  });

  it("closes an open confirmation when fresh readback reports another administrator's verification work", async () => {
    const view = renderSetup();
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Finish Agent 365 registration" }));
    server.handlers.set(`GET /api/v1/operations/${operationId}`, () => running(6));
    await act(() => view.client.refetchQueries({ queryKey: ["registration-operation", operationId, agentId] }));
    expect(await screen.findByText("Verifying the Agent 365 connection")).toBeVisible();
    expect(screen.queryByRole("button", { name: "Confirm registration" })).not.toBeInTheDocument();
    expect(setupCard()).toHaveAttribute("data-state", "busy");
    expect(server.requests.every(request => request.method === "GET")).toBe(true);
  });

  it("periodically notices another administrator's completion without animating or posting during the wait", async () => {
    renderSetup();
    await screen.findByRole("button", { name: "Finish Agent 365 registration" });
    expect(setupCard()).toHaveAttribute("data-motion", "static");
    server.handlers.set(`GET /api/v1/operations/${operationId}`, () => running(6));
    expect(await screen.findByText("Verifying the Agent 365 connection", {}, { timeout: 12000 })).toBeVisible();
    expect(server.requests.every(request => request.method === "GET")).toBe(true);
    expect(screen.queryByRole("button", { name: "Finish Agent 365 registration" })).not.toBeInTheDocument();
  }, 15000);

  it("reads back queued verification after a lost response instead of reposting confirmation", async () => {
    server.handlers.set(`POST /api/v1/operations/${operationId}:complete-agent365-registration`, () => {
      server.handlers.set(`GET /api/v1/operations/${operationId}`, () => running(6, "Pending"));
      throw new TypeError("Lost response");
    });
    renderSetup();
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Finish Agent 365 registration" }));
    await user.click(screen.getByRole("button", { name: "Confirm registration" }));
    await screen.findByText(/no request will be repeated automatically/);
    expect(setupCard()).toHaveAttribute("data-motion", "static");
    await refresh();
    await waitFor(() => expect(setupCard()).toHaveAttribute("data-state", "busy"));
    expect(screen.queryByRole("button", { name: "Finish Agent 365 registration" })).not.toBeInTheDocument();
    expect(server.requests.filter(request => request.method === "POST")).toHaveLength(1);
  });

  it("keeps a reported skipped stage distinct from a completed stage", async () => {
    const operation = running(2);
    operation.steps[0].status = "Skipped";
    server.handlers.set(`GET /api/v1/operations/${operationId}`, () => operation);
    renderSetup({ ...approvalAgent, status: "Provisioning" });
    const steps = await screen.findByRole("list", { name: "Setup stages" });
    const first = within(steps).getAllByRole("listitem")[0];
    expect(first).toHaveAttribute("data-state", "skipped");
    expect(first).toHaveTextContent("Skipped");
    expect(first).not.toHaveTextContent("Done");
  });

  it("does not invent missing operation capabilities from an older API", async () => {
    server.handlers.set(`GET /api/v1/operations/${operationId}`, () => ({
      ...registrationOperation, agent365RegistrationCompletionAvailable: undefined,
    }));
    renderSetup();
    expect(await screen.findByRole("alert")).toHaveTextContent("response does not match this Console");
    expect(screen.queryByRole("button", { name: "Finish Agent 365 registration" })).not.toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Review registration access and compatibility" })).toBeVisible();
  });

  it("recovers a missing detail operation ID through bound history before reading an operation", async () => {
    server.handlers.set(`GET /api/v1/agents/${agentId}/provisioning-history`, () => provisioningHistory);
    renderSetup({ ...approvalAgent, provisioning: { ...approvalAgent.provisioning, operationId: undefined } });
    expect(await screen.findByRole("button", { name: "Finish Agent 365 registration" })).toBeEnabled();
    expect(screen.getByText("Operation found in this agent's provisioning history.")).toBeVisible();
    expect(server.requests.map(request => request.path)).toEqual([
      `/api/v1/agents/${agentId}/provisioning-history`, `/api/v1/operations/${operationId}`,
    ]);
  });

  it("does not fall back to history when a reported operation ID is invalid", async () => {
    renderSetup({ ...approvalAgent, provisioning: { ...approvalAgent.provisioning, operationId: "invalid" } });
    expect(await screen.findByRole("alert")).toHaveTextContent("valid operation ID");
    expect(server.requests).toHaveLength(0);
    expect(setupCard()).toHaveAttribute("data-motion", "static");
  });

  it("does not read an operation from a differently bound history", async () => {
    server.handlers.set(`GET /api/v1/agents/${agentId}/provisioning-history`, () => ({ ...provisioningHistory, agentId: tenantId }));
    renderSetup({ ...approvalAgent, provisioning: null });
    expect(await screen.findByRole("alert")).toHaveTextContent("does not belong to this agent");
    expect(server.requests).toHaveLength(1);
    expect(screen.queryByRole("button", { name: "Finish Agent 365 registration" })).not.toBeInTheDocument();
  });

  it.each([null, "DifferentAdministratorAction"])("keeps an unsupported waiting action %s static and names the limitation", async requiredAction => {
    server.handlers.set(`GET /api/v1/operations/${operationId}`, () => ({ ...registrationOperation, requiredAction }));
    renderSetup();
    await screen.findByRole("list", { name: "Setup stages" });
    expect(screen.getByText(/No confirmation is available/)).toBeVisible();
    if (requiredAction) expect(screen.getByText(requiredAction)).toBeVisible();
    expect(screen.getByRole("link", { name: "Review registration access and compatibility" })).toHaveAttribute("href", "/platform#registration-access");
    expect(setupCard()).toHaveAttribute("data-motion", "static");
    expect(screen.queryByRole("button", { name: "Finish Agent 365 registration" })).not.toBeInTheDocument();
  });

  it.each([
    { type: "DeleteAgent" }, { workflowVersion: 1, legacy: true }, { status: "UnknownFutureState" },
    { steps: null }, { steps: registrationOperation.steps.slice(1) },
    { steps: [...registrationOperation.steps].reverse() },
    { steps: registrationOperation.steps.map(() => registrationOperation.steps[0]) },
  ])("fails visibly for an unsupported workflow shape", async change => {
    server.handlers.set(`GET /api/v1/operations/${operationId}`, () => ({ ...registrationOperation, ...change }));
    renderSetup();
    expect(await screen.findByText(/workflow or stages are not supported/)).toBeVisible();
    expect(screen.queryByRole("list", { name: "Setup stages" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Finish Agent 365 registration" })).not.toBeInTheDocument();
    expect(setupCard()).toHaveAttribute("data-motion", "static");
  });

  it("names the actual closed gate settings rather than an approval portal", async () => {
    server.handlers.set(`GET /api/v1/operations/${operationId}`, () => ({ ...registrationOperation, agent365RegistrationCompletionAvailable: false }));
    renderSetup();
    expect(await screen.findByText(/Registry completion gate is closed/)).toHaveTextContent("Agent365:DelegatedRegistry:Enabled");
    expect(screen.getByText(/Registry completion gate is closed/)).toHaveTextContent("Agent365:DelegatedRegistry:AllowContinuousDevelopmentAccess");
    expect(setupCard()).toHaveAttribute("data-motion", "static");
  });

  it("names the API Administrator role after a refused confirmation and preserves its support reference", async () => {
    server.handlers.set(`POST /api/v1/operations/${operationId}:complete-agent365-registration`, () =>
      response({ detail: "Forbidden", errorCode: "FORBIDDEN", correlationId: operationId }, 403));
    renderSetup();
    const user = userEvent.setup();
    await user.click(await screen.findByRole("button", { name: "Finish Agent 365 registration" }));
    await user.click(screen.getByRole("button", { name: "Confirm registration" }));
    expect(await screen.findByText(/This signed-in session was refused/)).toHaveTextContent("Gateway.Administrator");
    expect(screen.getByText(/This signed-in session was refused/)).toHaveTextContent("access_as_user");
    await user.click(within(screen.getByRole("alert")).getByText("Details"));
    expect(within(screen.getByRole("alert")).getByText(`Reference: ${operationId}`)).toBeVisible();
    expect(setupCard()).toHaveAttribute("data-motion", "static");
    expect(server.requests.filter(request => request.method === "POST")).toHaveLength(1);
  });

  it("names the read roles when operation access is refused", async () => {
    server.handlers.set(`GET /api/v1/operations/${operationId}`, () => response({ detail: "Forbidden" }, 403));
    renderSetup();
    expect(await screen.findByText(/Reading provisioning history and operations requires/)).toHaveTextContent("Gateway.Operator");
    expect(screen.getByRole("link", { name: "Review registration access and compatibility" })).toBeVisible();
    expect(screen.queryByRole("button", { name: "Finish Agent 365 registration" })).not.toBeInTheDocument();
  });

  it("stops motion on failed steps and exposes the exact failure and operation reference", async () => {
    server.handlers.set(`GET /api/v1/operations/${operationId}`, () => ({
      ...running(6), status: "Failed", pollingRecommended: false,
      steps: running(6).steps.map((step, index) => index === 6 ? { ...step, status: "Failed" } : step),
      error: { code: "REGISTRY_READBACK_FAILED", message: "The provider readback did not match." },
    }));
    renderSetup({ ...approvalAgent, status: "Provisioning" });
    expect(await screen.findByRole("alert")).toHaveTextContent("The provider readback did not match.");
    expect(setupCard()).toHaveAttribute("data-state", "error");
    expect(setupCard().querySelector(".fui-Spinner")).toBeNull();
    const items = within(screen.getByRole("list", { name: "Setup stages" })).getAllByRole("listitem");
    expect(items[6]).toHaveAttribute("data-state", "failed");
    await userEvent.setup().click(screen.getByText("Operation details"));
    expect(screen.getByText("Code: REGISTRY_READBACK_FAILED")).toBeVisible();
    expect(screen.getByText(`Operation reference: ${operationId}`)).toBeVisible();
  });
});
