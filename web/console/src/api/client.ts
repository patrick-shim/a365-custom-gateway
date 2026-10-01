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

// The real client talks to the Gateway REST API (same-origin /api/v1/*, with
// the browser's OIDC session). It is selected when VITE_USE_MOCK !== "1".
// Until the backend endpoints for the UI-friendly projections are wired, the
// mock implementation backs the Console so the UX is fully runnable offline.

async function getJson<T>(path: string): Promise<T> {
  const res = await fetch(path, {
    headers: { Accept: "application/json" },
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
    headers: { "Content-Type": "application/json", Accept: "application/json" },
    credentials: "same-origin",
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!res.ok) {
    throw new Error(`POST ${path} failed: ${res.status}`);
  }
  return (await res.json()) as T;
}

const liveApi: GatewayApi = {
  getHealth: () => getJson<DeploymentHealth>("/api/v1/system/health"),
  listAgents: () => getJson<Agent[]>("/api/v1/agents"),
  getAgent: (id) => getJson<Agent | undefined>(`/api/v1/agents/${id}`),
  setPromptShield: (id, enabled) =>
    postJson<Agent>(`/api/v1/agents/${id}:${enabled ? "enable" : "disable"}-prompt-shield`),
  listBlueprints: () => getJson<Blueprint[]>("/api/v1/agent-identity-blueprints"),
  getPurviewConnection: () => getJson<PurviewConnection>("/api/v1/protection/purview/connection"),
  recheckPurviewConnection: () =>
    postJson<PurviewConnection>("/api/v1/protection/purview/connection:recheck"),
  listSensitiveInformationTypes: () =>
    getJson<SensitiveInformationType[]>("/api/v1/protection/purview/sensitive-information-types"),
  listDlpProfiles: () => getJson<DlpProfile[]>("/api/v1/protection/purview/dlp-profiles"),
};

const useMock = import.meta.env.VITE_USE_MOCK !== "0";

export const api: GatewayApi = useMock ? mockApi : liveApi;
export const usingMock = useMock;
