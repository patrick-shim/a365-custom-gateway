import { z } from "zod";

// Validate the wire contracts before data reaches a page. Unknown fields are
// allowed so additive API changes do not break older Console releases.
const text = z.string().min(1);
const nullableText = z.string().nullable();
const percentage = z.number().int().min(0).max(100);
export const operationIdSchema = z.string().uuid().regex(/^[0-9a-f-]+$/)
  .refine(value => value !== "00000000-0000-0000-0000-000000000000");
const operationErrorSchema = z.object({ code: nullableText, message: nullableText }).nullable();
const operationStepsSchema = z.array(z.object({ step: text, status: text })).nullable();

export const featuresSchema = z.object({
  observabilityMode: nullableText,
  purviewEnabled: z.boolean().nullable(),
  promptShieldEnabled: z.boolean().nullish(),
  promptShieldEffectivelyEnabled: z.boolean(),
  promptShieldCapabilityStatus: nullableText.optional(),
  agent365ObservabilityEnabled: z.boolean().nullish(),
  azureMonitorExportEnabled: z.boolean().nullish(),
});

const agentSchema = z.object({
  agentId: text,
  externalAgentId: text,
  name: text,
  status: text,
  environment: text,
  agent365: z.object({
    agentId: nullableText,
    blueprintId: nullableText,
    instanceId: nullableText,
    agentIdentityObjectId: nullableText.optional(),
    blueprintObjectId: nullableText.optional(),
  }).nullable(),
  features: featuresSchema.nullable(),
  lastActivityAtUtc: nullableText,
  createdAtUtc: text,
});

export const agentListSchema = z.object({
  items: z.array(agentSchema),
  nextCursor: nullableText,
  totalCount: z.number().nullable(),
});
export const agentDetailSchema = agentSchema.extend({
  rowVersion: text,
  ownerObjectId: text,
  provisioning: z.object({
    currentStep: nullableText,
    percentComplete: percentage,
    lastError: nullableText,
    operationId: text.nullish(),
  }).nullable(),
  retryProvisioning: z.object({
    supported: z.boolean(),
    reason: text,
  }).nullish(),
});
export const retryProvisioningSchema = z.object({
  agentId: text,
  status: nullableText,
  operationId: operationIdSchema,
});
export const registrationOperationSchema = z.object({
  operationId: operationIdSchema,
  agentId: operationIdSchema,
  type: text,
  status: text,
  currentStep: nullableText,
  percentComplete: percentage,
  error: operationErrorSchema,
  steps: operationStepsSchema,
  workflowVersion: z.number().int().optional(),
  legacy: z.boolean().optional(),
  pollingRecommended: z.boolean(),
  requiredAction: nullableText,
  agent365RegistrationCompletionAvailable: z.boolean(),
});
export const provisioningHistorySchema = z.object({
  agentId: operationIdSchema,
  jobs: z.array(z.object({
    operationId: operationIdSchema,
    type: text,
    status: text,
    percentComplete: percentage,
    startedAtUtc: text,
    completedAtUtc: nullableText,
    error: operationErrorSchema,
    steps: operationStepsSchema,
  })).refine(jobs => new Set(jobs.map(job => job.operationId)).size === jobs.length,
    "Provisioning job IDs must be unique."),
});
export const registrationCompletionSchema = z.object({
  operationId: text,
  agentId: text,
  agent365RegistrationId: text,
  status: z.literal("VerificationQueued"),
});
export const featuresUpdateSchema = z.object({
  agentId: text,
  features: featuresSchema,
  updatedAtUtc: text,
});

export const blueprintListSchema = z.object({
  items: z.array(z.object({
    blueprintObjectId: text,
    blueprintClientId: text,
    displayName: text,
    isAgent365Compatible: z.boolean(),
    agent365CompatibilityIssue: nullableText,
  })),
});

export const systemConfigSchema = z.object({
  provisioningMode: text,
  provisioningExecutionEnabled: z.boolean(),
  defaultObservabilityMode: text,
  defaultPromptShieldEnabled: z.boolean(),
  promptShieldAvailable: z.boolean(),
  rowVersion: nullableText,
  registrationDefaults: z.object({
    environment: z.enum(["Development", "Test", "Production"]),
    reason: nullableText,
  }).refine(value => value.environment === "Production" || !!value.reason?.trim(),
    "A non-production registration default requires the server's reason."),
});

const credentialSchema = z.object({
  keyId: text,
  apiKey: text,
  expiresAtUtc: text,
});
export const registrationSchema = z.object({
  agentId: text,
  externalAgentId: text,
  name: text,
  status: text,
  operationId: text,
  gatewayCredential: credentialSchema.nullable(),
});
export const credentialListSchema = z.object({
  agentId: text,
  items: z.array(z.object({
    keyId: text,
    createdAtUtc: text,
    expiresAtUtc: text,
    revokedAtUtc: nullableText,
  })),
});
export const issuedCredentialSchema = z.object({
  agentId: text,
  externalAgentId: text,
  gatewayCredential: credentialSchema,
});
export const revokedCredentialSchema = z.object({
  agentId: text,
  alreadyRevoked: z.boolean(),
});

export type Agent = z.infer<typeof agentSchema>;
export const purviewPolicyCatalogSchema = z.object({
  tenantId: z.string().uuid(), retrievedAtUtc: z.string().datetime({ offset: true }), source: z.literal("Purview"),
  items: z.array(z.object({
    id: z.string().uuid(), displayName: z.string().min(1).max(256), mode: z.string(),
    enforcementPlanes: z.array(z.string()), individualApplicationIds: z.array(z.string().uuid()),
    revision: z.string().regex(/^[a-f0-9]{64}$/),
    compatibility: z.object({ canAssign: z.boolean(), reason: z.string().nullable() }),
  })).max(2048),
});
export type AgentDetail = z.infer<typeof agentDetailSchema>;
export type RegistrationOperation = z.infer<typeof registrationOperationSchema>;
export type Blueprint = z.infer<typeof blueprintListSchema>["items"][number];
export type Registration = z.infer<typeof registrationSchema>;
export type GatewayCredential = z.infer<typeof credentialSchema>;

export interface RegisterAgentRequest {
  externalAgentId: string;
  name: string;
  ownerObjectId: string;
  environment: "Development" | "Test" | "Production";
  blueprint:
    | { mode: "UseExisting"; blueprintObjectId: string }
    | { mode: "CreateNew"; displayName: string };
}
