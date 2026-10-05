import { beforeEach, describe, expect, it, vi } from "vitest";
import { api } from "./client";
import { ApiError, readAuthorizationChallenge } from "./errors";
import {
  agent, agentId, blueprints, features, mockServer,
  response, rowVersion, tenantId, operationId, registrationOperation, systemConfig, provisioningHistory,
} from "../test/fixtures";

vi.mock("../auth/msal", () => ({ getApiToken: vi.fn(async () => "test-token") }));
vi.mock("../runtime-config", () => ({ config: { tenantId: "11111111-1111-4111-8111-111111111111" } }));

let server: ReturnType<typeof mockServer>;
beforeEach(() => { server = mockServer(); });

describe("Gateway wire contracts", () => {
  it("changes only gateway admission and rejects mismatched state responses", async () => {
    server.handlers.set(`POST /api/v1/agents/${agentId}:disable`, () => ({ agentId, status: "Disabled", effectiveAtUtc: new Date().toISOString() }));
    expect((await api.setAgentEnabled(agentId, false)).status).toBe("Disabled");
    server.handlers.set(`POST /api/v1/agents/${agentId}:enable`, () => ({ agentId, status: "Active", effectiveAtUtc: new Date().toISOString() }));
    expect((await api.setAgentEnabled(agentId, true)).status).toBe("Active");
    server.handlers.set(`POST /api/v1/agents/${agentId}:disable`, () => ({ agentId: operationId, status: "Disabled", effectiveAtUtc: new Date().toISOString() }));
    await expect(api.setAgentEnabled(agentId, false)).rejects.toMatchObject({ code: "INVALID_API_RESPONSE", outcomeUnknown: true });
    expect(server.requests).toHaveLength(3);
  });
  it("rejects a different or unknown assignment confirmation without repeating the mutation", async () => {
    const path = `POST /api/v1/agents/${agentId}/purview-policies/${operationId}/confirm`;
    server.handlers.set(path, () => ({ operationId: agentId, status: "Assigned" }));
    await expect(api.confirmAgentPolicy(agentId, operationId)).rejects.toMatchObject({ code: "INVALID_API_RESPONSE", outcomeUnknown: true });
    server.handlers.set(path, () => ({ operationId, status: "Protected" }));
    await expect(api.confirmAgentPolicy(agentId, operationId)).rejects.toMatchObject({ code: "INVALID_API_RESPONSE", outcomeUnknown: true });
    expect(server.requests).toHaveLength(2);
  });
  it("rejects stale and wrong-tenant Purview catalog data", async () => {
    const catalog = { tenantId, source: "Purview", retrievedAtUtc: new Date().toISOString(), items: [] };
    server.handlers.set("GET /api/v1/protection/purview/policies", () => catalog);
    expect((await api.listPurviewPolicies()).items).toEqual([]);
    server.handlers.set("GET /api/v1/protection/purview/policies", () => ({ ...catalog, tenantId: operationId }));
    await expect(api.listPurviewPolicies()).rejects.toMatchObject({ code: "PURVIEW_POLICY_CATALOG_INVALID" });
    server.handlers.set("GET /api/v1/protection/purview/policies", () => ({ ...catalog, retrievedAtUtc: new Date(Date.now() - 600_000).toISOString() }));
    await expect(api.listPurviewPolicies()).rejects.toMatchObject({ code: "PURVIEW_POLICY_CATALOG_INVALID" });
  });
  it("reads wrapped blueprints and preserves application versus object IDs", async () => {
    const result = await api.listBlueprints();
    expect(result).toEqual(blueprints.items);
    expect(result[0].blueprintObjectId).not.toEqual(result[0].blueprintClientId);
  });

  it("keeps pagination and unknown lifecycle statuses", async () => {
    server.handlers.set("GET /api/v1/agents", () => ({ items: [{ ...agent, status: "NewProviderState" }], nextCursor: "next value", totalCount: 55 }));
    const page = await api.listAgents("previous value");
    expect(server.requests[0].query.get("cursor")).toBe("previous value");
    expect(page.nextCursor).toBe("next value");
    expect(page.totalCount).toBe(55);
    expect(page.items[0].status).toBe("NewProviderState");
  });

  it.each([401, 403, 409, 503])("surfaces HTTP %s and its safe support reference", async status => {
    server.handlers.set("GET /api/v1/agents", () => response({
      detail: "This request cannot proceed.", errorCode: "TEST_FAILURE", correlationId: agentId,
    }, status));
    await expect(api.listAgents()).rejects.toMatchObject({
      status, message: "This request cannot proceed.", code: "TEST_FAILURE", correlationId: agentId,
    });
  });

  it("does not render HTML error responses from a proxy", async () => {
    server.handlers.set("GET /api/v1/agents", () => new Response("<html>internal proxy detail</html>", { status: 502 }));
    await expect(api.listAgents()).rejects.toMatchObject({ status: 502 });
    await expect(api.listAgents()).rejects.not.toHaveProperty("message", expect.stringContaining("<html>"));
  });

  it("uses PATCH features, concurrency, and matching idempotency, never lifecycle routes", async () => {
    server.handlers.set(`PATCH /api/v1/agents/${agentId}/features`, () => ({
      agentId, features: { ...features, promptShieldEnabled: true, promptShieldEffectivelyEnabled: true }, updatedAtUtc: agent.createdAtUtc,
    }));
    await api.setPromptShield(agentId, true, rowVersion);
    const [request] = server.requests;
    expect(request.method).toBe("PATCH");
    expect(request.path).toBe(`/api/v1/agents/${agentId}/features`);
    expect(request.body).toEqual({
      promptShieldEnabled: true, expectedRowVersion: rowVersion, idempotencyKey: request.headers.get("Idempotency-Key"),
    });
    expect(request.headers.get("If-Match")).toBe(rowVersion);
    expect(request.headers.get("Idempotency-Key")).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
    expect(server.requests.some(r => /:(enable|disable)$/.test(r.path))).toBe(false);
  });

  it("reads Registry progress and completes with no request body or fabricated evidence", async () => {
    expect(await api.getRegistrationOperation(operationId, agentId)).toEqual(registrationOperation);
    expect(await api.completeAgent365Registration(operationId, agentId)).toMatchObject({ status: "VerificationQueued" });
    const request = server.requests[1];
    expect(request.path).toBe(`/api/v1/operations/${operationId}:complete-agent365-registration`);
    expect(request.method).toBe("POST");
    expect(request.body).toBeUndefined();
    expect(request.headers.has("Content-Type")).toBe(false);
  });

  it("rejects operation readback belonging to a different agent", async () => {
    await expect(api.getRegistrationOperation(operationId, tenantId)).rejects.toMatchObject({ code: "OPERATION_MISMATCH" });
    expect(server.requests.every(r => r.method === "GET")).toBe(true);
  });

  it("discovers only the newest server-ordered job after binding history to the requested agent", async () => {
    server.handlers.set(`GET /api/v1/agents/${agentId}/provisioning-history`, () => ({
      ...provisioningHistory,
      jobs: [provisioningHistory.jobs[0], { ...provisioningHistory.jobs[0], operationId: tenantId, startedAtUtc: "2099-01-01T00:00:00Z" }],
    }));
    expect(await api.findLatestProvisioningOperation(agentId)).toBe(operationId);
    expect(server.requests).toHaveLength(1);
    expect(server.requests[0].path).toBe(`/api/v1/agents/${agentId}/provisioning-history`);
    expect(server.requests[0].method).toBe("GET");
  });

  it("does not guess an operation when the history has no jobs", async () => {
    expect(await api.findLatestProvisioningOperation(agentId)).toBeNull();
    expect(server.requests).toHaveLength(1);
  });

  it("rejects another agent's history before reading any operation", async () => {
    server.handlers.set(`GET /api/v1/agents/${agentId}/provisioning-history`, () => ({ ...provisioningHistory, agentId: tenantId }));
    await expect(api.findLatestProvisioningOperation(agentId)).rejects.toMatchObject({ code: "PROVISIONING_HISTORY_MISMATCH" });
    expect(server.requests).toHaveLength(1);
  });

  it("binds the agent detail to its route ID before selecting any setup operation", async () => {
    server.handlers.set(`GET /api/v1/agents/${agentId}`, () => ({ ...agent, agentId: tenantId }));
    await expect(api.getAgent(agentId)).rejects.toMatchObject({ code: "AGENT_MISMATCH" });
    expect(server.requests).toHaveLength(1);
  });

  it.each([
    { agentId, items: provisioningHistory.jobs },
    { agentId, jobs: null },
    { agentId, jobs: [provisioningHistory.jobs[0], provisioningHistory.jobs[0]] },
    { agentId, jobs: [{ ...provisioningHistory.jobs[0], operationId: "../another-operation" }] },
    { agentId, jobs: [{ ...provisioningHistory.jobs[0], operationId: "00000000-0000-0000-0000-000000000000" }] },
    { agentId, jobs: [{ operationId }] },
  ])("rejects incompatible or ambiguous history instead of reading a guessed operation", async history => {
    server.handlers.set(`GET /api/v1/agents/${agentId}/provisioning-history`, () => history);
    await expect(api.findLatestProvisioningOperation(agentId)).rejects.toMatchObject({ code: "INVALID_API_RESPONSE" });
    expect(server.requests).toHaveLength(1);
  });

  it("does not request an invalid reported operation ID", async () => {
    await expect(api.getRegistrationOperation("not-an-operation-id", agentId)).rejects.toMatchObject({ code: "INVALID_OPERATION_ID" });
    expect(server.requests).toHaveLength(0);
  });

  it.each([-1, 101, 28.5, "28"])("rejects invalid progress %s rather than clamping or inventing a percentage", async percentComplete => {
    server.handlers.set(`GET /api/v1/operations/${operationId}`, () => ({ ...registrationOperation, percentComplete }));
    await expect(api.getRegistrationOperation(operationId, agentId)).rejects.toMatchObject({ code: "INVALID_API_RESPONSE" });
  });

  it("does not accept Active as a fabricated completion response", async () => {
    server.handlers.set(`POST /api/v1/operations/${operationId}:complete-agent365-registration`, () => ({
      operationId, agentId, agent365RegistrationId: agentId, status: "Active",
    }));
    await expect(api.completeAgent365Registration(operationId, agentId))
      .rejects.toMatchObject({ code: "INVALID_API_RESPONSE", outcomeUnknown: true });
  });

  it.each([undefined, { environment: "Development", reason: null }, { environment: "Unknown", reason: "Unknown provider" }])(
    "requires authoritative registration defaults with a reason for preview exceptions", async registrationDefaults => {
      server.handlers.set("GET /api/v1/system/config", () => ({ ...systemConfig, registrationDefaults }));
      await expect(api.getSystemConfig()).rejects.toMatchObject({ code: "INVALID_API_RESPONSE" });
    },
  );

  it("accepts the standard server Production default without an exception reason", async () => {
    server.handlers.set("GET /api/v1/system/config", () => ({
      ...systemConfig, registrationDefaults: { environment: "Production", reason: null },
    }));
    expect((await api.getSystemConfig()).registrationDefaults.environment).toBe("Production");
  });

  it("retains a decoded claims challenge in memory without retrying the POST", async () => {
    const claims = JSON.stringify({ access_token: { acrs: { value: "test" } } });
    server.handlers.set(`POST /api/v1/operations/${operationId}:complete-agent365-registration`, () => new Response(
      JSON.stringify({ errorCode: "AGENT365_REGISTRY_DELEGATED_ACCESS_REQUIRED" }),
      { status: 401, headers: { "WWW-Authenticate": `Bearer error="insufficient_claims", claims="${btoa(claims)}"` } },
    ));
    await expect(api.completeAgent365Registration(operationId, agentId)).rejects.toMatchObject({
      status: 401, authorizationChallenge: { kind: "claims", claims }, outcomeUnknown: false,
    });
    expect(server.requests).toHaveLength(1);
  });

  it("recognizes consent scopes as guidance, not a different browser authority", () => {
    expect(readAuthorizationChallenge('Bearer authorization_uri="https://untrusted.invalid", error="insufficient_scope", scope="https://graph.microsoft.com/AgentRegistry.ReadWrite.All"'))
      .toEqual({ kind: "consent", scopes: ["https://graph.microsoft.com/AgentRegistry.ReadWrite.All"] });
  });

  it.each([
    null, 'Bearer error="insufficient_claims", claims="bad"',
    `Bearer error="insufficient_claims", claims="${btoa("{}")}"`,
    'Bearer error="insufficient_claims", error="insufficient_scope"',
  ])("rejects an unreadable authorization challenge visibly", header => {
    expect(readAuthorizationChallenge(header)).toEqual({ kind: "unavailable" });
  });

  it("flags an unconfirmed mutation instead of silently repeating it", async () => {
    server.fetch.mockRejectedValue(new TypeError("Network unavailable"));
    await expect(api.issueCredential(agentId)).rejects.toMatchObject({ outcomeUnknown: true, code: "REQUEST_UNCONFIRMED" });
    expect(server.fetch).toHaveBeenCalledTimes(1);
  });

  it("does not interpret Unhealthy as Healthy", async () => {
    server.handlers.set("GET /health/checks", () => new Response("Unhealthy"));
    expect(await api.getHealth()).toBe("Unhealthy");
  });

  it("treats malformed successful mutations as unconfirmed, not successful", async () => {
    server.handlers.set(`POST /api/v1/agents/${agentId}/credentials`, () => ({ key: "incorrect shape" }));
    const result = api.issueCredential(agentId);
    await expect(result).rejects.toBeInstanceOf(ApiError);
    await expect(result).rejects.toMatchObject({ outcomeUnknown: true, code: "INVALID_API_RESPONSE" });
  });
});
