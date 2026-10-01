import { z } from "zod";
import { getApiToken } from "../auth/msal";
import { config } from "../runtime-config";
import { ApiError } from "./errors";
import {
  acceptedOperationSchema, agentDetailSchema, agentListSchema, blueprintListSchema,
  capabilitiesSchema, confirmationSchema, connectionResponseSchema, credentialListSchema,
  dlpProfilesSchema, featuresUpdateSchema, inventorySchema, issuedCredentialSchema,
  operationResponseSchema, registrationSchema, reviewSchema, revokedCredentialSchema,
  systemConfigSchema,
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
  getAgent: (id: string) => json(agentDetailSchema, `/api/v1/agents/${encodeURIComponent(id)}`),
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
      { tenantId: config.tenantId, expectedRowVersion }, { "If-Match": expectedRowVersion });
    if (result.review.tenantId !== config.tenantId || result.review.operationType !== "ConnectPurviewTenant") {
      throw new ApiError("The review did not match this tenant and action. Refresh and review again.", 200, "REVIEW_MISMATCH");
    }
    return { ...result, expectedRowVersion };
  },
  async confirmPurviewConnection(review: ConnectionReview) {
    const confirmation = await json(confirmationSchema, "/api/v1/protection/operation-reviews:confirm", "POST", {
      reviewTokenId: review.reviewTokenId, reviewToken: review.reviewToken,
    });
    const idempotencyKey = crypto.randomUUID();
    return json(acceptedOperationSchema, "/api/v1/protection/purview/connection-operations", "POST", {
      tenantId: review.review.tenantId, ...confirmation, idempotencyKey,
      expectedRowVersion: review.expectedRowVersion,
    }, mutationHeaders(review.expectedRowVersion, idempotencyKey));
  },
  async getProtectionOperation(id: string) {
    return (await json(operationResponseSchema, `/api/v1/protection/operations/${encodeURIComponent(id)}`)).operation;
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
