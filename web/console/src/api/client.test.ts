import { beforeEach, describe, expect, it, vi } from "vitest";
import { api } from "./client";
import { ApiError } from "./errors";
import {
  agent, agentId, blueprints, connected, failedConnection, features, mockServer,
  response, review, rowVersion, tenantId,
} from "../test/fixtures";
import { connectionIsUsable } from "./types";

vi.mock("../auth/msal", () => ({ getApiToken: vi.fn(async () => "test-token") }));
vi.mock("../runtime-config", () => ({ config: { tenantId: "11111111-1111-4111-8111-111111111111" } }));

let server: ReturnType<typeof mockServer>;
beforeEach(() => { server = mockServer(); });

describe("Gateway wire contracts", () => {
  it("reads wrapped blueprints and preserves application versus object IDs", async () => {
    const result = await api.listBlueprints();
    expect(result).toEqual(blueprints.items);
    expect(result[0].blueprintObjectId).not.toEqual(result[0].blueprintClientId);
  });

  it("unwraps a failed connection without guessing its cause", async () => {
    expect(await api.getPurviewConnection()).toEqual(failedConnection);
  });

  it("accepts a genuinely unconfigured connection", async () => {
    server.handlers.set("GET /api/v1/protection/purview/connection", () => ({ connection: null }));
    expect(await api.getPurviewConnection()).toBeNull();
  });

  it("does not convert missing or wrongly wrapped data into an empty success", async () => {
    server.handlers.set("GET /api/v1/agent-identity-blueprints", () => blueprints.items);
    await expect(api.listBlueprints()).rejects.toMatchObject({ code: "INVALID_API_RESPONSE" });
    server.handlers.set("GET /api/v1/protection/purview/connection", () => ({}));
    await expect(api.getPurviewConnection()).rejects.toMatchObject({ code: "INVALID_API_RESPONSE" });
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

  it("sends the reviewed connection protocol with tenant and exact version bindings", async () => {
    const ticket = await api.reviewPurviewConnection(rowVersion);
    expect(server.requests).toHaveLength(1);
    await api.confirmPurviewConnection(ticket);
    expect(server.requests.map(r => r.path)).toEqual([
      "/api/v1/protection/purview/connection-operations:review",
      "/api/v1/protection/operation-reviews:confirm",
      "/api/v1/protection/purview/connection-operations",
    ]);
    expect(server.requests[0].body).toEqual({ tenantId, expectedRowVersion: rowVersion });
    expect(server.requests[0].headers.get("If-Match")).toBe(rowVersion);
    expect(server.requests[2].body).toMatchObject({ tenantId, expectedRowVersion: rowVersion });
    expect(server.requests[2].headers.get("If-Match")).toBe(rowVersion);
  });

  it("rejects a review for another tenant before confirmation", async () => {
    server.handlers.set("POST /api/v1/protection/purview/connection-operations:review", () => ({
      ...review, review: { ...review.review, tenantId: agentId },
    }));
    await expect(api.reviewPurviewConnection(rowVersion)).rejects.toMatchObject({ code: "REVIEW_MISMATCH" });
    expect(server.requests).toHaveLength(1);
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

  it("does not claim an expired or unverified connection is usable", () => {
    expect(connectionIsUsable(connected)).toBe(true);
    expect(connectionIsUsable({ ...connected, lastVerifiedAtUtc: null })).toBe(false);
    expect(connectionIsUsable({ ...connected, expiresAtUtc: "2000-01-01T00:00:00" })).toBe(false);
    expect(connectionIsUsable(failedConnection)).toBe(false);
    expect(connectionIsUsable(null)).toBe(false);
  });

  it("treats malformed successful mutations as unconfirmed, not successful", async () => {
    server.handlers.set(`POST /api/v1/agents/${agentId}/credentials`, () => ({ key: "incorrect shape" }));
    const result = api.issueCredential(agentId);
    await expect(result).rejects.toBeInstanceOf(ApiError);
    await expect(result).rejects.toMatchObject({ outcomeUnknown: true, code: "INVALID_API_RESPONSE" });
  });
});
