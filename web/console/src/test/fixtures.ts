import { vi } from "vitest";

export const tenantId = "11111111-1111-4111-8111-111111111111";
export const agentId = "22222222-2222-4222-8222-222222222222";
export const blueprintObjectId = "33333333-3333-4333-8333-333333333333";
export const blueprintClientId = "44444444-4444-4444-8444-444444444444";
export const operationId = "55555555-5555-4555-8555-555555555555";
export const testKey = "test-only-not-a-real-gateway-key";
export const rowVersion = "AAAAAAAAB9I=";

export const features = {
  observabilityMode: "Agent365", purviewEnabled: false, purviewMode: null,
  agent365ObservabilityEnabled: true, azureMonitorExportEnabled: false,
  promptShieldEnabled: false, purviewDlpProfile: null, purviewEffectivelyEnabled: false,
  purviewReadiness: null, promptShieldEffectivelyEnabled: false, promptShieldCapabilityStatus: "Installed",
  purviewPolicyMode: null, purviewConfigurationOperationId: null, purviewConfigurationStatus: null,
  purviewProfileStatus: null,
};
export const agent = {
  agentId, externalAgentId: "test-agent", name: "Test agent", description: null,
  status: "Active", environment: "Test",
  agent365: {
    agentId: "66666666-6666-4666-8666-666666666666", blueprintId: blueprintClientId,
    blueprintObjectId, instanceId: null, agentIdentityObjectId: "77777777-7777-4777-8777-777777777777",
  },
  features, lastActivityAtUtc: null, createdAtUtc: "2026-10-01T13:00:00",
  updatedAtUtc: "2026-10-01T13:00:00", ownerObjectId: "88888888-8888-4888-8888-888888888888",
  rowVersion, provisioning: null, links: null, retryProvisioning: null,
};
export const blueprints = {
  items: [
    { blueprintObjectId, blueprintClientId, displayName: "Support blueprint", isAgent365Compatible: true, agent365CompatibilityIssue: null },
    { blueprintObjectId: "99999999-9999-4999-8999-999999999999", blueprintClientId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      displayName: "Incompatible blueprint", isAgent365Compatible: false, agent365CompatibilityIssue: "MissingRequiredManagerApplications" },
  ],
};
export const failedConnection = {
  id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", tenantId, status: "VerificationFailed",
  authorityKind: "VerificationFailed", authorityApplicationId: null, authorityServicePrincipalObjectId: null,
  activeInventoryGenerationId: null, authorizedAtUtc: null, expiresAtUtc: null,
  lastVerifiedAtUtc: null, lastFailureCode: "PURVIEW_CONNECTION_PROVIDER_UNVERIFIED", rowVersion,
};
export const connected = {
  ...failedConnection, status: "Connected", authorityKind: "Application",
  authorityApplicationId: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
  authorityServicePrincipalObjectId: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
  activeInventoryGenerationId: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
  authorizedAtUtc: "2026-10-01T13:00:00", lastVerifiedAtUtc: "2026-10-01T13:00:00",
  expiresAtUtc: "2099-01-01T00:00:00Z", lastFailureCode: null,
};
export const inventory = {
  generationId: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", tenantId,
  retrievedAtUtc: "2026-10-01T13:00:00Z", expiresAtUtc: "2099-01-01T00:00:00Z", isExpired: false,
  items: [{ id: "ffffffff-ffff-4fff-8fff-ffffffffffff", exactName: "Credit Card Number", publisher: "Microsoft Corporation" }],
};
export const systemConfig = {
  provisioningMode: "Automatic", provisioningExecutionEnabled: true, defaultObservabilityMode: "Agent365",
  defaultPromptShieldEnabled: false, promptShieldAvailable: true, rowVersion,
  registrationDefaults: {
    environment: "Development",
    reason: "This installed DirectRegistryPreview provider uses the Agent 365 beta registry and supports Development only.",
  },
};
export const registration = {
  agentId, externalAgentId: agent.externalAgentId, name: agent.name, status: "Provisioning", operationId,
  createdAtUtc: agent.createdAtUtc, links: null,
  gatewayCredential: { keyId: "01234567-0123-4123-8123-012345678901", apiKey: testKey, expiresAtUtc: "2099-01-01T00:00:00Z" },
};
export const credentials = {
  agentId, items: [{ keyId: "01234567-0123-4123-8123-012345678901",
    createdAtUtc: agent.createdAtUtc, expiresAtUtc: "2099-01-01T00:00:00Z", revokedAtUtc: null }],
};
export const review = {
  reviewTokenId: operationId, reviewToken: "test-only-review", reviewedPayloadHash: "test-hash",
  expiresAtUtc: "2099-01-01T00:00:00Z",
  review: { tenantId, operationType: "VerifyPurviewTenantConnection", targetIdentifier: tenantId,
    targetType: "PurviewTenantConnection", verificationMode: "Gateway",
    readinessDisclaimer: "The Gateway reads Purview using the installed certificate authority. Readback is required." },
};
export const operation = {
  operation: { id: operationId, type: "VerifyPurviewTenantConnection", tenantId, targetType: "PurviewTenantConnection",
    status: "Completed", failureCode: null, requiredAction: null,
    requiresManualIntervention: false, correlationId: operationId, blockers: [],
    steps: [{ step: "RecordExactReadback", status: "Completed", failureCode: null }] },
};
export const approvalAgent = {
  ...agent, status: "AwaitingAdminApproval",
  provisioning: { operationId, currentStep: "RegisterAgent", percentComplete: 71, lastError: null },
};
export const registrationOperation = {
  operationId, agentId, type: "ProvisionAgent", status: "AwaitingAdministratorAction", currentStep: "RegisterAgent", percentComplete: 71,
  error: null, steps: [{ step: "RegisterAgent", status: "Pending" }],
  pollingRecommended: false, requiredAction: "CompleteAgent365Registration", agent365RegistrationCompletionAvailable: true,
};

export interface CapturedRequest {
  path: string;
  query: URLSearchParams;
  method: string;
  body: unknown;
  headers: Headers;
}
export type Handler = (request: CapturedRequest) => unknown | Response | Promise<unknown | Response>;

export function response(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

export function mockServer() {
  const requests: CapturedRequest[] = [];
  const handlers = new Map<string, Handler>([
    ["GET /health/checks", () => new Response("Healthy")],
    ["GET /api/v1/agents", () => ({ items: [agent], nextCursor: null, totalCount: 1 })],
    [`GET /api/v1/agents/${agentId}`, () => agent],
    [`GET /api/v1/operations/${operationId}`, () => registrationOperation],
    [`POST /api/v1/operations/${operationId}:complete-agent365-registration`, () => ({
      operationId, agentId, agent365RegistrationId: "12345678-1234-4234-8234-123456789012", status: "VerificationQueued",
    })],
    ["GET /api/v1/agent-identity-blueprints", () => blueprints],
    ["GET /api/v1/protection/purview/connection", () => ({ connection: failedConnection })],
    ["GET /api/v1/protection/purview/sensitive-information-types", () => inventory],
    ["GET /api/v1/protection/purview/dlp-profiles", () => ({ items: [] })],
    ["GET /api/v1/system/config", () => systemConfig],
    ["GET /api/v1/protection/capabilities", () => ({ items: [
      { id: blueprintObjectId, capability: "PromptShields", status: "Installed", lastFailureCode: null, lastReadbackAtUtc: agent.createdAtUtc },
    ] })],
    ["POST /api/v1/agents", () => response(registration, 202)],
    [`GET /api/v1/agents/${agentId}/credentials`, () => credentials],
    [`POST /api/v1/agents/${agentId}/credentials`, () => response({ agentId, externalAgentId: agent.externalAgentId, gatewayCredential: registration.gatewayCredential }, 201)],
    [`DELETE /api/v1/agents/${agentId}/credentials/${credentials.items[0].keyId}`, () => ({ agentId, alreadyRevoked: false })],
    ["POST /api/v1/protection/purview/connection-operations:review", () => review],
    ["POST /api/v1/protection/operation-reviews:confirm", () => ({ confirmationTokenId: operationId, confirmationToken: "test-only-confirmation" })],
    ["POST /api/v1/protection/purview/connection-operations", () => response({ operationId, status: "Pending", correlationId: operationId }, 202)],
    [`GET /api/v1/protection/operations/${operationId}`, () => operation],
  ]);
  const fetch = vi.fn<typeof globalThis.fetch>(async (input, init) => {
    const url = new URL(input instanceof Request ? input.url : String(input), "https://console.test");
    const request: CapturedRequest = {
      path: url.pathname, query: url.searchParams, method: init?.method ?? "GET",
      body: typeof init?.body === "string" ? JSON.parse(init.body) : undefined, headers: new Headers(init?.headers),
    };
    requests.push(request);
    const handler = handlers.get(`${request.method} ${request.path}`);
    if (!handler) return response({ detail: `Unexpected test request: ${request.method} ${request.path}` }, 500);
    const result = await handler(request);
    return result instanceof Response ? result : response(result);
  });
  vi.stubGlobal("fetch", fetch);
  return { requests, handlers, fetch };
}
