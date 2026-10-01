import type {
  Agent,
  Blueprint,
  DeploymentHealth,
  DlpProfile,
  GatewayApi,
  PurviewConnection,
  SensitiveInformationType,
} from "./types";

// Deterministic demo data that mirrors a real deployment (gw40397-dev). The
// Purview connection intentionally reflects the real-world first-run state:
// certificate sign-in works, but the Security & Compliance service-principal
// reference has not been registered yet, so verification is blocked until an
// administrator runs New-ServicePrincipal once.

const blueprints: Blueprint[] = [
  {
    id: "b1f3c2a0-0001-4a00-9000-000000000001",
    displayName: "Support Copilot blueprint",
    blueprintApplicationId: "78ab9ba2-1adf-4a69-9609-994fc93698f4",
    dlpProfileId: "d1000000-0000-4000-9000-000000000001",
    shared: true,
  },
  {
    id: "b1f3c2a0-0002-4a00-9000-000000000002",
    displayName: "Analytics agent blueprint",
    blueprintApplicationId: "5c2b9a10-2d4e-4f80-ab10-7c1e2f3a4b5c",
    shared: false,
  },
];

let agents: Agent[] = [
  {
    id: "a0000000-0000-4000-9000-000000000001",
    displayName: "Support Copilot",
    externalAgentId: "ext-support-01",
    childAgentId: "agent365-9a2f-support-01",
    blueprint: blueprints[0],
    lifecycle: "Active",
    promptShield: "On",
    createdAtUtc: "2026-09-28T04:12:00Z",
    lastActivityAtUtc: "2026-10-01T13:51:00Z",
    activity24h: 1284,
    observabilityExport: "Agent365+AzureMonitor",
  },
  {
    id: "a0000000-0000-4000-9000-000000000002",
    displayName: "Analytics Assistant",
    externalAgentId: "ext-analytics-02",
    childAgentId: "agent365-71bd-analytics-02",
    blueprint: blueprints[1],
    lifecycle: "Active",
    promptShield: "Off",
    createdAtUtc: "2026-09-30T09:02:00Z",
    lastActivityAtUtc: "2026-10-01T11:20:00Z",
    activity24h: 212,
    observabilityExport: "Agent365",
  },
  {
    id: "a0000000-0000-4000-9000-000000000003",
    displayName: "Onboarding Bot",
    externalAgentId: "ext-onboard-03",
    blueprint: blueprints[0],
    lifecycle: "AwaitingRegistryHandoff",
    promptShield: "DefaultOn",
    createdAtUtc: "2026-10-01T12:40:00Z",
    activity24h: 0,
    observabilityExport: "Agent365",
  },
];

let purview: PurviewConnection = {
  status: "AwaitingProviderReference",
  tenantId: "ff8b1e46-ff0f-4bc2-ab02-caf2b92da496",
  automationApplicationId: "fe396f52-0364-4447-b34b-9018aa7461c4",
  automationServicePrincipalObjectId: "a1a0a04d-8ca9-4168-abe5-942af6549fca",
  lastFailureCode: "PURVIEW_CONNECTION_PROVIDER_UNVERIFIED",
  administratorUpn: "admin@diax48836189.onmicrosoft.com",
};

const sits: SensitiveInformationType[] = [
  { id: "sit-0001", name: "Credit Card Number", publisher: "Microsoft Corporation" },
  { id: "sit-0002", name: "U.S. Social Security Number (SSN)", publisher: "Microsoft Corporation" },
  { id: "sit-0003", name: "Azure Storage Account Key", publisher: "Microsoft Corporation" },
  { id: "sit-0004", name: "EU Passport Number", publisher: "Microsoft Corporation" },
];

const dlpProfiles: DlpProfile[] = [
  {
    id: "d1000000-0000-4000-9000-000000000001",
    blueprintDisplayName: "Support Copilot blueprint",
    blueprintApplicationId: "78ab9ba2-1adf-4a69-9609-994fc93698f4",
    mode: "SimulationWithTips",
    selectedSitCount: 3,
    minThreshold: 1,
    maxThreshold: 10,
    readiness: "Pending",
    updatedAtUtc: "2026-10-01T10:05:00Z",
  },
];

const delay = <T>(value: T, ms = 220): Promise<T> =>
  new Promise((resolve) => setTimeout(() => resolve(value), ms));

export const mockApi: GatewayApi = {
  getHealth: (): Promise<DeploymentHealth> =>
    delay({
      api: "Healthy",
      worker: "Healthy",
      promptShields: "Installed",
      purview: "Degraded",
      admissionMode: "OpenDevelopmentPreview",
      region: "koreacentral",
    }),
  listAgents: () => delay(agents.map((a) => ({ ...a }))),
  getAgent: (id) => delay(agents.find((a) => a.id === id)),
  setPromptShield: (id, enabled) => {
    agents = agents.map((a) =>
      a.id === id ? { ...a, promptShield: enabled ? "On" : "Off" } : a,
    );
    return delay(agents.find((a) => a.id === id)!);
  },
  listBlueprints: () => delay(blueprints.map((b) => ({ ...b }))),
  getPurviewConnection: () => delay({ ...purview }),
  recheckPurviewConnection: () => {
    // Re-check reflects the real behavior: still blocked until the one-time
    // New-ServicePrincipal registration exists. The real client calls the API.
    return delay({ ...purview });
  },
  listSensitiveInformationTypes: () => delay(sits.map((s) => ({ ...s }))),
  listDlpProfiles: () => delay(dlpProfiles.map((p) => ({ ...p }))),
};

// Allow a connected-state demo via ?connected=1 for screenshots/testing.
export function applyDemoOverrides(search: string): void {
  const params = new URLSearchParams(search);
  if (params.get("connected") === "1") {
    purview = {
      ...purview,
      status: "Connected",
      lastFailureCode: undefined,
      lastVerifiedAtUtc: "2026-10-01T14:40:00Z",
      sensitiveInformationTypeCount: sits.length,
    };
  }
}
