// Types mirror the Gateway REST API DTOs (api/v1/*). They are intentionally a
// thin, UI-friendly projection of the backend contracts in Gateway.Contracts.

export type AgentLifecycle =
  | "Draft"
  | "Provisioning"
  | "Active"
  | "AwaitingRegistryHandoff"
  | "Disabled"
  | "Failed";

export type PromptShieldState = "On" | "Off" | "DefaultOn" | "DefaultOff";

export interface Blueprint {
  id: string;
  displayName: string;
  /** Resolved Entra Agent ID blueprint application id. */
  blueprintApplicationId: string;
  /** DLP profile id bound to this blueprint, when configured. */
  dlpProfileId?: string;
  shared: boolean;
}

export interface Agent {
  id: string;
  displayName: string;
  /** External agent id the developer uses at the ingress. */
  externalAgentId: string;
  /** The distinct child Agent 365 identity provisioned under the blueprint. */
  childAgentId?: string;
  blueprint: Blueprint;
  lifecycle: AgentLifecycle;
  promptShield: PromptShieldState;
  createdAtUtc: string;
  lastActivityAtUtc?: string;
  /** Count of interactions in the last 24h (sanitized activity summary). */
  activity24h: number;
  observabilityExport: "Agent365" | "Agent365+AzureMonitor";
}

export type CapabilityStatus = "Installed" | "NotInstalled" | "Degraded";

export interface PurviewConnection {
  status:
    | "Connected"
    | "VerificationFailed"
    | "AwaitingProviderReference"
    | "PendingVerification"
    | "NotConnected";
  tenantId: string;
  automationApplicationId?: string;
  automationServicePrincipalObjectId?: string;
  lastFailureCode?: string;
  lastVerifiedAtUtc?: string;
  sensitiveInformationTypeCount?: number;
  administratorUpn?: string;
}

export type DlpMode = "Enforce" | "SimulationWithTips" | "SimulationWithoutTips" | "Disabled";

export interface DlpProfile {
  id: string;
  blueprintDisplayName: string;
  blueprintApplicationId: string;
  mode: DlpMode;
  selectedSitCount: number;
  minThreshold: number;
  maxThreshold: number;
  readiness: "Ready" | "Pending" | "Expired" | "Failed";
  updatedAtUtc: string;
}

export interface SensitiveInformationType {
  id: string;
  name: string;
  publisher: string;
}

export interface DeploymentHealth {
  api: "Healthy" | "Degraded" | "Unhealthy";
  worker: "Healthy" | "Degraded" | "Unhealthy";
  promptShields: CapabilityStatus;
  purview: CapabilityStatus;
  admissionMode: string;
  region: string;
}

export interface GatewayApi {
  getHealth(): Promise<DeploymentHealth>;
  listAgents(): Promise<Agent[]>;
  getAgent(id: string): Promise<Agent | undefined>;
  setPromptShield(id: string, enabled: boolean): Promise<Agent>;
  listBlueprints(): Promise<Blueprint[]>;
  getPurviewConnection(): Promise<PurviewConnection>;
  recheckPurviewConnection(): Promise<PurviewConnection>;
  listSensitiveInformationTypes(): Promise<SensitiveInformationType[]>;
  listDlpProfiles(): Promise<DlpProfile[]>;
}
