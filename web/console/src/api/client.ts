import type {
  Agent,
  Blueprint,
  DeploymentHealth,
  DlpProfile,
  GatewayApi,
  PurviewConnection,
  SensitiveInformationType,
} from "./types";
import { mockApi } from "./mock";
import { config } from "../runtime-config";
import { getApiToken } from "../auth/msal";

// The real client talks to the Gateway REST API (same-origin /api/v1/*), attaching
// the signed-in user's access token. It is selected when runtime config provides a
// client id (container deployment). Local dev with no config uses the mock.

async function authHeaders(): Promise<Record<string, string>> {
  const token = await getApiToken();
  return token ? { Authorization: `Bearer ${token}` } : {};
}

async function getJson<T>(path: string): Promise<T> {
  const res = await fetch(path, {
    headers: { Accept: "application/json", ...(await authHeaders()) },
    credentials: "same-origin",
  });
  if (!res.ok) {
    throw new Error(`GET ${path} failed: ${res.status}`);
  }
  return (await res.json()) as T;
}

async function postJson<T>(path: string, body?: unknown): Promise<T> {
  const res = await fetch(path, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json",
      ...(await authHeaders()),
    },
    credentials: "same-origin",
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!res.ok) {
    throw new Error(`POST ${path} failed: ${res.status}`);
  }
  return (await res.json()) as T;
}

interface RawAgent365 {
  agentId?: string | null;
  blueprintId?: string | null;
  blueprintObjectId?: string | null;
}
interface RawFeatures {
  promptShieldEnabled?: boolean | null;
  promptShieldEffectivelyEnabled?: boolean;
  azureMonitorExportEnabled?: boolean | null;
}
interface RawAgentSummary {
  agentId: string;
  externalAgentId: string;
  name: string;
  status: string;
  agent365?: RawAgent365 | null;
  features?: RawFeatures | null;
  lastActivityAtUtc?: string | null;
  createdAtUtc: string;
}
interface RawAgentList {
  items?: RawAgentSummary[];
}

const lifecycleMap: Record<string, Agent["lifecycle"]> = {
  Draft: "Draft",
  Pending: "Provisioning",
  Provisioning: "Provisioning",
  Active: "Active",
  AwaitingRegistryHandoff: "AwaitingRegistryHandoff",
  AwaitingRegistry: "AwaitingRegistryHandoff",
  Disabled: "Disabled",
  Failed: "Failed",
};

function mapAgent(a: RawAgentSummary): Agent {
  const blueprintId = a.agent365?.blueprintId ?? "";
  const shieldOn = a.features?.promptShieldEffectivelyEnabled ?? a.features?.promptShieldEnabled ?? false;
  const explicit = a.features?.promptShieldEnabled !== null && a.features?.promptShieldEnabled !== undefined;
  return {
    id: a.agentId,
    displayName: a.name,
    externalAgentId: a.externalAgentId,
    childAgentId: a.agent365?.agentId ?? undefined,
    blueprint: {
      id: blueprintId,
      displayName: blueprintId || "—",
      blueprintApplicationId: a.agent365?.blueprintObjectId ?? "",
      shared: false,
    },
    lifecycle: lifecycleMap[a.status] ?? "Provisioning",
    promptShield: explicit ? (shieldOn ? "On" : "Off") : shieldOn ? "DefaultOn" : "DefaultOff",
    createdAtUtc: a.createdAtUtc,
    lastActivityAtUtc: a.lastActivityAtUtc ?? undefined,
    activity24h: 0,
    observabilityExport: a.features?.azureMonitorExportEnabled ? "Agent365+AzureMonitor" : "Agent365",
  };
}

async function safe<T>(work: () => Promise<T>, fallback: T): Promise<T> {
  try {
    return await work();
  } catch {
    return fallback;
  }
}

async function getHealthLive(): Promise<DeploymentHealth> {
  let api: DeploymentHealth["api"] = "Unhealthy";
  try {
    const res = await fetch("/health/checks", { headers: await authHeaders(), credentials: "same-origin" });
    const text = (await res.text()).trim();
    api = res.ok && /healthy/i.test(text) ? "Healthy" : res.ok ? "Degraded" : "Unhealthy";
  } catch {
    api = "Unhealthy";
  }
  return {
    api,
    worker: api,
    promptShields: "Installed",
    purview: "Degraded",
    admissionMode: "OpenDevelopmentPreview",
    region: "koreacentral",
  };
}

const liveApi: GatewayApi = {
  getHealth: () => getHealthLive(),
  listAgents: () => safe(async () => (await getJson<RawAgentList>("/api/v1/agents")).items?.map(mapAgent) ?? [], []),
  getAgent: (id) =>
    safe<Agent | undefined>(async () => mapAgent(await getJson<RawAgentSummary>(`/api/v1/agents/${id}`)), undefined),
  setPromptShield: async (id, enabled) => {
    await postJson(`/api/v1/agents/${id}:${enabled ? "enable" : "disable"}`);
    const current = await getJson<RawAgentSummary>(`/api/v1/agents/${id}`);
    return mapAgent(current);
  },
  listBlueprints: () => safe(() => getJson<Blueprint[]>("/api/v1/agent-identity-blueprints"), []),
  getPurviewConnection: () =>
    safe(() => getJson<PurviewConnection>("/api/v1/protection/purview/connection"), {
      status: "NotConnected",
      tenantId: config.tenantId,
    }),
  recheckPurviewConnection: () =>
    safe(() => postJson<PurviewConnection>("/api/v1/protection/purview/connection:recheck"), {
      status: "NotConnected",
      tenantId: config.tenantId,
    }),
  listSensitiveInformationTypes: () =>
    safe(() => getJson<SensitiveInformationType[]>("/api/v1/protection/purview/sensitive-information-types"), []),
  listDlpProfiles: () => safe(() => getJson<DlpProfile[]>("/api/v1/protection/purview/dlp-profiles"), []),
};

const useMock = config.useMock;

export const api: GatewayApi = useMock ? mockApi : liveApi;
export const usingMock = useMock;
