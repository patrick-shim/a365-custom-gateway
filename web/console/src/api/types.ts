import { z } from "zod";
import { utcTime } from "./display";

// Validate the wire contracts before data reaches a page. Unknown fields are
// allowed so additive API changes do not break older Console releases.
const text = z.string().min(1);
const nullableText = z.string().nullable();

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
    percentComplete: z.number(),
    lastError: nullableText,
    operationId: text.nullish(),
  }).nullable(),
});
export const registrationOperationSchema = z.object({
  operationId: text,
  agentId: text,
  type: text,
  status: text,
  currentStep: nullableText,
  percentComplete: z.number(),
  error: z.object({ code: nullableText, message: nullableText }).nullable(),
  steps: z.array(z.object({ step: text, status: text })).nullable(),
  pollingRecommended: z.boolean(),
  requiredAction: nullableText,
  agent365RegistrationCompletionAvailable: z.boolean(),
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

const connectionSchema = z.object({
  id: text,
  tenantId: text,
  status: text,
  authorityKind: nullableText,
  authorityApplicationId: nullableText,
  authorityServicePrincipalObjectId: nullableText,
  activeInventoryGenerationId: nullableText,
  authorizedAtUtc: nullableText,
  expiresAtUtc: nullableText,
  lastVerifiedAtUtc: nullableText,
  lastFailureCode: nullableText,
  rowVersion: text,
});
export const connectionResponseSchema = z.object({ connection: connectionSchema.nullable() });
export const inventorySchema = z.object({
  generationId: text,
  tenantId: text,
  retrievedAtUtc: text,
  expiresAtUtc: text,
  isExpired: z.boolean(),
  items: z.array(z.object({ id: text, exactName: text, publisher: z.string() })),
});
export const dlpProfilesSchema = z.object({
  items: z.array(z.object({
    id: text,
    blueprintApplicationId: text,
    displayName: text,
    mode: text,
    policyMode: nullableText.optional(),
    status: text,
    sensitiveInformationTypeName: z.string(),
    sensitiveInformationTypes: z.array(z.object({
      sensitiveInformationTypeId: text,
      exactName: text,
    })).nullish(),
    readiness: z.object({ isReady: z.boolean(), blockers: z.array(z.string()) }),
    lastReadbackAtUtc: nullableText,
    rowVersion: text,
  })),
});

export const capabilitiesSchema = z.object({
  items: z.array(z.object({
    id: text,
    capability: text,
    status: text,
    lastFailureCode: nullableText,
    lastReadbackAtUtc: nullableText,
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

export const reviewSchema = z.object({
  reviewTokenId: text,
  reviewToken: text,
  expiresAtUtc: text,
  review: z.object({
    tenantId: text,
    operationType: text,
    targetType: text,
    targetIdentifier: text,
    verificationMode: nullableText.optional(),
    readinessDisclaimer: z.string(),
  }),
});
export const confirmationSchema = z.object({
  confirmationTokenId: text,
  confirmationToken: text,
});
export const acceptedOperationSchema = z.object({
  operationId: text,
  status: text,
  correlationId: text,
  companionLaunch: z.unknown().nullable().optional(),
});
export const operationResponseSchema = z.object({
  operation: z.object({
    id: text,
    type: text,
    tenantId: text,
    targetType: text,
    status: text,
    failureCode: nullableText,
    requiredAction: nullableText,
    requiresManualIntervention: z.boolean(),
    correlationId: text,
    blockers: z.array(z.string()),
    steps: z.array(z.object({ step: text, status: text, failureCode: nullableText })),
  }),
});

export type Agent = z.infer<typeof agentSchema>;
export type AgentDetail = z.infer<typeof agentDetailSchema>;
export type Blueprint = z.infer<typeof blueprintListSchema>["items"][number];
export type PurviewConnection = z.infer<typeof connectionSchema>;
export type Registration = z.infer<typeof registrationSchema>;
export type GatewayCredential = z.infer<typeof credentialSchema>;
export type ConnectionReview = z.infer<typeof reviewSchema> & { expectedRowVersion: string };

export interface RegisterAgentRequest {
  externalAgentId: string;
  name: string;
  ownerObjectId: string;
  environment: "Development" | "Test" | "Production";
  blueprint:
    | { mode: "UseExisting"; blueprintObjectId: string }
    | { mode: "CreateNew"; displayName: string };
}

export function connectionIsUsable(connection: PurviewConnection | null): boolean {
  return connection !== null && connection.status === "Connected" &&
    connection.lastVerifiedAtUtc !== null &&
    (connection.expiresAtUtc === null || utcTime(connection.expiresAtUtc) > Date.now());
}
