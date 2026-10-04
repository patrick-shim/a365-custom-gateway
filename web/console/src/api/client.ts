import { z } from "zod";
import { getApiToken } from "../auth/msal";
import { config } from "../runtime-config";
import { ApiError, readAuthorizationChallenge } from "./errors";
import {
  agentDetailSchema, agentListSchema, blueprintListSchema,
  credentialListSchema,
  featuresUpdateSchema, issuedCredentialSchema,
  registrationSchema, revokedCredentialSchema,
  systemConfigSchema, registrationOperationSchema, registrationCompletionSchema,
  provisioningHistorySchema, operationIdSchema, retryProvisioningSchema, purviewPolicyCatalogSchema,
  type RegisterAgentRequest,
} from "./types";

const problemSchema = z.object({
  title: z.string().optional(),
  detail: z.string().optional(),
  errorCode: z.string().optional(),
  correlationId: z.string().optional(),
  errors: z.record(z.array(z.string())).optional(),
});

async function request(path: string, method = "GET", body?: unknown, headers?: HeadersInit): Promise<Response> {
  const token = await getApiToken();
  const requestHeaders = new Headers(headers);
  requestHeaders.set("Accept", "application/json");
  requestHeaders.set("Authorization", `Bearer ${token}`);
  if (body !== undefined) requestHeaders.set("Content-Type", "application/json");
  let response: Response;
  try {
    response = await fetch(path, {
      method,
      headers: requestHeaders,
      credentials: "same-origin",
      cache: "no-store",
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(45_000),
    });
  } catch {
    throw new ApiError(
      method === "GET"
        ? "The Gateway could not be reached. Check your connection and try again."
        : "The response was lost. Refresh the current state before trying this change again.",
      0, "REQUEST_UNCONFIRMED", undefined, method !== "GET",
    );
  }
  if (!response.ok) {
    const raw = await response.text();
    let problem: z.infer<typeof problemSchema> = {};
    try {
      const result = problemSchema.safeParse(JSON.parse(raw));
      if (result.success) problem = result.data;
    } catch {
      // A proxy can return HTML. Never show that response as an API error.
    }
    const fallback = response.status === 401
      ? "Your session has expired. Sign in again."
      : response.status === 403
        ? "Your account does not have permission for this action."
        : `The Gateway returned HTTP ${response.status}. Try again or contact your administrator.`;
    const validation = problem.errors ? Object.values(problem.errors).flat().slice(0, 8).join(" ") : undefined;
    throw new ApiError(
      validation || problem.detail || problem.title || fallback,
      response.status, problem.errorCode, problem.correlationId, method !== "GET" && response.status >= 500,
      response.status === 401 && problem.errorCode === "AGENT365_REGISTRY_DELEGATED_ACCESS_REQUIRED"
        ? readAuthorizationChallenge(response.headers.get("WWW-Authenticate"))
        : undefined,
    );
  }
  return response;
}

async function json<T>(schema: z.ZodType<T>, path: string, method = "GET", body?: unknown, headers?: HeadersInit): Promise<T> {
  const response = await request(path, method, body, headers);
  let raw: unknown;
  try {
    raw = await response.json();
  } catch {
    throw new ApiError("The Gateway returned an unreadable response. Refresh before continuing.", response.status,
      "INVALID_API_RESPONSE", undefined, method !== "GET");
  }
  const parsed = schema.safeParse(raw);
  if (!parsed.success) {
    throw new ApiError("The Gateway response does not match this Console. Refresh or contact your administrator.",
      response.status, "INVALID_API_RESPONSE", undefined, method !== "GET");
  }
  return parsed.data;
}

function mutationHeaders(expectedRowVersion: string, idempotencyKey: string): HeadersInit {
  return { "If-Match": expectedRowVersion, "Idempotency-Key": idempotencyKey };
}

const assignmentReviewSchema = z.object({ operationId: z.string().uuid(), agentId: z.string().uuid(), agentIdentityId: z.string().uuid(), policyId: z.string().uuid(), policyName: z.string(), expiresAtUtc: z.string(), effect: z.string() });
const assignmentListSchema = z.object({ agentId: z.string().uuid(), agentIdentityId: z.string().nullable(), bindingCurrent: z.boolean(), allowObservedAtUtc: z.string().nullable(), blockObservedAtUtc: z.string().nullable(), items: z.array(z.object({ operationId: z.string().uuid(), policyId: z.string().uuid(), policyName: z.string(), status: z.enum(["Pending", "Assigned", "Failed"]), failureCode: z.string().nullable(), confirmedAtUtc: z.string().datetime({ offset: true }).nullable().optional(), expiresAtUtc: z.string().datetime({ offset: true }).optional(), assignedAtUtc: z.string().nullable() })) });
export const api = {
  async listAgentPolicies(agentId: string) {
    const value = await json(assignmentListSchema, `/api/v1/agents/${encodeURIComponent(agentId)}/purview-policies`);
    if (value.agentId !== agentId) throw new ApiError("Agent assignment response mismatch.", 502, "INVALID_API_RESPONSE");
    return value;
  },
  async reviewAgentPolicy(agentId: string, policyId: string, revision: string) {
    const value = await json(assignmentReviewSchema, `/api/v1/agents/${encodeURIComponent(agentId)}/purview-policies/review`, "POST", { policyId, revision });
    if (value.agentId !== agentId || value.policyId !== policyId) throw new ApiError("Assignment review response mismatch.", 502, "INVALID_API_RESPONSE");
    return value;
  },
  async confirmAgentPolicy(agentId: string, operationId: string) {
    const result = await json(z.object({ operationId: z.string().uuid(), status: z.enum(["Pending", "Assigned", "Failed"]) }), `/api/v1/agents/${encodeURIComponent(agentId)}/purview-policies/${encodeURIComponent(operationId)}/confirm`, "POST", {});
    if (result.operationId !== operationId) {
      throw new ApiError("The confirmation did not match the reviewed assignment. Refresh its status before continuing.",
        502, "INVALID_API_RESPONSE", undefined, true);
    }
    return result;
  },
  async getHealth() {
    const response = await request("/health/checks");
    const parsed = z.enum(["Healthy", "Degraded", "Unhealthy"]).safeParse((await response.text()).trim());
    if (!parsed.success) throw new ApiError("The health endpoint returned an unexpected response.", 200, "INVALID_API_RESPONSE");
    return parsed.data;
  },
  listAgents(cursor?: string, search?: string) {
    const query = new URLSearchParams({ limit: "50" });
    if (cursor) query.set("cursor", cursor);
    if (search) query.set("search", search);
    return json(agentListSchema, `/api/v1/agents?${query}`);
  },
  async getAgent(id: string) {
    const result = await json(agentDetailSchema, `/api/v1/agents/${encodeURIComponent(id)}`);
    if (result.agentId !== id) {
      throw new ApiError("The agent response does not match the requested agent. No setup operation was selected.",
        200, "AGENT_MISMATCH");
    }
    return result;
  },
  async findLatestProvisioningOperation(agentId: string) {
    const result = await json(provisioningHistorySchema, `/api/v1/agents/${encodeURIComponent(agentId)}/provisioning-history`);
    if (result.agentId !== agentId) {
      throw new ApiError("The provisioning history does not belong to this agent. No operation was selected.",
        200, "PROVISIONING_HISTORY_MISMATCH");
    }
    // The API orders jobs by creation time, newest first. Do not guess from
    // start time or fall back to an older job when the latest one is unsupported.
    return result.jobs[0]?.operationId ?? null;
  },
  async getRegistrationOperation(operationId: string, agentId: string) {
    if (!operationIdSchema.safeParse(operationId).success) {
      throw new ApiError("The Gateway did not supply a valid operation ID. No operation was requested.",
        200, "INVALID_OPERATION_ID");
    }
    const result = await json(registrationOperationSchema, `/api/v1/operations/${encodeURIComponent(operationId)}`);
    if (result.operationId !== operationId || result.agentId !== agentId) {
      throw new ApiError("The operation does not belong to this agent. Refresh or contact your administrator.",
        200, "OPERATION_MISMATCH");
    }
    return result;
  },
  async completeAgent365Registration(operationId: string, agentId: string) {
    const result = await json(registrationCompletionSchema,
      `/api/v1/operations/${encodeURIComponent(operationId)}:complete-agent365-registration`, "POST");
    if (result.operationId !== operationId || result.agentId !== agentId) {
      throw new ApiError("The completion response did not match this operation. Check current status before continuing.",
        200, "OPERATION_MISMATCH", undefined, true);
    }
    return result;
  },
  async retryProvisioning(agentId: string) {
    const result = await json(
      retryProvisioningSchema,
      `/api/v1/agents/${encodeURIComponent(agentId)}:retry-provisioning`,
      "POST",
    );
    if (result.agentId !== agentId) {
      throw new ApiError("The retry response did not match this agent. Refresh before trying again.",
        200, "AGENT_MISMATCH", undefined, true);
    }
    return result;
  },
  setPromptShield(id: string, enabled: boolean, expectedRowVersion: string) {
    const idempotencyKey = crypto.randomUUID();
    return json(featuresUpdateSchema, `/api/v1/agents/${encodeURIComponent(id)}/features`, "PATCH", {
      promptShieldEnabled: enabled, expectedRowVersion, idempotencyKey,
    }, mutationHeaders(expectedRowVersion, idempotencyKey));
  },
  async listBlueprints() {
    return (await json(blueprintListSchema, "/api/v1/agent-identity-blueprints")).items;
  },
  registerAgent: (body: RegisterAgentRequest) => json(registrationSchema, "/api/v1/agents", "POST", {
    ...body,
    // Data protection is configured separately, never an implicit registration dependency.
    features: { purviewEnabled: false },
  }),
  listCredentials: (id: string) => json(credentialListSchema, `/api/v1/agents/${encodeURIComponent(id)}/credentials`),
  issueCredential: (id: string) => json(issuedCredentialSchema, `/api/v1/agents/${encodeURIComponent(id)}/credentials`, "POST"),
  revokeCredential: (id: string, keyId: string) => json(revokedCredentialSchema,
    `/api/v1/agents/${encodeURIComponent(id)}/credentials/${encodeURIComponent(keyId)}`, "DELETE"),
  async listPurviewPolicies() {
    const catalog = await json(purviewPolicyCatalogSchema, "/api/v1/protection/purview/policies");
    const age = Date.now() - Date.parse(catalog.retrievedAtUtc);
    if (catalog.tenantId !== config.tenantId || age > 300_000 || age < -60_000 || new Set(catalog.items.map(p => p.id)).size !== catalog.items.length) {
      throw new ApiError("A current policy catalog for this tenant could not be confirmed.", 503, "PURVIEW_POLICY_CATALOG_INVALID");
    }
    return catalog;
  },
  getSystemConfig: () => json(systemConfigSchema, "/api/v1/system/config"),
  setPromptShieldDefault(enabled: boolean, expectedRowVersion: string) {
    const idempotencyKey = crypto.randomUUID();
    return json(systemConfigSchema, "/api/v1/system/config", "PATCH", {
      defaultPromptShieldEnabled: enabled, expectedRowVersion, idempotencyKey,
    }, mutationHeaders(expectedRowVersion, idempotencyKey));
  },
};
