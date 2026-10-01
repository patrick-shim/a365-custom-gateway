// The container supplies public Entra settings at startup. Missing settings must
// never turn a live deployment into a demo.

export interface RuntimeConfig {
  clientId: string;
  tenantId: string;
  apiScope: string;
}

declare global {
  interface Window {
    __A365_CONFIG__?: Partial<RuntimeConfig> & { useMock?: boolean };
  }
}

const injected = typeof window !== "undefined" ? window.__A365_CONFIG__ : undefined;

export const config: RuntimeConfig = {
  clientId: injected?.clientId ?? import.meta.env.VITE_CLIENT_ID ?? "",
  tenantId: injected?.tenantId ?? import.meta.env.VITE_TENANT_ID ?? "",
  apiScope: injected?.apiScope ?? import.meta.env.VITE_API_SCOPE ?? "",
};

export function validateConfig(): void {
  if (!config.clientId || !config.tenantId || !config.apiScope || injected?.useMock === true) {
    throw new Error("Console sign-in is not configured. Ask the deployer to check the client ID, tenant ID, and API scope.");
  }
}
