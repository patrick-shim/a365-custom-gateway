import { beforeEach, expect, it, vi } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { FluentProvider, webLightTheme } from "@fluentui/react-components";
import { AgentDeletion } from "./AgentDeletion";
import { api } from "../api/client";
import { agent as fixture } from "../test/fixtures";
vi.mock("../api/client", () => ({ api: { listAgents: vi.fn(), getAgent: vi.fn(), deleteRegisteredAgent: vi.fn(), setAgentEnabled: vi.fn() } }));
const agent = { ...fixture, agent365: { ...fixture.agent365, instanceId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" } };
beforeEach(() => {
  vi.resetAllMocks();
  vi.mocked(api.listAgents).mockResolvedValue({items: [agent], nextCursor: null, totalCount: 1});
  vi.mocked(api.getAgent).mockResolvedValue(agent);
});
function show() {
  render(<FluentProvider theme={webLightTheme}><QueryClientProvider client={new QueryClient({defaultOptions:{queries:{retry:false},mutations:{retry:false}}})}><AgentDeletion /></QueryClientProvider></FluentProvider>);
}
it("confirms gateway-only disable, refreshes status and offers enable without deleting", async () => {
  vi.mocked(api.setAgentEnabled).mockImplementation(async (id, enabled) => {
    const status = enabled ? "Active" : "Disabled";
    vi.mocked(api.listAgents).mockResolvedValue({items: [{...agent, status}], nextCursor: null, totalCount: 1});
    return {agentId:id, status, effectiveAtUtc:new Date().toISOString()};
  });
  show(); const user = userEvent.setup();
  await user.click(await screen.findByRole("checkbox", {name: `${agent.name} — ${agent.externalAgentId}`}));
  await user.click(screen.getByRole("button", {name:"Disable selected (1)"}));
  expect(api.setAgentEnabled).not.toHaveBeenCalled();
  await user.click(await screen.findByRole("button", {name:"Disable gateway access"}));
  await screen.findByText("Gateway access blocked · Agent 365 registration unchanged");
  expect(api.setAgentEnabled).toHaveBeenCalledWith(agent.agentId, false);
  await user.click(screen.getByRole("checkbox", {name: `${agent.name} — ${agent.externalAgentId}`}));
  await user.click(screen.getByRole("button", {name:"Enable selected (1)"}));
  await user.click(await screen.findByRole("button", {name:"Enable gateway access"}));
  await screen.findByText("Active — gateway access restored");
  expect(api.setAgentEnabled).toHaveBeenCalledWith(agent.agentId, true);
  expect(api.deleteRegisteredAgent).not.toHaveBeenCalled();
});
it("requires reviewed selection and typed confirmation; cancel never deletes", async () => {
  show(); const user = userEvent.setup();
  await user.click(await screen.findByRole("checkbox", {name: `${agent.name} — ${agent.externalAgentId}`}));
  await user.click(screen.getByRole("button", {name:"Review deletion (1)"}));
  expect(await screen.findByRole("button", {name:"Delete permanently"})).toBeDisabled();
  await user.click(screen.getByRole("button", {name:"Cancel"}));
  expect(api.deleteRegisteredAgent).not.toHaveBeenCalled();
});
it("passes the reviewed version and retains an unconfirmed failure for retry", async () => {
  vi.mocked(api.deleteRegisteredAgent).mockRejectedValue(new Error("Microsoft deletion unconfirmed"));
  show(); const user = userEvent.setup();
  await user.click(await screen.findByRole("checkbox", {name: `${agent.name} — ${agent.externalAgentId}`}));
  await user.click(screen.getByRole("button", {name:"Review deletion (1)"}));
  await user.type(await screen.findByLabelText("Type DELETE to confirm"), "DELETE");
  await user.click(screen.getByRole("button", {name:"Delete permanently"}));
  await screen.findByText("Microsoft deletion unconfirmed");
  expect(api.deleteRegisteredAgent).toHaveBeenCalledWith(agent.agentId, agent.rowVersion);
  await waitFor(() => expect(screen.getByRole("button", {name:"Review deletion (1)"})).toBeEnabled());
});
it("processes multiple selections independently and preserves the failed selection", async () => {
  const second = { ...agent, agentId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", name: "Second agent", externalAgentId: "second" };
  vi.mocked(api.listAgents).mockResolvedValue({items:[agent,second],nextCursor:null,totalCount:2});
  vi.mocked(api.getAgent).mockImplementation(async id => id === second.agentId ? second : agent);
  vi.mocked(api.deleteRegisteredAgent).mockImplementation(async id => {
    if (id === second.agentId) throw new Error("Second deletion unconfirmed");
    return {agentId:id,status:"Deleted",operationId:"cccccccc-cccc-4ccc-8ccc-cccccccccccc"};
  });
  show(); const user = userEvent.setup();
  await user.click(await screen.findByRole("checkbox",{name:"Select all eligible agents on loaded pages"}));
  await user.click(screen.getByRole("button",{name:"Review deletion (2)"}));
  await user.type(await screen.findByLabelText("Type DELETE to confirm"),"DELETE");
  await user.click(screen.getByRole("button",{name:"Delete permanently"}));
  await screen.findByText("Second deletion unconfirmed");
  expect(screen.getByText("Deleted from gateway and Agent 365")).toBeInTheDocument();
  expect(api.deleteRegisteredAgent).toHaveBeenCalledTimes(2);
  await waitFor(() => expect(screen.getByRole("button",{name:"Review deletion (1)"})).toBeEnabled());
});
