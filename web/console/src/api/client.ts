import { z } from "zod";
import { getApiToken } from "../auth/msal";
import { config } from "../runtime-config";
import { ApiError, readAuthorizationChallenge } from "./errors";
import {
  acceptedOperationSchema, agentDetailSchema, agentListSchema, blueprintListSchema,
  capabilitiesSchema, confirmationSchema, connectionResponseSchema, credentialListSchema,
  dlpProfilesSchema, featuresUpdateSchema, inventorySchema, issuedCredentialSchema,
  operationResponseSchema, registrationSchema, reviewSchema, revokedCredentialSchema,
  systemConfigSchema, registrationOperationSchema, registrationCompletionSchema,
  provisioningHistorySchema, operationIdSchema,
  type ConnectionReview, type RegisterAgentRequest,
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

export const api = {
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
  async getPurviewConnection() {
    return (await json(connectionResponseSchema, "/api/v1/protection/purview/connection")).connection;
  },
  async reviewPurviewConnection(expectedRowVersion: string): Promise<ConnectionReview> {
    const result = await json(reviewSchema, "/api/v1/protection/purview/connection-operations:review", "POST",
      { tenantId: config.tenantId, expectedRowVersion, verificationMode: "Gateway" }, { "If-Match": expectedRowVersion });
    if (result.review.tenantId !== config.tenantId || result.review.targetIdentifier !== config.tenantId ||
      result.review.targetType !== "PurviewTenantConnection" ||
      result.review.operationType !== "VerifyPurviewTenantConnection" || result.review.verificationMode !== "Gateway") {
      throw new ApiError("The API did not review Gateway-owned verification for this tenant. Update the API and worker before continuing.",
        200, "REVIEW_MISMATCH");
    }
    return { ...result, expectedRowVersion };
  },
  async confirmPurviewConnection(review: ConnectionReview) {
    if (review.review.tenantId !== config.tenantId || review.review.targetIdentifier !== config.tenantId ||
      review.review.targetType !== "PurviewTenantConnection" || review.review.operationType !== "VerifyPurviewTenantConnection" ||
      review.review.verificationMode !== "Gateway") {
      throw new ApiError("Review Gateway-owned verification again before confirming.", 400, "REVIEW_MISMATCH");
    }
    const confirmation = await json(confirmationSchema, "/api/v1/protection/operation-reviews:confirm", "POST", {
      reviewTokenId: review.reviewTokenId, reviewToken: review.reviewToken,
    });
    if (confirmation.confirmationTokenId !== review.reviewTokenId) {
      throw new ApiError("The confirmation did not match this review. Start a new review.", 200, "REVIEW_MISMATCH");
    }
    const idempotencyKey = crypto.randomUUID();
    const accepted = await json(acceptedOperationSchema, "/api/v1/protection/purview/connection-operations", "POST", {
      tenantId: review.review.tenantId, ...confirmation, idempotencyKey,
      expectedRowVersion: review.expectedRowVersion, verificationMode: "Gateway",
    }, mutationHeaders(review.expectedRowVersion, idempotencyKey));
    if (accepted.operationId !== review.reviewTokenId || accepted.status !== "Pending" || accepted.companionLaunch != null) {
      throw new ApiError("Gateway-owned verification was not confirmed. Check the reviewed operation; do not repeat the request.",
        202, "OPERATION_MISMATCH", accepted.correlationId, true);
    }
    return accepted;
  },
  async getProtectionOperation(id: string) {
    const result = (await json(operationResponseSchema, `/api/v1/protection/operations/${encodeURIComponent(id)}`)).operation;
    if (result.id !== id || result.tenantId !== config.tenantId) {
      throw new ApiError("The operation did not match this tenant and request.", 200, "OPERATION_MISMATCH");
    }
    return result;
  },
  listSensitiveInformationTypes: () => json(inventorySchema, "/api/v1/protection/purview/sensitive-information-types"),
  async listDlpProfiles() {
    return (await json(dlpProfilesSchema, "/api/v1/protection/purview/dlp-profiles")).items;
  },
  async getCapabilities() {
    return (await json(capabilitiesSchema, "/api/v1/protection/capabilities")).items;
  },
  getSystemConfig: () => json(systemConfigSchema, "/api/v1/system/config"),
  setPromptShieldDefault(enabled: boolean, expectedRowVersion: string) {
    const idempotencyKey = crypto.randomUUID();
    return json(systemConfigSchema, "/api/v1/system/config", "PATCH", {
      defaultPromptShieldEnabled: enabled, expectedRowVersion, idempotencyKey,
    }, mutationHeaders(expectedRowVersion, idempotencyKey));
  },
};
